# Runbook — recovering a console you have broken

> **Read this before you set Stride as the default HOME app.** Prove the revert path *first*.
> If you cannot get back to iFit, do not proceed.

*Generated from Stride's source repository by `tools/sync-runbook.sh`, so it is readable by someone
standing in front of a console that will not boot. Tested on a NordicTrack Commercial 1750.*

The console has no physical Home or Back button. A launcher that crashes on start, or an overlay
that swallows every touch, leaves you with a treadmill you cannot operate by hand. ADB is the only
reliable way back, so ADB access must be established and tested **before** anything else.

---

## 0. Prerequisites — set these up first, verify them, then continue

```bash
# Confirm the device is reachable and authorised.
adb devices          # must show "device", not "unauthorized" or "offline"

# If it is on Wi-Fi rather than USB:
adb connect <console-ip>:5555
```

**Keep a second terminal with an open `adb shell` while you experiment.** If the UI locks up, an
already-open shell is faster and more reliable than establishing a new connection.

### Prove ADB survives a reboot — before you touch HOME

This is the step people skip and then regret. A broken HOME app is most dangerous exactly when the
console has just rebooted, which is also when a Wi-Fi ADB connection is least likely to come back on
its own. If ADB is over Wi-Fi, the console may not re-enable port 5555 after a reboot at all.

```bash
adb reboot
# wait for the console to come back, then WITHOUT touching the screen:
adb devices        # must show "device" again
```

One warm `adb reboot` is necessary but not sufficient. Also prove:

```bash
# A cold reconnect, not just a live session that happened to survive.
adb kill-server && adb devices          # (over Wi-Fi: adb connect <ip>:5555)

# The revert command itself, run against the CURRENT iFit HOME, so you know the
# syntax is right on this firmware before you need it in anger.
adb shell cmd package set-home-activity com.ifit.rivendell/<activity>
adb shell cmd package resolve-activity -a android.intent.action.MAIN \
  -c android.intent.category.HOME
```

- [ ] A **full power cycle** (pull mains, not `adb reboot`) and ADB still returns unattended
- [ ] `adb kill-server` then a fresh connect, with no screen interaction
- [ ] The console's IP is stable — a DHCP lease change over Wi-Fi loses you the device; set a static
      lease on the router if you cannot use USB

If any of that does not work unattended, **stop**. Fix ADB persistence, or use USB, before
continuing. Do not change the default launcher on a console you can only reach through a connection
you have not proven survives a restart.

A broken HOME app does not itself control adbd or Wi-Fi, so there is no launcher-specific way to lose
ADB — the realistic risk is a crash-looping HOME app starving the device, plus the ordinary
possibility that ADB was never going to come back anyway. Cold reconnect plus a power cycle is the
proof that matters.

### Record the state you are restoring to

```bash
# Note the -a: without an action, resolve-activity returns "No activity found".
adb shell cmd package resolve-activity -a android.intent.action.MAIN \
  -c android.intent.category.HOME

adb shell settings get secure enabled_accessibility_services
adb shell settings get secure accessibility_enabled
```

**Save that output.** The accessibility value in particular may list OEM or iFit services; §3 below
appends to it rather than overwriting it, but if something does overwrite it, this recording is the
only way back. A value of `null` means the setting is unset, which is different from an empty
string — restore it with `settings delete secure <key>`, not by writing `"null"`.

### Do the safe things first

The temptation on day one is to install Stride and set it as HOME, because that is the interesting
part. Do not. Setting HOME is the only step that can leave the console unusable, and it is the step
that gains the least - Stride runs perfectly well as an ordinary app you launch by hand, and that is
how you find out whether it starts reliably on *your* console.

Install it, use it for a few sessions, reboot the console a couple of times, and only then consider
making it HOME - after §0's persistence gate has passed *and* you have run the revert command in §1
successfully against the current iFit HOME.

Two practical notes for a Wi-Fi ADB session:

- **`adb tcpip 5555` does not survive a reboot.** Wireless debugging typically reverts to USB mode on
  restart, so the first reboot after you set HOME is exactly when you are most likely to lose the
  connection *and* most likely to need it. That combination is the lockout. Prove the cold-boot path
  in §0, or keep USB available, before stage 5.
- **Pin the console's IP.** A DHCP lease change silently loses you the device. Set a static lease on
  the router first; rediscovering the console by scanning while it sits on a broken launcher is not
  a position you want to be in.

Nothing about stages 1-4 requires the belt to move, and nothing in this build can move it. Do the
hardware work with the machine powered but idle, and keep the safety key out of the magnet until
there is a reason for it to be in.

---

## 1. Revert the default launcher

The most common failure. Symptom: the console boots to a black screen, a crashing app, or Stride
with no way out.

```bash
# Point HOME back at the iFit console app.
adb shell cmd package set-home-activity com.ifit.rivendell/<activity>

# If you do not know the activity name, list every HOME candidate:
adb shell cmd package query-activities -a android.intent.action.MAIN \
  -c android.intent.category.HOME
```

If `set-home-activity` is unavailable on this firmware, disable Stride so the system is forced to
fall back to the only remaining HOME app:

```bash
adb shell pm disable-user --user 0 io.stride.spikes
# and to bring it back later
adb shell pm enable io.stride.spikes
```

Note: `pm clear-package-preferred-activities` does **not** exist on modern `pm` (verified absent on
API 33; do not rely on it on 26-28 either). `pm clear android` is sometimes suggested online for
resetting HOME preference — **never run it**. It wipes the settings of the `android` system package
and can take Wi-Fi, ADB, and your way back in with it.

Last resort:

```bash
adb uninstall io.stride.spikes
```

---

## 2. Kill a runaway overlay

Symptom: the screen is covered, or edge strips eat every touch so no app is usable.

```bash
# Revoke the overlay permission - the windows disappear immediately.
adb shell appops set io.stride.spikes SYSTEM_ALERT_WINDOW deny

# Or stop the process outright.
adb shell am force-stop io.stride.spikes
```

Re-grant later with:

```bash
adb shell appops set io.stride.spikes SYSTEM_ALERT_WINDOW allow
```

---

## 3. Disable the accessibility service

Symptom: unexpected Back presses, or the service is interfering with input.

`enabled_accessibility_services` is a single colon-separated list shared by **every** accessibility
service on the device, including OEM and iFit ones. Blanket-writing it is how you silently disable
something the console needed. Append and remove surgically instead.

Both snippets below are self-contained (safe to paste into a fresh terminal), fail closed if ADB is
not reachable, and match the component **exactly** so a lookalike package is never touched. Android
records a component in either full (`pkg/pkg.Class`) or short (`pkg/.Class`) form, so both are
matched.

Remove only Stride, preserving everything else:

```bash
STRIDE_PKG=io.stride.spikes
STRIDE_CLS=io.stride.spikes.StrideAccessibilityService

if ! adb get-state >/dev/null 2>&1; then echo "ADB not connected - STOP"; exit 1; fi
CUR=$(adb shell settings get secure enabled_accessibility_services 2>/dev/null | tr -d '\r') || {
  echo "read failed - refusing to write"; exit 1; }
case "$CUR" in null|"") CUR="" ;; esac

NEW=$(printf '%s' "$CUR" | tr ':' '\n' \
  | grep -vx -e "$STRIDE_PKG/$STRIDE_CLS" -e "$STRIDE_PKG/.${STRIDE_CLS##*.}" \
  | grep -v '^$' | paste -sd: -)

if [ -z "$NEW" ]; then
  adb shell settings delete secure enabled_accessibility_services
  adb shell settings put secure accessibility_enabled 0
else
  adb shell settings put secure enabled_accessibility_services "$NEW"
fi
```

Only set `accessibility_enabled 0` when the resulting list is empty — the snippet does this for you.
Turning the master switch off while other services are still listed disables them too.

Re-enable by appending, not replacing:

```bash
STRIDE_PKG=io.stride.spikes
STRIDE_CLS=io.stride.spikes.StrideAccessibilityService
STRIDE_SVC="$STRIDE_PKG/$STRIDE_CLS"

if ! adb get-state >/dev/null 2>&1; then echo "ADB not connected - STOP"; exit 1; fi
CUR=$(adb shell settings get secure enabled_accessibility_services 2>/dev/null | tr -d '\r') || {
  echo "read failed - refusing to write"; exit 1; }
case "$CUR" in null|"") CUR="" ;; esac

if printf '%s' "$CUR" | tr ':' '\n' \
     | grep -qx -e "$STRIDE_SVC" -e "$STRIDE_PKG/.${STRIDE_CLS##*.}"; then
  echo "already present"
else
  [ -z "$CUR" ] && NEW="$STRIDE_SVC" || NEW="$CUR:$STRIDE_SVC"
  adb shell settings put secure enabled_accessibility_services "$NEW"
fi
adb shell settings put secure accessibility_enabled 1
```

Both snippets were exercised against a live device across seven cases: an OEM service alongside
Stride, Stride recorded in short form, Stride as the only entry, an unset (`null`) baseline, a
repeated add, and a lookalike package (`io.stride.spikesOTHER`) that must survive removal. On macOS
they rely on BSD `paste -sd: -` and `grep -x`, both of which behave as required.

If you lost the baseline entirely, the recording from the top of this document is the only way back.

---

## 4. Navigating without buttons, from the host

While the console has no Home or Back button, ADB does:

```bash
adb shell input keyevent KEYCODE_HOME      # 3
adb shell input keyevent KEYCODE_BACK      # 4
adb shell input keyevent KEYCODE_APP_SWITCH # 187
```

This works from the host because `adb shell` runs with shell UID, which holds `INJECT_EVENTS`. A
sideloaded app does not — which is exactly why Stride needs the accessibility service (plan §3.3).

### Back and Home stopped working — the overlay buttons do nothing

Most likely the accessibility service was silently disabled. A **force-stop** does not merely unbind
it: on API 28 it *emptied* `enabled_accessibility_services` and reset `accessibility_enabled` to `0`,
and nothing ever restored it. A crash loop, an OEM battery/memory manager, an app update, or someone
pressing "Force stop" in Settings can all do this. On this console that means no navigation at all.

Check first — the setting and the *bound* state are different things, and only the second one matters:

```bash
adb shell settings get secure enabled_accessibility_services
adb shell settings get secure accessibility_enabled
adb shell dumpsys accessibility | grep -o 'label=[^,]*'   # authoritative: is it actually bound?
```

`dumpsys accessibility` prints the service **label**, not the package, so grepping for the package
name will wrongly look like a failure. If the label is absent, re-add the component using the
surgical snippet in §3 (append, never overwrite — the list is shared with OEM services), then set
`accessibility_enabled 1` and re-check `dumpsys`.

**Installing a new build does both of these to you.** `adb install -r` stops the app, which tears
down `OverlayService` — so the HUD and the edge swipes are gone until you start them again from
**Hardware diagnostics → S3 — Overlay → Start**. `OverlayService` is deliberately not exported, so
`am startservice` from the host is refused (`Requires permission not exported from uid`); it has to
be started from inside the app. And if you `force-stop` at any point, the accessibility service is
wiped as described above and **Back** stops working even though **Home** still does — Home is a real
intent that Stride receives as the HOME activity, whereas Back exists only through accessibility.
That asymmetry is the tell: if Home works and Back does not, it is this, not the overlay.

After any reinstall, the full restore is:

```bash
adb shell settings put secure enabled_accessibility_services \
  io.stride.spikes/io.stride.spikes.StrideAccessibilityService
adb shell settings put secure accessibility_enabled 1
# then, in the app: Hardware diagnostics → S3 — Overlay → Start
```

On the real console, do this **before** you step on the belt, and confirm both Back and Home work
against a third-party app first.

### Stop having to do this at all

The restore above is a workaround for a problem Stride can fix itself. Grant it once:

```bash
adb shell pm grant io.stride.spikes android.permission.WRITE_SECURE_SETTINGS
```

`WRITE_SECURE_SETTINGS` is development-tier: no dialog can ever grant it, and it **survives
reinstalls** as long as the app keeps declaring it. With it held, `StridePermissions.repair()` puts
the accessibility and notification-listener entries back by itself — on overlay start, on every
launcher resume, and on the first press of a Back button that isn't working. It only ever *appends*
Stride's own component; other apps' entries in those shared lists are preserved
(`SecureListMergeTest` pins that).

Confirm it took:

```bash
adb shell dumpsys package io.stride.spikes | grep WRITE_SECURE_SETTINGS
# expect: android.permission.WRITE_SECURE_SETTINGS: granted=true
```

Without the grant nothing breaks — Stride falls back to the non-dismissible setup card on the
launcher, which names the missing grant and deep-links to it. The grant just means the rider never
sees the card.

### A trap: your overlay is hidden over Settings

Android hides non-system overlay windows over the Settings app's permission pages, on purpose —
it is the standard defence against overlay tapjacking. So when Stride sends the rider to Settings
to fix a grant, **Stride's own Back and Home buttons are not on screen there.** On a console with
no physical buttons that is a one-way trip into Settings.

This is why self-repair matters more than a better prompt: with `WRITE_SECURE_SETTINGS` granted,
"Fix this" repairs the grant in place and never opens Settings at all.

On the console itself, the way back is the **notification shade** — a system window, so it survives
where our overlay does not. Swipe down, tap "Stride is running". That notification is the escape
hatch, which is why its channel is `IMPORTANCE_LOW` rather than `MIN` (MIN can be collapsed out of
sight) and why the Settings button in Stride's own settings screen says so before you tap it.

From the host, if you are wedged:

```bash
adb shell am start -n io.stride.spikes/.MainActivity
```

---

## 5. If the belt is moving and you cannot stop it

**Pull the safety key. That is the only true emergency stop.**

No software path in this repository is a fail-safe. Do not attempt to debug a moving treadmill from
a terminal. Stop it physically, then investigate.

Afterwards, capture what happened:

```bash
adb logcat -d > ~/stride-incident-$(date +%s).log
```

---

## 6. Permission grants Stride needs

Collected here so a console can be brought back to a working state quickly. The
installer applies these for you; they are spelled out for when you need one on its own.

```bash
# Grant this one FIRST. It is what lets Stride restore the other two by itself after a reinstall,
# and it is the only grant here that cannot be repaired from inside the app once lost.
adb shell pm grant io.stride.spikes android.permission.WRITE_SECURE_SETTINGS

# S3 - overlay windows
adb shell appops set io.stride.spikes SYSTEM_ALERT_WINDOW allow

# S5 - MediaSessionManager.getActiveSessions() requires an enabled notification listener.
# Verified present on API 33 and on API 28, where it also *appends* rather than overwriting
# (an unrelated setupwizard listener already in the list survived). NOT present on API 26
# (NotificationManagerService gained this shell command in API 27), so try it and check the
# result rather than assuming it worked:
adb shell cmd notification allow_listener \
  io.stride.spikes/io.stride.spikes.StrideNotificationListener
adb shell settings get secure enabled_notification_listeners
```

If that command is unavailable on this firmware, append to the setting directly. Same surgical
pattern as §3 — `enabled_notification_listeners` is also a shared colon-separated list, so do not
overwrite it:

```bash
LSNR=io.stride.spikes/io.stride.spikes.StrideNotificationListener
CUR=$(adb shell settings get secure enabled_notification_listeners 2>/dev/null | tr -d '\r')
case "$CUR" in null|"") CUR="" ;; esac
if printf '%s' "$CUR" | tr ':' '\n' | grep -qx "$LSNR"; then echo "already present"; else
  [ -z "$CUR" ] && NEW="$LSNR" || NEW="$CUR:$LSNR"
  adb shell settings put secure enabled_notification_listeners "$NEW"
fi
```

A failure here does not endanger the console — it produces a false S5 failure, which is its own kind
of expensive mistake.

**It fails silently, which is worse.** Without this grant `getActiveSessions()` simply reports no
sessions, so the overlay's now-playing card never appears and the workout/media coupling never
fires, with nothing logged and no error surfaced. Confirm the grant landed before concluding that
either feature is broken:

```bash
adb shell settings get secure enabled_notification_listeners   # must contain io.stride.spikes
adb shell dumpsys media_session | grep -E 'Sessions Stack|state=Playback'
```

A `PlaybackState {state=3, ...}` is playing and `state=2` is paused; the card is only expected
while something is actually playing.

```bash
# S10 - Back / Recents. Use the APPEND snippet in §3, not a bare
# "settings put secure enabled_accessibility_services". Overwriting the list here would undo
# exactly the protection §3 exists to provide.

# S1 - only after the revert path above has been tested AND ADB is proven to survive a reboot
adb shell cmd package set-home-activity io.stride.spikes/io.stride.spikes.MainActivity
```

### The app store — permission to install other apps

`StrideAppstoreService` needs `REQUEST_INSTALL_PACKAGES`. API 26 replaced the
global "unknown sources" toggle with this per-app one; it grants the right to *ask*, not to install
silently, so every install still shows the system confirmation.

```bash
adb shell appops set io.stride.spikes REQUEST_INSTALL_PACKAGES allow
adb shell appops get io.stride.spikes REQUEST_INSTALL_PACKAGES   # expect: allow
```

Unlike the listener grant above, this one **fails loudly**: the updates sheet shows the permission
as missing and offers a Fix button, because `ACTION_MANAGE_UNKNOWN_APP_SOURCES` is one of the few
grants a rider can actually complete on the console itself.

If updates are the problem rather than the permission, the catalog is a plain file you can read from
the host — the device parses exactly what you see here, so a bad publish is visible without a device:

```bash
curl -sS https://raw.githubusercontent.com/Clancey/stride-catalog/main/catalog.json | head -40
```

The service refuses a non-https catalog URL in code, so a redirect off TLS reads as "check failed",
not as a silent downgrade. To recover from a bad Stride build, the ordinary escalation in §8 still
applies — the app store cannot roll back, by design.

---

## 7. An APK will not install

### "This app was built for an older version of Android and doesn't include the latest privacy protections"

That is `INSTALL_FAILED_DEPRECATED_SDK_VERSION`. Android refuses to sideload apps whose
**`targetSdkVersion`** is below a floor. It is about `targetSdk`, not `minSdk`, and not the version
of Android you are installing *onto* being too old.

| Installing onto | Minimum `targetSdkVersion` accepted |
|---|---|
| Android 13 (API 33) and earlier | no restriction |
| Android 14 (API 34) | 23 |
| Android 15 / 16 (API 35 / 36) | 24 |

**The Stride spike harness is not affected by this.** It declares `minSdk 26` / `targetSdk 28`,
which clears every floor above, and it installs on an API 33 emulator. So if you see this message,
first find out *which* APK is actually being rejected.

Check any APK, ours or a third party's:

```bash
AAPT=$(ls "$ANDROID_SDK_ROOT"/build-tools/*/aapt2 | tail -1)
"$AAPT" dump badging some.apk | grep -E "package:|sdkVersion"
```

The likely culprits are the **third-party APKs that `SPIKES.md` asks you to sideload** — NordicFTMS
and tHUD are older apps and may well target below the floor. On the treadmill console itself (API
26-28) no floor exists, so this error only appears when you install one of them on a modern phone or
tablet.

To install a low-target APK anyway, for testing only:

```bash
adb install --bypass-low-target-sdk-block some.apk
```

That flag exists on Android 14+ and is the supported developer escape hatch. There is no way for a
normal user to bypass the block from the UI, which is why it is a poor idea to ever depend on a
low-target APK in the product itself.

### The harness specifically

If our own APK is rejected, it is an OEM-specific policy rather than stock Android. Build a variant
that targets a modern SDK:

```bash
flutter build apk --debug -PstrideTargetSdk=35
```

**Do not make that the default.** `targetSdk 28` is a deliberate choice, and raising it changes
runtime behaviour in ways that would invalidate the spike results: **package-visibility filtering at
30+ breaks app enumeration, which is the launcher's core feature** (S4), and
background-activity-start limits at 29+ affect the overlay.
A modern-target build is for inspecting the UI on a phone, not for drawing conclusions about the
console.

### Other install failures

```bash
# Signature mismatch with an already-installed copy - uninstall first.
adb uninstall io.stride.spikes

# Not enough space for a 160+ MB debug APK.
adb shell df -h /data

# Wrong ABI (rare; the debug APK is fat and includes all of them).
adb shell getprop ro.product.cpu.abilist
```

---

## 8. Escalation order

1. Revoke the specific permission causing the problem (§2, §3).
2. Force-stop the app (§2).
3. Revert HOME (§1).
4. Disable the package (§1).
5. Uninstall (§1).
6. Factory reset the console — **only** with a known-good path back to a working iFit install, since
   this console is not a device you can trivially reimage.
