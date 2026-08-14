# stride-catalog

The update catalog for **[Stride](https://github.com/Clancey/stride)** — a Flutter Android launcher
and workout overlay for NordicTrack / iFit consoles.

## Install Stride

On your Mac or Linux machine, with the console reachable over adb:

```bash
curl -fsSL https://raw.githubusercontent.com/Clancey/stride-catalog/main/install.sh | bash
```

That downloads Stride, checks it, installs it, and grants the permissions Stride cannot grant
itself. It prints what it is about to do and waits for you to confirm.

If the console is on your network rather than USB:

```bash
curl -fsSL https://raw.githubusercontent.com/Clancey/stride-catalog/main/install.sh | bash -s -- --connect 192.168.1.50
```

**`adb` is the only prerequisite:**

```bash
brew install --cask android-platform-tools    # macOS
sudo apt install adb                          # Debian/Ubuntu
```

Then open Stride on the console. From there it keeps itself and its apps up to date:

- **All apps → Store** — browse the catalog and install apps
- **Updates** — pending updates, and Stride's own upgrades

## Making Stride the launcher

The installer deliberately does *not* do this, because it is the one step that can leave you with a
console you cannot operate. Try Stride first. When you are happy it starts:

```bash
curl -fsSL https://raw.githubusercontent.com/Clancey/stride-catalog/main/install.sh | bash -s -- --set-home
```

Keep adb connected the first time. If anything goes wrong, put the console's own launcher back:

```bash
adb shell cmd package set-home-activity com.ifit.standalone/.MainActivity
```

Before doing this on a machine you rely on, read
[`docs/RUNBOOK.md`](https://github.com/Clancey/stride/blob/main/docs/RUNBOOK.md).

## Safety

Stride controls a machine that can physically hurt someone. Two rules are enforced in the client:

- **Installs never happen while the belt is moving.** The Android install dialog is full-screen and
  would cover the stop control. Downloads continue; installs wait for the workout to end.
- **Stride never updates itself unprompted.** A self-update kills the process, and with it the
  overlay that supplies the only Back and Home this console has.

Every download is verified twice before the installer opens: SHA-256 over the bytes, and the APK's
signing certificate against the one the catalog pins. A mismatch is a hard failure, never a warning.

## If something goes wrong

| Symptom | Fix |
|---|---|
| `adb not found` | Install platform-tools (above). |
| `no console connected` | Enable Developer options → ADB/wireless debugging on the console, then `--connect <ip>`. |
| `more than one device` | `--device <serial>`, from `adb devices`. |
| `SHA-256 mismatch` | Refused on purpose. Re-run; if it persists, open an issue — do not force it. |
| `no Stride build published yet` | The catalog is reachable but has no Stride release yet. |
| Console stuck after `--set-home` | `adb shell cmd package set-home-activity com.ifit.standalone/.MainActivity` |

Re-running the installer is safe: it reinstalls over the top and re-applies the grants.

## What this repo is

`catalog.json` is a static manifest that Stride's background `StrideAppstoreService` reads over
HTTPS. Stride's own APKs are attached to Releases here; third-party APKs live in Cloudflare R2.

```
Stride on the console ──► raw.githubusercontent.com/.../catalog.json
                          ├─► Stride     → GitHub Releases (this repo)
                          └─► other apps → Cloudflare R2
```

Nothing here runs. It is a static file host that happens to be a git repo, so every change to what
a console will install is a reviewable commit.

Publishing a build, the `catalog.json` schema, R2 setup, and why Google Play cannot be installed on
this hardware are all in **[PUBLISHING.md](PUBLISHING.md)**.
