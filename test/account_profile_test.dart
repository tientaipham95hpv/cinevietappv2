import 'package:cineviet_app_v2/main.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ThemeData _testTheme() => ThemeData(
  snackBarTheme: SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: CvColors.panel2,
    contentTextStyle: const TextStyle(color: CvColors.text),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  ),
);

Widget _app({required Widget home}) =>
    MaterialApp(theme: _testTheme(), home: home);

Widget _wrap(Widget child) => _app(home: Scaffold(body: child));

Map<String, dynamic> _user({
  bool vip = false,
  String? vipExpiresAt,
  String avatar = '',
}) {
  final user = <String, dynamic>{
    'id': 1,
    'name': 'Boss',
    'email': 'boss@cineviet.live',
    'avatar': avatar,
    'is_vip': vip ? 1 : 0,
  };
  if (vipExpiresAt != null) user['vip_expires_at'] = vipExpiresAt;
  return user;
}

Interceptor _mockApi({
  required void Function(
    RequestOptions options,
    RequestInterceptorHandler handler,
  )
  onRequest,
}) {
  final interceptor = QueuedInterceptorsWrapper(onRequest: onRequest);
  Api.instance.dio.interceptors.add(interceptor);
  return interceptor;
}

Future<void> _withMockApi(
  WidgetTester tester,
  Future<void> Function() body, {
  required void Function(
    RequestOptions options,
    RequestInterceptorHandler handler,
  )
  onRequest,
}) async {
  SharedPreferences.setMockInitialValues({});
  await Api.instance.saveToken('test-token');
  final interceptor = _mockApi(onRequest: onRequest);
  try {
    await body();
  } finally {
    Api.instance.dio.interceptors.remove(interceptor);
    await Api.instance.clearToken();
  }
}

void _resolve(
  RequestOptions options,
  RequestInterceptorHandler handler,
  Object? data,
) {
  handler.resolve(
    Response<dynamic>(requestOptions: options, statusCode: 200, data: data),
  );
}

void _reject(
  RequestOptions options,
  RequestInterceptorHandler handler,
  int statusCode,
  Object? data,
) {
  handler.reject(
    DioException(
      requestOptions: options,
      response: Response<dynamic>(
        requestOptions: options,
        statusCode: statusCode,
        data: data,
      ),
    ),
  );
}

void main() {
  test('vipLabel formats membership state defensively', () {
    expect(vipLabel(_user()), 'Thành viên');
    expect(
      vipLabel(_user(vip: true, vipExpiresAt: '2099-12-31T08:00:00Z')),
      'VIP · hết hạn 31/12/2099',
    );
    expect(vipLabel(_user(vip: true)), 'VIP');
    expect(vipLabel(_user(vip: true, vipExpiresAt: 'not-a-date')), 'VIP');
    expect(isVipUser({'status': 'vip'}), isTrue);
    expect(isVipUser({'is_vip': true}), isTrue);
    expect(isVipUser({'is_vip': 0, 'status': 'active'}), isFalse);
  });

  test('userAvatarUrlFrom reads nested and local avatar shapes', () {
    expect(
      userAvatarUrlFrom({'avatar': '/uploads/a.jpg'}),
      'https://cineviet.live/uploads/a.jpg',
    );
    expect(
      userAvatarUrlFrom({
        'user': {'photo_url': 'https://cdn.example/avatar.png'},
      }),
      'https://cdn.example/avatar.png',
    );
    expect(userAvatarUrlFrom({'avatar': ''}), isEmpty);
  });

  testWidgets('AccountPanel stays readable on a narrow phone', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        AccountPanel(
          user: _user(vip: true, vipExpiresAt: '2100-01-01T00:00:00Z')
            ..['name'] = 'Administrator CineViet với tên rất dài',
          onLogout: () {},
          onUpdated: (_) {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('account-membership-chip')), findsOneWidget);
    expect(find.text('Mật khẩu'), findsOneWidget);
    expect(find.text('Chỉnh sửa'), findsOneWidget);
    expect(find.text('Đăng xuất'), findsOneWidget);
    expect(
      tester.getSize(find.byType(AccountPanel)).width,
      lessThanOrEqualTo(390),
    );
  });

  testWidgets('UserAvatar renders VIP frame only for VIP users', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const UserAvatar(name: 'Boss', avatarUrl: '', isVip: true, radius: 24),
      ),
    );
    expect(find.byKey(const ValueKey('user_avatar_vip_frame')), findsOneWidget);
    expect(find.byKey(const ValueKey('user_avatar_vip_badge')), findsOneWidget);
    expect(find.byIcon(Icons.workspace_premium_rounded), findsOneWidget);

    await tester.pumpWidget(
      _wrap(
        const UserAvatar(name: 'Boss', avatarUrl: '', isVip: false, radius: 24),
      ),
    );
    expect(find.byKey(const ValueKey('user_avatar_vip_frame')), findsNothing);
    expect(find.byKey(const ValueKey('user_avatar_vip_badge')), findsNothing);
  });

  testWidgets('ProfileEditScreen blocks empty display names before API calls', (
    tester,
  ) async {
    var calls = 0;
    await _withMockApi(
      tester,
      () async {
        await tester.pumpWidget(_wrap(ProfileEditScreen(user: _user())));
        await tester.enterText(find.byType(TextField), '   ');
        await tester.tap(find.text('Lưu thay đổi'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Tên hiển thị không được để trống'), findsOneWidget);
        expect(calls, 0);
      },
      onRequest: (options, handler) {
        calls += 1;
        _resolve(options, handler, {});
      },
    );
  });

  testWidgets('ProfileEditScreen shows backend profile errors', (tester) async {
    await _withMockApi(
      tester,
      () async {
        await tester.pumpWidget(_wrap(ProfileEditScreen(user: _user())));
        await tester.enterText(find.byType(TextField), 'Admin');
        await tester.tap(find.text('Lưu thay đổi'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          find.text('Tên hiển thị này không được phép sử dụng.'),
          findsOneWidget,
        );
      },
      onRequest: (options, handler) {
        if (options.path == '/user/profile') {
          _reject(options, handler, 400, {
            'error': 'Tên hiển thị này không được phép sử dụng.',
          });
          return;
        }
        _resolve(options, handler, {});
      },
    );
  });

  testWidgets(
    'ProfileEditScreen keeps updated data when profile refresh fails',
    (tester) async {
      Map<String, dynamic>? result;

      await _withMockApi(
        tester,
        () async {
          await tester.pumpWidget(
            _app(
              home: Builder(
                builder: (context) => FilledButton(
                  onPressed: () async {
                    result = await Navigator.of(context)
                        .push<Map<String, dynamic>>(
                          MaterialPageRoute(
                            builder: (_) => ProfileEditScreen(user: _user()),
                          ),
                        );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'Boss mới');
          await tester.tap(find.text('Lưu thay đổi'));
          await tester.pumpAndSettle();

          expect(result?['name'], 'Boss mới');
        },
        onRequest: (options, handler) {
          if (options.path == '/user/profile') {
            _resolve(options, handler, {..._user(), 'name': 'Boss mới'});
            return;
          }
          if (options.path == '/auth/me') {
            _reject(options, handler, 500, {'error': 'refresh failed'});
            return;
          }
          _resolve(options, handler, {});
        },
      );
    },
  );

  testWidgets('ProfileEditScreen prefers refreshed user after save', (
    tester,
  ) async {
    Map<String, dynamic>? result;

    await _withMockApi(
      tester,
      () async {
        await tester.pumpWidget(
          _app(
            home: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  result = await Navigator.of(context)
                      .push<Map<String, dynamic>>(
                        MaterialPageRoute(
                          builder: (_) => ProfileEditScreen(user: _user()),
                        ),
                      );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Boss mới');
        await tester.tap(find.text('Lưu thay đổi'));
        await tester.pumpAndSettle();

        expect(result?['name'], 'Boss từ auth/me');
        expect(result?['is_vip'], 1);
      },
      onRequest: (options, handler) {
        if (options.path == '/user/profile') {
          _resolve(options, handler, {..._user(), 'name': 'Boss mới'});
          return;
        }
        if (options.path == '/auth/me') {
          _resolve(options, handler, {
            'user': {..._user(vip: true), 'name': 'Boss từ auth/me'},
          });
          return;
        }
        _resolve(options, handler, {});
      },
    );
  });

  testWidgets('ChangePasswordScreen validates confirmation before API calls', (
    tester,
  ) async {
    var calls = 0;
    await _withMockApi(
      tester,
      () async {
        await tester.pumpWidget(_wrap(const ChangePasswordScreen()));
        final fields = find.byType(TextField);
        await tester.enterText(fields.at(0), 'old-password');
        await tester.enterText(fields.at(1), 'new-password');
        await tester.enterText(fields.at(2), 'different-password');
        await tester.tap(find.widgetWithText(FilledButton, 'Đổi mật khẩu'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          find.text('Mật khẩu mới tối thiểu 6 ký tự và phải trùng nhau'),
          findsOneWidget,
        );
        expect(calls, 0);
      },
      onRequest: (options, handler) {
        calls += 1;
        _resolve(options, handler, {});
      },
    );
  });

  testWidgets('ChangePasswordScreen shows backend errors', (tester) async {
    await _withMockApi(
      tester,
      () async {
        await tester.pumpWidget(_wrap(const ChangePasswordScreen()));
        final fields = find.byType(TextField);
        await tester.enterText(fields.at(0), 'old-password');
        await tester.enterText(fields.at(1), 'new-password');
        await tester.enterText(fields.at(2), 'new-password');
        await tester.tap(find.widgetWithText(FilledButton, 'Đổi mật khẩu'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Mật khẩu hiện tại không đúng'), findsOneWidget);
      },
      onRequest: (options, handler) {
        if (options.path == '/user/change-password') {
          _reject(options, handler, 400, {
            'error': 'Mật khẩu hiện tại không đúng',
          });
          return;
        }
        _resolve(options, handler, {});
      },
    );
  });
}
