#!/usr/bin/env bash
#
# Add an iconUrl to catalog entries that do not have one, from APKs you already have locally.
#
# Why this exists as its own script: `publish.sh` extracts the icon while it publishes, so an entry
# published before the extractor understood adaptive icons has no iconUrl and no way to get one
# short of re-uploading the whole APK. That is tens of megabytes and a new versionCode's worth of
# churn to fix a picture. This uploads only the icon and patches only that one field.
#
# Usage:
#   set -a; source tools/r2.env; set +a
#   tools/backfill-icons.sh <dir-with-apks> [more dirs...]
#
# APKs are matched to catalog entries by the package name aapt2 reads out of them, not by filename,
# so a directory of arbitrarily named APKs is fine. Entries that already have an icon are skipped;
# pass --force to redo them.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CATALOG="$ROOT/catalog.json"

# shellcheck source=r2-lib.sh
source "$HERE/r2-lib.sh"

FORCE=0
DIRS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) DIRS+=("$1"); shift ;;
    esac
done
[[ ${#DIRS[@]} -gt 0 ]] || { echo "usage: $0 [--force] <dir-with-apks>..." >&2; exit 2; }

# aapt2 ships inside the SDK build-tools and is almost never on PATH.
if ! command -v aapt2 >/dev/null 2>&1; then
    for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
        [[ -n "$sdk" && -d "$sdk/build-tools" ]] || continue
        bt="$(ls -d "$sdk/build-tools"/* 2>/dev/null | sort -V | tail -1)"
        [[ -n "$bt" && -x "$bt/aapt2" ]] || continue
        PATH="$bt:$PATH"
        break
    done
fi
command -v aapt2 >/dev/null 2>&1 || { echo "missing aapt2. Install Android SDK build-tools." >&2; exit 1; }

missing="$(python3 - "$CATALOG" "$FORCE" <<'PY'
import json, sys
catalog = json.load(open(sys.argv[1]))
force = sys.argv[2] == "1"
for app in catalog.get("apps", []):
    if force or not app.get("iconUrl"):
        print(app["package"], app.get("versionCode", 0))
PY
)"

if [[ -z "$missing" ]]; then
    echo "every entry already has an icon."
    exit 0
fi

echo "entries without an icon:"
sed 's/^/  /' <<<"$missing"
echo

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

done_count=0
while read -r package version_code; do
    [[ -n "$package" ]] || continue

    apk=""
    while IFS= read -r candidate; do
        # Splits carry the same package name as their base but no launcher icon; skip them.
        case "$(basename "$candidate")" in config.*|*-config.*|split_*) continue ;; esac
        if [[ "$(aapt2 dump packagename "$candidate" 2>/dev/null | tr -d '\r')" == "$package" ]]; then
            apk="$candidate"
            break
        fi
    done < <(find "${DIRS[@]}" -name '*.apk' 2>/dev/null)

    if [[ -z "$apk" ]]; then
        echo "skip $package - no local APK found" >&2
        continue
    fi

    APK="$apk"
    BADGING="$(aapt2 dump badging "$APK" 2>/dev/null)" || { echo "skip $package - unreadable" >&2; continue; }

    icon_dir="$STAGE/$package"
    mkdir -p "$icon_dir"
    if ! extract_icon "$icon_dir/icon.png"; then
        echo "skip $package - no flattenable icon (vector layers?)" >&2
        continue
    fi

    key="icons/$package-$version_code.png"
    echo "uploading $key ($(wc -c <"$icon_dir/icon.png" | tr -d ' ') bytes)"
    if ! r2_put "$icon_dir/icon.png" "$key" "image/png" "${R2_APK_CACHE:-}"; then
        echo "skip $package - icon upload failed" >&2
        continue
    fi

    url="$(r2_public_url "$key")"
    python3 - "$CATALOG" "$package" "$url" <<'PY'
import collections, json, sys
path, package, url = sys.argv[1], sys.argv[2], sys.argv[3]
catalog = json.load(open(path), object_pairs_hook=collections.OrderedDict)
for app in catalog["apps"]:
    if app["package"] == package:
        app["iconUrl"] = url
with open(path, "w") as handle:
    json.dump(catalog, handle, indent=2)
    handle.write("\n")
PY
    done_count=$((done_count + 1))
done <<<"$missing"

echo
echo "added $done_count icon(s). Now run: tools/verify.sh"
