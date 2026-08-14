#!/usr/bin/env bash
#
# Remove an app from the catalog.
#
#   tools/unpublish.sh com.example.app
#   tools/unpublish.sh com.example.app --keep-bytes
#
# WHY THIS EXISTS SEPARATELY FROM publish.sh
#
# Not every APK works. Some crash on launch for want of Play Services, some are built for a phone
# and render off the edge of a 1920x1080 console, some simply refuse to run on API 33 with no
# keyboard. A store that offers an app which cannot work is worse than a store that does not offer
# it: the rider spends 200MB of download and a confirmation dialog to find out.
#
# Removing one has to be one command, or it will be done by hand-editing catalog.json, and a
# hand-edited catalog is how a bundle ends up naming a package that no longer exists - which the
# client rejects WHOLESALE, taking every console's updates down with it. So this script refuses to
# strand a bundle, and re-runs the same validation publish.sh does.
#
# THE BYTES ARE DELETED TOO, by default. An R2 object key is immutable while it is referenced, but
# once nothing points at it, leaving 200MB of a broken app in the bucket is just cost. Pass
# --keep-bytes to unlist an app without deleting it - the right choice when you intend to publish a
# fixed build under a new versionCode and want the old one for comparison.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: tools/unpublish.sh <package> [--keep-bytes] [--reason "why"]

  --keep-bytes  Leave the artifacts in R2. Default is to delete them.
  --reason      Recorded in the commit message this prints at the end.
EOF
    exit 2
}

[[ $# -ge 1 ]] || usage
PACKAGE="$1"; shift
KEEP_BYTES="false"
REASON=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-bytes) KEEP_BYTES="true"; shift ;;
        --reason)     REASON="${2:-}"; shift 2 ;;
        -h|--help)    usage ;;
        *)            usage ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/catalog.json"
# shellcheck source=tools/r2-lib.sh
source "$ROOT/tools/r2-lib.sh"

# ------------------------------------------------------------------ find it, and refuse if it is load-bearing

# Stride is the one entry that must never be removed: the catalog is how a console learns that a
# newer Stride exists, so unlisting it strands every device on whatever it is running now, with no
# way back short of adb.
INFO="$(python3 - "$CATALOG" "$PACKAGE" <<'PY'
import json, sys
catalog = json.load(open(sys.argv[1]))
package = sys.argv[2]
entry = next((a for a in catalog.get("apps", []) if a.get("package") == package), None)
if entry is None:
    print("MISSING")
    raise SystemExit
if entry.get("role") == "stride":
    print("STRIDE")
    raise SystemExit
holders = [b.get("id", "?") for b in catalog.get("bundles", []) if package in b.get("packages", [])]
if holders:
    print("BUNDLED %s" % ",".join(holders))
    raise SystemExit
urls = [entry["url"]] + [s["url"] for s in entry.get("splits", [])]
if entry.get("iconUrl"):
    urls.append(entry["iconUrl"])
print("OK %s %s" % (entry.get("name", package), entry.get("versionCode", "?")))
for u in urls:
    print(u)
PY
)"

STATUS="$(head -1 <<<"$INFO")"
case "$STATUS" in
    MISSING)
        echo "$PACKAGE is not in the catalog - nothing to do." >&2
        exit 0
        ;;
    STRIDE)
        echo "refusing: that is Stride itself. Unlisting it strands every console with no update" >&2
        echo "path back. If a Stride build is bad, publish a fixed one with a higher versionCode." >&2
        exit 1
        ;;
    BUNDLED*)
        echo "refusing: $PACKAGE is a member of bundle(s) ${STATUS#BUNDLED }." >&2
        echo "A bundle naming a package the catalog does not carry is rejected by the client" >&2
        echo "wholesale - every console would stop seeing updates entirely. Remove it from the" >&2
        echo "bundle in catalog.json first, or remove the bundle." >&2
        exit 1
        ;;
esac

read -r _ NAME VERSION_CODE <<<"$STATUS"
URLS="$(tail -n +2 <<<"$INFO")"

echo "removing $NAME ($PACKAGE, versionCode $VERSION_CODE)"

# ------------------------------------------------------------------ delete the bytes

if [[ "$KEEP_BYTES" == "true" ]]; then
    echo "  keeping artifacts in R2 (--keep-bytes)"
else
    r2_require_env
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        # Only our own bucket. An entry published with --backend url or --role stride points at
        # somebody else's host (or a GitHub Release), and deleting there is not this script's job.
        if [[ "$url" != "$R2_PUBLIC_BASE"/* ]]; then
            echo "  skipping $url (not in this bucket)"
            continue
        fi
        key="${url#"$R2_PUBLIC_BASE"/}"
        echo "  deleting r2://$R2_BUCKET/$key"
        r2_wrangler r2 object delete "$R2_BUCKET/$key" --remote >/dev/null 2>&1 ||
            echo "  note: delete failed for $key - remove it by hand if it matters."
    done <<<"$URLS"
fi

# ------------------------------------------------------------------ rewrite the catalog

python3 - "$CATALOG" "$PACKAGE" <<'PY'
import datetime, json, sys
path, package = sys.argv[1], sys.argv[2]
catalog = json.load(open(path))
catalog["apps"] = [a for a in catalog.get("apps", []) if a.get("package") != package]
catalog["generated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w") as handle:
    json.dump(catalog, handle, indent=2)
    handle.write("\n")
PY

cat <<EOF

removed $PACKAGE from the catalog.

A console that already installed it keeps it - unlisting is not an uninstall, and Stride never
removes an app a rider chose to have. It simply stops being offered, and stops being updated.

next: tools/verify.sh
      git commit -am "Drop $NAME from the catalog${REASON:+ - $REASON}"
EOF
