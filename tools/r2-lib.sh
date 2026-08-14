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
