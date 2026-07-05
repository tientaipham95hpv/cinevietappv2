import 'package:flutter_test/flutter_test.dart';
import 'package:cineviet_app_v2/main.dart';

void main() {
  // Regression: phim mới crawl có episodes rỗng/null -> parseEpisodes trả const []
  // -> toán tử ..sort() cố sửa list bất biến -> ném "Cannot modify an
  // unmodifiable list" -> cả danh sách type=movie/Tất cả fail. Fix = .toList().
  test('Movie.fromJson với episodes rỗng/null không ném lỗi', () {
    for (final episodes in <dynamic>[null, [], '', '[]', 'not-json']) {
      final m = Movie.fromJson({
        'id': 1,
        'title': 'Phim test',
        'slug': 'phim-test',
        'type': 'movie',
        'episodes': episodes,
      });
      expect(m.id, 1);
      expect(m.episodes, isA<List<EpisodeServer>>());
    }
  });

  test('Movie.fromJson vẫn sort được episodes hợp lệ theo ưu tiên nguồn', () {
    final m = Movie.fromJson({
      'id': 2,
      'title': 'Phim nhiều nguồn',
      'slug': 'phim-nhieu-nguon',
      'type': 'movie',
      'episodes': [
        {
          'server_name': 'NguonC',
          'server_data': [
            {'name': 'Full', 'link_embed': 'https://streamc.xyz/abc'},
          ],
        },
        {
          'server_name': 'Ophim',
          'server_data': [
            {'name': 'Full', 'link_m3u8': 'https://ophim.cc/a.m3u8'},
          ],
        },
      ],
    });
    expect(m.episodes.length, 2);
    // Ophim (ưu tiên 0) phải đứng trước NguonC (ưu tiên 2).
    expect(m.episodes.first.name.toLowerCase(), contains('ophim'));
  });
}
