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

  test('Movie collection parses, sorts, and survives cache serialization', () {
    final movie = Movie.fromJson({
      'id': 20,
      'title': 'Phần 2',
      'slug': 'phan-2',
      'collection': {
        'id': 3,
        'title': 'Các phần',
        'items': [
          {
            'movie_id': 20,
            'slug': 'phan-2',
            'title': 'Phần 2',
            'display_name': 'Phần hai',
            'sort_order': 2,
            'is_current': true,
          },
          {
            'movie_id': 10,
            'slug': 'phan-1',
            'title': 'Phần 1',
            'display_name': 'Phần một',
            'sort_order': 1,
            'is_current': false,
            'poster_url': 'https://example.com/1.jpg',
            'year': 2024,
          },
        ],
      },
    });
    expect(movie.collection!.items.map((item) => item.movieId), [10, 20]);
    expect(movie.collection!.items.last.isCurrent, isTrue);

    final cached = Movie.fromJson(movie.toCacheJson());
    expect(cached.collection!.items.first.label, 'Phần một');
    expect(cached.collection!.items.first.year, 2024);
  });

  test('Movie collection is safely nullable and ignores invalid shapes', () {
    expect(
      Movie.fromJson({'id': 1, 'title': 'A', 'slug': 'a'}).collection,
      isNull,
    );
    expect(
      Movie.fromJson({
        'id': 1,
        'title': 'A',
        'slug': 'a',
        'collection': {'id': 2, 'items': 'invalid'},
      }).collection,
      isNull,
    );
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

  test('WatchItem.fromJson đọc được progress cloud không có positionMs', () {
    final item = WatchItem.fromJson({
      'movie_id': 88,
      'movie': {
        'title': 'Phim Cloud',
        'slug': 'phim-cloud',
        'poster': '/poster.jpg',
      },
      'episode': 7,
      'progress': 42,
      'duration_seconds': 1000,
      'server_name': 'NguonC',
      'watched_at': '2026-07-28T03:00:00Z',
    });

    expect(item.movieId, 88);
    expect(item.slug, 'phim-cloud');
    expect(item.title, 'Phim Cloud');
    expect(item.episodeName, '7');
    expect(item.positionMs, 420000);
    expect(item.durationMs, 1000000);
    expect(item.shouldShow, isTrue);
  });

  test('Continue Watching giữ local item khi thiếu movieId nhưng có slug', () {
    final local = WatchItem(
      movieId: 0,
      slug: 'phim-mobile',
      title: 'Phim mobile',
      poster: '',
      backdrop: '',
      serverName: 'Server 1',
      serverIndex: 0,
      episodeName: '1',
      streamUrl: 'https://example.test/video.m3u8',
      positionMs: 120000,
      durationMs: 2400000,
      updatedAtMs: 20,
    );
    final older = WatchItem(
      movieId: 0,
      slug: 'phim-mobile',
      title: 'Phim mobile',
      poster: '',
      backdrop: '',
      serverName: 'Server 2',
      serverIndex: 1,
      episodeName: '1',
      streamUrl: 'https://example.test/older.m3u8',
      positionMs: 30000,
      durationMs: 2400000,
      updatedAtMs: 10,
    );

    expect(local.shouldShow, isTrue);
    final merged = mergeWatchHistoryItems([older], [local]);

    expect(merged, hasLength(1));
    expect(merged.single.streamUrl, local.streamUrl);
    expect(merged.single.progressPercent, 5);
  });

  test(
    'normalizes escaped bilingual HLS URLs and sends first-party headers',
    () {
      final url = normalizePlaybackUrl(
        r'\/api\/stream?url=https%3A%2F%2Fmedia.test%2Fdual.m3u8&amp;audio=vi',
      );
      expect(url, contains('/api/stream?url='));
      expect(url, contains('&audio=vi'));
      expect(playbackHeadersFor(Uri.parse(url)), contains('Origin'));
      expect(
        playbackHeadersFor(Uri.parse('https://media.test/video.m3u8')),
        isEmpty,
      );
    },
  );

  test('cloud history accepts nested iOS/API response and Unix seconds', () {
    final rows = cloudHistoryRows({
      'data': {
        'items': [
          {
            'movie_id': 99,
            'position_seconds': 30,
            'duration_seconds': 300,
            'updated_at_ms': 1785906000,
          },
        ],
      },
    });
    final item = WatchItem.fromJson(Map<String, dynamic>.from(rows.single));
    expect(item.movieId, 99);
    expect(item.updatedAtMs, 1785906000000);
    expect(item.shouldShow, isTrue);
  });
}
