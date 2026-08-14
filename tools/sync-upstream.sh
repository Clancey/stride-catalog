#!/usr/bin/env bash
#
# Track upstream GitHub Releases and republish anything that moved.
#
#   tools/sync-upstream.sh                       # every source in upstream.json
#   tools/sync-upstream.sh org.jellyfin.mobile   # just one
#
# Some apps in this catalog are published by their own project as a plain APK on a GitHub Release,
# at a URL that is stable for the life of the tag. For those there is nothing to host: the catalog
# can record the upstream URL and its digests, and the only recurring work is noticing that a new
# release exists. That is what this does, so an app added once keeps updating without anyone
# remembering to check.
#
# WHAT IT WILL NOT DO. Every source pins the upstream signing certificate, and a release signed
# with anything else is refused rather than published. Automation that follows whatever the latest
# tag happens to contain is a supply chain with no gate in it: the console verifies the signer
# against the catalog, so if this script were free to rewrite the pin, that check would be
# checking our automation against itself. A legitimate key rotation is then a human editing
# upstream.json in a reviewable commit, which is exactly the weight that decision deserves.
#
# Requires: python3, curl, aapt2 + apksigner (Android SDK build-tools). Set GITHUB_TOKEN to raise
# the API rate limit; it is not needed to read a public release.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/upstream.json"
CATALOG="$ROOT/catalog.json"
ONLY="${1:-}"

# Same build-tools discovery as publish.sh: these never sit on PATH, and forgetting to export it
# is the most likely reason this fails for someone else.
if ! command -v aapt2 >/dev/null 2>&1 || ! command -v apksigner >/dev/null 2>&1; then
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    [[ -n "$sdk" && -d "$sdk/build-tools" ]] || continue
    bt="$(find "$sdk/build-tools" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1)"
    [[ -n "$bt" && -x "$bt/aapt2" ]] || continue
    PATH="$bt:$PATH"
    break
  done
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need python3; need curl
command -v aapt2 >/dev/null 2>&1 && command -v apksigner >/dev/null 2>&1 || {
  echo "missing aapt2/apksigner. Install Android SDK build-tools, or set ANDROID_HOME." >&2
  exit 1
}

[[ -f "$SOURCES" ]] || { echo "no upstream.json at $SOURCES" >&2; exit 1; }

api() {
    # A token only raises the rate limit. Public release metadata reads fine without one, and a CI
    # run that failed because someone forgot a secret would be a worse outcome than a slow one.
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
             -H "X-GitHub-Api-Version: 2022-11-28" "$1"
    else
        curl -fsSL -H "X-GitHub-Api-Version: 2022-11-28" "$1"
    fi
}

SOURCE_LINES="$(python3 - "$SOURCES" "$ONLY" <<'PY'
import json, sys

with open(sys.argv[1]) as handle:
    doc = json.load(handle)
if doc.get("schema") != 1:
    sys.exit("upstream.json: unsupported schema %r" % doc.get("schema"))

only = sys.argv[2]
for source in doc.get("sources", []):
    for field in ("package", "name", "repo", "asset", "signerSha256"):
        if not source.get(field):
            sys.exit("upstream.json: %s is missing %s" % (source.get("package", "?"), field))
    if only and source["package"] != only:
        continue
    print("\t".join([
        source["package"], source["name"], source["repo"], source["asset"],
        source["signerSha256"].lower(),
        "true" if source.get("requiresGms") else "false",
    ]))
PY
)"

if [[ -z "$SOURCE_LINES" ]]; then
    echo "no sources to check${ONLY:+ for $ONLY}." >&2
    exit 1
fi

CHANGED=()
while IFS=$'\t' read -r PACKAGE NAME REPO ASSET_RE SIGNER_PIN REQUIRES_GMS; do
    [[ -n "$PACKAGE" ]] || continue
    printf '\n%s (%s)\n' "$PACKAGE" "$REPO"

    # /releases/latest, not /releases[0]: GitHub excludes prereleases and drafts from it. Handing a
    # treadmill a beta because it happened to be the newest tag is not a judgement call automation
    # should be making.
    RELEASE_JSON="$(mktemp)"
    api "https://api.github.com/repos/$REPO/releases/latest" > "$RELEASE_JSON" \
        || { echo "  FAIL could not read the latest release of $REPO"; rm -f "$RELEASE_JSON"; exit 1; }

    # Through a file, not interpolated into the heredoc: release bodies are arbitrary user text,
    # and one containing a quote sequence would otherwise turn into a python syntax error that
    # reads like a broken script rather than a broken assumption.
    RESOLVED="$(python3 - "$ASSET_RE" "$RELEASE_JSON" <<'PY'
import json, re, sys
with open(sys.argv[2]) as handle:
    release = json.load(handle)
pattern = re.compile(sys.argv[1])
matches = [a for a in release.get("assets", []) if pattern.match(a.get("name", ""))]
if len(matches) != 1:
    names = ", ".join(sorted(a.get("name", "") for a in release.get("assets", []))) or "none"
    sys.exit("%d assets match %s in %s. available: %s"
             % (len(matches), sys.argv[1], release.get("tag_name", "?"), names))
print(matches[0]["name"])
print(matches[0]["browser_download_url"])
print(release.get("html_url", ""))
print(release.get("tag_name", ""))
PY
)" || { rm -f "$RELEASE_JSON"; echo "  FAIL asset selection: see above"; exit 1; }
    rm -f "$RELEASE_JSON"

    ASSET_NAME="$(sed -n 1p <<<"$RESOLVED")"
    ASSET_URL="$(sed -n 2p <<<"$RESOLVED")"
    NOTES_URL="$(sed -n 3p <<<"$RESOLVED")"
    TAG="$(sed -n 4p <<<"$RESOLVED")"
    echo "  latest release $TAG -> $ASSET_NAME"

    [[ "$ASSET_URL" == https://* ]] || { echo "  FAIL asset url is not https"; exit 1; }

    STAGE="$(mktemp -d)"
    curl -fsSL --max-time 900 -o "$STAGE/$ASSET_NAME" "$ASSET_URL" \
        || { echo "  FAIL asset is not fetchable at $ASSET_URL"; rm -rf "$STAGE"; exit 1; }

    # Identity checks before anything is written. publish.sh reads the same fields out of the APK,
    # but it would happily publish a correctly-formed entry for the wrong app: the point here is
    # that this file must be the package we already decided to trust, signed by the key we decided
    # to trust, and nothing else.
    # Captured once rather than piped per field: `grep -m1` exits on its match and hands aapt2 a
    # SIGPIPE, which under `set -o pipefail` fails the pipeline precisely when the field WAS found.
    BADGING="$(aapt2 dump badging "$STAGE/$ASSET_NAME")"
    badging_field() {
        grep -m1 '^package:' <<<"$BADGING" | grep -o "$1='[^']*'" | head -1 | sed "s/^$1='//; s/'$//"
    }

    GOT_PACKAGE="$(badging_field name)"
    if [[ "$GOT_PACKAGE" != "$PACKAGE" ]]; then
        echo "  FAIL $ASSET_NAME is package $GOT_PACKAGE, not $PACKAGE"
        rm -rf "$STAGE"; exit 1
    fi

    GOT_SIGNER="$(apksigner verify --print-certs "$STAGE/$ASSET_NAME" \
        | sed -n 's/.*SHA-256 digest: *\([0-9a-fA-F]*\).*/\1/p' | head -1 | tr 'A-F' 'a-f')"
    if [[ "$GOT_SIGNER" != "$SIGNER_PIN" ]]; then
        echo "  FAIL signing certificate does not match the pin in upstream.json"
        echo "       pinned $SIGNER_PIN"
        echo "       served $GOT_SIGNER"
        echo "       nothing published. if upstream really did rotate its key, confirm that from"
        echo "       the project itself and update upstream.json by hand - a console will refuse"
        echo "       this APK as an update either way, since Android will not replace an installed"
        echo "       app with a differently-signed one."
        rm -rf "$STAGE"; exit 1
    fi

    GOT_VERSION="$(badging_field versionCode)"
    PUBLISHED="$(python3 - "$CATALOG" "$PACKAGE" <<'PY'
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
    if [[ -n "$PUBLISHED" ]] && (( GOT_VERSION <= PUBLISHED )); then
        echo "  up to date - versionCode $GOT_VERSION, catalog has $PUBLISHED"
        rm -rf "$STAGE"
        continue
    fi

    echo "  publishing versionCode $GOT_VERSION${PUBLISHED:+ (was $PUBLISHED)}"
    ARGS=(--role app --name "$NAME" --url "$ASSET_URL")
    [[ -n "$NOTES_URL" ]] && ARGS+=(--notes "$NOTES_URL")
    [[ "$REQUIRES_GMS" == "true" ]] && ARGS+=(--requires-gms)
    "$ROOT/tools/publish.sh" "$STAGE/$ASSET_NAME" "${ARGS[@]}"

    rm -rf "$STAGE"
    CHANGED+=("$PACKAGE $GOT_VERSION")
done <<<"$SOURCE_LINES"

echo
if [[ ${#CHANGED[@]} -eq 0 ]]; then
    echo "nothing to do - every tracked source is already published."
    exit 0
fi

printf 'updated:\n'
printf '  %s\n' "${CHANGED[@]}"
cat <<'EOF'

next: tools/verify.sh                        # prove the whole catalog resolves
      git add -A && git commit && git push   # publish the decision
EOF
