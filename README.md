# stride-catalog

The update catalog for **[Stride](https://github.com/Clancey/stride)** — a Flutter Android launcher
and workout overlay for NordicTrack / iFit consoles.

A treadmill console is a sideload-only device with no Play Store, no keyboard, and, once Stride is
the launcher, no obvious way to get a newer build onto it. This repository is the fix: it hosts
`catalog.json` and the APKs it points at, and Stride's background `StrideAppstoreService` reads them
directly over HTTPS.

```
Stride on the console ──► https://raw.githubusercontent.com/Clancey/stride-catalog/main/catalog.json
                          └─► apks/<package>-<versionCode>.apk
```

Nothing here runs. It is a static file host that happens to be a git repo, which means the whole
update history is reviewable and any change to what a console will install is a visible commit.

---

## Safety first

Stride controls a machine that can physically hurt someone. Two rules follow from that and are
enforced in the client, not here:

- **Installs never happen while the belt is moving.** The Android install confirmation is a
  full-screen dialog; raising it mid-run would cover the stop control. Downloads continue; installs
  wait for the workout to end.
- **Stride never updates itself unprompted.** A self-update kills the process, and with it the
  overlay that supplies the only Back and Home this console has.

Before you make Stride your default launcher, read
[`docs/RUNBOOK.md`](https://github.com/Clancey/stride/blob/main/docs/RUNBOOK.md) in the main
repository. A launcher that crashes on start leaves you with a treadmill you cannot operate.

---

## Installing Stride the first time

Stride cannot install its own first copy, so this part is done from a laptop. Everything after it
is handled on the console.

1. **Get a shell on the console.** Enable developer options and USB (or `adb connect <ip>:5555` if
   the console is on your network).

   ```bash
   adb devices          # confirm exactly one device is listed
   ```

2. **Check what the current launcher is, so you can get back to it.**

   ```bash
   adb shell cmd package resolve-activity -c android.intent.category.HOME
   ```

   Write the result down. This is your revert path.

3. **Install the APK.**

   ```bash
   adb install -r stride.apk
   ```

4. **Grant the permissions Stride cannot grant itself.** The console is Android 8/9 and several of
   these have no on-device UI:

   ```bash
   PKG=io.stride.spikes

   # Install other APKs (the updater). Every install is still confirmed by you.
   adb shell appops set $PKG REQUEST_INSTALL_PACKAGES allow

   # Draw the workout HUD and the stop control over other apps.
   adb shell appops set $PKG SYSTEM_ALERT_WINDOW allow

   # Back / Recents. The only mechanism available to a non-system app.
   adb shell settings put secure enabled_accessibility_services \
     $PKG/$PKG.StrideAccessibilityService
   adb shell settings put secure accessibility_enabled 1

   # Media session access, so pausing the workout pauses Spotify.
   adb shell cmd notification allow_listener $PKG/$PKG.StrideNotificationListener
   ```

5. **Open Stride and work through the Setup checklist** under the **Updates** button in the header.
   It recomputes all of the above on the device and shows you exactly which ones are still missing.

6. **Only then**, if you want it, make Stride the default launcher — and confirm the revert path
   from step 2 still works before you walk away.

From here on, updates arrive on their own.

---

## How updating works

- `StrideAppstoreService` checks this catalog roughly every 6 hours, on boot, and whenever you press
  **Check now**. It is a foreground service, because the check has to keep working while you are
  inside Spotify and Stride's UI is not running.
- Third-party updates download and install in the background (you still confirm each install).
- Stride's own upgrade is **only** ever offered as an explicit button, with a warning that the HUD
  disappears while it restarts.
- Every artifact is verified twice before the installer is opened: SHA-256 over the downloaded bytes,
  and the APK's signing certificate against `signerSha256`. A mismatch is a hard failure, never a
  warning.

---

## `catalog.json`

```jsonc
{
  "schema": 1,
  "generated": "2026-08-14T00:00:00Z",
  "apps": [
    {
      "package": "io.stride.spikes",
      "role": "stride",                 // "stride" for Stride itself, "app" for anything else
      "name": "Stride",
      "versionCode": 42,                // must be strictly greater to be offered as an update
      "versionName": "0.4.2",
      "minSdk": 26,
      "abis": ["arm64-v8a"],            // omit or leave empty for a universal APK
      "url": "https://raw.githubusercontent.com/Clancey/stride-catalog/main/apks/io.stride.spikes-42.apk",
      "sizeBytes": 31457280,
      "sha256": "…64 hex chars…",       // of the APK file
      "signerSha256": "…64 hex chars…", // of the APK's signing certificate
      "releaseNotesUrl": "https://github.com/Clancey/stride/releases/tag/v0.4.2"
    }
  ]
}
```

The client is deliberately strict and rejects the **whole document** — rather than skipping one
entry — if any of these hold:

| Rejected | Why |
|---|---|
| unknown `schema` | A future field an old client silently ignores could be one that matters (a revocation flag). Refusing is the safe read. |
| non-`https` `url` | The console targets an SDK level that still permits cleartext; this is enforced in code instead. |
| missing/short `sha256` or `signerSha256` | The transport is not the integrity story. The digests are. |
| `versionCode` or `sizeBytes` ≤ 0 | Malformed. |
| duplicate `package`, or two `"role": "stride"` entries | Ambiguous about what would actually be installed. |

### On third-party apps

The catalog stores **URLs and digests**, not other people's software. Only host an APK in `apks/`
if you have the right to redistribute it. For anything else, point `url` at the vendor's own
download and record its digests — and note that a vendor who re-signs or moves a build will simply
cause a verification failure, which is the intended outcome.

---

## Publishing a build

```bash
tools/publish.sh path/to/app-release.apk --role stride --name Stride
```

The script computes `sizeBytes`, `sha256`, the signing certificate digest, and reads `versionCode` /
`versionName` / `minSdk` / ABIs straight out of the APK, copies it into `apks/`, and rewrites
`catalog.json`. Then:

```bash
git add -A && git commit -m "Publish Stride 0.4.2 (42)" && git push
```

The console picks it up on its next check. Nothing else has to happen.

Requirements: `apksigner` and `aapt2` from the Android SDK build-tools, plus `python3`.

> **Note on large files.** GitHub rejects files over 100 MB and warns past 50 MB. Stride's APK is
> well under that. If you ever host something larger, attach it to a GitHub Release and point `url`
> at the release asset instead — the client does not care where the bytes come from, only that they
> match the digests.

---

## Pointing a console at a different catalog

Useful for testing a build without publishing it to everyone:

```bash
adb shell am broadcast -a io.stride.spikes.APPSTORE_CHECK   # force a check
```

The catalog URL is stored in Stride's app-private preferences and can be changed from the Updates
sheet. It must be `https`; a cleartext override is rejected rather than stored.
