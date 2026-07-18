import 'package:cineviet_app_v2/offline_downloads.dart';
import 'package:flutter_test/flutter_test.dart';

OfflineDownloadItem item({
  required OfflineDownloadState state,
  required int completed,
  required int total,
}) => OfflineDownloadItem(
  id: '1',
  movieId: 1,
  movieSlug: 'movie',
  movieTitle: 'Movie',
  episodeName: '1',
  serverName: 'Song ngữ',
  sourceUrl: 'https://example.com/index.m3u8',
  posterUrl: '',
  state: state,
  createdAt: DateTime(2026),
  completedFiles: completed,
  totalFiles: total,
);

void main() {
  test('active download reserves 100 percent for committed completion', () {
    expect(
      item(
        state: OfflineDownloadState.downloading,
        completed: 10,
        total: 10,
      ).progress,
      .99,
    );
  });

  test('completed download reports 100 percent', () {
    expect(
      item(
        state: OfflineDownloadState.completed,
        completed: 10,
        total: 10,
      ).progress,
      1,
    );
  });
}
