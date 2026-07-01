# GitHub Actions Release Builds

This repo has three separate GitHub Actions workflows:

- `CineViet Android Release`: builds mobile/tablet APKs and Android TV APK.
- `CineViet iOS Release`: builds an unsigned iOS app/IPA artifact for compile checks.
- `CineViet Windows Release`: builds and packages the Windows release ZIP.

Open GitHub repo -> Actions -> choose a workflow -> Run workflow.

## Android Signing Secrets

Android builds can run without signing secrets, but Gradle will fall back to
debug signing. Use debug-signed APKs for internal testing only.

For public direct APK releases, add these repository secrets:

- `ANDROID_KEYSTORE_BASE64`: base64 content of `cineviet-release.jks`
- `ANDROID_KEYSTORE_PASSWORD`: keystore password
- `ANDROID_KEY_ALIAS`: key alias
- `ANDROID_KEY_PASSWORD`: key password

When running the Android workflow manually, set `require_signing` to `true` to
fail the build if these secrets are missing.

## iOS Signing

The current iOS workflow intentionally builds with `--no-codesign`. The output
is useful for CI validation, but it is not a user-installable IPA.

To produce a TestFlight/App Store/Ad Hoc IPA, add Apple Developer signing assets
and replace the unsigned build/package steps with a signed archive/export flow.
