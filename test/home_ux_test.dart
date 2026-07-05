import 'package:cineviet_app_v2/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Movie _m(int id, String title) => Movie(
  id: id,
  title: title,
  slug: 'phim-$id',
  poster: '',
  backdrop: '',
);

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: child),
);

void main() {
  final repo = MovieRepository(Api.instance);

  testWidgets('HomeSkeleton renders without throwing', (tester) async {
    await tester.pumpWidget(_wrap(const HomeSkeleton()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(find.byType(SkeletonBox), findsWidgets);
  });

  testWidgets('PhoneHome builds with movies shared across tabs (no dup Hero tag)',
      (tester) async {
    // Cùng 1 phim (id 1) nằm ở nhiều danh mục -> kiểm tra Hero tag không trùng.
    final shared = _m(1, 'Phim Chung');
    final home = HomeData(
      featured: [shared, _m(2, 'Hero B')],
      latest: [shared, _m(3, 'Mới A')],
      cinema: [shared, _m(4, 'Rạp A')],
      series: [shared, _m(5, 'Bộ A')],
      single: [shared, _m(6, 'Lẻ A')],
      anime: [shared, _m(7, 'Anime A')],
      tvShows: [shared, _m(8, 'TV A')],
      history: const [],
    );

    await tester.pumpWidget(
      _wrap(
        PhoneHome(
          home: home,
          repo: repo,
          featured: home.featured,
          onRemoveHistory: (_) async {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);

    // Chuyển sang tab "Phim bộ" (lớp vuốt) và kiểm tra không văng exception.
    final seriesTab = find.text('Phim bộ');
    expect(seriesTab, findsOneWidget);
    await tester.tap(seriesTab);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.byType(MoviePosterCard), findsWidgets);
  });

  testWidgets('Seeded category tab renders grid, no crash', (tester) async {
    // Tab "Phim bộ" có sẵn <pageSize phim -> render lưới, không tự gọi API.
    final home = HomeData(
      featured: const [],
      latest: const [],
      cinema: const [],
      series: [_m(10, 'Bộ 1'), _m(11, 'Bộ 2'), _m(12, 'Bộ 3')],
      single: const [],
      anime: const [],
      tvShows: const [],
      history: const [],
    );
    await tester.pumpWidget(
      _wrap(
        PhoneHome(
          home: home,
          repo: repo,
          featured: const [],
          onRemoveHistory: (_) async {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    final seriesTab = find.descendant(
      of: find.byType(TabBar),
      matching: find.text('Phim bộ'),
    );
    await tester.tap(seriesTab);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.byType(MoviePosterCard), findsWidgets);
  });
}
