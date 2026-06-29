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
flutter build apk --release --dart-define=APP_VARIANT=mobile --build-name=2.0.0 --build-number=9200
flutter build apk --release --dart-define=APP_VARIANT=tv --dart-define=APP_IS_TV=true --build-name=2.0.0 --build-number=9200
```

Codemagic workflows are defined in `codemagic.yaml`.
