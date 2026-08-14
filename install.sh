#!/usr/bin/env bash
#
# Install Stride on a treadmill console, in one command:
#
#   curl -fsSL https://raw.githubusercontent.com/Clancey/stride-catalog/main/install.sh | bash
#
# Runs on your Mac or Linux box, not on the console. It talks to the console over adb, installs
# the current Stride build from this catalog, and grants the permissions Stride cannot grant
# itself. Everything it does is printed before it does it.
#
# It deliberately does NOT make Stride the default launcher. That is the one step that can leave
# you with a console you cannot operate, so it is a separate, explicit --set-home run after you
# have seen Stride start.

set -euo pipefail

CATALOG_URL="${STRIDE_CATALOG_URL:-https://raw.githubusercontent.com/Clancey/stride-catalog/main/catalog.json}"
PACKAGE="io.stride.spikes"
CONNECT=""
SET_HOME=0
ASSUME_YES=0
DEVICE="${STRIDE_DEVICE:-}"

usage() {
    cat <<'EOF'
usage: install.sh [--connect HOST[:PORT]] [--device SERIAL] [--set-home] [--yes]

  --connect HOST[:PORT]  Connect to a console over the network first (adb connect).
                         Consoles are usually not reachable by USB.
  --device SERIAL        Target a specific adb device. Default: the only one connected.
  --set-home             Also make Stride the default launcher. Do this only after you
                         have seen Stride start and work - see WARNING below.
  --yes                  Do not pause for confirmation.

WARNING about --set-home: if Stride fails to start, a console whose default launcher is
Stride has no other way to get to a home screen. Recover with:
  adb shell cmd package set-home-activity com.ifit.standalone/.MainActivity
Keep an adb connection open the first time you try it.
EOF
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --connect)  CONNECT="${2:-}"; shift 2 ;;
        --device)   DEVICE="${2:-}"; shift 2 ;;
        --set-home) SET_HOME=1; shift ;;
        --yes|-y)   ASSUME_YES=1; shift ;;
        -h|--help)  usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- find adb

find_adb() {
    if command -v adb >/dev/null 2>&1; then command -v adb; return; fi
    for candidate in \
        "$HOME/Library/Android/sdk/platform-tools/adb" \
        "$HOME/Android/Sdk/platform-tools/adb" \
        "/usr/local/bin/adb" \
        "/opt/homebrew/bin/adb"; do
        [[ -x "$candidate" ]] && { echo "$candidate"; return; }
    done
    return 1
}

ADB="$(find_adb)" || die "adb not found.

Install the Android platform-tools first:
  macOS:  brew install --cask android-platform-tools
  Linux:  sudo apt install adb    (or your distro's equivalent)"

info "adb: $ADB"

# ---------------------------------------------------------------- pick a device

if [[ -n "$CONNECT" ]]; then
    [[ "$CONNECT" == *:* ]] || CONNECT="$CONNECT:5555"
    say "Connecting to $CONNECT"
    "$ADB" connect "$CONNECT" >/dev/null 2>&1 || true
    sleep 1
fi

devices="$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}')"
count="$(printf '%s\n' "$devices" | grep -c . || true)"

if [[ -z "$DEVICE" ]]; then
    case "$count" in
        0) die "no console connected.

If the console is on your network, pass its address:
  install.sh --connect 192.168.1.50

To find it: on the console, enable Developer options and 'ADB over network' (or
'Wireless debugging'), then use the IP and port it shows." ;;
        1) DEVICE="$devices" ;;
        *) printf '\nMore than one device is connected:\n%s\n' "$devices" >&2
           die "pick one with --device SERIAL" ;;
    esac
fi

adbs() { "$ADB" -s "$DEVICE" "$@"; }

model="$(adbs shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
sdk="$(adbs shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
abi="$(adbs shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
[[ -n "$sdk" ]] || die "cannot talk to $DEVICE. Is the console still authorised for adb?"
info "console: ${model:-unknown} (Android API $sdk, $abi)"

# ---------------------------------------------------------------- read the catalog

say "Reading the Stride catalog"
catalog="$(curl -fsSL --max-time 60 "$CATALOG_URL")" \
    || die "cannot reach the catalog at $CATALOG_URL"

# Pull the one entry with role=stride. python3 is used rather than jq because it is already on
# every Mac and most Linux boxes, and this script should not need anything installed first.
read -r URL SHA VERSION_NAME VERSION_CODE MIN_SDK <<EOF
$(printf '%s' "$catalog" | python3 -c '
import json, sys
catalog = json.load(sys.stdin)
for app in catalog.get("apps", []):
    if app.get("role") == "stride":
        print(app["url"], app["sha256"], app.get("versionName", "?"),
              app.get("versionCode", 0), app.get("minSdk", 0))
        break
')
EOF

[[ -n "${URL:-}" ]] || die "this catalog has no Stride build published yet.

The catalog is reachable, it just has no entry with role=stride. Nothing to install."

info "Stride $VERSION_NAME (versionCode $VERSION_CODE)"

if [[ "$MIN_SDK" =~ ^[0-9]+$ ]] && [[ "$sdk" =~ ^[0-9]+$ ]] && (( sdk < MIN_SDK )); then
    die "this console runs API $sdk, and this Stride build needs API $MIN_SDK or newer."
fi

# ---------------------------------------------------------------- confirm

if [[ $ASSUME_YES -eq 0 ]] && [[ -t 0 || -e /dev/tty ]]; then
    cat <<EOF

About to:
  1. download Stride $VERSION_NAME and check its SHA-256
  2. install it on ${model:-$DEVICE}
  3. grant it: install-apps, draw-over-other-apps, accessibility (Back), media access
$( ((SET_HOME)) && echo "  4. make Stride the default launcher" )

It will not change your workouts, your iFit account, or the iFit app.
EOF
    printf '\nContinue? [y/N] '
    read -r reply </dev/tty || reply=""
    [[ "$reply" =~ ^[Yy] ]] || die "cancelled."
fi

# ---------------------------------------------------------------- download + verify

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APK="$TMP/stride.apk"

say "Downloading Stride $VERSION_NAME"
curl -fL --progress-bar --max-time 900 -o "$APK" "$URL" || die "download failed from $URL"

if command -v sha256sum >/dev/null 2>&1; then
    got="$(sha256sum "$APK" | cut -d' ' -f1)"
else
    got="$(shasum -a 256 "$APK" | cut -d' ' -f1)"
fi
# Fail closed. The catalog is served over HTTPS, but the digest is what actually proves these are
# the bytes that were published, and an install is not something to retry-and-hope on.
[[ "$got" == "$SHA" ]] || die "SHA-256 mismatch - refusing to install.
  expected $SHA
  got      $got"
info "checksum ok"

# ---------------------------------------------------------------- install

say "Installing"
adbs install -r "$APK" 2>&1 | tail -2

adbs shell pm path "$PACKAGE" >/dev/null 2>&1 \
    || die "install did not take - $PACKAGE is not present afterwards."

# ---------------------------------------------------------------- grant what it cannot grant itself

say "Granting permissions"
grant() {
    printf '  %-34s' "$1"
    if adbs shell "$2" >/dev/null 2>&1; then echo "ok"; else echo "FAILED (grant by hand later)"; fi
}
grant "install apps"        "appops set $PACKAGE REQUEST_INSTALL_PACKAGES allow"
grant "draw over other apps" "appops set $PACKAGE SYSTEM_ALERT_WINDOW allow"
grant "accessibility (Back)" "settings put secure enabled_accessibility_services $PACKAGE/$PACKAGE.StrideAccessibilityService"
grant "accessibility enabled" "settings put secure accessibility_enabled 1"
grant "media session access" "cmd notification allow_listener $PACKAGE/$PACKAGE.StrideNotificationListener"

# ---------------------------------------------------------------- optional: default launcher

if ((SET_HOME)); then
    say "Making Stride the default launcher"
    adbs shell cmd package set-home-activity "$PACKAGE/$PACKAGE.MainActivity" >/dev/null 2>&1 \
        && info "done" \
        || info "could not set it from adb - set it on the console under Settings > Home app"
fi

# ---------------------------------------------------------------- verify

say "Checking"
installed_code="$(adbs shell dumpsys package "$PACKAGE" 2>/dev/null | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1)"
info "installed versionCode: ${installed_code:-unknown} (catalog says $VERSION_CODE)"

cat <<EOF

$(printf '\033[32mStride is installed.\033[0m')

Open it on the console. From here Stride keeps itself and its apps up to date:
  All apps > Store   browse and install apps from the catalog
  Updates            pending updates, and Stride's own upgrades

EOF

if ((SET_HOME == 0)); then
    cat <<EOF
Stride is not the default launcher yet. Try it first; when you are happy it starts:

  install.sh --set-home$([[ -n "$CONNECT" ]] && echo " --connect $CONNECT")

If a launcher ever fails to start, put the console's own launcher back with:
  adb shell cmd package set-home-activity com.ifit.standalone/.MainActivity

EOF
fi
