import 'package:cineviet_app_v2/offline_downloads.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rewrites only the exact HLS segment line', () {
    const manifest = '''#EXTM3U
#EXTINF:6,
seg-1.ts
#EXTINF:6,
seg-10.ts
#EXT-X-ENDLIST''';

    final rewritten = rewriteHlsResourceReference(
      manifest,
      'seg-1.ts',
      'segment_00000.ts',
    );

    expect(rewritten, contains('\nsegment_00000.ts\n'));
    expect(rewritten, contains('\nseg-10.ts\n'));
    expect(rewritten, isNot(contains('segment_00000.ts0')));
  });

  test('rewrites only URI attribute for encryption keys', () {
    const manifest = '''#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x01
#EXTINF:6,
key.bin.ts''';

    final rewritten = rewriteHlsResourceReference(
      manifest,
      'key.bin',
      'key_00000.key',
    );

    expect(rewritten, contains('URI="key_00000.key"'));
    expect(rewritten, contains('\nkey.bin.ts'));
  });
}
