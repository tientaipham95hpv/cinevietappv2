# Android Release Signing

Android release artifacts should be signed with a long-lived upload keystore.
Keep the keystore and passwords private. Do not commit them to Git.

## Local Signing

1. Create or copy a keystore into `android/`, for example:

```bash
keytool -genkey -v -keystore android/upload-keystore.jks -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

2. Copy the template:

```bash
cp android/key.properties.example android/key.properties
```

3. Edit `android/key.properties`:

```properties
storeFile=upload-keystore.jks
storePassword=your-store-password
keyAlias=upload
keyPassword=your-key-password
```

4. Build:

```bash
flutter build appbundle --release --build-name=2.0.0 --build-number=2026063001
```

## Codemagic Secrets

Upload the keystore as a secure file or provide an absolute path exposed by
Codemagic. Add these environment variables in Codemagic:

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
secrets are missing so internal CI builds can still run.

Set this Codemagic variable to fail Android CI when signing is missing:

```text
REQUIRE_ANDROID_SIGNING=true
```

Use that gate for production `release` builds.
