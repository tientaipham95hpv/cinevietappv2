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

1. Copy the canonical CineViet keystore into `android/`.

Only create a new keystore for a new app identity. Existing users cannot install
an update over the current app if the signing key changes.

Example command for a brand-new app identity:

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
flutter build apk --release --flavor mobile --dart-define=APP_VARIANT=mobile --dart-define=APP_IS_TV=false --build-name=2.0.0 --build-number=2026063001
flutter build apk --release --flavor tv --dart-define=APP_VARIANT=tv --dart-define=APP_IS_TV=true --build-name=2.0.0 --build-number=2026063001
```

## Codemagic Secrets

Preferred direct-distribution setup: store the keystore as a base64 secret.
Add these environment variables in Codemagic under the
`cineviet_android_signing` variable group:

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

Release APK builds fail when release signing secrets are missing. Debug-signed
APKs are for internal testing only and must not be published as updates.

Set this Codemagic variable to make the signing requirement explicit:

```text
REQUIRE_ANDROID_SIGNING=true
```

Use that gate for `staging` and `release` direct-distribution APK builds.

## Backup

Store `cineviet-release.jks` and the passwords in at least two private places.
Losing this keystore can prevent existing users from installing updates over
the current app.
