# GitHub Actions Release Builds

This repo has three separate GitHub Actions workflows:

- `CineViet Android Release`: builds mobile/tablet APKs and Android TV APK.
- `CineViet iOS Release`: builds an unsigned iOS app/IPA artifact for compile checks.
- `CineViet Windows Release`: builds and packages the Windows release ZIP.

Open GitHub repo -> Actions -> choose a workflow -> Run workflow.

## Android Signing Secrets

For public direct APK releases, add these repository secrets:

- `ANDROID_KEYSTORE_BASE64`: base64 content of `cineviet-release.jks`
- `ANDROID_KEYSTORE_PASSWORD`: keystore password
- `ANDROID_KEY_ALIAS`: key alias
- `ANDROID_KEY_PASSWORD`: key password

For `ANDROID_KEYSTORE_BASE64`, paste the raw text from `CM_KEYSTORE_B64.txt`.
Do not paste the `.jks` file path or the binary `.jks` file content.

The workflow also accepts the Codemagic-style names `CM_KEYSTORE_B64`,
`CM_KEYSTORE_PASSWORD`, `CM_KEY_ALIAS`, and `CM_KEY_PASSWORD` if those are
already easier to copy.

Add them as repository secrets. Environment secrets are only injected when the
job is explicitly assigned to that environment.

Use the same long-lived CineViet release keystore for every public mobile/tablet
and Android TV APK. The Android workflow defaults `require_signing` to `true`
and release builds fail when these secrets are missing.

## iOS Signing

The current iOS workflow intentionally builds with `--no-codesign`. The output
is useful for CI validation, but it is not a user-installable IPA.

To produce a TestFlight/App Store/Ad Hoc IPA, add Apple Developer signing assets
and replace the unsigned build/package steps with a signed archive/export flow.
