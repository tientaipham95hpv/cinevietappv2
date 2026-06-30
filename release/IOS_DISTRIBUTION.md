# iOS Distribution Without App Store

iOS does not support open direct-install distribution like Android APK files.
An unsigned IPA from CI is only an engineering artifact; normal users cannot
install it directly on iPhone or iPad.

## Practical Options

- Keep iOS disabled for public release until Apple signing is ready.
- Use an Apple Developer account with Ad Hoc provisioning for a fixed list of
  test devices.
- Use Apple Enterprise distribution only if the account and use case are valid
  for internal organization distribution.
- Use a web/PWA fallback for users who need iPhone/iPad access without App
  Store distribution.

## What Codemagic Builds Today

The `ios-v2-release` workflow builds an unsigned iOS app and packages an
unsigned IPA. This verifies that Flutter/iOS source compiles, but it is not a
user-installable release.

## To Install On Real Devices

You need Apple signing assets:

- Apple Developer team ID
- iOS distribution certificate
- Provisioning profile containing the target bundle ID
- Registered device UDIDs for Ad Hoc builds

After those are available, update Codemagic with the signing certificate and
provisioning profile, then switch the iOS workflow from `--no-codesign` to a
signed archive/export flow.
