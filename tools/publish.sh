#!/usr/bin/env bash
#
# Publish an APK into this catalog.
#
#   tools/publish.sh build/app/outputs/apk/release/app-release.apk --role stride --name Stride
#   source tools/r2.env && tools/publish.sh Spotify.apk --name Spotify
#
# Reads versionCode, versionName, minSdk and ABIs out of the APK itself rather than trusting
# anything typed on the command line: a catalog entry that disagrees with the file it points at is
# rejected by the client, and finding that out on a treadmill is a bad time.
#
# WHERE THE BYTES GO IS DECIDED BY --role, because the two kinds of artifact have genuinely
# different lifecycles:
#
#   --role stride  -> a GitHub Release on THIS repo. Our own build, so it wants to sit next to a
#                     tag and release notes, and it costs nothing to serve. It goes on this public
#                     repo rather than Clancey/stride because that repo is private, and release
#                     assets on a private repo need an auth header a treadmill will never have.
#
#   --role app     -> Cloudflare R2. Someone else's build. It does not belong in our git history,
#                     it has no tag of ours to hang off, and it is the one that will actually be
#                     large. See "What belongs in the bucket" in README.md before adding one.
#
# THE ARTIFACT IS UPLOADED BEFORE THE CATALOG IS WRITTEN, always. A catalog entry pointing at
# something not there yet is a failed update on every console that checks in the meantime; an
# uploaded artifact no catalog mentions is invisible and harmless. When only one of the two can
# succeed, it must be the harmless one.
#
# Requires: aapt2 + apksigner (Android SDK build-tools), python3, curl, and either gh (for
# --role stride) or wrangler/npx (for --role app).

set -euo pipefail

RELEASE_REPO="Clancey/stride-catalog"

usage() {
    cat >&2 <<'EOF'
usage: tools/publish.sh <app.apk> [--role stride|app] [--name "Display Name"]
                        [--notes URL] [--backend release|r2|url] [--url URL]
                        [--requires-gms]

  --role     "stride" for Stride itself - prompted, never auto-installed, published
             to a GitHub Release on this repo.
             "app" for anything else - published to Cloudflare R2. Default: app.
  --name     Display name shown in the launcher. Default: the package name.
  --notes    Release notes URL recorded in the catalog entry.
  --backend  Override where the bytes go. Defaults from --role, which is almost
             always what you want.
  --url      Host it yourself and only record the URL. Implies --backend url.
  --requires-gms
             Mark the app as needing Google Play Services. On a console without
             GMS the client then shows it as ineligible with a reason, instead of
             installing an icon that opens to a crash. Do not set this merely
             because the manifest mentions GMS - nearly every mainstream APK does,
             and most degrade gracefully. Set it when the app is known to refuse
             to start without Play Services.
EOF
    exit 2
}

[[ $# -ge 1 ]] || usage
APK="$1"; shift
[[ -f "$APK" ]] || { echo "no such file: $APK" >&2; exit 1; }

ROLE="app"; NAME=""; NOTES=""; URL_OVERRIDE=""; BACKEND=""; REQUIRES_GMS="false"
# Which config splits to publish from a bundle. These match the consoles we know: arm64, English,
# xhdpi. Installing more than one ABI in a session is rejected by the platform, so this is a
# choice that has to be made somewhere - better here, visibly, than silently at install time.
SPLIT_SELECT="config.arm64_v8a,config.en,config.xhdpi"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)    ROLE="${2:-}"; shift 2 ;;
        --name)    NAME="${2:-}"; shift 2 ;;
        --notes)   NOTES="${2:-}"; shift 2 ;;
        --backend) BACKEND="${2:-}"; shift 2 ;;
        --url)     URL_OVERRIDE="${2:-}"; BACKEND="url"; shift 2 ;;
        --requires-gms) REQUIRES_GMS="true"; shift ;;
        --splits) SPLIT_SELECT="${2:-}"; shift 2 ;;
        *) usage ;;
    esac
done
[[ "$ROLE" == "stride" || "$ROLE" == "app" ]] || usage

# The role picks the store unless explicitly overridden.
if [[ -z "$BACKEND" ]]; then
    [[ "$ROLE" == "stride" ]] && BACKEND="release" || BACKEND="r2"
fi
[[ "$BACKEND" =~ ^(release|r2|url)$ ]] || usage

# aapt2 and apksigner ship inside the SDK's build-tools and are almost never on PATH. Find the
# newest build-tools dir ourselves rather than making every caller export PATH first - forgetting
# that is the single most likely reason this script fails for someone else.
if ! command -v aapt2 >/dev/null 2>&1 || ! command -v apksigner >/dev/null 2>&1; then
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    [[ -n "$sdk" && -d "$sdk/build-tools" ]] || continue
    # `sort -V` so 36.1.0 beats 9.0.0; without it a lexical sort picks the oldest.
    bt="$(find "$sdk/build-tools" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1)"
    [[ -n "$bt" && -x "$bt/aapt2" ]] || continue
    PATH="$bt:$PATH"
    break
  done
fi

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need python3; need curl
command -v aapt2 >/dev/null 2>&1 && command -v apksigner >/dev/null 2>&1 || {
  echo "missing aapt2/apksigner. Install Android SDK build-tools, or set ANDROID_HOME." >&2
  exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/catalog.json"
# shellcheck source=tools/r2-lib.sh
source "$ROOT/tools/r2-lib.sh"

# ------------------------------------------------------------------ read the APK

# Detect split bundles (XAPK/APKM) and unpack them.
#
# These are a zip *of* APKs - a base plus config.<abi>, config.<dpi> and per-language splits - not
# an APK. aapt2 fails on them only with "could not identify format of APK", which reads like a
# corrupt download rather than "this is a different format", so it is identified properly here.
#
# The discriminator is a root AndroidManifest.xml: every real APK has one, no bundle does. Member
# filenames are not reliable - the base inside an XAPK is often named <package>.apk, not base.apk.
#
# The listing is captured once rather than piped straight into grep: under `set -o pipefail`, a
# `grep -q` that exits early on a match hands unzip a SIGPIPE, and the pipeline then reports
# failure precisely when the manifest *was* found - inverting this check on every valid APK.
SPLIT_FILES=()
# name|url|sha256|sizeBytes for each published split, consumed by the catalog writer below.
SPLIT_META=()
ZIP_LISTING="$(unzip -l "$APK" 2>/dev/null || true)"
if ! grep -qE '(^| )AndroidManifest\.xml$' <<<"$ZIP_LISTING"; then
    MEMBERS="$(sed -n 's/^ *[0-9][0-9]*  *[^ ]*  *[^ ]*  *\(.*\.apk\)$/\1/p' <<<"$ZIP_LISTING")"
    [[ -n "$MEMBERS" ]] || die "$(basename "$APK") has no AndroidManifest.xml and contains no APKs - corrupt?"

    BUNDLE_DIR="$(mktemp -d)"
    trap 'rm -rf "$BUNDLE_DIR"' EXIT
    unzip -q -o "$APK" -d "$BUNDLE_DIR"

    # The base is the member that is itself a real APK with a root manifest. Identify it by
    # inspection rather than by name, for the same reason as above.
    BASE=""
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        [[ "$(basename "$m")" != config.* ]] || continue
        # Captured into a variable first, for the pipefail/SIGPIPE reason documented above: piping
        # unzip straight into `grep -q` inverts this test on exactly the member we are looking for.
        member_listing="$(unzip -l "$BUNDLE_DIR/$m" 2>/dev/null || true)"
        if grep -qE '(^| )AndroidManifest\.xml$' <<<"$member_listing"; then
            BASE="$BUNDLE_DIR/$m"
            break
        fi
    done <<<"$MEMBERS"
    [[ -n "$BASE" ]] || die "could not find a base APK inside $(basename "$APK")"

    # Only the splits this hardware can use. Installing every ABI at once is rejected by the
    # platform, and shipping ten languages would triple the download for a console that shows one.
    # Overridable with --splits for a device that needs different ones.
    for want in ${SPLIT_SELECT//,/ }; do
        for m in $MEMBERS; do
            if [[ "$(basename "$m" .apk)" == "$want" ]]; then
                SPLIT_FILES+=("$BUNDLE_DIR/$m")
                break
            fi
        done
    done

    echo "split bundle: base $(basename "$BASE") + ${#SPLIT_FILES[@]} split(s)" >&2
    for s in "${SPLIT_FILES[@]}"; do echo "  $(basename "$s")" >&2; done
    [[ ${#SPLIT_FILES[@]} -gt 0 ]] || die "none of the requested splits ($SPLIT_SELECT) are in this bundle.
Available:
$(sed 's/^/  /' <<<"$MEMBERS")
Choose with --splits name1,name2"

    # Everything downstream describes the app from the base APK.
    APK="$BASE"
fi

BADGING="$(aapt2 dump badging "$APK")"

# Read fields off the badging line by FIRST match, not with a greedy `.*key=`.
#
# The package line ends with fields that contain the earlier keys as substrings:
#
#   package: name='com.netflix.mediaclient' versionCode='64377' ... compileSdkVersionCodename='16'
#
# A greedy `.*name='\([^']*\)'` anchors on the last `name='` on that line - which is the tail of
# `compileSdkVersionCodename` - and silently yields "16" as the package name. That produces a
# plausible-looking catalog entry and an R2 key of apks/16/16-64377.apk, and every app sharing a
# compile SDK then collides on one package id and overwrites the others in the catalog.
pkg_field() {
    grep -m1 '^package:' <<<"$BADGING" \
        | grep -o "$1='[^']*'" \
        | head -1 \
        | sed "s/^$1='//; s/'\$//"
}

PACKAGE="$(pkg_field name)"
VERSION_CODE="$(pkg_field versionCode)"
VERSION_NAME="$(pkg_field versionName)"
# aapt2 writes this one as `minSdkVersion:'28'` on its own line - a colon, not an equals sign.
MIN_SDK="$(sed -n "s/^minSdkVersion:'\([^']*\)'.*/\1/p" <<<"$BADGING" | head -1)"
[[ -n "$MIN_SDK" ]] || MIN_SDK=0
ABIS="$(sed -n "s/^native-code: //p" <<<"$BADGING" | tr -d "'" | tr ' ' '\n' | grep -v '^$' | paste -sd, - || true)"
# A bundle's base APK carries no native code - it lives in the config.<abi> split. Read the ABI
# back off the split names we selected, or the entry would claim to support no architecture at all.
if [[ -z "$ABIS" && ${#SPLIT_FILES[@]} -gt 0 ]]; then
    for f in "${SPLIT_FILES[@]}"; do
        sname="$(basename "$f" .apk)"
        case "$sname" in
            config.arm64_v8a)   ABIS="${ABIS:+$ABIS,}arm64-v8a" ;;
            config.armeabi_v7a) ABIS="${ABIS:+$ABIS,}armeabi-v7a" ;;
            config.x86_64)      ABIS="${ABIS:+$ABIS,}x86_64" ;;
            config.x86)         ABIS="${ABIS:+$ABIS,}x86" ;;
        esac
    done
fi

# Validate rather than trust. Every one of these fired as a silent wrong value at least once while
# this script was being written, and a wrong package name is not a cosmetic problem: it is the R2
# key, the catalog identity, and what the console matches against what it has installed.
[[ "$PACKAGE" == *.* && "$PACKAGE" != *" "* ]] \
    || { echo "implausible package name '$PACKAGE' parsed from $APK - refusing" >&2; exit 1; }
[[ "$VERSION_CODE" =~ ^[0-9]+$ ]] \
    || { echo "implausible versionCode '$VERSION_CODE' parsed from $APK - refusing" >&2; exit 1; }
[[ "$MIN_SDK" =~ ^[0-9]+$ ]] && (( MIN_SDK > 0 )) \
    || { echo "could not read minSdkVersion from $APK (got '$MIN_SDK') - refusing, since a" >&2;
         echo "missing minSdk would offer this app to consoles too old to install it." >&2; exit 1; }
[[ -n "$NAME" ]] || NAME="$PACKAGE"

# The signer digest is the check that matters. Android will refuse to *update* an installed app
# with a differently-signed APK, but it says nothing about a first install - which is exactly
# where a compromised catalog could hand a console an impostor.
SIGNER="$(apksigner verify --print-certs "$APK" \
    | sed -n 's/.*SHA-256 digest: *\([0-9a-fA-F]*\).*/\1/p' | head -1 | tr 'A-F' 'a-f')"
[[ ${#SIGNER} -eq 64 ]] || { echo "could not read a signing certificate from $APK (is it signed?)" >&2; exit 1; }

SHA="$(sha256_of "$APK")"
SIZE="$(wc -c <"$APK" | tr -d ' ')"
ARTIFACT="$PACKAGE-$VERSION_CODE.apk"

# The client requires a strictly greater versionCode, and a downgrade will not install on a
# non-rooted device anyway. Catching it here beats shipping a catalog that quietly does nothing.
PREVIOUS="$(python3 - "$CATALOG" "$PACKAGE" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as handle:
        catalog = json.load(handle)
except (OSError, ValueError):
    sys.exit(0)
for app in catalog.get("apps", []):
    if app.get("package") == sys.argv[2]:
        print(app.get("versionCode", 0))
        break
PY
)"
if [[ -n "$PREVIOUS" ]] && (( VERSION_CODE < PREVIOUS )); then
    echo "refusing: versionCode $VERSION_CODE is lower than the published $PREVIOUS for $PACKAGE." >&2
    echo "it would not install over the newer build already out there." >&2
    exit 1
fi
if [[ -n "$PREVIOUS" ]] && (( VERSION_CODE == PREVIOUS )); then
    echo "note: versionCode $VERSION_CODE is already published for $PACKAGE - a no-op for any" >&2
    echo "console that already has it, since consoles compare versionCode." >&2
fi

# ------------------------------------------------------------- upload, then record

case "$BACKEND" in
    release)
        need gh
        TAG="stride-$VERSION_CODE"
        if ! gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
            echo "creating release $TAG on $RELEASE_REPO" >&2
            gh release create "$TAG" \
                --repo "$RELEASE_REPO" \
                --title "Stride $VERSION_NAME ($VERSION_CODE)" \
                --notes "Stride $VERSION_NAME, versionCode $VERSION_CODE.

Published by tools/publish.sh. The catalog entry in catalog.json pins the sha256 and
signing certificate of the asset attached here; a console verifies both before installing." \
                >/dev/null
        fi

        # Upload from a correctly-named copy. `gh release upload file#label` sets the display
        # LABEL, not the asset filename - and the download URL is built from the filename. Passing
        # the raw build output would publish it as "app-release.apk", making the catalog URL depend
        # on what the local build tree happened to call the file, and colliding across builds.
        STAGE="$(mktemp -d)"
        trap 'rm -rf "$STAGE"' EXIT
        cp "$APK" "$STAGE/$ARTIFACT"

        # No --clobber, deliberately. A release asset is immutable here for the same reason an R2
        # key is: the catalog pins a sha256, and replacing bytes under a URL some console has
        # already read breaks its update path. A changed build is a new versionCode.
        echo "uploading $ARTIFACT to $RELEASE_REPO@$TAG" >&2
        if ! gh release upload "$TAG" "$STAGE/$ARTIFACT" --repo "$RELEASE_REPO" 2>/dev/null; then
            echo "note: $ARTIFACT already attached to $TAG - leaving the published bytes alone." >&2
            echo "if this build differs from the published one, bump versionCode." >&2
        fi
        URL="https://github.com/$RELEASE_REPO/releases/download/$TAG/$ARTIFACT"
        ;;
    r2)
        r2_require_env || exit 1
        KEY="$(r2_apk_key "$PACKAGE" "$VERSION_CODE")"
        echo "uploading to r2://$R2_BUCKET/$KEY" >&2
        r2_put "$APK" "$KEY" "$R2_APK_TYPE" "$R2_APK_CACHE"
        URL="$(r2_public_url "$KEY")"

        # Splits go beside the base under the same package/versionCode prefix, so everything for
        # one install is deleted or audited together.
        for f in "${SPLIT_FILES[@]}"; do
            sname="$(basename "$f" .apk)"
            skey="apks/$PACKAGE/$PACKAGE-$VERSION_CODE-$sname.apk"
            echo "uploading split to r2://$R2_BUCKET/$skey" >&2
            r2_put "$f" "$skey" "$R2_APK_TYPE" "$R2_APK_CACHE"
            SPLIT_META+=("$sname|$(r2_public_url "$skey")|$(sha256_of "$f")|$(wc -c <"$f" | tr -d " ")")
        done
        ;;
    url)
        URL="$URL_OVERRIDE"
        ;;
esac
[[ "$URL" == https://* ]] || { echo "artifact url must be https: $URL" >&2; exit 1; }

# Read it back exactly the way a treadmill would, before writing a catalog entry that promises it
# works. An upload that succeeds but is not publicly readable - a private repo, a bucket with no
# public access, an unbound custom domain - fails here rather than on the hardware.
if [[ "$BACKEND" != "url" ]]; then
    echo "verifying published bytes..." >&2
    TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
    curl -fsSL --max-time 900 -o "$TMP" "$URL" \
        || { echo "published artifact is not publicly fetchable at $URL" >&2; exit 1; }
    FETCHED="$(sha256_of "$TMP")"
    [[ "$FETCHED" == "$SHA" ]] \
        || { echo "sha256 mismatch after upload: local $SHA, published $FETCHED" >&2; exit 1; }
    echo "  ok - serves the expected bytes" >&2
fi

python3 - "$CATALOG" <<PY
import json, sys, datetime

path = sys.argv[1]
try:
    with open(path) as handle:
        catalog = json.load(handle)
except (OSError, ValueError):
    catalog = {}

entry = {
    "package": "$PACKAGE",
    "role": "$ROLE",
    "name": "$NAME",
    "versionCode": int("$VERSION_CODE"),
    "versionName": "$VERSION_NAME",
    "minSdk": int("$MIN_SDK"),
    "abis": [a for a in "$ABIS".split(",") if a],
    "url": "$URL",
    "sizeBytes": int("$SIZE"),
    "sha256": "$SHA",
    "signerSha256": "$SIGNER",
}
if "$REQUIRES_GMS" == "true":
    entry["requiresGms"] = True

# Config splits, if this came from an app bundle. Passed as name|url|sha256|size lines rather than
# as JSON because assembling nested JSON in shell is how quoting bugs get published.
splits = []
for line in """$(printf '%s\n' "${SPLIT_META[@]+"${SPLIT_META[@]}"}")""".splitlines():
    line = line.strip()
    if not line:
        continue
    name, url, sha, size = line.split("|")
    splits.append({"name": name, "url": url, "sha256": sha, "sizeBytes": int(size)})
if splits:
    entry["splits"] = splits

notes = "$NOTES"
if notes:
    entry["releaseNotesUrl"] = notes

# One entry per package: the client rejects a catalog with duplicates outright, because it is
# ambiguous about what would actually be installed.
apps = [a for a in catalog.get("apps", []) if a.get("package") != entry["package"]]
apps.append(entry)
apps.sort(key=lambda a: (a.get("role") != "stride", a.get("package", "")))

catalog["schema"] = 1
catalog["generated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
catalog["apps"] = apps

with open(path, "w") as handle:
    json.dump(catalog, handle, indent=2)
    handle.write("\n")
PY

cat <<EOF

published $PACKAGE $VERSION_NAME (versionCode $VERSION_CODE) via $BACKEND
  url        $URL
  size       $SIZE
  sha256     $SHA
  signer     $SIGNER

next: tools/verify.sh                        # prove the whole catalog resolves
      git add -A && git commit && git push   # publish the decision
EOF
