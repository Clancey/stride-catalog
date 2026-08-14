#!/usr/bin/env bash
#
# Prove that catalog.json actually resolves, from outside, the way a treadmill would.
#
#   tools/verify.sh
#
# Every entry is fetched over the public internet with no credentials and checked against the
# digest and size the catalog promises. This is the one test that can catch the failures that
# matter here, because all of them are invisible from a local checkout:
#
#   * an R2 bucket that was never made public, or a custom domain that is not bound
#   * a GitHub Release asset on a private repo (403/404 without an auth header)
#   * a catalog committed and pushed before the artifact finished uploading
#   * bytes that were replaced under a key some console already pinned a digest for
#
# Exit status is 0 only if every entry is fetchable and matches. Safe to run in CI.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="${1:-$ROOT/catalog.json}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need python3; need curl
# shellcheck source=tools/r2-lib.sh
source "$ROOT/tools/r2-lib.sh"

[[ -f "$CATALOG" ]] || { echo "no catalog at $CATALOG" >&2; exit 1; }

# Reuse the same rejections the client applies, so a catalog that would be thrown out on the
# hardware is thrown out here instead. Emits one tab-separated line per entry.
ENTRIES="$(python3 - "$CATALOG" <<'PY'
import json, re, sys

with open(sys.argv[1]) as handle:
    catalog = json.load(handle)

problems = []
if catalog.get("schema") != 1:
    problems.append(f"unsupported schema {catalog.get('schema')!r}")

apps = catalog.get("apps")
if not isinstance(apps, list):
    problems.append("apps is not a list")
    apps = []

seen, strides = set(), 0
hex64 = re.compile(r"^[0-9a-f]{64}$")
for index, app in enumerate(apps):
    where = f"apps[{index}]"
    package = app.get("package", "")
    if not package:
        problems.append(f"{where} has no package")
    if package in seen:
        problems.append(f"{where} duplicates package {package}")
    seen.add(package)
    if app.get("role") == "stride":
        strides += 1
    if app.get("role") not in ("stride", "app"):
        problems.append(f"{where} has unknown role {app.get('role')!r}")
    if not str(app.get("url", "")).startswith("https://"):
        problems.append(f"{where} url is not https")
    if not hex64.match(str(app.get("sha256", ""))):
        problems.append(f"{where} sha256 is not a 64-char lowercase hex digest")
    if not hex64.match(str(app.get("signerSha256", ""))):
        problems.append(f"{where} signerSha256 is not a 64-char lowercase hex digest")
    if not isinstance(app.get("versionCode"), int) or app.get("versionCode", 0) <= 0:
        problems.append(f"{where} has a non-positive versionCode")
    if not isinstance(app.get("sizeBytes"), int) or app.get("sizeBytes", 0) <= 0:
        problems.append(f"{where} has a non-positive sizeBytes")

    # Splits are optional, but a bad one is as fatal as a bad base: the install session writes
    # every part or none, so an unfetchable split means the app cannot be installed at all.
    splits = app.get("splits")
    if splits is not None:
        if not isinstance(splits, list) or not splits:
            problems.append(f"{where} splits must be a non-empty list when present")
            splits = []
        names = set()
        for split_index, split in enumerate(splits):
            swhere = f"{where}.splits[{split_index}]"
            name = split.get("name", "")
            if not name:
                problems.append(f"{swhere} has no name")
            if name in names:
                problems.append(f"{swhere} duplicates split name {name}")
            names.add(name)
            if not str(split.get("url", "")).startswith("https://"):
                problems.append(f"{swhere} url is not https")
            if not hex64.match(str(split.get("sha256", ""))):
                problems.append(f"{swhere} sha256 is not a 64-char lowercase hex digest")
            if not isinstance(split.get("sizeBytes"), int) or split.get("sizeBytes", 0) <= 0:
                problems.append(f"{swhere} has a non-positive sizeBytes")
        # Two ABI splits in one session is rejected by the platform at install time. Catching it
        # here means it fails in CI rather than on a console already out in the field.
        abi_splits = [n for n in names if n.startswith("config.") and n.split(".", 1)[1] in
                      ("arm64_v8a", "armeabi_v7a", "x86", "x86_64", "armeabi", "mips")]
        if len(abi_splits) > 1:
            joined = ", ".join(sorted(abi_splits))
            problems.append(f"{where} has {len(abi_splits)} abi splits ({joined});"
                            " a single install session accepts only one")

if strides > 1:
    problems.append(f"catalog declares {strides} stride entries; at most one is allowed")

if problems:
    for problem in problems:
        print("STRUCTURE " + problem, file=sys.stderr)
    sys.exit(3)

for app in apps:
    # One row per artifact. Splits are fetched exactly like the base, because on the device they
    # are exactly as required as the base.
    print("\t".join([
        app["package"], str(app["versionCode"]), "base", app["url"],
        str(app["sizeBytes"]), app["sha256"],
    ]))
    for split in app.get("splits") or []:
        print("\t".join([
            app["package"], str(app["versionCode"]), split["name"], split["url"],
            str(split["sizeBytes"]), split["sha256"],
        ]))
PY
)" || { echo "catalog is structurally invalid - a console would reject it whole." >&2; exit 1; }

echo "structure ok: $CATALOG"

if [[ -z "$ENTRIES" ]]; then
    # Not an error. An empty catalog is a valid catalog, and it is what a fresh deployment serves.
    echo "no entries to fetch - nothing published yet."
    exit 0
fi

FAILED=0
while IFS=$'\t' read -r package version_code label url want_size want_sha; do
    [[ -n "$package" ]] || continue
    if [[ "$label" == base ]]; then
        printf '\n%s (versionCode %s)\n  %s\n' "$package" "$version_code" "$url"
    else
        printf '  split %s\n  %s\n' "$label" "$url"
    fi

    TMP="$(mktemp)"
    if ! curl -fsSL --max-time 900 -o "$TMP" "$url"; then
        echo "  FAIL not fetchable without credentials"
        rm -f "$TMP"; FAILED=1; continue
    fi

    got_size="$(wc -c <"$TMP" | tr -d ' ')"
    got_sha="$(sha256_of "$TMP")"
    rm -f "$TMP"

    if [[ "$got_size" != "$want_size" ]]; then
        echo "  FAIL size: catalog says $want_size, served $got_size"
        FAILED=1; continue
    fi
    if [[ "$got_sha" != "$want_sha" ]]; then
        echo "  FAIL sha256: catalog says $want_sha"
        echo "               served     $got_sha"
        echo "       the bytes behind this URL changed. a console that already read the catalog"
        echo "       will refuse this download. bump versionCode and publish again."
        FAILED=1; continue
    fi
    echo "  ok $got_size bytes, sha256 matches"
done <<<"$ENTRIES"

echo
if [[ $FAILED -eq 0 ]]; then
    echo "every entry resolves and matches."
else
    echo "one or more entries would fail on a console." >&2
fi
exit $FAILED
