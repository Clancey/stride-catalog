# Publishing to the Stride catalog

Maintainer documentation. If you just want to install Stride on a console, see the
[README](README.md) — it is one command and you do not need anything here.

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
      "url": "https://github.com/Clancey/stride-catalog/releases/download/stride-42/io.stride.spikes-42.apk",
      "sizeBytes": 31457280,
      "sha256": "…64 hex chars…",       // of the APK file
      "signerSha256": "…64 hex chars…", // of the APK's signing certificate
      "requiresGms": false,             // optional; true = needs Google Play Services
      "releaseNotesUrl": "https://github.com/Clancey/stride-catalog/releases/tag/stride-42"
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

`requiresGms` is optional and defaults to `false`. Setting it `true` makes the console show the app
as unavailable with the reason spelled out, instead of installing something that cannot work — see
[Google Play](#google-play) below.

---

## Where the bytes live

Two stores, chosen by `role`, because the two kinds of artifact have different lifecycles — plus the
case where the bytes are already served somewhere stable and neither store is needed:

| `role` | Hosted on | Why |
|---|---|---|
| `stride` | **GitHub Releases on this repo** | Our own build. It wants to sit next to a tag and release notes, and it costs nothing to serve. It goes on *this* public repo rather than `Clancey/stride` because that repo is private, and release assets on a private repo need an auth header a treadmill will never have. |
| `app` | **Cloudflare R2** | Someone else's build. It does not belong in our git history, has no tag of ours to hang off, and is the one that will actually be large. |
| `app`, `--url` | **wherever upstream already put it** | Someone else's build that they publish themselves at a stable URL. Copying it into our bucket would add a second thing to keep current for no gain — and a vendor who re-signs or moves a build then simply causes a verification failure, which is the intended outcome. See [Apps that update themselves](#apps-that-update-themselves). |

`catalog.json` itself stays in git regardless. That is the point of the split: the bytes want a CDN,
but the *decision* about what a console will install wants a reviewable commit and a revert button.

### R2 layout

```
r2://stride/
└── apks/
    └── <package>/
        └── <package>-<versionCode>.apk
```

**An object key is immutable.** The catalog pins a `sha256` for every artifact; if you replace the
bytes behind a key some console has already read a digest for, that console refuses the download and
stops updating — and a CDN edge can go on serving either version until its TTL expires. There is no
republish operation, deliberately. A changed APK is a new `versionCode`.

`tools/publish.sh` enforces this by refusing to overwrite, and objects are uploaded with
`Cache-Control: public, max-age=31536000, immutable` precisely because they can never change.

### R2 setup, once

```bash
cp tools/r2.env.example tools/r2.env    # gitignored
$EDITOR tools/r2.env                    # account id, bucket, public base URL, API token
source tools/r2.env
```

The bucket needs public read access, via either a custom domain (recommended) or its `r2.dev`
subdomain — Cloudflare rate-limits `r2.dev` and documents it as unsuitable for production, so it is
fine for a bench test and not for machines in the field. Create the API token scoped to this one
bucket with Object Read & Write; that credential's entire job is writing APKs into it.

`tools/verify.sh` fetches every catalog entry over the public internet with no credentials and
checks it against the digest and size the catalog promises. It is the only check that catches a
bucket that was never made public, an unbound custom domain, or a catalog pushed before its upload
finished — all of which look perfectly fine from a local checkout.

### On third-party apps

The catalog stores **URLs and digests**. Only host an APK yourself if you have the right to
redistribute it; for anything else, point `url` at the vendor's own download and record its digests.
A vendor who re-signs or moves a build then simply causes a verification failure, which is the
intended outcome.

---

## Google Play

**The Play Store cannot be installed through Stride, and this is not a limitation we can code
around.**

`com.android.vending` and `com.google.android.gms` are *privileged* apps. To function they must be
installed to `/system/priv-app` **and** allowlisted in a `privapp-permissions` XML under
`/system/etc/permissions`, alongside Google Services Framework and Google Account Manager. That is
because the permissions they need — `INSTALL_PACKAGES` above all — are `signature|privileged`, and
the platform will not grant them to anything installed by `PackageInstaller`.

Sideloading the Play Store APK onto a non-GMS console therefore produces an icon that opens, fails
to sign in, and cannot install anything. It is not a partial success; it is a dead icon that costs
you a trip to the treadmill to discover. Reaching `/system` needs root or a custom recovery, which
this console has and gets neither of — a factory reset is the *last* item in the runbook's
escalation order for good reason.

APKMirror does not change this. It also cannot be a `url`: the catalog needs a stable direct link to
the exact bytes we pinned a digest for, and APKMirror serves tokenised interstitial pages.

### What to do instead

**[Aurora Store](https://gitlab.com/AuroraOSS/AuroraStore)** — an open-source (GPLv3) Play Store
client that runs as an ordinary unprivileged app and downloads from Google's own servers, with
anonymous login or your account. This is the supported way to get Play-hosted apps onto the console,
and it is freely redistributable, so it can live in the catalog like anything else:

```bash
source tools/r2.env
tools/publish.sh AuroraStore.apk --name "Aurora Store" \
  --notes https://gitlab.com/AuroraOSS/AuroraStore/-/releases
```

Aurora hands each APK to the same system installer Stride uses, so every install still shows the
confirmation dialog — and Stride's rule that no install dialog appears while the belt is moving
does **not** cover apps Aurora installs on its own. Treat it as a tool to use while parked.

Caveats worth knowing before you rely on it:

- Apps that merely *ship from* Play work fine. Spotify is one of them.
- Apps that genuinely *depend on* Play Services at runtime — push notifications, Google sign-in,
  in-app purchases, Maps — will install and then misbehave. Mark those `"requiresGms": true` in the
  catalog so the console says so up front instead of finding out the hard way.
- microG is the other route people reach for. On stock, unrooted firmware it needs signature
  spoofing that the framework does not offer, so it is not a fix here either.

---

## Publishing a build

```bash
# Stride itself -> a GitHub Release on this repo
tools/publish.sh path/to/app-release.apk --role stride --name Stride

# anything else -> Cloudflare R2
source tools/r2.env
tools/publish.sh path/to/Something.apk --name "Something"
```

The script reads `versionCode` / `versionName` / `minSdk` / ABIs straight out of the APK, computes
`sizeBytes`, `sha256` and the signing certificate digest, uploads the artifact, re-downloads it to
confirm the published bytes match, and only then rewrites `catalog.json`.

That order is deliberate: **the artifact is uploaded before the catalog is written, always.** A
catalog entry pointing at something not there yet is a failed update on every console that checks in
the meantime; an uploaded artifact no catalog mentions is invisible and harmless. When only one of
the two can succeed, it must be the harmless one.

```bash
tools/verify.sh                                          # prove the whole catalog resolves
git add -A && git commit -m "Publish Stride 0.4.2 (42)" && git push
```

The console picks it up on its next check. Nothing else has to happen.

Requirements: `apksigner` and `aapt2` from the Android SDK build-tools, `python3`, `curl`, plus
`gh` for Stride releases and `wrangler` (or `npx`) for R2.

---

## Apps that update themselves

Some projects publish their own APK on a GitHub Release, at a URL that is stable for the life of the
tag. For those there is nothing to host: the catalog records the upstream URL and its digests, and
the only recurring work is noticing that a new release exists. `upstream.json` declares which apps
those are, and `tools/sync-upstream.sh` does the noticing — on a daily schedule, in the
[Sync upstream releases](.github/workflows/upstream-sync.yml) workflow.

```jsonc
{
  "schema": 1,
  "sources": [
    {
      "package": "org.jellyfin.mobile",
      "name": "Jellyfin",
      "repo": "jellyfin/jellyfin-android",
      "asset": "^jellyfin-android-v[0-9][0-9A-Za-z.+-]*-libre-release\\.apk$",
      "signerSha256": "d881796…",   // pinned; a differently-signed release is refused
      "requiresGms": false
    }
  ]
}
```

A run reads `/releases/latest` — which excludes prereleases, so a beta tag is never handed to a
treadmill — picks the single asset matching `asset`, downloads it, and refuses to go further unless
the archive **is** the declared package and **is** signed by the pinned certificate. Only then does
it hand the file to `tools/publish.sh --url`, which records the upstream URL along with the size and
digests it read from the bytes it just fetched.

The pin is the point. Automation that follows whatever the latest tag contains is a supply chain
with no gate in it, and the console's signer check would be checking our automation against itself.
A key rotation upstream therefore stops the sync with the observed digest printed, and resuming is a
human editing `upstream.json` in a reviewable commit — which is the weight that decision deserves.
Android would refuse the update anyway; this just means finding out in CI rather than on a console.

The workflow re-fetches only the entries it changed, from the public internet with no credentials,
before committing. A `versionCode` that is not strictly greater is a no-op, so a run that finds
nothing new writes nothing at all.

To add an app: append a source, run it once locally, and commit both files.

```bash
tools/sync-upstream.sh                       # every source
tools/sync-upstream.sh org.jellyfin.mobile   # just one
```

Only for upstreams that ship a **plain, universal APK**. An `.aab`, or a per-ABI split set, needs a
publishing decision this cannot make on its own — use `tools/publish.sh` by hand.

---

## Pointing a console at a different catalog

Useful for testing a build without publishing it to everyone. Open the **Updates** sheet on the
console and change the catalog URL there; it is stored in Stride's app-private preferences.

It must be `https` — a cleartext override is rejected rather than stored, because the digest checks
are what make an unsigned transport survivable and there is no reason to weaken both at once.

**Check now** in the same sheet forces an immediate check. The service's components are not
exported, so there is deliberately no `adb`-reachable trigger: anything on the console that could
make Stride install an APK on demand would be a hole, not a feature.
