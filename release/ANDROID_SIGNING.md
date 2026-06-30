# Android Direct APK Signing

Android APKs must be signed even when the app is distributed directly instead
of through Google Play. Use one long-lived CineViet keystore for every public
APK so users can update without uninstalling the old app.

Keep the keystore and passwords private. Do not commit them to Git.

## When No Store Is Used

- You do not need Google Play App Signing.
- You do not need an AAB for direct installs.
- You do need signed APK files for mobile/tablet and Android TV.
- Reuse the same keystore for all future APK updates.

## Local Signing

1. Create or copy a keystore into `android/`, for example:

```bash
keytool -genkey -v -keystore android/cineviet-release.jks -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias cineviet
```

2. Copy the template:

```bash
cp android/key.properties.example android/key.properties
```

3. Edit `android/key.properties`:

```properties
storeFile=cineviet-release.jks
storePassword=your-store-password
keyAlias=cineviet
keyPassword=your-key-password
```

4. Build:

```bash
flutter build apk --release --target-platform android-arm,android-arm64 --split-per-abi --build-name=2.0.0 --build-number=2026063001
flutter build apk --release --dart-define=APP_VARIANT=tv --dart-define=APP_IS_TV=true --build-name=2.0.0 --build-number=2026063001
```

## Codemagic Secrets

Preferred direct-distribution setup: store the keystore as a base64 secret.
Add these environment variables in Codemagic:

- `CM_KEYSTORE_B64`: base64 content of `cineviet-release.jks`
- `CM_KEYSTORE_PASSWORD`: keystore password
- `CM_KEY_ALIAS`: key alias
- `CM_KEY_PASSWORD`: key password

The workflow decodes `CM_KEYSTORE_B64` into a temporary keystore file and
exports `CM_KEYSTORE_PATH` for Gradle.

Alternative secure-file setup:

- `CM_KEYSTORE_PATH`: path to the uploaded keystore file
- `CM_KEYSTORE_PASSWORD`: keystore password
- `CM_KEY_ALIAS`: key alias
- `CM_KEY_PASSWORD`: key password

Optional compatibility names:

- `ANDROID_KEYSTORE_PATH`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

## Required Signing Gate

By default, the Gradle config falls back to debug signing when release signing
secrets are missing so internal CI builds can still run. Debug-signed APKs are
for internal testing only.

Set this Codemagic variable to fail Android CI when signing is missing:

```text
REQUIRE_ANDROID_SIGNING=true
```

Use that gate for `staging` and `release` direct-distribution APK builds.

## Backup

Store `cineviet-release.jks` and the passwords in at least two private places.
Losing this keystore can prevent existing users from installing updates over
the current app.
