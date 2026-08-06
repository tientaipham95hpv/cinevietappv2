import 'package:cineviet_app_v2/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isDecoderCapabilityPlaybackError', () {
    test('detects Android decoder capability failures', () {
      expect(
        isDecoderCapabilityPlaybackError(
          'MediaCodecVideoRenderer error, format_supported=NO_EXCEEDS_CAPABILITIES',
        ),
        isTrue,
      );
      expect(
        isDecoderCapabilityPlaybackError('DecoderInitializationException'),
        isTrue,
      );
    });

    test('does not classify generic source failures as codec failures', () {
      expect(isDecoderCapabilityPlaybackError('Source error'), isFalse);
      expect(isDecoderCapabilityPlaybackError('Future not completed'), isFalse);
    });
  });
}
