#!/usr/bin/env bash
#
# Shared R2 plumbing for the publish and verify scripts.
#
# Sourced, not executed. Everything here is about one rule:
#
#   AN OBJECT KEY IS IMMUTABLE.
#
# The catalog pins a sha256 for every artifact. If you overwrite the bytes behind a key that some
# console has already read a digest for, that console fails verification and stops updating - and
# a CDN edge may go on serving either version for as long as its TTL. There is no "republish"
# operation here on purpose. A changed APK is a new versionCode.

r2_require_env() {
    local missing=0
    for var in R2_ACCOUNT_ID R2_BUCKET R2_PUBLIC_BASE; do
        if [[ -z "${!var:-}" ]]; then
            echo "missing \$$var - see tools/r2.env.example" >&2
            missing=1
        fi
    done
    if [[ "${R2_PUBLIC_BASE:-}" != https://* ]]; then
        echo "\$R2_PUBLIC_BASE must be https (got '${R2_PUBLIC_BASE:-}')" >&2
        missing=1
    fi
    if [[ "${R2_PUBLIC_BASE:-}" == */ ]]; then
        echo "\$R2_PUBLIC_BASE must not end in a slash" >&2
        missing=1
    fi
    [[ $missing -eq 0 ]] || return 1
}

r2_wrangler() {
    if command -v wrangler >/dev/null 2>&1; then
        CLOUDFLARE_ACCOUNT_ID="$R2_ACCOUNT_ID" wrangler "$@"
    else
        CLOUDFLARE_ACCOUNT_ID="$R2_ACCOUNT_ID" npx --yes wrangler@4 "$@"
    fi
}

# The URL a console will use for a given key.
r2_public_url() { printf '%s/%s' "$R2_PUBLIC_BASE" "$1"; }

# Existence check over the *public* URL rather than the S3 API.
#
# This deliberately answers the question that matters - "can a treadmill fetch this?" - which also
# catches a bucket that was never made public, a custom domain that is not bound, and a token that
# can write objects nobody can read. An API-side check would pass in all three cases.
#
# Echoes the remote length on stdout when present. Returns 1 when absent.
r2_remote_size() {
    local url headers status
    url="$(r2_public_url "$1")"
    headers="$(curl -fsS -I --max-time 30 "$url" 2>/dev/null)" || return 1
    status="$(printf '%s' "$headers" | head -1)"
    case "$status" in
        *" 200"*) ;;
        *) return 1 ;;
    esac
    printf '%s' "$headers" \
        | tr -d '\r' \
        | sed -n 's/^[Cc]ontent-[Ll]ength: *//p' \
        | tail -1
}

r2_exists() { r2_remote_size "$1" >/dev/null 2>&1; }

# Upload, refusing to clobber.
#
#   r2_put <local-file> <key> <content-type> <cache-control>
#
# The guard is not paranoia about fat fingers; it is the only thing standing between a re-run of
# publish.sh and a fleet that can no longer verify its downloads.
r2_put() {
    local file="$1" key="$2" ctype="$3" cache="$4"
    local local_size remote_size

    local_size="$(wc -c <"$file" | tr -d ' ')"

    if remote_size="$(r2_remote_size "$key")"; then
        if [[ "$remote_size" == "$local_size" ]]; then
            echo "  = $key already present ($remote_size bytes), skipping" >&2
            return 0
        fi
        cat >&2 <<EOF

REFUSING TO OVERWRITE $key

  already in R2 : $remote_size bytes
  about to push : $local_size bytes

An object key is immutable here. Some console may already hold a catalog pinning the
sha256 of the bytes currently at this key; replacing them breaks its update path, and
a cached edge copy can keep serving the old bytes regardless.

Bump versionCode in the APK and publish that instead.
EOF
        return 1
    fi

    echo "  + $key ($local_size bytes)" >&2
    r2_wrangler r2 object put "$R2_BUCKET/$key" \
        --file "$file" \
        --content-type "$ctype" \
        --cache-control "$cache" \
        --remote >/dev/null
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Artifacts are content-pinned by the catalog and keyed by versionCode, so they can be cached
# forever. The catalog itself is the only mutable thing in the system.
# shellcheck disable=SC2034  # consumed by publish.sh, which sources this file
readonly R2_APK_CACHE="public, max-age=31536000, immutable"
# shellcheck disable=SC2034  # consumed by publish.sh, which sources this file
readonly R2_APK_TYPE="application/vnd.android.package-archive"

# apks/<package>/<package>-<versionCode>.apk
#
# Grouped by package so a lifecycle rule or a human can reason about one app's history, and keyed
# by versionCode because that is the identity the client actually compares. The digest is not in
# the key: it would make the layout unreadable, and the immutability guard above plus the catalog's
# sha256 already cover what a content-addressed key would buy.
r2_apk_key() { printf 'apks/%s/%s-%s.apk' "$1" "$1" "$2"; }

extract_icon() {
    # Produce a PNG for the store to show next to an app that is not installed yet.
    #
    # aapt2 lists one icon per density as `application-icon-<dpi>:'res/...'`. The obvious approach -
    # take the highest-density entry that ends in .png - silently yields *nothing* for essentially
    # every modern app, because they all ship an adaptive icon and the path is a compiled binary
    # `.xml`. That is how the catalog ended up with sixteen apps and zero icons: the fallback was
    # working exactly as written, and what it fell back to was a letter tile every time.
    #
    # So handle both. A raster icon is used as-is; an adaptive one is flattened here by resolving
    # its <background> and <foreground> layers back to raster resources and compositing them the
    # way the launcher would, including the 108dp -> 72dp safe-zone crop. A vector layer is still
    # out of reach without a renderer, and still falls back to a letter tile.
    local out="$1"
    local best=""
    while IFS= read -r line; do
        local path="${line#*:}"
        path="${path//\'/}"
        case "$path" in *.png|*.webp) best="$path" ;; esac
    done < <(grep -o "^application-icon-[0-9]*:'[^']*'" <<<"$BADGING" | sort -t- -k3 -n)

    if [[ -n "$best" ]]; then
        unzip -p "$APK" "$best" > "$out" 2>/dev/null || return 1
        [[ -s "$out" ]] || return 1
        return 0
    fi

    # No raster at any density: this is an adaptive icon. Find its xml and flatten it.
    local xml
    xml="$(grep -o "^application-icon-[0-9]*:'[^']*\.xml'" <<<"$BADGING" | tail -1 || true)"
    xml="${xml#*:}"
    xml="${xml//\'/}"
    [[ -n "$xml" ]] || return 1

    local tree
    tree="$(aapt2 dump xmltree --file "$xml" "$APK" 2>/dev/null)" || return 1

    # Layer ids in declaration order: <background> then <foreground>.
    local ids
    ids="$(grep -oE 'android:drawable\(0x[0-9a-f]+\)=@0x[0-9a-f]+' <<<"$tree" | sed 's/.*=@//')"
    local bg_id fg_id
    bg_id="$(sed -n 1p <<<"$ids")"
    fg_id="$(sed -n 2p <<<"$ids")"
    [[ -n "$fg_id" ]] || return 1

    local res
    res="$(aapt2 dump resources "$APK" 2>/dev/null)" || return 1

    # Highest-density raster for one resource id. Densities are listed low to high, so take the last.
    layer_path() {
        [[ -n "$1" ]] || return 1
        awk -v id="$1" '
            $0 ~ ("^ *resource " id " ") { grab = 1; next }
            grab && /^ *resource /       { exit }
            grab && /\(file\) res\// {
                for (i = 1; i <= NF; i++) if ($i ~ /^res\//) last = $i
            }
            END { if (last != "") print last }
        ' <<<"$res"
    }

    local fg bg
    fg="$(layer_path "$fg_id")"
    bg="$(layer_path "$bg_id")"
    # A vector foreground has no (file) res/ raster; there is nothing to composite.
    [[ -n "$fg" ]] || return 1
    case "$fg" in *.xml) return 1 ;; esac

    local dir
    dir="$(dirname "$out")"
    unzip -p "$APK" "$fg" > "$dir/fg.bin" 2>/dev/null || return 1
    if [[ -n "$bg" && "$bg" != *.xml ]]; then
        unzip -p "$APK" "$bg" > "$dir/bg.bin" 2>/dev/null || true
    fi

    ICON_FG="$dir/fg.bin" ICON_BG="$dir/bg.bin" ICON_OUT="$out" python3 - <<'PYICON' || return 1
import os, sys
try:
    from PIL import Image
except ImportError:
    sys.exit(1)

fg_path, bg_path, out = os.environ["ICON_FG"], os.environ["ICON_BG"], os.environ["ICON_OUT"]
fg = Image.open(fg_path).convert("RGBA")
size = fg.size

base = Image.new("RGBA", size, (255, 255, 255, 0))
if os.path.exists(bg_path) and os.path.getsize(bg_path) > 0:
    try:
        bg = Image.open(bg_path).convert("RGBA").resize(size, Image.LANCZOS)
        base.alpha_composite(bg)
    except Exception:
        pass
base.alpha_composite(fg)

# An adaptive icon is authored on a 108dp canvas of which only the middle 72dp is guaranteed
# visible; the launcher crops the rest. Skipping this leaves every icon floating in a wide margin.
inset = round(size[0] * (108 - 72) / 2 / 108)
base = base.crop((inset, inset, size[0] - inset, size[1] - inset))
base.thumbnail((192, 192), Image.LANCZOS)
base.save(out, "PNG", optimize=True)
PYICON

    rm -f "$dir/fg.bin" "$dir/bg.bin"
    [[ -s "$out" ]] || return 1
    return 0
}
