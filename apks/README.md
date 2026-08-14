# apks/

Published artifacts, referenced by `../catalog.json`.

Named `<package>-<versionCode>.apk` so two versions of one package can never alias, and so a stale
`catalog.json` cannot silently point at a file that has been overwritten with different bytes.

Only commit an APK here if you have the right to redistribute it. For third-party apps, point the
catalog entry's `url` at the vendor's own download instead and record its digests.
