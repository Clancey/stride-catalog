#!/usr/bin/env bash
#
# Publish an APK into this catalog.
#
#   tools/publish.sh path/to/app-release.apk --role stride --name Stride
#
# Reads versionCode, versionName, minSdk and ABIs out of the APK itself rather than trusting
# anything typed on the command line: a catalog entry that disagrees with the file it points at is
# rejected by the client, and finding that out on a treadmill is a bad time.
#
# Requires: apksigner and aapt2 (Android SDK build-tools), python3.

set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/Clancey/stride-catalog/main/apks"

usage() {
    cat >&2 <<'EOF'
usage: tools/publish.sh <app.apk> [--role stride|app] [--name "Display Name"]
                        [--notes URL] [--url URL]

  --role   "stride" for Stride itself (prompted, never auto-installed),
           "app" for anything else. Default: app.
  --name   Display name shown in the launcher. Default: the package name.
  --notes  Release notes URL.
  --url    Override the artifact URL. Use this when hosting the APK elsewhere
           (a GitHub Release asset, say) instead of committing it to apks/.
EOF
    exit 2
}

[[ $# -ge 1 ]] || usage
APK="$1"; shift
[[ -f "$APK" ]] || { echo "no such file: $APK" >&2; exit 1; }

ROLE="app"
NAME=""
NOTES=""
URL_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)  ROLE="${2:-}"; shift 2 ;;
        --name)  NAME="${2:-}"; shift 2 ;;
        --notes) NOTES="${2:-}"; shift 2 ;;
        --url)   URL_OVERRIDE="${2:-}"; shift 2 ;;
        *) usage ;;
    esac
done
[[ "$ROLE" == "stride" || "$ROLE" == "app" ]] || usage

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need python3
need aapt2
need apksigner

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/catalog.json"

BADGING="$(aapt2 dump badging "$APK")"
extract() { sed -n "s/.*$1='\([^']*\)'.*/\1/p" <<<"$BADGING" | head -1; }

PACKAGE="$(grep -m1 '^package:' <<<"$BADGING" | sed -n "s/.*name='\([^']*\)'.*/\1/p")"
VERSION_CODE="$(grep -m1 '^package:' <<<"$BADGING" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p")"
VERSION_NAME="$(grep -m1 '^package:' <<<"$BADGING" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p")"
MIN_SDK="$(extract sdkVersion)"
[[ -n "$MIN_SDK" ]] || MIN_SDK=0
ABIS="$(sed -n "s/^native-code: //p" <<<"$BADGING" | tr -d "'" | tr ' ' '\n' | grep -v '^$' | paste -sd, -)"
[[ -n "$PACKAGE" && -n "$VERSION_CODE" ]] || { echo "could not read package metadata from $APK" >&2; exit 1; }
[[ -n "$NAME" ]] || NAME="$PACKAGE"

# The signer digest is the check that matters. Android will refuse to *update* an installed app with
# a differently-signed APK, but it says nothing about a first install - which is exactly where a
# compromised catalog could hand a console an impostor.
SIGNER="$(apksigner verify --print-certs "$APK" \
    | sed -n 's/.*SHA-256 digest: *\([0-9a-fA-F]*\).*/\1/p' | head -1 | tr 'A-F' 'a-f')"
[[ ${#SIGNER} -eq 64 ]] || { echo "could not read a signing certificate from $APK (is it signed?)" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then
    SHA="$(sha256sum "$APK" | cut -d' ' -f1)"
else
    SHA="$(shasum -a 256 "$APK" | cut -d' ' -f1)"
fi
SIZE="$(python3 -c 'import os,sys;print(os.path.getsize(sys.argv[1]))' "$APK")"

ARTIFACT="$PACKAGE-$VERSION_CODE.apk"
if [[ -n "$URL_OVERRIDE" ]]; then
    URL="$URL_OVERRIDE"
else
    mkdir -p "$ROOT/apks"
    cp "$APK" "$ROOT/apks/$ARTIFACT"
    URL="$RAW_BASE/$ARTIFACT"
fi
[[ "$URL" == https://* ]] || { echo "artifact url must be https: $URL" >&2; exit 1; }

python3 - "$CATALOG" <<PY
import json, sys, datetime

path = sys.argv[1]
with open(path) as handle:
    catalog = json.load(handle)

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

echo "published $PACKAGE $VERSION_NAME ($VERSION_CODE)"
echo "  url        $URL"
echo "  sha256     $SHA"
echo "  signer     $SIGNER"
echo
echo "review catalog.json, then: git add -A && git commit && git push"
