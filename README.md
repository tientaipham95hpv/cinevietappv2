# CineViet App v2

Flutter app v2 for CineViet, rebuilt as a Netflix-style cross-platform client.

## Targets

- Android mobile/tablet
- Android TV / TV box with `--dart-define=APP_IS_TV=true`
- iOS
- Windows

## Core Features

- Netflix-style home with hero banner and horizontal movie rows
- Responsive layout for mobile, tablet, desktop, and TV
- Movie search and type filters
- Movie detail, server selection, episode grid
- Video player with resume, progress saving, keyboard/remote shortcuts
- Continue watching using the existing v1 history key
- Login with access/refresh token handling
- Favorites
- Playlists and add-to-playlist
- Rating and comments
- TV login code flow
- Watch together public rooms and room creation entry
- App update check through the existing backend API

## Commands

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
export VERSION_NAME=2.0.0
export BUILD_NUMBER=$(date -u +%Y%m%d%H)
flutter build apk --release --target-platform android-arm,android-arm64 --split-per-abi --dart-define=APP_VARIANT=mobile --build-name=$VERSION_NAME --build-number=$BUILD_NUMBER
flutter build apk --release --dart-define=APP_VARIANT=tv --dart-define=APP_IS_TV=true --build-name=$VERSION_NAME --build-number=$BUILD_NUMBER
```

Codemagic workflows are defined in `codemagic.yaml`.

- `android-v2-release`: runs analyze/test, then builds signed direct-install APKs for mobile/tablet and Android TV.
- `ios-v2-release`: runs analyze/test, builds unsigned iOS app, and packages an unsigned IPA.
- `windows-v2-release`: runs analyze/test, builds Windows release, and packages a portable ZIP.

CI artifact names use `VERSION_NAME` and `BUILD_NUMBER`/`PROJECT_BUILD_NUMBER`, so every build has a unique versioned filename.
Set `RELEASE_CHANNEL` to `internal`, `staging`, or `release` to mark artifact intent.
Release channel notes, QA checklist, and release notes template live in `release/`.
Android direct APK signing setup is documented in `release/ANDROID_SIGNING.md`; copy `android/key.properties.example` to `android/key.properties` for local signed builds.
iOS no-store distribution constraints are documented in `release/IOS_DISTRIBUTION.md`; unsigned IPA artifacts are not user-installable releases.
