import 'package:cineviet_app_v2/offline_downloads.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('offlineDownloadsSupportedFor', () {
    test('supports native CineViet targets', () {
      expect(
        offlineDownloadsSupportedFor(isWeb: false, platform: 'android'),
        isTrue,
      );
      expect(
        offlineDownloadsSupportedFor(isWeb: false, platform: 'ios'),
        isTrue,
      );
      expect(
        offlineDownloadsSupportedFor(isWeb: false, platform: 'windows'),
        isTrue,
      );
    });

    test('keeps web and unsupported desktop targets disabled', () {
      expect(
        offlineDownloadsSupportedFor(isWeb: true, platform: 'windows'),
        isFalse,
      );
      expect(
        offlineDownloadsSupportedFor(isWeb: false, platform: 'linux'),
        isFalse,
      );
      expect(
        offlineDownloadsSupportedFor(isWeb: false, platform: 'macos'),
        isFalse,
      );
    });
  });
}
