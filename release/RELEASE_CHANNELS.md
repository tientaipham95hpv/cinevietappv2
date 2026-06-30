# CineViet v2 Release Channels

Use `RELEASE_CHANNEL` in Codemagic to mark artifact intent. Default is `release`.

## Channels

- `internal`: fast validation builds for the team. Bugs are expected.
- `staging`: device-matrix QA builds before public release.
- `release`: candidate or production direct-install builds for users.

## Required Gates

Every channel must pass:

- `flutter analyze`
- `flutter test`
- Platform build step for the selected workflow

`staging` and `release` should also pass the manual checklist in `QA_CHECKLIST.md`.

## Artifact Naming

Artifacts follow this pattern:

```text
CineViet-v2-<channel>-<platform-or-target>-<version>+<build>.<ext>
```

Examples:

```text
CineViet-v2-release-Mobile-Tablet-arm64-v8a-2.0.0+2026062915.apk
CineViet-v2-staging-Android-TV-universal-2.0.0+2026062915.apk
CineViet-v2-internal-Windows-2.0.0+2026062915.zip
```

## Build Info

Every artifact bundle includes `BUILD_INFO.txt` with:

- app
- platform
- channel
- version
- build number
- workflow
- commit
- branch
- build time UTC
