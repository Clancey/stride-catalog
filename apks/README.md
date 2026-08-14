# apks/

**Nothing is served from this directory.** It is kept only as a staging area, and `*.apk` here is
gitignored.

Artifacts live in one of two places, chosen by the entry's `role`:

| `role` | Hosted on |
|---|---|
| `stride` | GitHub Releases on this repo |
| `app` | Cloudflare R2 |

See "Where the bytes live" in the top-level [README](../README.md). `tools/publish.sh` picks the
right one automatically.

The repo used to host APKs directly from here. That was dropped because GitHub caps files at 100 MB,
serves them without useful cache headers, and — for third-party APKs especially — permanently bloats
every future clone with binaries that have nothing to do with the catalog's history.
