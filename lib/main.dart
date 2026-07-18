import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show
        ContentType,
        Directory,
        File,
        HttpServer,
        HttpStatus,
        InternetAddress,
        Platform,
        Process,
        ProcessStartMode;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:media_kit/media_kit.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:webview_windows/webview_windows.dart' as windows_webview;

import 'offline_downloads.dart';

const apiBase = 'https://cineviet.live/api';
const siteBase = 'https://cineviet.live';
const tmdbImageBase = 'https://image.tmdb.org/t/p';
const appFlavor = String.fromEnvironment('FLUTTER_APP_FLAVOR');
const isTvBuild = bool.fromEnvironment('APP_IS_TV') || appFlavor == 'tv';
const googleServerClientId =
    '186784861581-5l7skrrke87pmf669l6ach0brbra4v76.apps.googleusercontent.com';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

bool get supportsTvQrScan =>
    !kIsWeb && !isTvBuild && (Platform.isAndroid || Platform.isIOS);
bool get isWindowsDesktop => !kIsWeb && !isTvBuild && Platform.isWindows;
bool get useLeanbackControls => isTvBuild || isWindowsDesktop;

bool isTouchTablet(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return !isTvBuild && !isWindowsDesktop && width >= 600;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final telemetry = await AppTelemetry.bootstrap();
  if (!kIsWeb && Platform.isWindows) {
    MediaKit.ensureInitialized();
    VideoPlayerMediaKit.ensureInitialized(windows: true);
  }
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('CineViet Flutter error: ${details.exceptionAsString()}');
    telemetry.recordFlutterFatal(details);
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('CineViet platform error: $error');
    debugPrintStack(stackTrace: stack);
    telemetry.recordFatal(error, stack);
    return true;
  };
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const CineVietV2App());
}

class AppTelemetry {
  AppTelemetry._({required this.enabled, this.analytics});

  final bool enabled;
  final FirebaseAnalytics? analytics;

  static Future<AppTelemetry> bootstrap() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return AppTelemetry._(enabled: false);
    }
    try {
      await Firebase.initializeApp();
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(
        kReleaseMode,
      );
      await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(
        kReleaseMode,
      );
      await FirebaseAnalytics.instance.logAppOpen();
      return AppTelemetry._(
        enabled: true,
        analytics: FirebaseAnalytics.instance,
      );
    } catch (error, stack) {
      debugPrint('CineViet telemetry disabled: $error');
      debugPrintStack(stackTrace: stack);
      return AppTelemetry._(enabled: false);
    }
  }

  void recordFlutterFatal(FlutterErrorDetails details) {
    if (!enabled) return;
    unawaited(FirebaseCrashlytics.instance.recordFlutterFatalError(details));
  }

  void recordFatal(Object error, StackTrace stack) {
    if (!enabled) return;
    unawaited(
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true),
    );
  }
}

class DeepLinkService {
  DeepLinkService._();
  static final AppLinks _links = AppLinks();
  static StreamSubscription<Uri>? _subscription;
  static Timer? _windowsBridgeTimer;
  static String _lastWindowsBridgeUrl = '';

  static Future<void> start(MovieRepository repo) async {
    if (kIsWeb ||
        !(Platform.isAndroid || Platform.isIOS || Platform.isWindows)) {
      return;
    }
    try {
      final initial = await _links.getInitialLink();
      if (initial != null) unawaited(open(initial, repo));
    } catch (_) {}
    await _subscription?.cancel();
    _subscription = _links.uriLinkStream.listen(
      (uri) => unawaited(open(uri, repo)),
      onError: (_) {},
    );
    if (Platform.isWindows) {
      await _consumeWindowsBridge(repo);
      _windowsBridgeTimer?.cancel();
      _windowsBridgeTimer = Timer.periodic(
        const Duration(milliseconds: 600),
        (_) => unawaited(_consumeWindowsBridge(repo)),
      );
    }
  }

  static Future<void> _consumeWindowsBridge(MovieRepository repo) async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      final file = File(windowsDeepLinkBridgePath);
      if (!await file.exists()) return;
      final url = cleanText(await file.readAsString());
      try {
        await file.delete();
      } catch (_) {
        await file.writeAsString('');
      }
      if (url.isEmpty || url == _lastWindowsBridgeUrl) return;
      _lastWindowsBridgeUrl = url;
      unawaited(open(Uri.parse(url), repo));
    } catch (_) {}
  }

  static Future<void> open(Uri uri, MovieRepository repo) async {
    final slug = _movieSlug(uri);
    if (slug == null || slug.isEmpty) return;
    try {
      final movie = await repo.detail(slug);
      final context = appNavigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      openDetail(context, repo, movie);
    } catch (_) {}
  }

  static String? _movieSlug(Uri uri) {
    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments
        .where((e) => e.trim().isNotEmpty)
        .toList();
    if (host == 'phim' && segments.isNotEmpty) return segments.first;
    final phimIndex = segments.indexWhere((e) => e.toLowerCase() == 'phim');
    if (phimIndex >= 0 && segments.length > phimIndex + 1) {
      return segments[phimIndex + 1];
    }
    return null;
  }
}

class CineVietV2App extends StatelessWidget {
  const CineVietV2App({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: CvColors.black,
      fontFamily: 'Plus Jakarta Sans',
      colorScheme: const ColorScheme.dark(
        primary: CvColors.accent,
        secondary: CvColors.accent,
        surface: CvColors.panel,
        error: CvColors.danger,
        onPrimary: CvColors.black,
        onSurface: CvColors.text,
      ),
      textTheme: Typography.whiteMountainView.apply(
        bodyColor: CvColors.text,
        displayColor: CvColors.text,
      ),
      cardTheme: CardThemeData(
        color: CvColors.panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: CvColors.border),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: CvColors.ink,
        indicatorColor: CvColors.accent.withValues(alpha: .18),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected)
                ? CvColors.accent
                : CvColors.muted,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: CvColors.panel2,
        contentTextStyle: const TextStyle(
          color: CvColors.text,
          fontWeight: FontWeight.w800,
        ),
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
    return MaterialApp(
      title: isTvBuild ? 'CineViet TV' : 'CineViet',
      debugShowCheckedModeBanner: false,
      theme: theme,
      navigatorKey: appNavigatorKey,
      home: const AppShell(),
    );
  }
}

class CvColors {
  static const black = Color(0xff07090d);
  static const ink = Color(0xff101217);
  static const panel = Color(0xff171a20);
  static const panel2 = Color(0xff20242c);
  static const border = Color(0xff2b3038);
  static const borderLight = Color(0xff3a414c);
  static const red = Color(0xffe5092f);
  static const accent = Color(0xff2de0a0);
  static const amber = Color(0xffffb020);
  static const blue = Color(0xff4da3ff);
  static const green = Color(0xff3ddc84);
  static const danger = Color(0xffef4444);
  static const text = Color(0xfff0f4f8);
  static const muted = Color(0xffb8c4d4);
  static const soft = Color(0xff7a8a9e);
}

String imageUrl(String? value) {
  final raw = (value ?? '').trim();
  if (raw.isEmpty || raw == 'null') return '';
  if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
  if (raw.startsWith('//')) return 'https:$raw';
  if (raw.startsWith('/')) return '$siteBase$raw';
  return '$siteBase/$raw';
}

String tmdbImageUrlFrom(String? value, {required bool poster}) {
  final raw = (value ?? '').trim();
  if (raw.isEmpty || raw == 'null') return '';
  if (raw.startsWith('/')) {
    return '$tmdbImageBase/${poster ? 'w500' : 'w1280'}$raw';
  }
  final uri = Uri.tryParse(raw);
  final host = uri?.host.toLowerCase() ?? '';
  final path = uri?.path ?? '';
  if (host.contains('image.tmdb.org')) {
    final fileName = uri?.pathSegments.isNotEmpty == true
        ? uri!.pathSegments.last
        : '';
    return fileName.isEmpty
        ? ''
        : '$tmdbImageBase/${poster ? 'w500' : 'w1280'}/$fileName';
  }
  if (!host.contains('phim.nguonc.com') ||
      !path.contains('/public/images/Film/')) {
    return '';
  }
  final fileName = uri?.pathSegments.isNotEmpty == true
      ? uri!.pathSegments.last
      : raw.split('/').last;
  final match = RegExp(
    r'^([A-Za-z0-9_-]{18,})\.(jpe?g|png|webp)$',
    caseSensitive: false,
  ).firstMatch(fileName);
  if (match == null) return '';
  return '$tmdbImageBase/${poster ? 'w500' : 'w1280'}/${match.group(1)}.${match.group(2)}';
}

int? asInt(dynamic value) {
  if (value == null) return null;
  return int.tryParse('$value');
}

double? asDouble(dynamic value) {
  if (value == null) return null;
  return double.tryParse('$value');
}

String cleanText(dynamic value) => '${value ?? ''}'.trim();

Map<String, dynamic> cleanMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

String userAvatarUrlFrom(Map<String, dynamic> user) {
  final nested = [
    cleanMap(user['user']),
    cleanMap(user['author']),
    cleanMap(user['profile']),
    cleanMap(user['account']),
  ].where((map) => map.isNotEmpty);
  final maps = [user, ...nested];
  for (final map in maps) {
    final avatar = cleanText(
      map['avatar'] ??
          map['user_avatar'] ??
          map['userAvatar'] ??
          map['avatarUrl'] ??
          map['avatar_url'] ??
          map['photo'] ??
          map['photoUrl'] ??
          map['photo_url'] ??
          map['picture'] ??
          map['image'] ??
          map['profilePicture'] ??
          map['profile_picture'] ??
          map['profile_photo_url'],
    );
    final url = imageUrl(avatar);
    if (url.isNotEmpty) return url;
  }
  return '';
}

bool isUnknownLabel(String value) {
  final lower = value.toLowerCase().trim();
  final key = compactKey(value);
  return key.isEmpty ||
      key == 'null' ||
      key == 'na' ||
      key == 'n/a' ||
      key == 'unknown' ||
      key == 'dangcapnhat' ||
      key == 'dangupload' ||
      key == 'updating' ||
      lower == 'đang cập nhật' ||
      lower == 'đang upload' ||
      lower == 'không rõ';
}

String compactKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

List<T> uniqueBy<T>(Iterable<T> items, String Function(T item) keyOf) {
  final seen = <String>{};
  final result = <T>[];
  for (final item in items) {
    final key = compactKey(keyOf(item));
    if (key.isEmpty || seen.contains(key)) continue;
    seen.add(key);
    result.add(item);
  }
  return result;
}

Future<Map<String, String>>? _playbackClientInfoFuture;

Future<Map<String, String>> playbackClientInfo() {
  return _playbackClientInfoFuture ??= () async {
    final info = await PackageInfo.fromPlatform();
    final platform = isTvBuild
        ? 'android_tv'
        : Platform.isAndroid
        ? 'android'
        : Platform.isIOS
        ? 'ios'
        : Platform.isWindows
        ? 'windows'
        : Platform.operatingSystem;
    var deviceModel = isTvBuild ? 'Android TV / TV Box' : platform;
    var deviceOs = Platform.operatingSystemVersion;
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final data = (await plugin.androidInfo).data;
        final manufacturer = cleanText(data['manufacturer']);
        final model = cleanText(data['model']);
        final brand = cleanText(data['brand']);
        final version = data['version'] is Map
            ? Map<String, dynamic>.from(data['version'] as Map)
            : const <String, dynamic>{};
        deviceModel = [
          if (manufacturer.isNotEmpty) manufacturer,
          if (model.isNotEmpty &&
              model.toLowerCase() != manufacturer.toLowerCase())
            model,
        ].join(' ');
        if (deviceModel.isEmpty) deviceModel = brand.isEmpty ? platform : brand;
        deviceOs = [
          'Android ${cleanText(version['release']).isEmpty ? '' : cleanText(version['release'])}'
              .trim(),
          if (cleanText(version['sdkInt']).isNotEmpty)
            'SDK ${cleanText(version['sdkInt'])}',
          if (cleanText(version['incremental']).isNotEmpty)
            cleanText(version['incremental']),
        ].where((e) => e.trim().isNotEmpty).join(' • ');
      } else if (Platform.isIOS) {
        final data = (await plugin.iosInfo).data;
        final utsname = data['utsname'] is Map
            ? Map<String, dynamic>.from(data['utsname'] as Map)
            : const <String, dynamic>{};
        deviceModel = cleanText(utsname['machine']).isNotEmpty
            ? cleanText(utsname['machine'])
            : cleanText(data['model']);
        deviceOs =
            '${cleanText(data['systemName']).isEmpty ? 'iOS' : cleanText(data['systemName'])} ${cleanText(data['systemVersion'])}'
                .trim();
      } else if (Platform.isWindows) {
        final data = (await plugin.windowsInfo).data;
        deviceModel = cleanText(data['computerName']).isEmpty
            ? 'Windows PC'
            : cleanText(data['computerName']);
        deviceOs = [
          cleanText(data['productName']).isEmpty
              ? 'Windows'
              : cleanText(data['productName']),
          if (cleanText(data['displayVersion']).isNotEmpty)
            cleanText(data['displayVersion']),
          if (cleanText(data['buildNumber']).isNotEmpty)
            'build ${cleanText(data['buildNumber'])}',
        ].join(' • ');
      }
    } catch (_) {}
    return {
      'app_platform': platform,
      'app_version': info.version,
      'app_build': info.buildNumber,
      'device_model': deviceModel,
      'device_os': deviceOs,
    };
  }();
}

String get windowsOAuthBridgePath =>
    '${Directory.systemTemp.path}\\cineviet_oauth_callback.txt';
String get windowsDeepLinkBridgePath =>
    '${Directory.systemTemp.path}\\cineviet_deeplink.txt';

List<String> csv(dynamic value) {
  if (value is List) {
    return value.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList();
  }
  final raw = cleanText(value);
  if (raw.isEmpty) return const [];
  return raw
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

String compactLanguageLabel(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final lower = raw.toLowerCase();
  final hasVietsub = lower.contains('vietsub') || lower.contains('việt sub');
  final hasThuyetMinh =
      lower.contains('thuyết minh') ||
      lower.contains('thuyet minh') ||
      lower.contains('voice over');
  final hasLongTieng =
      lower.contains('lồng tiếng') ||
      lower.contains('long tieng') ||
      lower.contains('dub');
  final labels = <String>[
    if (hasVietsub) 'VS',
    if (hasThuyetMinh) 'TM',
    if (hasLongTieng) 'LT',
  ];
  if (labels.isEmpty) return raw;
  return labels.join(' + ');
}

class Api {
  Api._() {
    dio.interceptors.add(
      QueuedInterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _readAccessToken();
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) async {
          final status = error.response?.statusCode;
          final path = error.requestOptions.path;
          final isAuthRefresh = path.contains('/auth/refresh');
          final alreadyRetried =
              error.requestOptions.extra['authRetried'] == true;
          if (status == 401 &&
              !path.contains('/auth/login') &&
              !isAuthRefresh &&
              !alreadyRetried &&
              await refreshToken()) {
            try {
              final token = await _readAccessToken();
              final retryOptions = error.requestOptions;
              retryOptions.extra['authRetried'] = true;
              if (token != null && token.isNotEmpty) {
                retryOptions.headers['Authorization'] = 'Bearer $token';
              }
              final retry = await dio.fetch<dynamic>(retryOptions);
              return handler.resolve(retry);
            } catch (_) {}
          }
          if (await _retryTransient(error, handler)) return;
          handler.next(error);
        },
      ),
    );
  }
  static final Api instance = Api._();
  final Dio dio = Dio(
    BaseOptions(
      baseUrl: apiBase,
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 25),
      headers: {
        'Accept': 'application/json',
        'User-Agent': 'CineVietFlutter/2.0',
        'X-Mobile-Key': 'cineviet-mobile-app-v2',
      },
    ),
  );
  bool _refreshing = false;
  Future<bool>? _refreshFuture;
  bool _tokensLoaded = false;
  String _accessToken = '';
  String _refreshToken = '';

  Future<bool> _retryTransient(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    final request = error.requestOptions;
    final method = request.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') return false;
    final attempts = (request.extra['retryCount'] as int?) ?? 0;
    if (attempts >= 2) return false;
    final status = error.response?.statusCode ?? 0;
    final transient =
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.connectionError ||
        status == 408 ||
        status == 429 ||
        status >= 500;
    if (!transient) return false;
    await Future<void>.delayed(Duration(milliseconds: 350 * (attempts + 1)));
    request.extra['retryCount'] = attempts + 1;
    try {
      final retry = await dio.fetch<dynamic>(request);
      handler.resolve(retry);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool get hasAuthToken {
    final header = dio.options.headers['Authorization'];
    return header is String && header.trim().startsWith('Bearer ');
  }

  Future<String?> _readAccessToken() async {
    await _ensureTokensLoaded();
    return _accessToken.isEmpty ? null : _accessToken;
  }

  Future<String?> _readRefreshToken() async {
    await _ensureTokensLoaded();
    return _refreshToken.isEmpty ? null : _refreshToken;
  }

  Future<bool> hasStoredSession() async {
    await _ensureTokensLoaded();
    return _accessToken.isNotEmpty || _refreshToken.isNotEmpty;
  }

  Future<Map<String, dynamic>?> cachedUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('cineviet_v2_cached_user');
    if (raw == null || raw.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<void> _cacheUser(Map<String, dynamic> user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cineviet_v2_cached_user', jsonEncode(user));
  }

  Future<void> _ensureTokensLoaded() async {
    if (_tokensLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    _accessToken =
        prefs.getString('cineviet_v2_access_token') ??
        prefs.getString('cineviet_access_token') ??
        '';
    _refreshToken =
        prefs.getString('cineviet_v2_refresh_token') ??
        prefs.getString('cineviet_refresh_token') ??
        '';
    _tokensLoaded = true;
  }

  Future<void> restoreToken() async {
    final token = await _readAccessToken();
    if (token != null && token.isNotEmpty) {
      dio.options.headers['Authorization'] = 'Bearer $token';
      return;
    }
    if (await refreshToken()) {
      final refreshed = await _readAccessToken();
      if (refreshed != null && refreshed.isNotEmpty) {
        dio.options.headers['Authorization'] = 'Bearer $refreshed';
      }
    }
  }

  Future<void> saveSession(String token, String refreshToken) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cineviet_v2_access_token', token);
    await prefs.setString('cineviet_access_token', token);
    _accessToken = token;
    if (refreshToken.isNotEmpty) {
      await prefs.setString('cineviet_v2_refresh_token', refreshToken);
      await prefs.setString('cineviet_refresh_token', refreshToken);
      _refreshToken = refreshToken;
    }
    _tokensLoaded = true;
    dio.options.headers['Authorization'] = 'Bearer $token';
  }

  Future<void> saveToken(String token) => saveSession(token, '');

  Future<bool> refreshToken() async {
    final running = _refreshFuture;
    if (running != null) return running;
    _refreshFuture = _refreshTokenOnce().whenComplete(() {
      _refreshFuture = null;
    });
    return _refreshFuture!;
  }

  Future<bool> _refreshTokenOnce() async {
    if (_refreshing) return false;
    _refreshing = true;
    try {
      final refresh = await _readRefreshToken();
      if (refresh == null || refresh.isEmpty) return false;
      final res = await dio.post(
        '/auth/refresh',
        data: {'refreshToken': refresh},
      );
      final token = cleanText(res.data['accessToken'] ?? res.data['token']);
      final nextRefresh = cleanText(res.data['refreshToken']);
      if (token.isEmpty) return false;
      await saveSession(token, nextRefresh.isEmpty ? refresh : nextRefresh);
      return true;
    } catch (_) {
      return false;
    } finally {
      _refreshing = false;
    }
  }

  Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('cineviet_v2_access_token');
    await prefs.remove('cineviet_v2_refresh_token');
    await prefs.remove('cineviet_access_token');
    await prefs.remove('cineviet_refresh_token');
    await prefs.remove('cineviet_v2_cached_user');
    _accessToken = '';
    _refreshToken = '';
    _tokensLoaded = true;
    dio.options.headers.remove('Authorization');
  }

  Future<Map<String, dynamic>?> currentUser({bool allowRefresh = true}) async {
    if (!hasAuthToken) await restoreToken();
    if (!hasAuthToken && allowRefresh) await refreshToken();
    if (!hasAuthToken) return null;
    try {
      final res = await dio.get('/auth/me');
      final user = userMapFromAuthResponse(res.data);
      if (user != null) await _cacheUser(user);
      if (user != null || !allowRefresh) return user;
      if (!await refreshToken()) return null;
      final retry = await dio.get('/auth/me');
      final refreshedUser = userMapFromAuthResponse(retry.data);
      if (refreshedUser != null) await _cacheUser(refreshedUser);
      return refreshedUser;
    } catch (_) {
      if (!allowRefresh || !await refreshToken()) return null;
      try {
        final retry = await dio.get('/auth/me');
        final user = userMapFromAuthResponse(retry.data);
        if (user != null) await _cacheUser(user);
        return user;
      } catch (_) {
        return null;
      }
    }
  }
}

class Movie {
  const Movie({
    required this.id,
    required this.title,
    required this.slug,
    this.titleEn = '',
    this.description = '',
    this.tmdbId = '',
    this.imdbId = '',
    this.poster = '',
    this.backdrop = '',
    this.thumbnail = '',
    this.trailerUrl = '',
    this.releaseYear,
    this.duration,
    this.rating,
    this.quality = '',
    this.language = '',
    this.country = '',
    this.type = '',
    this.episodeCurrent = '',
    this.totalEpisodes,
    this.partNumber,
    this.genres = const [],
    this.cast = const [],
    this.directors = const [],
    this.episodes = const [],
    this.related = const [],
    this.collection,
  });

  final int id;
  final String title;
  final String slug;
  final String titleEn;
  final String description;
  final String tmdbId;
  final String imdbId;
  final String poster;
  final String backdrop;
  final String thumbnail;
  final String trailerUrl;
  final int? releaseYear;
  final int? duration;
  final double? rating;
  final String quality;
  final String language;
  final String country;
  final String type;
  final String episodeCurrent;
  final int? totalEpisodes;
  final int? partNumber;
  final List<String> genres;
  final List<MoviePerson> cast;
  final List<MoviePerson> directors;
  final List<EpisodeServer> episodes;
  final List<Movie> related;
  final MovieCollection? collection;

  bool get hasTmdbId => tmdbId.trim().isNotEmpty && tmdbId.trim() != 'null';
  String get sourcePosterUrl =>
      imageUrl(poster.isNotEmpty ? poster : thumbnail);
  String get sourceBackdropUrl => imageUrl(
    backdrop.isNotEmpty
        ? backdrop
        : (thumbnail.isNotEmpty ? thumbnail : poster),
  );
  String get tmdbPosterUrl =>
      hasTmdbId ? tmdbImageUrlFrom(poster, poster: true) : '';
  String get tmdbBackdropUrl => hasTmdbId
      ? tmdbImageUrlFrom(
          backdrop.isNotEmpty ? backdrop : thumbnail,
          poster: false,
        )
      : '';
  String get posterUrl =>
      tmdbPosterUrl.isNotEmpty ? tmdbPosterUrl : sourcePosterUrl;
  String get posterFallbackUrl =>
      posterUrl != sourcePosterUrl ? sourcePosterUrl : '';
  String get backdropUrl =>
      tmdbBackdropUrl.isNotEmpty ? tmdbBackdropUrl : sourceBackdropUrl;
  String get backdropFallbackUrl =>
      backdropUrl != sourceBackdropUrl ? sourceBackdropUrl : '';
  String get routeKey => slug.isNotEmpty ? slug : '$id';
  bool get hasPlayableVideo => episodes.any(
    (server) => server.items.any((episode) => episode.playUrl.isNotEmpty),
  );
  bool get isTrailerOnly => !hasPlayableVideo && trailerUrl.isNotEmpty;
  bool get hasBilingualServer => episodes.any((server) {
    final value = server.name.toLowerCase();
    return value.contains('song ngữ') || value.contains('song ngu');
  });
  bool get isSeriesLike {
    final t = type.toLowerCase();
    return t.contains('series') ||
        t.contains('tv') ||
        t.contains('anime') ||
        (totalEpisodes ?? 0) > 1;
  }

  int? get currentEpisodeNumber {
    final matches = RegExp(r'\d+').allMatches(episodeCurrent).toList();
    if (matches.isEmpty) return null;
    return int.tryParse(matches.first.group(0) ?? '');
  }

  String get availabilityBadgeLabel {
    if (!hasPlayableVideo) return trailerUrl.isNotEmpty ? 'Trailer' : 'Sắp có';
    if (!isSeriesLike) return 'Full';
    final current = currentEpisodeNumber;
    final total = totalEpisodes;
    if (current != null && total != null && total > 0) {
      return 'Tập $current/$total';
    }
    if (current != null) return 'Tập $current';
    final raw = episodeCurrent.trim();
    if (raw.isNotEmpty) return raw;
    return 'Tập mới';
  }

  String get qualityBadgeLabel =>
      hasPlayableVideo ? (quality.isEmpty ? 'HD' : quality) : '';

  String get posterBadgeLabel => availabilityBadgeLabel;

  String get metaLine {
    return metaLineFor();
  }

  String metaLineFor({
    bool compactLanguage = false,
    bool includeQuality = true,
  }) {
    final parts = [
      if (releaseYear != null) '$releaseYear',
      if (includeQuality && quality.isNotEmpty) quality,
      if (language.isNotEmpty)
        compactLanguage ? compactLanguageLabel(language) : language,
      if (isSeriesLike && episodeCurrent.isNotEmpty) episodeCurrent,
      if (!isSeriesLike && hasPlayableVideo) 'Full',
      if (duration != null && duration! > 0) '${duration}p',
    ];
    return parts.join('  •  ');
  }

  factory Movie.fromJson(Map<String, dynamic> json) {
    List<EpisodeServer> parseEpisodes(dynamic value) {
      dynamic decoded = value;
      if (value is String && value.isNotEmpty) {
        try {
          decoded = jsonDecode(value);
        } catch (_) {
          decoded = const [];
        }
      }
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => EpisodeServer.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.items.isNotEmpty)
          .toList();
    }

    List<Movie> parseRelated(dynamic value) {
      if (value is! List) return const [];
      return value
          .whereType<Map>()
          .map((e) => Movie.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }

    MovieCollection? parseCollection(dynamic value) {
      if (value is! Map) return null;
      final parsed = MovieCollection.fromJson(Map<String, dynamic>.from(value));
      return parsed.items.isEmpty ? null : parsed;
    }

    List<MoviePerson> parsePeople(dynamic value) {
      dynamic decoded = value;
      if (value is String && value.trim().isNotEmpty) {
        try {
          decoded = jsonDecode(value);
        } catch (_) {
          decoded = value
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();
        }
      }
      if (decoded is List) {
        return decoded
            .map(MoviePerson.fromJson)
            .where((e) => e.name.isNotEmpty)
            .toList();
      }
      final single = MoviePerson.fromJson(decoded);
      return single.name.isEmpty ? const [] : [single];
    }

    int serverPriority(EpisodeServer server) {
      final name = server.name.toLowerCase();
      // Thứ tự ưu tiên nguồn phát: KKPhim/PhimAPI → OPhim → NguồnC.
      // NguồnC/StreamC chỉ là dự phòng embed/WebView, không đứng trước m3u8 sạch.
      if (name.contains('kkphim') || name.contains('phimapi')) return 0;
      if (name.contains('ophim')) return 1;
      if (name.contains('nguồn c') ||
          name.contains('nguồnc') ||
          name.contains('nguonc') ||
          server.items.any(
            (e) => e.linkEmbed.toLowerCase().contains('streamc.xyz'),
          )) {
        return 2;
      }
      return 3;
    }

    final parsedEpisodes = parseEpisodes(json['episodes']).toList()
      ..sort((a, b) {
        final pa = serverPriority(a);
        final pb = serverPriority(b);
        return pa == pb ? 0 : pa.compareTo(pb);
      });
    final videoUrl = cleanText(json['video_url']);
    final episodes = parsedEpisodes.isNotEmpty || videoUrl.isEmpty
        ? parsedEpisodes
        : [
            EpisodeServer(
              name: 'Server',
              items: [EpisodeItem(name: 'Full', linkEmbed: videoUrl)],
            ),
          ];

    return Movie(
      id: asInt(json['id']) ?? 0,
      title: cleanText(json['title']).isEmpty
          ? 'Không tên'
          : cleanText(json['title']),
      slug: cleanText(
        json['slug'].toString().isNotEmpty ? json['slug'] : json['id'],
      ),
      titleEn: cleanText(json['title_en']),
      description: cleanText(json['description']),
      tmdbId: cleanText(json['tmdb_id'] ?? json['tmdbId']),
      imdbId: cleanText(json['imdb_id'] ?? json['imdbId']),
      poster: cleanText(json['poster']),
      backdrop: cleanText(json['backdrop']),
      thumbnail: cleanText(json['thumbnail']),
      trailerUrl: cleanText(json['trailer_url'] ?? json['trailerUrl']),
      releaseYear: asInt(json['release_year']),
      duration: asInt(json['duration']),
      rating: asDouble(json['rating']) ?? asDouble(json['tmdb_vote_average']),
      quality: cleanText(json['quality']),
      language: cleanText(json['language']),
      country: cleanText(json['country']),
      type: cleanText(json['type']),
      episodeCurrent: cleanText(json['episode_current']),
      totalEpisodes: asInt(json['total_episodes']),
      partNumber: asInt(json['part_number']),
      genres: csv(json['genres']),
      cast: parsePeople(json['cast'] ?? json['actors']),
      directors: parsePeople(json['director'] ?? json['directors']),
      episodes: episodes,
      related: parseRelated(json['related']),
      collection: parseCollection(json['collection']),
    );
  }

  // Serialize gọn cho cache home (chỉ field hiển thị; episodes/cast/related
  // không cache vì màn chi tiết luôn fetch full riêng).
  Map<String, dynamic> toCacheJson() => {
    'id': id,
    'title': title,
    'slug': slug,
    'title_en': titleEn,
    'description': description,
    'tmdb_id': tmdbId,
    'imdb_id': imdbId,
    'poster': poster,
    'backdrop': backdrop,
    'thumbnail': thumbnail,
    'trailer_url': trailerUrl,
    'release_year': releaseYear,
    'duration': duration,
    'rating': rating,
    'quality': quality,
    'language': language,
    'country': country,
    'type': type,
    'episode_current': episodeCurrent,
    'total_episodes': totalEpisodes,
    'part_number': partNumber,
    'genres': genres,
    if (collection != null) 'collection': collection!.toJson(),
  };
}

class MovieCollection {
  const MovieCollection({
    required this.id,
    required this.title,
    required this.items,
  });

  final int id;
  final String title;
  final List<MovieCollectionItem> items;

  factory MovieCollection.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items =
        (rawItems is List ? rawItems : const [])
            .whereType<Map>()
            .map(
              (item) =>
                  MovieCollectionItem.fromJson(Map<String, dynamic>.from(item)),
            )
            .where((item) => item.movieId > 0 && item.slug.isNotEmpty)
            .toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return MovieCollection(
      id: asInt(json['id']) ?? 0,
      title: cleanText(json['title']),
      items: List.unmodifiable(items),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'items': items.map((item) => item.toJson()).toList(),
  };
}

class MovieCollectionItem {
  const MovieCollectionItem({
    required this.movieId,
    required this.slug,
    required this.title,
    required this.displayName,
    required this.sortOrder,
    required this.isCurrent,
    this.posterUrl = '',
    this.year,
  });

  final int movieId;
  final String slug;
  final String title;
  final String displayName;
  final int sortOrder;
  final bool isCurrent;
  final String posterUrl;
  final int? year;

  String get label => displayName.isNotEmpty ? displayName : title;

  factory MovieCollectionItem.fromJson(Map<String, dynamic> json) =>
      MovieCollectionItem(
        movieId: asInt(json['movie_id']) ?? 0,
        slug: cleanText(json['slug']),
        title: cleanText(json['title']),
        displayName: cleanText(json['display_name']),
        sortOrder: asInt(json['sort_order']) ?? 0,
        isCurrent: json['is_current'] == true || asInt(json['is_current']) == 1,
        posterUrl: cleanText(json['poster_url']),
        year: asInt(json['year']),
      );

  Map<String, dynamic> toJson() => {
    'movie_id': movieId,
    'slug': slug,
    'title': title,
    'display_name': displayName,
    'sort_order': sortOrder,
    'is_current': isCurrent,
    if (posterUrl.isNotEmpty) 'poster_url': posterUrl,
    if (year != null) 'year': year,
  };
}

class EpisodeServer {
  const EpisodeServer({required this.name, required this.items});
  final String name;
  final List<EpisodeItem> items;

  String get typeName {
    final s = name.toLowerCase();
    if (s.contains('song ngữ') ||
        s.contains('song ngu') ||
        s.contains('vicdn')) {
      return 'Song Ngữ';
    }
    if (s.contains('lồng tiếng') || s.contains('long tieng')) {
      return 'Lồng Tiếng';
    }
    if (s.contains('thuyết minh') || s.contains('thuyet minh')) {
      return 'Thuyết Minh';
    }
    if (s.contains('vietsub')) return 'Vietsub';
    return displayName;
  }

  String get sourceName {
    final s = name.toLowerCase();
    if (typeName == 'Song Ngữ' || s.contains('vicdn')) return 'Nguồn khác';
    if (s.contains('ophim')) return 'OPhim';
    if (s.contains('kkphim') || s.contains('phimapi')) return 'KKPhim';
    if (s.contains('nguồn c') ||
        s.contains('nguonc') ||
        items.any((e) => e.linkEmbed.contains('streamc.xyz'))) {
      return 'NguồnC';
    }
    return 'Nguồn khác';
  }

  bool get supportsOfflineDownload {
    final normalized = name.toLowerCase();
    final isNguonC =
        normalized.contains('nguồn c') ||
        normalized.contains('nguồnc') ||
        normalized.contains('nguonc') ||
        items.any(
          (episode) =>
              episode.linkEmbed.toLowerCase().contains('streamc.xyz') ||
              episode.playUrl.toLowerCase().contains('streamc.xyz'),
        );
    if (isNguonC) return false;
    return items.any((episode) => episode.linkM3u8.trim().isNotEmpty);
  }

  String get displayName {
    final base = name
        .replaceAll(
          RegExp(
            r'\s*\[(ophim|kkphim|phimapi|nguồn\s*c|nguonc|vicdn)\]\s*',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\s*(ophim|kkphim|phimapi|nguồn\s*c|nguonc|vicdn)\s*[-–]\s*',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final s = name.toLowerCase();
    String tag = '';
    if (RegExp(r'\[ophim\]|ophim').hasMatch(s)) {
      tag = 'ophim';
    } else if (RegExp(r'\[kkphim\]|kkphim|\[phimapi\]|phimapi').hasMatch(s)) {
      tag = 'kkphim';
    } else if (RegExp(
      r'\[nguồn\s*c\]|\[nguonc\]|nguồn\s*c|nguonc|streamc',
    ).hasMatch(s)) {
      tag = 'nguonc';
    }
    final label = base.isEmpty ? 'Nguồn' : base;
    return tag.isEmpty ? label : '$label [$tag]';
  }

  factory EpisodeServer.fromJson(Map<String, dynamic> json) => EpisodeServer(
    name: cleanText(json['server_name'] ?? json['name']).isEmpty
        ? 'Server'
        : cleanText(json['server_name'] ?? json['name']),
    items: ((json['server_data'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => EpisodeItem.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.playUrl.isNotEmpty)
        .toList(),
  );
}

class EpisodeItem {
  const EpisodeItem({
    required this.name,
    this.filename = '',
    this.linkM3u8 = '',
    this.linkEmbed = '',
    this.subtitles = const [],
    this.audioSources = const [],
  });

  final String name;
  final String filename;
  final String linkM3u8;
  final String linkEmbed;
  final List<EpisodeSubtitleTrack> subtitles;
  final List<EpisodeAudioSource> audioSources;

  String get displayName {
    final text = name.trim();
    if (RegExp(r'^\d+$').hasMatch(text)) return 'Tập $text';
    return text.isEmpty ? 'Tập' : text;
  }

  String get playUrl => linkM3u8.isNotEmpty ? linkM3u8 : linkEmbed;

  factory EpisodeItem.fromJson(Map<String, dynamic> json) => EpisodeItem(
    name: cleanText(json['name'] ?? json['slug']),
    filename: cleanText(json['filename']),
    linkM3u8: cleanText(json['link_m3u8']),
    linkEmbed: cleanText(json['link_embed']),
    subtitles: ((json['subtitles'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => EpisodeSubtitleTrack.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.url.isNotEmpty)
        .toList(),
    audioSources: ((json['audio_sources'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => EpisodeAudioSource.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.url.isNotEmpty)
        .toList(),
  );
}

class EpisodeSubtitleTrack {
  const EpisodeSubtitleTrack({
    required this.lang,
    required this.label,
    required this.url,
    this.format = 'vtt',
  });

  final String lang;
  final String label;
  final String url;
  final String format;

  factory EpisodeSubtitleTrack.fromJson(Map<String, dynamic> json) {
    final lang = cleanText(json['lang'] ?? json['language'] ?? json['key']);
    final label = cleanText(json['label'] ?? json['name']).isEmpty
        ? (lang.isEmpty ? 'Phụ đề' : lang.toUpperCase())
        : cleanText(json['label'] ?? json['name']);
    return EpisodeSubtitleTrack(
      lang: lang,
      label: label,
      url: cleanText(json['url'] ?? json['link'] ?? json['src']),
      format: cleanText(json['format']).isEmpty
          ? 'vtt'
          : cleanText(json['format']).toLowerCase(),
    );
  }
}

class BilingualCaptionFile extends ClosedCaptionFile {
  BilingualCaptionFile(ClosedCaptionFile primary, ClosedCaptionFile secondary)
    : captions = _mergeCaptions(primary.captions, secondary.captions);

  static const separator = '\u241eCINEVIET_BILINGUAL\u241e';

  @override
  final List<Caption> captions;

  static List<Caption> _mergeCaptions(
    List<Caption> primary,
    List<Caption> secondary,
  ) {
    final out = <Caption>[];
    final usedSecondary = <int>{};

    for (final first in primary) {
      Caption? best;
      var bestOverlap = Duration.zero;
      for (var i = 0; i < secondary.length; i++) {
        if (usedSecondary.contains(i)) continue;
        final second = secondary[i];
        final start = first.start > second.start ? first.start : second.start;
        final end = first.end < second.end ? first.end : second.end;
        final overlap = end - start;
        if (overlap > bestOverlap) {
          bestOverlap = overlap;
          best = second;
        }
      }
      if (best != null && bestOverlap.inMilliseconds > 0) {
        usedSecondary.add(secondary.indexOf(best));
      }
      final text = [
        first.text.trim(),
        if (best != null && best.text.trim().isNotEmpty) best.text.trim(),
      ].where((line) => line.isNotEmpty).join(separator);
      if (text.isEmpty) continue;
      out.add(
        Caption(
          number: out.length + 1,
          start: first.start,
          end: first.end,
          text: text,
        ),
      );
    }

    for (var i = 0; i < secondary.length; i++) {
      if (usedSecondary.contains(i)) continue;
      final second = secondary[i];
      final text = second.text.trim();
      if (text.isEmpty) continue;
      out.add(
        Caption(
          number: out.length + 1,
          start: second.start,
          end: second.end,
          text: text,
        ),
      );
    }

    out.sort((a, b) => a.start.compareTo(b.start));
    return [
      for (var i = 0; i < out.length; i++)
        Caption(
          number: i + 1,
          start: out[i].start,
          end: out[i].end,
          text: out[i].text,
        ),
    ];
  }
}

class AppSubtitleStyle {
  const AppSubtitleStyle({
    this.font = 'Lora',
    required this.size,
    required this.color,
    required this.bottom,
  });

  final String font;
  final double size;
  final Color color;
  final double bottom;

  AppSubtitleStyle copyWith({
    String? font,
    double? size,
    Color? color,
    double? bottom,
  }) => AppSubtitleStyle(
    font: font ?? this.font,
    size: size ?? this.size,
    color: color ?? this.color,
    bottom: bottom ?? this.bottom,
  );

  Map<String, dynamic> toJson() => {
    'font': font,
    'size': size,
    'color': color.toARGB32(),
    'bottom': bottom,
  };

  factory AppSubtitleStyle.fromJson(Object? raw, AppSubtitleStyle fallback) {
    if (raw is! Map) return fallback;
    const fonts = ['Lora', 'Plus Jakarta Sans', 'Arial', 'Tahoma'];
    final font = fonts.contains(raw['font']) ? raw['font'] as String : 'Lora';
    return AppSubtitleStyle(
      font: font,
      size: ((raw['size'] as num?)?.toDouble() ?? fallback.size).clamp(10, 50),
      color: Color(
        (raw['color'] as num?)?.toInt() ?? fallback.color.toARGB32(),
      ),
      bottom: ((raw['bottom'] as num?)?.toDouble() ?? fallback.bottom).clamp(
        2,
        30,
      ),
    );
  }
}

class EpisodeAudioSource {
  const EpisodeAudioSource({
    required this.key,
    required this.label,
    required this.url,
  });

  final String key;
  final String label;
  final String url;

  factory EpisodeAudioSource.fromJson(Map<String, dynamic> json) {
    final key = cleanText(json['key'] ?? json['lang'] ?? json['id']);
    final label = cleanText(json['label'] ?? json['name']).isEmpty
        ? (key.isEmpty ? 'Audio' : key)
        : cleanText(json['label'] ?? json['name']);
    return EpisodeAudioSource(
      key: key.isEmpty ? compactKey(label) : key,
      label: label,
      url: cleanText(json['url'] ?? json['link'] ?? json['src']),
    );
  }
}

class PlaybackSourceCandidate {
  const PlaybackSourceCandidate({
    required this.server,
    required this.episode,
    required this.serverIndex,
    required this.qualityLabel,
    required this.qualityRank,
    required this.sourceLabel,
    required this.urls,
    this.webViewUrl,
  });

  final EpisodeServer server;
  final EpisodeItem episode;
  final int serverIndex;
  final String qualityLabel;
  final int qualityRank;
  final String sourceLabel;
  final List<String> urls;
  final String? webViewUrl;

  String get id =>
      '${serverIndex}_${compactKey(server.name)}_${compactKey(episode.name)}_'
      '${compactKey(episode.linkM3u8)}_${compactKey(episode.linkEmbed)}';

  bool get isWebViewOnly => urls.isEmpty && webViewUrl != null;

  String get displayName => '$sourceLabel • $qualityLabel';
}

class PlaybackUrlCandidate {
  const PlaybackUrlCandidate({required this.source, required this.url});

  final PlaybackSourceCandidate source;
  final String url;
}

class IntroSkipSegment {
  const IntroSkipSegment({
    required this.type,
    required this.start,
    required this.end,
  });

  final String type;
  final Duration start;
  final Duration end;

  String get key => '$type:${start.inMilliseconds}:${end.inMilliseconds}';

  String get buttonLabel {
    switch (type) {
      case 'recap':
        return 'Bỏ qua recap';
      case 'outro':
        return 'Bỏ qua outro';
      default:
        return 'Bỏ qua intro';
    }
  }

  factory IntroSkipSegment.fromJson(Map<String, dynamic> json) {
    final type = cleanText(json['type']).toLowerCase();
    final start = asDouble(json['start_sec']) ?? 0;
    final end = asDouble(json['end_sec']) ?? 0;
    return IntroSkipSegment(
      type: type.isEmpty ? 'intro' : type,
      start: Duration(milliseconds: (start * 1000).round()),
      end: Duration(milliseconds: (end * 1000).round()),
    );
  }
}

class IntroSkipData {
  const IntroSkipData({required this.segments});

  final List<IntroSkipSegment> segments;

  bool get hasSegments => segments.isNotEmpty;

  factory IntroSkipData.fromJson(Map<String, dynamic> json) {
    final rows =
        ((json['segments'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => IntroSkipSegment.fromJson(Map<String, dynamic>.from(e)))
            .where((e) => e.end > e.start)
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    return IntroSkipData(segments: List.unmodifiable(rows));
  }
}

class ServerCheckResult {
  const ServerCheckResult({
    required this.serverIndex,
    required this.label,
    required this.ok,
    required this.status,
    required this.responseMs,
  });

  final int serverIndex;
  final String label;
  final bool ok;
  final int status;
  final int responseMs;

  factory ServerCheckResult.fromJson(Map<String, dynamic> json) =>
      ServerCheckResult(
        serverIndex: asInt(json['serverIndex']) ?? -1,
        label: cleanText(json['label']).isEmpty
            ? 'Lỗi'
            : cleanText(json['label']),
        ok: json['ok'] == true,
        status: asInt(json['status']) ?? 0,
        responseMs: asInt(json['responseMs']) ?? 0,
      );
}

class WatchItem {
  const WatchItem({
    required this.movieId,
    required this.slug,
    required this.title,
    required this.poster,
    required this.backdrop,
    required this.serverName,
    required this.serverIndex,
    required this.episodeName,
    required this.streamUrl,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAtMs,
  });

  final int movieId;
  final String slug;
  final String title;
  final String poster;
  final String backdrop;
  final String serverName;
  final int serverIndex;
  final String episodeName;
  final String streamUrl;
  final int positionMs;
  final int durationMs;
  final int updatedAtMs;

  String get key => '$slug|$serverName|$episodeName';
  double get progress =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0, 1) : 0;
  bool get isCompleted => progress >= 0.95;
  int get progressPercent {
    final percent = (progress * 100).round().clamp(0, 100);
    if (percent <= 0 && positionMs >= 3000 && !isCompleted) return 1;
    return percent;
  }

  bool get shouldShow => positionMs >= 3000 && !isCompleted;

  Map<String, dynamic> toJson() => {
    'movieId': movieId,
    'slug': slug,
    'title': title,
    'poster': poster,
    'backdrop': backdrop,
    'serverName': serverName,
    'serverIndex': serverIndex,
    'episodeName': episodeName,
    'streamUrl': streamUrl,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAtMs': updatedAtMs,
  };

  Map<String, dynamic> toCloudJson() => {
    'movie_id': movieId,
    'episode': episodeNumber(episodeName),
    'progress': progressPercent,
    'completed': isCompleted ? 1 : 0,
    'position_seconds': positionMs / 1000,
    'duration_seconds': durationMs / 1000,
    'server_index': serverIndex,
    'episode_name': episodeName,
    'server_name': serverName,
    'stream_url': streamUrl,
  };

  factory WatchItem.fromJson(Map<String, dynamic> json) => WatchItem(
    movieId: asInt(json['movieId'] ?? json['movie_id']) ?? 0,
    slug: cleanText(json['slug']),
    title: cleanText(json['title']).isEmpty
        ? 'Không tên'
        : cleanText(json['title']),
    poster: imageUrl(json['poster'] ?? json['posterUrl'] ?? json['thumbnail']),
    backdrop: imageUrl(
      json['backdrop'] ?? json['backdropUrl'] ?? json['thumbnail'],
    ),
    serverName: cleanText(json['serverName'] ?? json['server_name']).isEmpty
        ? 'Server'
        : cleanText(json['serverName'] ?? json['server_name']),
    serverIndex: asInt(json['serverIndex'] ?? json['server_index']) ?? 0,
    episodeName: cleanText(
      json['episodeName'] ?? json['episode_name'] ?? json['episode'],
    ).replaceFirst(RegExp(r'^$'), 'Tập'),
    streamUrl: cleanText(json['streamUrl'] ?? json['stream_url']),
    positionMs:
        asInt(json['positionMs']) ??
        (((asDouble(json['position_seconds']) ?? 0) * 1000).round()),
    durationMs:
        asInt(json['durationMs']) ??
        (((asDouble(json['duration_seconds']) ?? 0) * 1000).round()),
    updatedAtMs:
        asInt(json['updatedAtMs']) ??
        DateTime.tryParse(
          cleanText(json['watched_at']),
        )?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch,
  );
}

class CinePlaylist {
  const CinePlaylist({
    required this.id,
    required this.name,
    required this.slug,
    this.description = '',
    this.cover = '',
    this.movieCount = 0,
    this.isPublic = false,
  });

  final int id;
  final String name;
  final String slug;
  final String description;
  final String cover;
  final int movieCount;
  final bool isPublic;

  factory CinePlaylist.fromJson(Map<String, dynamic> json) => CinePlaylist(
    id: asInt(json['id']) ?? 0,
    name: cleanText(json['name']).isEmpty
        ? 'Playlist'
        : cleanText(json['name']),
    slug: cleanText(json['slug'] ?? json['id']),
    description: cleanText(json['description']),
    cover: imageUrl(json['cover'] ?? json['poster'] ?? json['backdrop']),
    movieCount: asInt(json['movie_count'] ?? json['movieCount']) ?? 0,
    isPublic: (asInt(json['is_public'] ?? json['isPublic']) ?? 0) == 1,
  );
}

class PlaylistDetail {
  const PlaylistDetail({required this.playlist, required this.movies});
  final CinePlaylist playlist;
  final List<Movie> movies;
}

class MoviePerson {
  const MoviePerson({required this.name, this.avatar = ''});
  final String name;
  final String avatar;

  String get avatarUrl {
    final raw = avatar.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('/') && !raw.startsWith('/uploads/')) {
      return 'https://image.tmdb.org/t/p/w185$raw';
    }
    return imageUrl(raw);
  }

  factory MoviePerson.fromJson(dynamic value) {
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      return MoviePerson(
        name: cleanText(map['name'] ?? map['title']),
        avatar: cleanText(map['avatar'] ?? map['photo'] ?? map['profile_path']),
      );
    }
    return MoviePerson(name: cleanText(value));
  }
}

List<MoviePerson> cleanPeople(
  Iterable<MoviePerson> people, {
  Set<String> exclude = const {},
}) {
  final excluded = exclude.map(compactKey).where((e) => e.isNotEmpty).toSet();
  return uniqueBy(
    people.where((person) {
      final key = compactKey(person.name);
      return !isUnknownLabel(person.name) && !excluded.contains(key);
    }),
    (person) => person.name,
  );
}

class MovieComment {
  const MovieComment({
    required this.id,
    required this.content,
    required this.userName,
    required this.createdAt,
    this.userAvatar = '',
    this.likes = 0,
    this.isSpoiler = false,
    this.isVip = false,
    this.isAdmin = false,
  });

  final int id;
  final String content;
  final String userName;
  final String userAvatar;
  final String createdAt;
  final int likes;
  final bool isSpoiler;
  final bool isVip;
  final bool isAdmin;

  factory MovieComment.fromJson(Map<String, dynamic> json) {
    final nestedUser = cleanMap(json['user']).isNotEmpty
        ? cleanMap(json['user'])
        : cleanMap(json['author']);
    final userName = cleanText(
      json['user_name'] ??
          json['userName'] ??
          json['name'] ??
          nestedUser['name'] ??
          nestedUser['displayName'] ??
          nestedUser['email'],
    );
    return MovieComment(
      id: asInt(json['id']) ?? 0,
      content: cleanText(json['content']),
      userName: userName.isEmpty ? 'CineViet' : userName,
      userAvatar: userAvatarUrlFrom({...json, ...nestedUser}),
      createdAt: cleanText(json['created_at'] ?? json['createdAt']),
      likes:
          asInt(json['likes'] ?? json['like_count'] ?? json['likeCount']) ?? 0,
      isSpoiler:
          json['is_spoiler'] == true || (asInt(json['is_spoiler']) ?? 0) == 1,
      isVip:
          json['user_is_vip'] == true ||
          (asInt(json['user_is_vip'] ?? json['is_vip']) ?? 0) == 1,
      isAdmin: isAdminUser({...json, ...nestedUser}),
    );
  }
}

class RatingStats {
  const RatingStats({
    required this.average,
    required this.total,
    this.userRating,
  });
  final double average;
  final int total;
  final int? userRating;

  factory RatingStats.fromJson(Map<String, dynamic> json) => RatingStats(
    average: asDouble(json['average'] ?? json['rating']) ?? 0,
    total: asInt(json['total'] ?? json['count']) ?? 0,
    userRating: asInt(json['userRating'] ?? json['user_rating']),
  );
}

class TvLoginSession {
  const TvLoginSession({
    required this.sessionId,
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.qrData,
    required this.expiresIn,
    required this.interval,
    this.expiresAt,
  });

  final String sessionId;
  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final String qrData;
  final int expiresIn;
  final int interval;
  final DateTime? expiresAt;

  factory TvLoginSession.fromJson(Map<String, dynamic> json) {
    final expiresAtMs = asInt(json['expiresAt']);
    return TvLoginSession(
      sessionId: cleanText(json['sessionId']),
      deviceCode: cleanText(json['deviceCode'] ?? json['sessionId']),
      userCode: cleanText(json['code'] ?? json['userCode']),
      verificationUrl: cleanText(
        json['verificationUriComplete'] ?? json['verificationUrl'],
      ),
      qrData: cleanText(json['qrData']),
      expiresIn: asInt(json['expiresIn']) ?? 600,
      interval: asInt(json['interval']) ?? 2,
      expiresAt: expiresAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expiresAtMs),
    );
  }
}

class WatchRoom {
  const WatchRoom({
    required this.code,
    required this.movieTitle,
    required this.videoUrl,
    required this.memberCount,
    required this.maxMembers,
  });

  final String code;
  final String movieTitle;
  final String videoUrl;
  final int memberCount;
  final int maxMembers;

  factory WatchRoom.fromJson(Map<String, dynamic> json) => WatchRoom(
    code: cleanText(json['code']),
    movieTitle: cleanText(json['movieTitle']).isEmpty
        ? 'Phòng xem chung'
        : cleanText(json['movieTitle']),
    videoUrl: cleanText(json['videoUrl']),
    memberCount: asInt(json['memberCount']) ?? 0,
    maxMembers: asInt(json['maxMembers']) ?? 8,
  );
}

class WatchTogetherMember {
  const WatchTogetherMember({required this.id, required this.name});
  final String id;
  final String name;

  factory WatchTogetherMember.fromJson(Map<String, dynamic> json) =>
      WatchTogetherMember(
        id: cleanText(json['id']),
        name: cleanText(json['name']).isEmpty
            ? 'Thành viên'
            : cleanText(json['name']),
      );
}

class WatchTogetherMessage {
  const WatchTogetherMessage({
    required this.id,
    required this.type,
    required this.payload,
    this.userName,
  });

  final String id;
  final String type;
  final String payload;
  final String? userName;

  bool get isSystem => type == 'system';

  factory WatchTogetherMessage.fromJson(Map<String, dynamic> json) =>
      WatchTogetherMessage(
        id: cleanText(json['id']).isEmpty
            ? '${DateTime.now().millisecondsSinceEpoch}'
            : cleanText(json['id']),
        type: cleanText(json['type']).isEmpty
            ? 'text'
            : cleanText(json['type']),
        payload: cleanText(json['payload']),
        userName: cleanText(json['userName']).isEmpty
            ? null
            : cleanText(json['userName']),
      );
}

class WatchTogetherState {
  const WatchTogetherState({
    required this.code,
    required this.movieTitle,
    required this.videoUrl,
    required this.hostSocketId,
    required this.members,
    required this.currentTime,
    required this.playing,
    required this.messages,
  });

  final String code;
  final String movieTitle;
  final String videoUrl;
  final String hostSocketId;
  final List<WatchTogetherMember> members;
  final double currentTime;
  final bool playing;
  final List<WatchTogetherMessage> messages;

  factory WatchTogetherState.fromJson(
    Map<String, dynamic> json,
  ) => WatchTogetherState(
    code: cleanText(json['code']),
    movieTitle: cleanText(json['movieTitle']).isEmpty
        ? 'Phòng xem chung'
        : cleanText(json['movieTitle']),
    videoUrl: cleanText(json['videoUrl']),
    hostSocketId: cleanText(json['hostSocketId']),
    members: ((json['members'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => WatchTogetherMember.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    currentTime: asDouble(json['currentTime']) ?? 0,
    playing: json['playing'] == true,
    messages: ((json['messages'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => WatchTogetherMessage.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
  );
}

class WatchTogetherCreateResult {
  const WatchTogetherCreateResult({required this.code, this.room});
  final String code;
  final WatchTogetherState? room;
}

class _MovieListCacheEntry {
  const _MovieListCacheEntry(this.movies, this.expiresAt);
  final List<Movie> movies;
  final DateTime expiresAt;

  bool get isFresh => DateTime.now().isBefore(expiresAt);
}

class MovieRepository {
  MovieRepository(this.api);
  static const Duration _listCacheTtl = Duration(minutes: 10);
  final Api api;
  final Map<String, Movie> _cache = {};
  final Map<String, _MovieListCacheEntry> _listCache = {};
  Set<int>? _favoriteIdsCache;
  static io.Socket? _activeWatchRoomSocket;
  static String? _activeWatchRoomCode;
  static bool _activeWatchRoomIsHost = false;

  static io.Socket? get activeWatchRoomSocket => _activeWatchRoomSocket;
  static String? get activeWatchRoomSocketId => _activeWatchRoomSocket?.id;
  static String? get activeWatchRoomCode => _activeWatchRoomCode;
  static bool get activeWatchRoomIsHost => _activeWatchRoomIsHost;

  Future<List<Movie>> list({
    int page = 1,
    int limit = 24,
    String search = '',
    String type = '',
    String genre = '',
    String country = '',
    String year = '',
    String sort = 'created_at',
    String featured = '',
    String cinema = '',
    String bilingual = '',
    bool forceRefresh = false,
  }) async {
    final query = {
      'page': page,
      'limit': limit,
      'sort': sort,
      'order': 'desc',
      if (search.trim().isNotEmpty) 'search': search.trim(),
      if (type.isNotEmpty) 'type': type,
      if (genre.isNotEmpty) 'genre': genre,
      if (country.isNotEmpty) 'country': country,
      if (year.isNotEmpty) 'release_year': year,
      if (featured.isNotEmpty) 'featured': featured,
      if (cinema.isNotEmpty) 'chieu_rap': cinema,
      if (bilingual.isNotEmpty) 'song_ngu': bilingual,
    };
    final cacheKey = _listCacheKey(query);
    final cached = _listCache[cacheKey];
    if (!forceRefresh && cached != null && cached.isFresh) {
      return List<Movie>.of(cached.movies);
    }

    final res = await api.dio.get('/movies', queryParameters: query);
    final movies = ((res.data['movies'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Movie.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    for (final movie in movies) {
      _cache[movie.routeKey] = movie;
      _cache['${movie.id}'] = movie;
    }
    _listCache[cacheKey] = _MovieListCacheEntry(
      List<Movie>.unmodifiable(movies),
      DateTime.now().add(_listCacheTtl),
    );
    return movies;
  }

  String _listCacheKey(Map<String, Object> query) {
    final entries = query.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries.map((entry) => '${entry.key}=${entry.value}').join('&');
  }

  Future<List<(String, String)>> genres() => _metaList(
    '/movies/meta/genres',
    fallback: _BrowseScreenState.defaultGenres,
    allLabel: 'Tất cả thể loại',
  );

  Future<List<(String, String)>> countries() => _metaList(
    '/movies/meta/countries',
    fallback: _BrowseScreenState.defaultCountries,
    allLabel: 'Tất cả quốc gia',
  );

  Future<List<(String, String)>> _metaList(
    String path, {
    required List<(String, String)> fallback,
    required String allLabel,
  }) async {
    try {
      final res = await api.dio.get(path);
      final rows = res.data is List ? res.data as List : const [];
      final items = <(String, String)>[('', allLabel)];
      for (final row in rows) {
        if (row is! Map) continue;
        final slug = cleanText(row['slug']);
        final name = cleanText(row['name']);
        if (slug.isNotEmpty && name.isNotEmpty) items.add((slug, name));
      }
      return items.length > 1 ? items : fallback;
    } catch (_) {
      return fallback;
    }
  }

  Future<Movie> detail(String idOrSlug) async {
    final res = await api.dio.get('/movies/$idOrSlug');
    final movie = Movie.fromJson(Map<String, dynamic>.from(res.data as Map));
    _cache[movie.routeKey] = movie;
    _cache['${movie.id}'] = movie;
    return movie;
  }

  Future<IntroSkipData?> introSkipSegments({
    required Movie movie,
    required EpisodeItem episode,
  }) async {
    if (!movie.isSeriesLike || movie.id <= 0) return null;
    final episodeNo = episodeNumber(episode.displayName);
    if (episodeNo <= 0) return null;
    try {
      final res = await api.dio.get(
        '/app/intro-segments',
        queryParameters: {
          'movie_id': movie.id,
          'episode': episodeNo,
          if ((movie.partNumber ?? 0) > 0) 'season': movie.partNumber,
        },
      );
      final data = Map<String, dynamic>.from(res.data as Map);
      final parsed = IntroSkipData.fromJson(data);
      return parsed.hasSegments ? parsed : null;
    } catch (_) {
      return null;
    }
  }

  Future<List<WatchItem>> cloudHistory() async {
    try {
      final res = await api.dio.get(
        '/history/continue-watching',
        queryParameters: {'limit': 20},
      );
      final rows = res.data is List
          ? res.data as List
          : ((res.data['history'] as List?) ?? const []);
      final list = rows
          .whereType<Map>()
          .map((e) => WatchItem.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.shouldShow)
          .toList();
      return list;
    } catch (_) {
      return const [];
    }
  }

  Future<void> syncWatch(WatchItem item) async {
    try {
      await api.dio.post(
        '/movies/${item.movieId}/watch',
        data: item.toCloudJson(),
      );
      await api.dio.post('/history', data: item.toCloudJson());
    } catch (_) {}
  }

  Future<int> syncLocalHistoryToCloud() async {
    if (!api.hasAuthToken) return 0;
    final local = await LocalHistory.items();
    final deletedIds = await LocalHistory.deletedMovieIds();
    final cloudByMovie = <int, WatchItem>{};
    try {
      for (final item in await cloudHistory()) {
        final existing = cloudByMovie[item.movieId];
        if (existing == null || item.updatedAtMs > existing.updatedAtMs) {
          cloudByMovie[item.movieId] = item;
        }
      }
    } catch (_) {}
    final latestLocalByMovie = <int, WatchItem>{};
    for (final item in local) {
      if (!item.shouldShow || item.movieId <= 0) continue;
      if (deletedIds.contains(item.movieId)) continue;
      final existing = latestLocalByMovie[item.movieId];
      if (existing == null || item.updatedAtMs > existing.updatedAtMs) {
        latestLocalByMovie[item.movieId] = item;
      }
    }
    var synced = 0;
    for (final item in latestLocalByMovie.values) {
      final cloud = cloudByMovie[item.movieId];
      if (cloud != null && cloud.updatedAtMs >= item.updatedAtMs) continue;
      try {
        await api.dio.post(
          '/movies/${item.movieId}/watch',
          data: item.toCloudJson(),
        );
        await api.dio.post('/history', data: item.toCloudJson());
        synced += 1;
      } catch (_) {
        // Keep local history intact; retry on next login/startup.
      }
    }
    return synced;
  }

  Future<int> syncLocalFavoritesToCloud() async {
    if (!api.hasAuthToken) return 0;
    final local = await LocalFavorites.items();
    var synced = 0;
    for (final movie in local) {
      if (movie.id <= 0) continue;
      try {
        await api.dio.post('/user/favorites/${movie.id}');
        synced += 1;
      } catch (_) {
        // Keep local favorites intact; retry on next login/startup.
      }
    }
    if (synced > 0) _favoriteIdsCache = null;
    return synced;
  }

  Future<({int history, int favorites})> syncLocalLibraryToCloud() async {
    final history = await syncLocalHistoryToCloud();
    final favorites = await syncLocalFavoritesToCloud();
    return (history: history, favorites: favorites);
  }

  Future<void> reportPlaybackEvent({
    required Movie movie,
    required EpisodeServer server,
    required EpisodeItem episode,
    required String eventType,
    String errorCode = '',
    String errorMessage = '',
    String sourceType = '',
    String sourceLabel = '',
    String sourceMode = '',
    String sessionId = '',
  }) async {
    try {
      final clientInfo = await playbackClientInfo();
      await api.dio.post(
        '/app/playback-event',
        data: {
          'movie_id': movie.id,
          'episode': episodeNumber(episode.name),
          'server_name': server.displayName,
          'source_type': sourceType,
          'event_type': eventType,
          'error_code': errorCode,
          'error_message': errorMessage,
          'source_label': sourceLabel,
          'source_mode': sourceMode,
          'session_id': sessionId,
          ...clientInfo,
        },
      );
    } catch (_) {}
  }

  Future<({Map<int, ServerCheckResult> results, int? bestServerIndex})>
  checkServers(List<Map<String, dynamic>> sources) async {
    final res = await api.dio.post('/server-check', data: {'sources': sources});
    final data = Map<String, dynamic>.from(res.data as Map);
    final rows = ((data['results'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => ServerCheckResult.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.serverIndex >= 0)
        .toList();
    return (
      results: {for (final row in rows) row.serverIndex: row},
      bestServerIndex: asInt(data['bestServerIndex']),
    );
  }

  Future<void> reportWatch({
    required Movie movie,
    required EpisodeServer server,
    required EpisodeItem episode,
    required String message,
  }) async {
    if (!api.hasAuthToken) {
      await reportPlaybackEvent(
        movie: movie,
        server: server,
        episode: episode,
        eventType: 'user_report',
        errorCode: 'manual_report_guest',
        errorMessage: message,
      );
      return;
    }
    await api.dio.post(
      '/user/report-watch',
      data: {
        'movie_id': movie.id,
        'episode': episodeNumber(episode.name),
        'report_type': 'video_error',
        'message': message,
      },
    );
  }

  Future<void> deleteHistoryMovie(int movieId) async {
    if (movieId <= 0) return;
    await api.dio.delete('/history/$movieId');
  }

  Future<void> clearHistory() async {
    await api.dio.delete('/history');
  }

  Future<List<Movie>> favorites() async {
    if (!api.hasAuthToken) return LocalFavorites.items();
    try {
      final res = await api.dio.get('/user/favorites');
      final data = res.data;
      final rows = data is Map
          ? ((data['movies'] as List?) ??
                (data['favorites'] as List?) ??
                const [])
          : (data is List ? data : const []);
      final movies = rows
          .whereType<Map>()
          .map((e) => Movie.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      _favoriteIdsCache = movies
          .map((movie) => movie.id)
          .where((id) => id > 0)
          .toSet();
      return movies;
    } catch (_) {
      return const [];
    }
  }

  Future<Set<int>> favoriteIds({bool force = false}) async {
    if (!api.hasAuthToken) {
      _favoriteIdsCache = null;
      return LocalFavorites.ids();
    }
    final cached = _favoriteIdsCache;
    if (!force && cached != null) return cached;
    try {
      final res = await api.dio.get('/user/favorite-ids');
      final data = res.data;
      final rows = data is Map
          ? ((data['ids'] as List?) ??
                (data['movie_ids'] as List?) ??
                (data['favorites'] as List?) ??
                const [])
          : (data is List ? data : const []);
      final ids = rows
          .map(
            (value) => value is Map ? value['movie_id'] ?? value['id'] : value,
          )
          .map(asInt)
          .whereType<int>()
          .where((id) => id > 0)
          .toSet();
      _favoriteIdsCache = ids;
      return ids;
    } catch (_) {
      final movies = await favorites();
      return movies.map((movie) => movie.id).where((id) => id > 0).toSet();
    }
  }

  Future<bool> isFavorite(Movie movie, {bool force = false}) async {
    if (movie.id <= 0) return false;
    final ids = await favoriteIds(force: force);
    return ids.contains(movie.id);
  }

  Future<void> toggleFavorite(Movie movie, bool add) async {
    if (!api.hasAuthToken) {
      if (add) {
        await LocalFavorites.upsert(movie);
      } else {
        await LocalFavorites.remove(movie.id);
      }
      _favoriteIdsCache = null;
      return;
    }
    if (add) {
      await api.dio.post('/user/favorites/${movie.id}');
    } else {
      await api.dio.delete('/user/favorites/${movie.id}');
    }
    final next = Set<int>.from(_favoriteIdsCache ?? const <int>{});
    if (add) {
      next.add(movie.id);
    } else {
      next.remove(movie.id);
    }
    _favoriteIdsCache = next;
  }

  Future<List<CinePlaylist>> playlists() async {
    final res = await api.dio.get('/playlists/my');
    return (res.data is List ? res.data as List : const [])
        .whereType<Map>()
        .map((e) => CinePlaylist.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.id > 0)
        .toList();
  }

  Future<CinePlaylist> createPlaylist(
    String name, {
    String description = '',
    bool isPublic = false,
  }) async {
    final res = await api.dio.post(
      '/playlists',
      data: {
        'name': name.trim(),
        'description': description.trim(),
        'is_public': isPublic,
      },
    );
    return CinePlaylist.fromJson(Map<String, dynamic>.from(res.data as Map));
  }

  Future<CinePlaylist> updatePlaylistVisibility(
    int playlistId, {
    required bool isPublic,
  }) async {
    final res = await api.dio.patch(
      '/playlists/$playlistId',
      data: {'is_public': isPublic},
    );
    return CinePlaylist.fromJson(Map<String, dynamic>.from(res.data as Map));
  }

  Future<void> deletePlaylist(int playlistId) async {
    await api.dio.delete('/playlists/$playlistId');
  }

  Future<PlaylistDetail> playlistMovies(CinePlaylist playlist) async {
    final res = await api.dio.get('/playlists/${playlist.id}/movies');
    final data = res.data is Map
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    final rows = data['movies'] is List ? data['movies'] as List : const [];
    final movies = rows
        .whereType<Map>()
        .map((e) => Movie.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.id > 0)
        .toList();
    final nextPlaylist = data['playlist'] is Map
        ? CinePlaylist.fromJson(
            Map<String, dynamic>.from(data['playlist'] as Map),
          )
        : playlist;
    return PlaylistDetail(playlist: nextPlaylist, movies: movies);
  }

  Future<void> addToPlaylist(int playlistId, int movieId) async {
    await api.dio.post(
      '/playlists/$playlistId/movies',
      data: {'movie_id': movieId},
    );
  }

  Future<void> removeFromPlaylist(int playlistId, int movieId) async {
    await api.dio.delete('/playlists/$playlistId/movies/$movieId');
  }

  Future<List<MovieComment>> comments(int movieId) async {
    final res = await api.dio.get('/movies/$movieId/comments');
    return (res.data is List ? res.data as List : const [])
        .whereType<Map>()
        .map((e) => MovieComment.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<MovieComment> addComment(
    int movieId,
    String content, {
    bool isSpoiler = false,
  }) async {
    if (!api.hasAuthToken) throw Exception('Cần đăng nhập để bình luận');
    final res = await api.dio.post(
      '/movies/$movieId/comments',
      data: {'content': content.trim(), 'is_spoiler': isSpoiler},
    );
    return MovieComment.fromJson(Map<String, dynamic>.from(res.data as Map));
  }

  Future<RatingStats> ratingStats(int movieId) async {
    final res = await api.dio.get('/movies/$movieId/rating-stats');
    return RatingStats.fromJson(Map<String, dynamic>.from(res.data as Map));
  }

  Future<RatingStats> rateMovie(int movieId, int rating) async {
    if (!api.hasAuthToken) throw Exception('Cần đăng nhập để chấm điểm');
    await api.dio.post('/movies/$movieId/rate', data: {'rating': rating});
    return ratingStats(movieId);
  }

  Future<TvLoginSession> createTvSession() async {
    final res = await api.dio.post('/auth/tv/pair');
    return TvLoginSession.fromJson(Map<String, dynamic>.from(res.data as Map));
  }

  Future<bool> pollTvSession(TvLoginSession session) async {
    final sessionId = session.sessionId.isNotEmpty
        ? session.sessionId
        : session.deviceCode;
    if (sessionId.isEmpty) return false;
    try {
      final res = await api.dio.get('/auth/tv/poll/$sessionId');
      final data = res.data is Map
          ? Map<String, dynamic>.from(res.data as Map)
          : <String, dynamic>{};
      if (data['ok'] != true || data['status'] != 'confirmed') return false;
      final token = cleanText(data['accessToken'] ?? data['token']);
      final refreshToken = cleanText(data['refreshToken']);
      if (token.isNotEmpty) {
        await api.saveSession(token, refreshToken);
        await syncLocalLibraryToCloud();
      }
      return token.isNotEmpty;
    } on DioException catch (e) {
      if (e.response?.statusCode == 428 || e.response?.statusCode == 404) {
        return false;
      }
      rethrow;
    }
  }

  Future<void> approveTvCode(String userCode) async {
    await api.dio.post(
      '/auth/tv/confirm',
      data: {'code': userCode.replaceAll(RegExp(r'\D'), '').trim()},
    );
  }

  Future<List<WatchRoom>> publicRooms() async {
    final res = await api.dio.get('/watch-party/rooms');
    final rows = res.data is Map ? res.data['rooms'] as List? : null;
    return (rows ?? const [])
        .whereType<Map>()
        .map((e) => WatchRoom.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.code.isNotEmpty)
        .toList();
  }

  io.Socket _watchSocket() => io.io(
    siteBase,
    io.OptionBuilder()
        .setPath('/socket.io')
        .setTransports(['websocket', 'polling'])
        .disableAutoConnect()
        .enableReconnection()
        .setTimeout(12000)
        .build(),
  );

  void _keepWatchRoomSocket(
    io.Socket socket, {
    required String code,
    required bool isHost,
  }) {
    final previous = _activeWatchRoomSocket;
    if (previous != null && previous.id != socket.id) {
      try {
        if (_activeWatchRoomIsHost && _activeWatchRoomCode != null) {
          previous.emit('close-room', {'code': _activeWatchRoomCode});
        } else {
          previous.emit('leave-room');
        }
        previous.disconnect();
      } catch (_) {}
    }
    _activeWatchRoomSocket = socket;
    _activeWatchRoomCode = code.trim().toUpperCase();
    _activeWatchRoomIsHost = isHost;
    socket.onDisconnect((_) {
      if (_activeWatchRoomSocket?.id == socket.id) {
        _activeWatchRoomSocket = null;
        _activeWatchRoomCode = null;
        _activeWatchRoomIsHost = false;
      }
    });
    socket.on('room-closed', (_) {
      if (_activeWatchRoomSocket?.id == socket.id) {
        _activeWatchRoomSocket = null;
        _activeWatchRoomCode = null;
        _activeWatchRoomIsHost = false;
      }
      try {
        socket.disconnect();
      } catch (_) {}
    });
  }

  Future<WatchTogetherCreateResult> createWatchRoom(
    Movie movie,
    String videoUrl, {
    String hostName = 'CineViet',
    int maxMembers = 8,
    bool isPublic = true,
  }) async {
    final rawVideoUrl = videoUrl.trim();
    if (rawVideoUrl.isEmpty) {
      throw Exception('Phim này chưa có link phát để tạo phòng');
    }
    final socket = _watchSocket();
    final completer = Completer<WatchTogetherCreateResult>();
    Timer? timeout;

    void fail(Object error) {
      if (!completer.isCompleted) completer.completeError(error);
      timeout?.cancel();
      socket.disconnect();
    }

    socket.onConnect((_) {
      socket.emitWithAck(
        'create-room',
        {
          'hostName': hostName.trim().isEmpty ? 'Chủ phòng' : hostName.trim(),
          'videoUrl': rawVideoUrl,
          'movieTitle': movie.title.trim().isEmpty
              ? 'Watch Party'
              : movie.title,
          'maxMembers': maxMembers,
          'isPublic': isPublic,
        },
        ack: (data) {
          final map = data is Map
              ? Map<String, dynamic>.from(data)
              : <String, dynamic>{};
          final error = cleanText(map['error']);
          final code = cleanText(map['code']);
          if (error.isNotEmpty || code.isEmpty) {
            fail(error.isEmpty ? 'Không tạo được phòng' : error);
            return;
          }
          timeout?.cancel();
          final roomData = map['room'];
          final room = roomData is Map
              ? WatchTogetherState.fromJson(Map<String, dynamic>.from(roomData))
              : null;
          _keepWatchRoomSocket(socket, code: code, isHost: true);
          completer.complete(WatchTogetherCreateResult(code: code, room: room));
        },
      );
    });
    socket.onConnectError(
      (error) => fail(error ?? 'Không kết nối được Xem chung'),
    );
    socket.onError((error) => fail(error ?? 'Không kết nối được Xem chung'));
    timeout = Timer(
      const Duration(seconds: 15),
      () => fail('Kết nối quá thời gian'),
    );
    socket.connect();
    return completer.future;
  }

  Future<WatchTogetherState?> joinWatchRoom(String code) async {
    final roomCode = code.trim().toUpperCase();
    if (roomCode.isEmpty) throw Exception('Nhập mã phòng');
    final socket = _watchSocket();
    final completer = Completer<WatchTogetherState?>();
    Timer? timeout;

    void fail(Object error) {
      if (!completer.isCompleted) completer.completeError(error);
      timeout?.cancel();
      socket.disconnect();
    }

    socket.onConnect((_) {
      socket.emitWithAck(
        'join-room',
        {'code': roomCode, 'userName': 'CineViet'},
        ack: (data) {
          final map = data is Map
              ? Map<String, dynamic>.from(data)
              : <String, dynamic>{};
          final error = cleanText(map['error']);
          if (error.isNotEmpty) {
            fail(error);
            return;
          }
          final roomData = map['room'];
          final room = roomData is Map
              ? WatchTogetherState.fromJson(Map<String, dynamic>.from(roomData))
              : null;
          timeout?.cancel();
          _keepWatchRoomSocket(
            socket,
            code: room?.code.isNotEmpty == true ? room!.code : roomCode,
            isHost: room?.hostSocketId == socket.id,
          );
          completer.complete(room);
        },
      );
    });
    socket.onConnectError(
      (error) => fail(error ?? 'Không kết nối được Xem chung'),
    );
    socket.onError((error) => fail(error ?? 'Không kết nối được Xem chung'));
    timeout = Timer(
      const Duration(seconds: 12),
      () => fail('Kết nối quá thời gian'),
    );
    socket.connect();
    return completer.future;
  }

  Future<void> closeWatchRoom({bool forceDelete = false}) async {
    final socket = _activeWatchRoomSocket;
    final code = _activeWatchRoomCode;
    final isHost = _activeWatchRoomIsHost;
    if (socket == null) return;
    _activeWatchRoomSocket = null;
    _activeWatchRoomCode = null;
    _activeWatchRoomIsHost = false;
    try {
      if (forceDelete || isHost) {
        final completer = Completer<void>();
        Timer? timeout;
        socket.emit('close-room', {'code': code});
        socket.emitWithAck(
          'close-room',
          {'code': code},
          ack: (_) {
            if (!completer.isCompleted) completer.complete();
            timeout?.cancel();
          },
        );
        timeout = Timer(const Duration(milliseconds: 900), () {
          if (!completer.isCompleted) completer.complete();
        });
        await completer.future;
      } else {
        socket.emit('leave-room');
      }
      socket.disconnect();
    } catch (_) {
      try {
        if (forceDelete || isHost) {
          socket.emit('close-room', {'code': code});
        } else {
          socket.emit('leave-room');
        }
        socket.disconnect();
      } catch (_) {}
    }
  }

  void sendWatchRoomMessage(String text) {
    final message = text.trim();
    final socket = _activeWatchRoomSocket;
    if (message.isEmpty || socket == null || socket.disconnected == true) {
      return;
    }
    socket.emitWithAck('chat-message', {'text': message});
  }

  void syncWatchRoomState({
    required double currentTime,
    required bool playing,
  }) {
    final socket = _activeWatchRoomSocket;
    if (socket == null || socket.disconnected == true) return;
    socket.emit('sync-state', {'currentTime': currentTime, 'playing': playing});
  }
}

class LocalHistory {
  static const key = 'cineviet_watch_history_v1';
  static const deletedKey = 'cineviet_watch_history_deleted_v1';
  static final ValueNotifier<int> version = ValueNotifier<int>(0);

  static void _notifyChanged() {
    version.value += 1;
  }

  static Future<List<WatchItem>> items() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => WatchItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      list.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
      return list;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> upsert(WatchItem item) async {
    final prefs = await SharedPreferences.getInstance();
    await _forgetDeletedMovie(prefs, item.movieId);
    final current = await items();
    final next = [
      item,
      ...current.where((e) => e.key != item.key),
    ].take(120).toList();
    await prefs.setString(
      key,
      jsonEncode(next.map((e) => e.toJson()).toList()),
    );
    _notifyChanged();
  }

  static Future<void> removeMovie(int movieId) async {
    final prefs = await SharedPreferences.getInstance();
    await _rememberDeletedMovie(prefs, movieId);
    final next = (await items()).where((e) => e.movieId != movieId).toList();
    if (next.isEmpty) {
      await prefs.remove(key);
      _notifyChanged();
      return;
    }
    await prefs.setString(
      key,
      jsonEncode(next.map((e) => e.toJson()).toList()),
    );
    _notifyChanged();
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = (await items())
        .map((item) => item.movieId)
        .where((id) => id > 0);
    await _rememberDeletedMovies(prefs, ids);
    await prefs.remove(key);
    _notifyChanged();
  }

  static Future<Set<int>> deletedMovieIds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs
            .getStringList(deletedKey)
            ?.map((value) => int.tryParse(value) ?? 0)
            .where((id) => id > 0)
            .toSet() ??
        <int>{};
  }

  static Future<void> _rememberDeletedMovie(
    SharedPreferences prefs,
    int movieId,
  ) => _rememberDeletedMovies(prefs, [movieId]);

  static Future<void> _rememberDeletedMovies(
    SharedPreferences prefs,
    Iterable<int> movieIds,
  ) async {
    final ids = {
      ...?prefs
          .getStringList(deletedKey)
          ?.map((value) => int.tryParse(value) ?? 0),
      ...movieIds,
    }.where((id) => id > 0).take(300).map((id) => '$id').toList();
    if (ids.isEmpty) {
      await prefs.remove(deletedKey);
    } else {
      await prefs.setStringList(deletedKey, ids);
    }
  }

  static Future<void> _forgetDeletedMovie(
    SharedPreferences prefs,
    int movieId,
  ) async {
    if (movieId <= 0) return;
    final current = prefs.getStringList(deletedKey);
    if (current == null || current.isEmpty) return;
    final next = current
        .where((value) => int.tryParse(value) != movieId)
        .toList();
    if (next.isEmpty) {
      await prefs.remove(deletedKey);
    } else {
      await prefs.setStringList(deletedKey, next);
    }
  }
}

class LocalFavorites {
  static const key = 'cineviet_favorites_v1';

  static Future<List<Movie>> items() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => Movie.fromJson(Map<String, dynamic>.from(e)))
          .where((movie) => movie.id > 0)
          .toList();
      return list;
    } catch (_) {
      return const [];
    }
  }

  static Future<Set<int>> ids() async {
    final movies = await items();
    return movies.map((movie) => movie.id).where((id) => id > 0).toSet();
  }

  static Future<void> upsert(Movie movie) async {
    if (movie.id <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final current = await items();
    final next = [
      movie,
      ...current.where((item) => item.id != movie.id),
    ].take(300).toList();
    await prefs.setString(
      key,
      jsonEncode(next.map((movie) => movie.toCacheJson()).toList()),
    );
  }

  static Future<void> remove(int movieId) async {
    final prefs = await SharedPreferences.getInstance();
    final next = (await items()).where((movie) => movie.id != movieId).toList();
    if (next.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(
      key,
      jsonEncode(next.map((movie) => movie.toCacheJson()).toList()),
    );
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}

Future<List<WatchItem>> mergedWatchHistory(MovieRepository repo) async {
  final local = await LocalHistory.items();
  var cloud = const <WatchItem>[];
  if (Api.instance.hasAuthToken) {
    try {
      cloud = await repo.cloudHistory();
    } catch (error) {
      debugPrint('CineViet cloud history merge error: $error');
    }
  }
  final merged = <int, WatchItem>{};
  for (final item in [...local, ...cloud]) {
    if (!item.shouldShow || item.movieId <= 0) continue;
    final existing = merged[item.movieId];
    if (existing == null || item.updatedAtMs >= existing.updatedAtMs) {
      merged[item.movieId] = item;
    }
  }
  final list = merged.values.toList();
  list.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
  return list;
}

WatchItem? findWatchItemForMovie(List<WatchItem> items, Movie movie) {
  WatchItem? match;
  for (final item in items) {
    final sameMovie =
        (movie.id > 0 && item.movieId == movie.id) ||
        (movie.slug.isNotEmpty && item.slug == movie.slug);
    if (!sameMovie) continue;
    if (match == null || item.updatedAtMs >= match.updatedAtMs) {
      match = item;
    }
  }
  return match;
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final repo = MovieRepository(Api.instance);
  int index = 0;
  bool ready = false;

  @override
  void initState() {
    super.initState();
    Api.instance.restoreToken().whenComplete(() {
      if (!mounted) return;
      setState(() => ready = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkStartupUpdate();
        unawaited(DeepLinkService.start(repo));
        if (Api.instance.hasAuthToken) {
          unawaited(repo.syncLocalLibraryToCloud());
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) return const SplashScreen();
    final destinations = [
      AppDestination(
        icon: Icons.home_rounded,
        label: isTvBuild ? 'Trang chủ' : 'Home',
        screen: HomeScreen(repo: repo),
      ),
      AppDestination(
        icon: Icons.search_rounded,
        label: isTvBuild ? 'Tìm kiếm' : 'Tìm',
        screen: BrowseScreen(repo: repo, embedded: true),
      ),
      AppDestination(
        icon: Icons.play_circle_fill_rounded,
        label: 'Short',
        screen: ShortDramaScreen(repo: repo),
      ),
      if (!isTvBuild)
        AppDestination(
          icon: Icons.groups_rounded,
          label: 'Xem\u00a0chung',
          screen: WatchTogetherScreen(repo: repo),
          requiresLogin: true,
        ),
      AppDestination(
        icon: Icons.person_rounded,
        label: isTvBuild ? 'Của tôi' : 'Tôi',
        screen: ProfileScreen(repo: repo),
      ),
    ];
    if (index >= destinations.length) index = destinations.length - 1;
    final wide = MediaQuery.sizeOf(context).width >= 900 || isTvBuild;
    final body = IndexedStack(
      index: index,
      children: [for (final item in destinations) item.screen],
    );
    return Scaffold(
      body: Row(
        children: [
          if (wide)
            RailNav(
              index: index,
              items: destinations,
              onChanged: (value) => setTab(value, destinations),
            ),
          Expanded(child: body),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: index,
              backgroundColor: CvColors.ink,
              indicatorColor: CvColors.accent.withValues(alpha: .22),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: [
                for (final item in destinations)
                  NavigationDestination(
                    icon: Icon(item.icon),
                    label: item.label,
                  ),
              ],
              onDestinationSelected: (value) => setTab(value, destinations),
            ),
    );
  }

  Future<void> _checkStartupUpdate() async {
    try {
      final data = await _UpdateInfoScreenState.loadUpdateInfo();
      if (!mounted) return;
      final remote = data['remote'];
      if (remote is! Map) return;
      final updateAvailable = remote['updateAvailable'] == true;
      final forceUpdate =
          remote['forceUpdate'] == true || remote['forced'] == true;
      final url = cleanText(remote['url'] ?? remote['downloadUrl']);
      final notes = cleanText(remote['notes'] ?? remote['releaseNotes']);
      if (!updateAvailable || url.isEmpty) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: !forceUpdate,
        builder: (context) => AlertDialog(
          title: Text(
            forceUpdate ? 'Cần cập nhật ứng dụng' : 'Có bản cập nhật mới',
          ),
          content: Text(
            notes.isNotEmpty
                ? notes
                : forceUpdate
                ? 'Phiên bản hiện tại đã cũ. Vui lòng cập nhật để tiếp tục sử dụng CineViet.'
                : 'Đã có phiên bản CineViet mới. Bạn có thể cập nhật trực tiếp trong app.',
          ),
          actions: [
            if (!forceUpdate)
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Để sau'),
              ),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const UpdateInfoScreen()),
                );
              },
              icon: const Icon(Icons.system_update_alt_rounded),
              label: const Text('Cập nhật'),
            ),
          ],
        ),
      );
    } catch (_) {}
  }

  void openProfileTab() {
    if (!mounted) return;
    setState(() => index = isTvBuild ? 3 : 4);
  }

  Future<void> setTab(int value, List<AppDestination> destinations) async {
    final destination = destinations[value];
    if (destination.requiresLogin &&
        !await requireLogin(context, destination.label)) {
      return;
    }
    if (!mounted) return;
    setState(() => index = value);
  }
}

class AppDestination {
  const AppDestination({
    required this.icon,
    required this.label,
    required this.screen,
    this.requiresLogin = false,
  });

  final IconData icon;
  final String label;
  final Widget screen;
  final bool requiresLogin;
}

class ShortDramaScreen extends StatefulWidget {
  const ShortDramaScreen({super.key, required this.repo});
  final MovieRepository repo;

  @override
  State<ShortDramaScreen> createState() => _ShortDramaScreenState();
}

class _ShortDramaScreenState extends State<ShortDramaScreen> {
  late Future<List<Movie>> movies;

  @override
  void initState() {
    super.initState();
    movies = widget.repo.list(genre: 'short-drama', limit: 100);
  }

  Future<void> reload() async {
    final next = widget.repo.list(
      genre: 'short-drama',
      limit: 100,
      forceRefresh: true,
    );
    setState(() => movies = next);
    await next;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Short Drama')),
    body: FutureBuilder<List<Movie>>(
      future: movies,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LoadingPage(label: 'Đang tải Short Drama');
        }
        if (snapshot.hasError) {
          return Center(
            child: FilledButton.icon(
              onPressed: reload,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Tải lại'),
            ),
          );
        }
        final items = snapshot.data ?? const <Movie>[];
        if (items.isEmpty) return const EmptyState('Chưa có Short Drama');
        final width = cardExtent(context);
        return RefreshIndicator(
          onRefresh: reload,
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: width + 24,
              mainAxisExtent: moviePosterCardHeight(width),
              crossAxisSpacing: 14,
              mainAxisSpacing: 18,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) => MoviePosterCard(
              movie: items[index],
              width: width,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ShortDramaViewerScreen(
                    repo: widget.repo,
                    movie: items[index],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class ShortDramaViewerScreen extends StatefulWidget {
  const ShortDramaViewerScreen({
    super.key,
    required this.repo,
    required this.movie,
  });
  final MovieRepository repo;
  final Movie movie;

  @override
  State<ShortDramaViewerScreen> createState() => _ShortDramaViewerScreenState();
}

class _ShortDramaViewerScreenState extends State<ShortDramaViewerScreen> {
  late final Future<Movie> movie = widget.repo.detail(widget.movie.routeKey);
  final pageController = PageController();
  final focusNode = FocusNode();
  final episodeKeys = <int, GlobalKey<_ShortEpisodePageState>>{};
  int currentPage = 0;

  GlobalKey<_ShortEpisodePageState> episodeKey(int index) =>
      episodeKeys.putIfAbsent(index, GlobalKey<_ShortEpisodePageState>.new);

  @override
  void dispose() {
    pageController.dispose();
    focusNode.dispose();
    super.dispose();
  }

  KeyEventResult handleTvKey(KeyEvent event, int total) {
    if (!isTvBuild) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final player = episodeKeys[currentPage]?.currentState;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      if (event is KeyRepeatEvent) {
        unawaited(player?.setFastForward(true));
      } else if (event is KeyDownEvent) {
        unawaited(player?.seekBy(key == LogicalKeyboardKey.arrowLeft ? -5 : 5));
      } else if (event is KeyUpEvent) {
        unawaited(player?.setFastForward(false));
      }
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.space) &&
        event is KeyDownEvent) {
      unawaited(player?.togglePlayback());
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final target = key == LogicalKeyboardKey.arrowUp
          ? currentPage - 1
          : currentPage + 1;
      if (target >= 0 && target < total) {
        unawaited(player?.setFastForward(false));
        pageController.animateToPage(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: FutureBuilder<Movie>(
      future: movie,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LoadingPage(label: 'Đang mở Short Drama');
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return const EmptyState('Không thể tải phim');
        }
        final detail = snapshot.data!;
        final episodes = <(EpisodeServer, EpisodeItem)>[
          for (final server in detail.episodes)
            for (final episode in server.items)
              if (episode.linkM3u8.isNotEmpty) (server, episode),
        ];
        if (episodes.isEmpty) {
          return const EmptyState('Phim chưa có tập phát trực tiếp');
        }
        final pages = PageView.builder(
          controller: pageController,
          onPageChanged: (index) => currentPage = index,
          physics: isTvBuild
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          scrollDirection: Axis.vertical,
          itemCount: episodes.length,
          itemBuilder: (context, index) => ShortEpisodePage(
            key: episodeKey(index),
            movie: detail,
            episode: episodes[index].$2,
            index: index,
            total: episodes.length,
          ),
        );
        if (!isTvBuild) return pages;
        return KeyboardListener(
          autofocus: true,
          focusNode: focusNode,
          onKeyEvent: (event) => handleTvKey(event, episodes.length),
          child: pages,
        );
      },
    ),
  );
}

class ShortEpisodePage extends StatefulWidget {
  const ShortEpisodePage({
    super.key,
    required this.movie,
    required this.episode,
    required this.index,
    required this.total,
  });
  final Movie movie;
  final EpisodeItem episode;
  final int index;
  final int total;

  @override
  State<ShortEpisodePage> createState() => _ShortEpisodePageState();
}

class _ShortEpisodePageState extends State<ShortEpisodePage> {
  VideoPlayerController? controller;
  Timer? controlsTimer;
  Timer? seekFeedbackTimer;
  bool controlsVisible = true;
  bool fastForwarding = false;
  int? seekFeedbackSeconds;
  String error = '';

  @override
  void initState() {
    super.initState();
    unawaited(initVideo());
  }

  Future<void> initVideo() async {
    final raw = widget.episode.linkM3u8.trim();
    final direct = raw.startsWith('//') ? 'https:$raw' : raw;
    final url = direct.startsWith('$apiBase/stream?')
        ? direct
        : '$apiBase/stream?url=${Uri.encodeComponent(direct)}';
    final next = VideoPlayerController.networkUrl(
      Uri.parse(url),
      formatHint: direct.toLowerCase().contains('.m3u8')
          ? VideoFormat.hls
          : null,
    );
    controller = next;
    try {
      await next.initialize().timeout(const Duration(seconds: 18));
      await next.setLooping(true);
      await next.play();
      if (mounted) {
        setState(() {});
        scheduleControlsHide();
      }
    } catch (_) {
      await next.dispose();
      controller = null;
      if (mounted) setState(() => error = 'Không thể phát tập này');
    }
  }

  void scheduleControlsHide() {
    controlsTimer?.cancel();
    if (controller?.value.isPlaying != true) return;
    controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && controller?.value.isPlaying == true) {
        setState(() => controlsVisible = false);
      }
    });
  }

  Future<void> handleTap() async {
    if (!controlsVisible) {
      setState(() => controlsVisible = true);
      scheduleControlsHide();
      return;
    }
    await togglePlayback();
  }

  Future<void> togglePlayback() async {
    final video = controller;
    if (video?.value.isInitialized != true) return;
    await setFastForward(false);
    if (video!.value.isPlaying) {
      controlsTimer?.cancel();
      await video.pause();
      if (mounted) setState(() => controlsVisible = true);
    } else {
      await video.play();
      if (mounted) {
        setState(() => controlsVisible = true);
        scheduleControlsHide();
      }
    }
  }

  Future<void> seekBy(int seconds) async {
    final video = controller;
    if (video?.value.isInitialized != true) return;
    final duration = video!.value.duration;
    final target = video.value.position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : target > duration
        ? duration
        : target;
    await video.seekTo(clamped);
    seekFeedbackTimer?.cancel();
    if (mounted) setState(() => seekFeedbackSeconds = seconds);
    seekFeedbackTimer = Timer(const Duration(milliseconds: 750), () {
      if (mounted) setState(() => seekFeedbackSeconds = null);
    });
  }

  Future<void> setFastForward(bool enabled) async {
    final video = controller;
    if (video?.value.isInitialized != true || fastForwarding == enabled) return;
    fastForwarding = enabled;
    await video!.setPlaybackSpeed(enabled ? 2 : 1);
    if (enabled && !video.value.isPlaying) await video.play();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controlsTimer?.cancel();
    seekFeedbackTimer?.cancel();
    if (fastForwarding) controller?.setPlaybackSpeed(1);
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = controller;
    final ready = video?.value.isInitialized == true;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: ready ? handleTap : null,
      onDoubleTapDown: ready && !isTvBuild
          ? (details) {
              final width = MediaQuery.sizeOf(context).width;
              unawaited(seekBy(details.localPosition.dx < width / 2 ? -5 : 5));
            }
          : null,
      onLongPressStart: ready && !isTvBuild
          ? (_) => unawaited(setFastForward(true))
          : null,
      onLongPressEnd: ready && !isTvBuild
          ? (_) => unawaited(setFastForward(false))
          : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: video!.value.size.width,
                height: video.value.size.height,
                child: VideoPlayer(video),
              ),
            )
          else
            NetworkBackdrop(
              url: widget.movie.posterUrl,
              fallbackUrl: widget.movie.posterFallbackUrl,
              fit: BoxFit.cover,
            ),
          AnimatedOpacity(
            opacity: controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black45, Colors.transparent, Colors.black87],
                ),
              ),
            ),
          ),
          AnimatedOpacity(
            opacity: controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: IgnorePointer(
              ignoring: !controlsVisible,
              child: SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: IconButton.filledTonal(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                ),
              ),
            ),
          ),
          if (error.isNotEmpty)
            Center(child: Text(error, style: const TextStyle(fontSize: 16)))
          else if (!ready)
            const Center(child: CircularProgressIndicator()),
          if (ready && !video!.value.isPlaying)
            const Center(child: Icon(Icons.play_arrow_rounded, size: 76)),
          if (ready && fastForwarding)
            const Positioned(
              top: 56,
              right: 20,
              child: Chip(
                avatar: Icon(Icons.fast_forward_rounded, size: 20),
                label: Text('2x'),
              ),
            ),
          if (ready && seekFeedbackSeconds != null)
            Align(
              alignment: seekFeedbackSeconds! < 0
                  ? const Alignment(-.58, 0)
                  : const Alignment(.58, 0),
              child: AnimatedOpacity(
                opacity: seekFeedbackSeconds == null ? 0 : 1,
                duration: const Duration(milliseconds: 120),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          seekFeedbackSeconds! < 0
                              ? Icons.replay_5_rounded
                              : Icons.forward_5_rounded,
                          size: 30,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          seekFeedbackSeconds! < 0 ? '−5 giây' : '+5 giây',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (ready && controlsVisible)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(
                video!,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(vertical: 14),
                colors: VideoProgressColors(
                  playedColor: CvColors.accent,
                  bufferedColor: CvColors.accent.withValues(alpha: .42),
                  backgroundColor: CvColors.border,
                ),
              ),
            ),
          if (controlsVisible)
            Positioned(
              left: 18,
              right: 18,
              bottom: 52,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.movie.title,
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${widget.episode.displayName}  •  ${widget.index + 1}/${widget.total}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isTvBuild
                        ? '↑ ↓ đổi tập • ← → tua 5s • giữ ← → xem 2x • OK phát/tạm dừng'
                        : 'Vuốt để đổi tập • chạm đúp trái/phải tua 5s • giữ để xem 2x',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CineLogo(size: 72),
            SizedBox(height: 18),
            CircularProgressIndicator(color: CvColors.accent),
          ],
        ),
      ),
    );
  }
}

class RailNav extends StatelessWidget {
  const RailNav({
    super.key,
    required this.index,
    required this.items,
    required this.onChanged,
  });
  final int index;
  final List<AppDestination> items;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      right: false,
      child: Container(
        width: isTvBuild ? 118 : 104,
        color: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(
          children: [
            const SidebarLogo(),
            const SizedBox(height: 18),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: items.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  child: FocusButton(
                    selected: i == index,
                    onPressed: () => onChanged(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        children: [
                          Icon(
                            items[i].icon,
                            size: isTvBuild ? 30 : 26,
                            color: i == index ? CvColors.accent : CvColors.text,
                          ),
                          const SizedBox(height: 5),
                          Text(
                            items[i].label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            textScaler: TextScaler.noScaling,
                            style: TextStyle(
                              color: i == index
                                  ? CvColors.accent
                                  : CvColors.muted,
                              fontSize: isTvBuild ? 12 : 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repo});
  final MovieRepository repo;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<HomeData> data;
  HomeData? _cachedHome; // dữ liệu cache hiển ngay khi mở app
  bool _refreshingHistoryOnly = false;

  @override
  void initState() {
    super.initState();
    data = _loadWithCache();
    LocalHistory.version.addListener(_refreshHistoryOnly);
  }

  @override
  void dispose() {
    LocalHistory.version.removeListener(_refreshHistoryOnly);
    super.dispose();
  }

  // Đọc cache trước để hiển thị tức thì, sau đó tải mới ghi đè (stale-while-revalidate).
  Future<HomeData> _loadWithCache() async {
    final cached = await HomeCache.read();
    if (cached != null && mounted) {
      setState(() => _cachedHome = cached);
    }
    return _load();
  }

  Future<HomeData> _load() async {
    final sectionLimit = isTvBuild ? 8 : 18;
    final historyFuture = _safeHistory();
    final results = await Future.wait<List<Movie>>([
      _safeMovies(
        () => widget.repo.list(limit: isTvBuild ? 8 : 10, featured: '1'),
      ),
      _safeMovies(() => widget.repo.list(limit: isTvBuild ? 12 : 22)),
      _safeMovies(() => widget.repo.list(limit: sectionLimit, cinema: '1')),
      _safeMovies(() => widget.repo.list(limit: sectionLimit, type: 'series')),
      _safeMovies(() => widget.repo.list(limit: sectionLimit, type: 'movie')),
      _safeMovies(() => widget.repo.list(limit: sectionLimit, type: 'anime')),
      _safeMovies(() => widget.repo.list(limit: sectionLimit, type: 'tvshows')),
      _safeMovies(() => widget.repo.list(limit: sectionLimit, bilingual: '1')),
    ]);
    final home = HomeData(
      featured: results[0],
      latest: results[1],
      cinema: results[2],
      series: results[3],
      single: results[4],
      anime: results[5],
      tvShows: results[6],
      bilingual: results[7],
      history: await historyFuture,
    );
    // Ghi cache nền (không cache history vì thay đổi liên tục).
    unawaited(HomeCache.write(home));
    if (mounted) setState(() => _cachedHome = null);
    return home;
  }

  Future<List<Movie>> _safeMovies(Future<List<Movie>> Function() load) async {
    try {
      return await load();
    } catch (error, stackTrace) {
      debugPrint('CineViet home movie section error: $error');
      debugPrintStack(stackTrace: stackTrace);
      return const [];
    }
  }

  Future<List<WatchItem>> _safeHistory() async {
    try {
      return await _history();
    } catch (error, stackTrace) {
      debugPrint('CineViet home history error: $error');
      debugPrintStack(stackTrace: stackTrace);
      return const [];
    }
  }

  Future<List<WatchItem>> _history() async {
    return mergedWatchHistory(widget.repo);
  }

  Future<void> _refreshHistoryOnly() async {
    if (!mounted || _refreshingHistoryOnly) return;
    _refreshingHistoryOnly = true;
    try {
      final history = await _safeHistory();
      HomeData? current = _cachedHome;
      try {
        current = await data;
      } catch (_) {}
      if (!mounted || current == null) return;
      final next = current.copyWith(history: history);
      setState(() {
        _cachedHome = _cachedHome?.copyWith(history: history);
        data = Future.value(next);
      });
    } finally {
      _refreshingHistoryOnly = false;
    }
  }

  Future<void> _removeHistory(WatchItem item) async {
    await LocalHistory.removeMovie(item.movieId);
    if (Api.instance.hasAuthToken) {
      try {
        await widget.repo.deleteHistoryMovie(item.movieId);
      } catch (_) {}
    }
    if (mounted) setState(() => data = _loadWithCache());
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => setState(() => data = _loadWithCache()),
      color: CvColors.accent,
      child: FutureBuilder<HomeData>(
        future: data,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            // Có cache → hiển thị ngay dữ liệu cũ trong lúc tải mới.
            if (_cachedHome != null) {
              return _buildHome(_cachedHome!);
            }
            if (snapshot.hasError) {
              debugPrint('CineViet home load error: ${snapshot.error}');
              return HomeErrorState(
                onRetry: () {
                  setState(() => data = _loadWithCache());
                },
              );
            }
            return const HomeSkeleton();
          }
          return _buildHome(snapshot.data!);
        },
      ),
    );
  }

  Widget _buildHome(HomeData home) {
    final featured = home.featured.isNotEmpty
        ? home.featured
        : home.latest.take(8).toList();
    if (isTvBuild) {
      return CustomScrollView(
        key: const PageStorageKey('home-tv-scroll'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(
              height: heroBannerHeight(context),
              child: featured.isEmpty
                  ? const HomeEmptyHero()
                  : FeaturedHeroCarousel(movies: featured, repo: widget.repo),
            ),
          ),
          SliverPadding(
            padding: pagePadding(context).copyWith(top: 22, bottom: 72),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                if (home.history.isNotEmpty)
                  WatchRow(
                    title: 'Xem tiếp',
                    items: home.history,
                    repo: widget.repo,
                    padded: false,
                    onRemove: _removeHistory,
                  ),
                MovieRow(
                  title: 'Mới cập nhật hôm nay',
                  movies: home.latest,
                  repo: widget.repo,
                  padded: false,
                ),
                MovieRow(
                  title: 'Phim chiếu rạp',
                  movies: home.cinema,
                  repo: widget.repo,
                  padded: false,
                ),
                MovieRow(
                  title: 'Phim bộ',
                  movies: home.series,
                  repo: widget.repo,
                  padded: false,
                ),
                MovieRow(
                  title: 'Phim lẻ',
                  movies: home.single,
                  repo: widget.repo,
                  padded: false,
                ),
                MovieRow(
                  title: 'Anime',
                  movies: home.anime,
                  repo: widget.repo,
                  padded: false,
                ),
                MovieRow(
                  title: 'TV Shows',
                  movies: home.tvShows,
                  repo: widget.repo,
                  padded: false,
                ),
              ]),
            ),
          ),
        ],
      );
    }
    return PhoneHome(
      home: home,
      repo: widget.repo,
      featured: featured,
      onRemoveHistory: _removeHistory,
    );
  }
}

// Home 2 lớp kiểu iQiyi: lớp neo (hero + thanh tab dính đỉnh khi cuộn)
// + lớp vuốt (TabBarView vuốt ngang giữa các danh mục).
class PhoneHome extends StatelessWidget {
  const PhoneHome({
    super.key,
    required this.home,
    required this.repo,
    required this.featured,
    required this.onRemoveHistory,
  });
  final HomeData home;
  final MovieRepository repo;
  final List<Movie> featured;
  final Future<void> Function(WatchItem item) onRemoveHistory;

  @override
  Widget build(BuildContext context) {
    // Tab đầu "Đề xuất" giữ nguyên trải nghiệm cũ (nhiều hàng cuộn dọc);
    // các tab sau lọc theo danh mục, hiển dạng lưới.
    final tabs = <_HomeTab>[
      _HomeTab('Đề xuất', null),
      _HomeTab('Song ngữ', home.bilingual, bilingual: true),
      _HomeTab('Phim bộ', home.series, type: 'series'),
      _HomeTab('Phim lẻ', home.single, type: 'movie'),
      _HomeTab('Chiếu rạp', home.cinema, cinema: true),
      _HomeTab('Hoạt hình', home.anime, type: 'anime'),
      _HomeTab('TV Shows', home.tvShows, type: 'tvshows'),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: NestedScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        headerSliverBuilder: (context, innerScrolled) => [
          SliverOverlapAbsorber(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
            sliver: SliverToBoxAdapter(
              child: featured.isEmpty
                  ? const SizedBox(height: 120)
                  : FeaturedHeroCarousel(movies: featured, repo: repo),
            ),
          ),
          SliverPersistentHeader(
            pinned: true,
            delegate: _HomeTabBarDelegate(
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                indicatorColor: CvColors.accent,
                indicatorSize: TabBarIndicatorSize.label,
                labelColor: Colors.white,
                unselectedLabelColor: CvColors.muted,
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
                tabs: [for (final t in tabs) Tab(text: t.title)],
              ),
            ),
          ),
        ],
        body: TabBarView(
          children: [
            for (final t in tabs)
              _HomeTabView(
                tab: t,
                home: home,
                repo: repo,
                onRemoveHistory: onRemoveHistory,
              ),
          ],
        ),
      ),
    );
  }
}

class _HomeTab {
  const _HomeTab(
    this.title,
    this.movies, {
    this.type = '',
    this.cinema = false,
    this.bilingual = false,
  });
  final String title;
  final List<Movie>? movies; // null = tab "Đề xuất"; ngược lại = seed trang 1
  final String type; // type gọi API cho tab danh mục
  final bool cinema; // chieu_rap=1
  final bool bilingual; // song_ngu=1
}

class _HomeTabView extends StatelessWidget {
  const _HomeTabView({
    required this.tab,
    required this.home,
    required this.repo,
    required this.onRemoveHistory,
  });
  final _HomeTab tab;
  final HomeData home;
  final MovieRepository repo;
  final Future<void> Function(WatchItem item) onRemoveHistory;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) => CustomScrollView(
        key: PageStorageKey('home-tab-${tab.title}'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverOverlapInjector(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          ),
          if (tab.movies == null) ...[
            // Tab Đề xuất: giữ nguyên các hàng cuộn ngang như trước.
            if (home.history.isNotEmpty)
              SliverToBoxAdapter(
                child: WatchRow(
                  title: 'Xem tiếp',
                  items: home.history,
                  repo: repo,
                  onRemove: onRemoveHistory,
                ),
              ),
            SliverToBoxAdapter(
              child: MovieRow(
                title: 'Mới cập nhật',
                movies: home.latest,
                repo: repo,
              ),
            ),
            SliverToBoxAdapter(
              child: MovieRow(
                title: 'Phim chiếu rạp',
                movies: home.cinema,
                repo: repo,
              ),
            ),
            SliverToBoxAdapter(
              child: MovieRow(
                title: 'Phim bộ',
                movies: home.series,
                repo: repo,
              ),
            ),
            SliverToBoxAdapter(
              child: MovieRow(
                title: 'Phim lẻ',
                movies: home.single,
                repo: repo,
              ),
            ),
            SliverToBoxAdapter(
              child: MovieRow(
                title: 'Hoạt hình',
                movies: home.anime,
                repo: repo,
              ),
            ),
            SliverToBoxAdapter(
              child: MovieRow(
                title: 'TV Shows',
                movies: home.tvShows,
                repo: repo,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 48)),
          ] else
            _CategoryGrid(
              seed: tab.movies!,
              title: tab.title,
              type: tab.type,
              cinema: tab.cinema,
              bilingual: tab.bilingual,
              repo: repo,
            ),
        ],
      ),
    );
  }
}

// Lưới danh mục có phân trang: seed = trang 1 (18 phim lấy sẵn ở home),
// cuộn gần cuối thì tự tải trang tiếp, khử trùng theo id.
class _CategoryGrid extends StatefulWidget {
  const _CategoryGrid({
    required this.seed,
    required this.title,
    required this.type,
    required this.cinema,
    required this.bilingual,
    required this.repo,
  });
  final List<Movie> seed;
  final String title;
  final String type;
  final bool cinema;
  final bool bilingual;
  final MovieRepository repo;

  @override
  State<_CategoryGrid> createState() => _CategoryGridState();
}

class _CategoryGridState extends State<_CategoryGrid> {
  static const int _pageSize =
      18; // khớp sectionLimit của home để nối liền mạch
  late List<Movie> _items;
  final Set<int> _ids = {};
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _items = [...widget.seed];
    _ids.addAll(_items.map((m) => m.id));
    if (_items.isEmpty) {
      // Seed rỗng (call trang chủ lỗi/timeout) → tự tải trang 1 từ API.
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    } else if (_items.length < _pageSize) {
      // Trang 1 chưa đầy → coi như hết.
      _hasMore = false;
    }
  }

  @override
  void didUpdateWidget(covariant _CategoryGrid old) {
    super.didUpdateWidget(old);
    // Dữ liệu home tươi về sau khi State đã tạo (seed cũ rỗng do đọc cache cũ
    // hoặc call lỗi lần đầu). Nếu seed thay đổi thì nạp lại từ seed mới.
    final oldFirst = old.seed.isEmpty ? null : old.seed.first.id;
    final newFirst = widget.seed.isEmpty ? null : widget.seed.first.id;
    final seedChanged =
        old.seed.length != widget.seed.length || oldFirst != newFirst;
    // Chỉ reset khi đang rỗng (nhận ngay seed tươi) HOẶC chưa cuộn sang
    // trang khác (tránh xoá dữ liệu người dùng đã cuộn tới).
    final canReset = _items.isEmpty || (_page == 1 && !_loading);
    if (seedChanged && widget.seed.isNotEmpty && canReset) {
      setState(() {
        _items = [...widget.seed];
        _ids
          ..clear()
          ..addAll(_items.map((m) => m.id));
        _page = 1;
        _hasMore = widget.seed.length >= _pageSize;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    _loading = true;
    // Seed rỗng thì bắt đầu từ trang 1, ngược lại tải trang kế tiếp.
    final next = _items.isEmpty ? 1 : _page + 1;
    try {
      final more = await widget.repo.list(
        page: next,
        limit: _pageSize,
        type: widget.type,
        cinema: widget.cinema ? '1' : '',
        bilingual: widget.bilingual ? '1' : '',
      );
      final fresh = more.where((m) => _ids.add(m.id)).toList();
      if (!mounted) return;
      setState(() {
        _items.addAll(fresh);
        _page = next;
        if (more.length < _pageSize) _hasMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _hasMore = false);
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      // Đang tải trang 1 (seed rỗng) hoặc thật sự không có phim.
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: _hasMore
              ? const CircularProgressIndicator(color: CvColors.accent)
              : const Text(
                  'Chưa có phim',
                  style: TextStyle(color: CvColors.muted),
                ),
        ),
      );
    }
    final pad = pagePadding(context);
    final avail = MediaQuery.sizeOf(context).width - pad.left - pad.right;
    const spacing = 12.0;
    final target = movieCardExtent(context);
    final count = math.max(2, ((avail + spacing) / (target + spacing)).floor());
    final cellW = (avail - spacing * (count - 1)) / count;
    // Truyền đúng cellW cho card để chiều cao khớp, tránh overflow.
    final cellH = moviePosterCardHeight(cellW);
    return SliverPadding(
      padding: pad.copyWith(top: 16, bottom: 48),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: count,
          mainAxisSpacing: 18,
          crossAxisSpacing: spacing,
          mainAxisExtent: cellH,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          // Sắp chạm cuối → tải thêm trang.
          if (index >= _items.length - 6 && _hasMore && !_loading) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
          }
          final m = _items[index];
          final tag = 'poster-${widget.title}-${m.id}-$index';
          return MoviePosterCard(
            movie: m,
            width: cellW,
            heroTag: tag,
            onTap: () => openDetail(context, widget.repo, m, heroTag: tag),
          );
        }, childCount: _items.length),
      ),
    );
  }
}

class _HomeTabBarDelegate extends SliverPersistentHeaderDelegate {
  _HomeTabBarDelegate(this.tabBar);
  final TabBar tabBar;

  @override
  double get minExtent => 48;
  @override
  double get maxExtent => 48;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: CvColors.black,
      alignment: Alignment.centerLeft,
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(covariant _HomeTabBarDelegate oldDelegate) =>
      oldDelegate.tabBar != tabBar;
}

class HomeData {
  const HomeData({
    required this.featured,
    required this.latest,
    required this.cinema,
    required this.series,
    required this.single,
    required this.anime,
    required this.tvShows,
    this.bilingual = const [],
    required this.history,
  });
  final List<Movie> featured;
  final List<Movie> latest;
  final List<Movie> cinema;
  final List<Movie> series;
  final List<Movie> single;
  final List<Movie> anime;
  final List<Movie> tvShows;
  final List<Movie> bilingual;
  final List<WatchItem> history;

  HomeData copyWith({List<WatchItem>? history}) => HomeData(
    featured: featured,
    latest: latest,
    cinema: cinema,
    series: series,
    single: single,
    anime: anime,
    tvShows: tvShows,
    bilingual: bilingual,
    history: history ?? this.history,
  );

  Map<String, dynamic> toCacheJson() => {
    'featured': featured.map((m) => m.toCacheJson()).toList(),
    'latest': latest.map((m) => m.toCacheJson()).toList(),
    'cinema': cinema.map((m) => m.toCacheJson()).toList(),
    'series': series.map((m) => m.toCacheJson()).toList(),
    'single': single.map((m) => m.toCacheJson()).toList(),
    'anime': anime.map((m) => m.toCacheJson()).toList(),
    'tvShows': tvShows.map((m) => m.toCacheJson()).toList(),
    'bilingual': bilingual.map((m) => m.toCacheJson()).toList(),
  };

  factory HomeData.fromCacheJson(Map<String, dynamic> json) {
    List<Movie> parse(dynamic v) => v is List
        ? v
              .whereType<Map>()
              .map((e) => Movie.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : const <Movie>[];
    return HomeData(
      featured: parse(json['featured']),
      latest: parse(json['latest']),
      cinema: parse(json['cinema']),
      series: parse(json['series']),
      single: parse(json['single']),
      anime: parse(json['anime']),
      tvShows: parse(json['tvShows']),
      bilingual: parse(json['bilingual']),
      history: const [],
    );
  }

  bool get isEmpty =>
      featured.isEmpty &&
      latest.isEmpty &&
      cinema.isEmpty &&
      series.isEmpty &&
      single.isEmpty &&
      anime.isEmpty &&
      tvShows.isEmpty &&
      bilingual.isEmpty;
}

// Cache dữ liệu home vào SharedPreferences để mở app hiển thị tức thì
// (stale-while-revalidate): lần sau mở app show dữ liệu cũ ngay, rồi nền tải mới.
class HomeCache {
  static const _key = 'cineviet_home_cache_v2';
  static const _tsKey = 'cineviet_home_cache_ts_v2';
  // Cache cũ hơn ngưỡng này vẫn hiển nhưng được coi là stale (vẫn revalidate nền).
  static const staleAfter = Duration(hours: 6);

  static Future<HomeData?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final data = HomeData.fromCacheJson(Map<String, dynamic>.from(decoded));
      return data.isEmpty ? null : data;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(HomeData data) async {
    try {
      if (data.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(data.toCacheJson()));
      await prefs.setInt(_tsKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  static Future<bool> isStale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ts = prefs.getInt(_tsKey);
      if (ts == null) return true;
      final age = DateTime.now().millisecondsSinceEpoch - ts;
      return age > staleAfter.inMilliseconds;
    } catch (_) {
      return true;
    }
  }
}

class HomeErrorState extends StatelessWidget {
  const HomeErrorState({super.key, required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    slivers: [
      SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.wifi_tethering_error_rounded,
                  color: CvColors.muted,
                  size: 42,
                ),
                const SizedBox(height: 14),
                const Text(
                  'Chưa tải được Home',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Kéo xuống để thử lại hoặc bấm tải lại.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: CvColors.muted),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Tải lại'),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

class FeaturedHeroCarousel extends StatefulWidget {
  const FeaturedHeroCarousel({
    super.key,
    required this.movies,
    required this.repo,
  });
  final List<Movie> movies;
  final MovieRepository repo;

  @override
  State<FeaturedHeroCarousel> createState() => _FeaturedHeroCarouselState();
}

class HomeEmptyHero extends StatelessWidget {
  const HomeEmptyHero({super.key});

  @override
  Widget build(BuildContext context) => Container(
    color: CvColors.ink,
    alignment: Alignment.center,
    child: const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CineLogo(size: 72),
        SizedBox(height: 16),
        Text(
          'CineViet',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
        ),
        SizedBox(height: 8),
        Text('Đang chờ dữ liệu phim', style: TextStyle(color: CvColors.muted)),
      ],
    ),
  );
}

class _FeaturedHeroCarouselState extends State<FeaturedHeroCarousel> {
  late final PageController controller;
  Timer? timer;
  int page = 0;

  @override
  void initState() {
    super.initState();
    controller = PageController();
    _startAutoScroll();
  }

  @override
  void didUpdateWidget(covariant FeaturedHeroCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.movies.length != widget.movies.length) {
      page = page.clamp(0, math.max(0, widget.movies.length - 1));
      _startAutoScroll();
    }
  }

  void _startAutoScroll() {
    timer?.cancel();
    // Trên Android TV không tự đổi hero khi remote đang điều hướng; người dùng
    // có thể chuyển bằng D-pad/PageView, tránh mất focus vào nút hành động.
    if (isTvBuild || widget.movies.length < 2) return;
    timer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || !controller.hasClients) return;
      final next = (page + 1) % widget.movies.length;
      controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    controller.dispose();
    super.dispose();
  }

  void _revealWholeHero(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !context.mounted) return;
      final scrollable = Scrollable.maybeOf(context);
      if (scrollable == null || !scrollable.position.hasPixels) return;
      scrollable.position.animateTo(
        scrollable.position.minScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final height = heroBannerHeight(context);
    return SizedBox(
      height: height,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: const {
                ui.PointerDeviceKind.touch,
                ui.PointerDeviceKind.mouse,
                ui.PointerDeviceKind.trackpad,
                ui.PointerDeviceKind.stylus,
              },
            ),
            child: PageView.builder(
              controller: controller,
              itemCount: widget.movies.length,
              onPageChanged: (value) => setState(() => page = value),
              itemBuilder: (context, index) =>
                  HeroBanner(movie: widget.movies[index], repo: widget.repo),
            ),
          ),
          if (isTvBuild && widget.movies.length > 1)
            Positioned(
              left: 28,
              right: 28,
              bottom: 18,
              child: SizedBox(
                height: 88,
                child: ListView.separated(
                  clipBehavior: Clip.none,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  scrollDirection: Axis.horizontal,
                  itemCount: widget.movies.length.clamp(0, 12),
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final selected = index == page;
                    return FocusButton(
                      autofocus: selected,
                      onFocus: () {
                        // Dùng context của carousel, không dùng context của item
                        // nằm trong ListView ngang (nếu không sẽ cuộn nhầm trục).
                        _revealWholeHero(this.context);
                        if (index == page || !controller.hasClients) return;
                        controller.animateToPage(
                          index,
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                        );
                      },
                      onPressed: () => openDetail(
                        context,
                        widget.repo,
                        widget.movies[index],
                      ),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 112,
                        height: 68,
                        padding: EdgeInsets.all(selected ? 3 : 1),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: selected
                                ? Colors.transparent
                                : Colors.white.withValues(alpha: .35),
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: NetworkBackdrop(
                            url: widget.movies[index].backdropUrl.isNotEmpty
                                ? widget.movies[index].backdropUrl
                                : widget.movies[index].posterUrl,
                            fallbackUrl: widget.movies[index].posterFallbackUrl,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            )
          else if (widget.movies.length > 1)
            Positioned(
              bottom: 18,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.movies.length.clamp(0, 12); i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: i == page ? 22 : 7,
                      height: 7,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: i == page
                            ? Colors.white
                            : Colors.white.withValues(alpha: .38),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

double heroBannerHeight(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final compact = size.width < 600 && !isTvBuild;
  return compact
      ? (size.height * .72).clamp(520.0, 680.0)
      : (size.height * (isTvBuild || isWindowsDesktop ? .72 : .62)).clamp(
          480.0,
          760.0,
        );
}

class HeroBanner extends StatelessWidget {
  const HeroBanner({super.key, required this.movie, required this.repo});
  final Movie movie;
  final MovieRepository repo;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 600 && !isTvBuild;
    final tablet = size.width >= 600 && size.width < 1100 && !isTvBuild;
    final usePosterArt = compact;
    final artwork = usePosterArt
        ? (movie.posterUrl.isNotEmpty ? movie.posterUrl : movie.backdropUrl)
        : (movie.backdropUrl.isNotEmpty ? movie.backdropUrl : movie.posterUrl);
    final artworkFallback = usePosterArt
        ? (movie.posterFallbackUrl.isNotEmpty
              ? movie.posterFallbackUrl
              : movie.backdropFallbackUrl)
        : (movie.backdropFallbackUrl.isNotEmpty
              ? movie.backdropFallbackUrl
              : movie.posterFallbackUrl);
    final height = heroBannerHeight(context);
    final heroMeta = [
      if (movie.releaseYear != null) '${movie.releaseYear}',
      if (movie.quality.isNotEmpty) movie.quality,
      if (movie.language.isNotEmpty) movie.language,
      if (movie.episodeCurrent.isNotEmpty) movie.episodeCurrent,
    ];
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          NetworkBackdrop(
            url: artwork,
            fallbackUrl: artworkFallback,
            fit: BoxFit.cover,
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerRight,
                end: Alignment.centerLeft,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: .82),
                ],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black.withValues(alpha: .08), CvColors.black],
                stops: const [.55, 1],
              ),
            ),
          ),
          Padding(
            padding: pagePadding(context).copyWith(
              top: compact ? 64 : 86,
              // Android TV dành riêng vùng đáy cho dải thumbnail; không để
              // thumbnail phủ lên mô tả của hero.
              bottom: isTvBuild ? 124 : (compact ? 34 : 56),
            ),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.bottomLeft,
                child: Column(
                  children: [
                    SizedBox(
                      width: compact
                          ? size.width - 48
                          : (isTvBuild ? 760 : 620),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const FeaturedBadge(),
                          SizedBox(height: compact || tablet ? 14 : 24),
                          Text(
                            movie.title,
                            maxLines: tablet ? 2 : 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Be Vietnam Pro',
                              fontFamilyFallback: const [
                                'Plus Jakarta Sans',
                                'Roboto',
                                'sans-serif',
                              ],
                              fontSize: compact
                                  ? 34
                                  : (isTvBuild ? 54 : (tablet ? 32 : 38)),
                              height: 1.08,
                              // Asset cao nhất là 800; dùng 900 khiến một số TV
                              // fallback sang font hệ thống khi gặp dấu tiếng Việt.
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0,
                            ),
                          ),
                          if (heroMeta.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: heroMeta
                                  .map(
                                    (label) => InfoPill(
                                      label,
                                      prominent: label == movie.quality,
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                          if (movie.description.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              movie.description,
                              maxLines: compact || tablet
                                  ? 2
                                  : (isTvBuild ? 3 : 3),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15.5,
                                height: 1.42,
                              ),
                            ),
                          ],
                          if (!isTvBuild) ...[
                            SizedBox(height: tablet ? 16 : 22),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 14,
                                    ),
                                  ),
                                  onPressed: () => openDetail(
                                    context,
                                    repo,
                                    movie,
                                    autoplay: true,
                                  ),
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  label: const Text('Xem ngay'),
                                ),
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: BorderSide(
                                      color: Colors.white.withValues(
                                        alpha: .42,
                                      ),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 18,
                                      vertical: 14,
                                    ),
                                  ),
                                  onPressed: () =>
                                      openDetail(context, repo, movie),
                                  icon: const Icon(Icons.info_outline_rounded),
                                  label: const Text('Chi tiết'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MovieRow extends StatelessWidget {
  const MovieRow({
    super.key,
    required this.title,
    required this.movies,
    required this.repo,
    this.padded = true,
  });
  final String title;
  final List<Movie> movies;
  final MovieRepository repo;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    if (movies.isEmpty) return const SizedBox.shrink();
    final cardWidth = movieCardExtent(context);
    return Padding(
      padding: (padded ? pagePadding(context) : EdgeInsets.zero).copyWith(
        top: 28,
        bottom: 0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(title),
          const SizedBox(height: 12),
          SizedBox(
            // TV focus scale needs extra paint room; otherwise poster cards can be
            // clipped by the horizontal viewport and look like the poster is cut.
            height: moviePosterRowHeight(cardWidth) + (isTvBuild ? 16 : 0),
            child: ListView.separated(
              key: PageStorageKey('movie-row-$title'),
              clipBehavior: Clip.none,
              padding: EdgeInsets.symmetric(vertical: isTvBuild ? 8 : 0),
              scrollDirection: Axis.horizontal,
              itemCount: movies.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final tag = 'poster-$title-${movies[index].id}-$index';
                return MoviePosterCard(
                  movie: movies[index],
                  width: cardWidth,
                  heroTag: tag,
                  onTap: () =>
                      openDetail(context, repo, movies[index], heroTag: tag),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class WatchRow extends StatefulWidget {
  const WatchRow({
    super.key,
    required this.title,
    required this.items,
    required this.repo,
    this.padded = true,
    this.onRemove,
  });
  final String title;
  final List<WatchItem> items;
  final MovieRepository repo;
  final bool padded;
  final Future<void> Function(WatchItem item)? onRemove;

  @override
  State<WatchRow> createState() => _WatchRowState();
}

class _WatchRowState extends State<WatchRow> {
  late List<WatchItem> visibleItems;

  @override
  void initState() {
    super.initState();
    visibleItems = List.of(widget.items);
  }

  @override
  void didUpdateWidget(covariant WatchRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items != widget.items) visibleItems = List.of(widget.items);
  }

  Future<void> remove(WatchItem item) async {
    setState(
      () => visibleItems = visibleItems
          .where((e) => e.movieId != item.movieId)
          .toList(),
    );
    await widget.onRemove?.call(item);
  }

  @override
  Widget build(BuildContext context) {
    if (visibleItems.isEmpty) return const SizedBox.shrink();
    final width = landscapeExtent(context);
    return Padding(
      padding: (widget.padded ? pagePadding(context) : EdgeInsets.zero)
          .copyWith(top: 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(widget.title),
          const SizedBox(height: 12),
          SizedBox(
            height: width * .68,
            child: ListView.separated(
              key: PageStorageKey('watch-row-${widget.title}'),
              scrollDirection: Axis.horizontal,
              itemCount: visibleItems.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) => ContinueCard(
                item: visibleItems[index],
                width: width,
                onRemove: widget.onRemove == null
                    ? null
                    : () => remove(visibleItems[index]),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ResumeLoaderScreen(
                      repo: widget.repo,
                      item: visibleItems[index],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SearchHistoryStore {
  static const _key = 'cineviet_v2_recent_searches';
  static const _limit = 8;

  static Future<List<String>> items() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? const <String>[])
        .map((value) => value.trim())
        .where((value) => value.length >= 2)
        .toList(growable: false);
  }

  static Future<List<String>> add(String query) async {
    final value = query.trim();
    if (value.length < 2) return items();
    final prefs = await SharedPreferences.getInstance();
    final next = <String>[value];
    for (final item in prefs.getStringList(_key) ?? const <String>[]) {
      if (item.trim().toLowerCase() != value.toLowerCase() &&
          item.trim().length >= 2) {
        next.add(item.trim());
      }
      if (next.length >= _limit) break;
    }
    await prefs.setStringList(_key, next);
    return next;
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

class BrowseScreen extends StatefulWidget {
  const BrowseScreen({
    super.key,
    required this.repo,
    this.initialSearch = '',
    this.embedded = false,
  });
  final MovieRepository repo;
  final String initialSearch;
  final bool embedded;

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  final search = TextEditingController();
  String type = '';
  bool bilingual = false;
  String genre = '';
  String country = '';
  String year = '';
  String sort = 'created_at';
  late Future<List<Movie>> results;
  late Future<BrowseMeta> meta;
  Timer? _searchDebounce;
  List<String> recentSearches = const [];

  static const quickSearches = <String>[
    'phim mới',
    'hành động',
    'tình cảm',
    'hoạt hình',
    'Hàn Quốc',
    'Trung Quốc',
  ];

  static const defaultGenres = [
    ('', 'Tất cả thể loại'),
    ('chinh-kich', 'Chính kịch'),
    ('hanh-dong', 'Hành động'),
    ('tinh-cam', 'Tình cảm'),
    ('hai-huoc', 'Hài hước'),
    ('kinh-di', 'Kinh dị'),
    ('vien-tuong', 'Viễn tưởng'),
    ('phieu-luu', 'Phiêu lưu'),
    ('tam-ly', 'Tâm lý'),
    ('hinh-su', 'Hình sự'),
    ('hoat-hinh', 'Hoạt hình'),
    ('bi-an', 'Bí ẩn'),
    ('khoa-hoc', 'Khoa học'),
    ('gia-dinh', 'Gia đình'),
    ('tai-lieu', 'Tài liệu'),
    ('co-trang', 'Cổ trang'),
    ('chien-tranh', 'Chiến tranh'),
  ];

  static const defaultCountries = [
    ('', 'Tất cả quốc gia'),
    ('au-my', 'Âu Mỹ'),
    ('trung-quoc', 'Trung Quốc'),
    ('nhat-ban', 'Nhật Bản'),
    ('han-quoc', 'Hàn Quốc'),
    ('anh', 'Anh'),
    ('thai-lan', 'Thái Lan'),
    ('phap', 'Pháp'),
    ('viet-nam', 'Việt Nam'),
    ('an-do', 'Ấn Độ'),
    ('hong-kong', 'Hồng Kông'),
    ('canada', 'Canada'),
    ('tay-ban-nha', 'Tây Ban Nha'),
    ('duc', 'Đức'),
    ('quoc-gia-khac', 'Quốc gia khác'),
  ];

  static const sorts = [
    ('created_at', 'Mới cập nhật'),
    ('release_year', 'Năm phát hành'),
    ('view_count', 'Xem nhiều'),
    ('rating', 'Đánh giá cao'),
  ];

  @override
  void initState() {
    super.initState();
    search.text = widget.initialSearch;
    results = widget.repo.list(limit: 36, search: widget.initialSearch);
    meta = _loadMeta();
    unawaited(_loadRecentSearches());
  }

  Future<BrowseMeta> _loadMeta() async {
    final rows = await Future.wait([
      widget.repo.genres(),
      widget.repo.countries(),
    ]);
    final now = DateTime.now().year + 1;
    final years = <(String, String)>[
      ('', 'Tất cả năm'),
      for (var value = now; value >= 1990; value--) ('$value', '$value'),
    ];
    return BrowseMeta(genres: rows[0], countries: rows[1], years: years);
  }

  Future<void> _loadRecentSearches() async {
    final items = await SearchHistoryStore.items();
    if (!mounted) return;
    setState(() => recentSearches = items);
  }

  void applySearchText(String value) {
    search.text = value;
    search.selection = TextSelection.collapsed(offset: search.text.length);
    runSearch();
  }

  void runSearch() {
    _searchDebounce?.cancel();
    final query = search.text.trim();
    if (query.length >= 2) {
      unawaited(
        SearchHistoryStore.add(query).then((items) {
          if (mounted) setState(() => recentSearches = items);
        }),
      );
    }
    setState(() {
      results = widget.repo.list(
        limit: 48,
        search: query,
        type: type,
        genre: genre,
        country: country,
        year: year,
        sort: sort,
        bilingual: bilingual ? '1' : '',
      );
    });
  }

  bool get hasActiveFilters =>
      type.isNotEmpty ||
      bilingual ||
      genre.isNotEmpty ||
      country.isNotEmpty ||
      year.isNotEmpty ||
      sort != 'created_at';

  void clearFilters() {
    setState(() {
      type = '';
      bilingual = false;
      genre = '';
      country = '';
      year = '';
      sort = 'created_at';
    });
    runSearch();
  }

  String typeLabel(String value) => switch (value) {
    'movie' => 'Phim lẻ',
    'series' => 'Phim bộ',
    'anime' => 'Hoạt hình',
    'tvshows' => 'TV Shows',
    _ => 'Tất cả',
  };

  String filterLabel(List<(String, String)> items, String value) {
    if (value.isEmpty) return '';
    return items
        .firstWhere((item) => item.$1 == value, orElse: () => (value, value))
        .$2;
  }

  void scheduleSearch() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), runSearch);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gridWidth = movieCardExtent(context);
    final largeControls = useLeanbackControls;
    final tablet = isTouchTablet(context);
    final topPadding = largeControls ? 46.0 : 36.0;
    final content = CustomScrollView(
      key: PageStorageKey(
        widget.embedded ? 'browse-embedded-scroll' : 'browse-full-scroll',
      ),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: pagePadding(context).copyWith(top: topPadding, bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(child: PageHeading('Tìm kiếm')),
                    if (largeControls)
                      Text(
                        isTvBuild
                            ? 'Tìm nhanh phim, bộ sưu tập và thể loại'
                            : 'Tìm nhanh phim, diễn viên và thể loại',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: .54),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
                SizedBox(height: largeControls ? 24 : 18),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: search,
                        textInputAction: TextInputAction.search,
                        onChanged: (_) => scheduleSearch(),
                        onSubmitted: (_) => runSearch(),
                        decoration: InputDecoration(
                          hintText: 'Tên phim, diễn viên, quốc gia...',
                          prefixIcon: const Icon(Icons.search_rounded),
                          filled: true,
                          fillColor: largeControls
                              ? Colors.white.withValues(alpha: .1)
                              : CvColors.panel,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: largeControls ? 20 : 16,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (largeControls)
                      TvActionButton(
                        icon: Icons.search_rounded,
                        label: 'Tìm',
                        primary: true,
                        onPressed: runSearch,
                      )
                    else
                      IconButton.filled(
                        onPressed: runSearch,
                        icon: const Icon(Icons.arrow_forward_rounded),
                      ),
                  ],
                ),
                if (recentSearches.isNotEmpty ||
                    search.text.trim().isEmpty) ...[
                  SizedBox(height: largeControls ? 14 : 10),
                  SearchSuggestionChips(
                    recent: recentSearches,
                    quick: quickSearches,
                    onSelect: applySearchText,
                    onClearRecent: recentSearches.isEmpty
                        ? null
                        : () async {
                            await SearchHistoryStore.clear();
                            if (mounted) {
                              setState(() => recentSearches = const []);
                            }
                          },
                  ),
                ],
                SizedBox(height: largeControls ? 18 : 14),
                Wrap(
                  spacing: largeControls ? 12 : 8,
                  runSpacing: largeControls ? 12 : 8,
                  children: [
                    typeFilter('Tất cả', '', Icons.apps_rounded),
                    typeFilter('Phim lẻ', 'movie', Icons.movie_rounded),
                    typeFilter('Phim bộ', 'series', Icons.live_tv_rounded),
                    typeFilter('Hoạt hình', 'anime', Icons.animation_rounded),
                    typeFilter('TV Shows', 'tvshows', Icons.tv_rounded),
                    bilingualFilter(),
                  ],
                ),
                SizedBox(height: largeControls ? 18 : 14),
                if (tablet) ...[
                  TabletDiscoveryStrip(
                    selectedGenre: genre,
                    selectedSort: sort,
                    onGenre: (value) {
                      genre = value;
                      runSearch();
                    },
                    onSort: (value) {
                      sort = value;
                      runSearch();
                    },
                  ),
                  const SizedBox(height: 14),
                ],
                FutureBuilder<BrowseMeta>(
                  future: meta,
                  builder: (context, snapshot) {
                    final data = snapshot.data ?? BrowseMeta.fallback;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FilterBar(
                          genre: genre,
                          country: country,
                          year: year,
                          sort: sort,
                          genres: data.genres,
                          countries: data.countries,
                          years: data.years,
                          sorts: sorts,
                          onGenre: (value) {
                            genre = value;
                            runSearch();
                          },
                          onCountry: (value) {
                            country = value;
                            runSearch();
                          },
                          onYear: (value) {
                            year = value;
                            runSearch();
                          },
                          onSort: (value) {
                            sort = value;
                            runSearch();
                          },
                        ),
                        if (hasActiveFilters) ...[
                          const SizedBox(height: 10),
                          ActiveFilterChips(
                            filters: [
                              if (bilingual)
                                (
                                  'Song ngữ',
                                  () {
                                    bilingual = false;
                                    runSearch();
                                  },
                                ),
                              if (type.isNotEmpty)
                                (
                                  'Loại: ${typeLabel(type)}',
                                  () {
                                    type = '';
                                    runSearch();
                                  },
                                ),
                              if (genre.isNotEmpty)
                                (
                                  'Thể loại: ${filterLabel(data.genres, genre)}',
                                  () {
                                    genre = '';
                                    runSearch();
                                  },
                                ),
                              if (country.isNotEmpty)
                                (
                                  'Quốc gia: ${filterLabel(data.countries, country)}',
                                  () {
                                    country = '';
                                    runSearch();
                                  },
                                ),
                              if (year.isNotEmpty)
                                (
                                  'Năm: $year',
                                  () {
                                    year = '';
                                    runSearch();
                                  },
                                ),
                              if (sort != 'created_at')
                                (
                                  'Sắp xếp: ${filterLabel(sorts, sort)}',
                                  () {
                                    sort = 'created_at';
                                    runSearch();
                                  },
                                ),
                            ],
                            onClearAll: clearFilters,
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        FutureGrid(
          future: results,
          cardWidth: gridWidth,
          repo: widget.repo,
          touchColumns: 2,
          onRetry: runSearch,
          emptyMessage: hasActiveFilters
              ? 'Không có phim khớp bộ lọc hiện tại'
              : 'Không tìm thấy phim phù hợp',
          emptyActionLabel: hasActiveFilters ? 'Xoá bộ lọc' : null,
          onEmptyAction: hasActiveFilters ? clearFilters : null,
        ),
      ],
    );
    if (widget.embedded) return content;
    return Scaffold(body: content);
  }

  Widget typeFilter(String label, String value, IconData icon) {
    void select() {
      setState(() {
        type = value;
      });
      runSearch();
    }

    if (useLeanbackControls) {
      return TvFilterChip(
        label: label,
        icon: icon,
        selected: type == value,
        onPressed: select,
      );
    }
    return ChoiceChip(
      label: Text(label),
      selected: type == value,
      showCheckmark: false,
      onSelected: (_) => select(),
    );
  }

  Widget bilingualFilter() {
    void select() {
      setState(() => bilingual = !bilingual);
      runSearch();
    }

    if (useLeanbackControls) {
      return TvFilterChip(
        label: 'Song ngữ',
        icon: Icons.translate_rounded,
        selected: bilingual,
        onPressed: select,
      );
    }
    return ChoiceChip(
      label: const Text('Song ngữ'),
      selected: bilingual,
      showCheckmark: false,
      onSelected: (_) => select(),
    );
  }
}

class SearchSuggestionChips extends StatelessWidget {
  const SearchSuggestionChips({
    super.key,
    required this.recent,
    required this.quick,
    required this.onSelect,
    this.onClearRecent,
  });

  final List<String> recent;
  final List<String> quick;
  final ValueChanged<String> onSelect;
  final VoidCallback? onClearRecent;

  @override
  Widget build(BuildContext context) {
    final suggestions = <String>[
      ...recent,
      for (final item in quick)
        if (!recent.any((r) => r.toLowerCase() == item.toLowerCase())) item,
    ].take(10).toList(growable: false);
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              recent.isEmpty ? 'Gợi ý nhanh' : 'Tìm gần đây',
              style: const TextStyle(
                color: CvColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            const Spacer(),
            if (onClearRecent != null)
              TextButton.icon(
                onPressed: onClearRecent,
                icon: const Icon(Icons.close_rounded, size: 14),
                label: const Text('Xoá'),
                style: TextButton.styleFrom(
                  foregroundColor: CvColors.muted,
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final item in suggestions)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: Icon(
                      recent.contains(item)
                          ? Icons.history_rounded
                          : Icons.local_fire_department_rounded,
                      size: 16,
                    ),
                    label: Text(item),
                    onPressed: () => onSelect(item),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class ActiveFilterChips extends StatelessWidget {
  const ActiveFilterChips({
    super.key,
    required this.filters,
    required this.onClearAll,
  });

  final List<(String, VoidCallback)> filters;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    if (filters.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final filter in filters)
          InputChip(
            avatar: const Icon(Icons.tune_rounded, size: 16),
            label: Text(filter.$1),
            onDeleted: filter.$2,
          ),
        TextButton.icon(
          onPressed: onClearAll,
          icon: const Icon(Icons.clear_all_rounded, size: 18),
          label: const Text('Xoá lọc'),
        ),
      ],
    );
  }
}

class FilterBar extends StatelessWidget {
  const FilterBar({
    super.key,
    required this.genre,
    required this.country,
    required this.year,
    required this.sort,
    required this.genres,
    required this.countries,
    required this.years,
    required this.sorts,
    required this.onGenre,
    required this.onCountry,
    required this.onYear,
    required this.onSort,
  });

  final String genre;
  final String country;
  final String year;
  final String sort;
  final List<(String, String)> genres;
  final List<(String, String)> countries;
  final List<(String, String)> years;
  final List<(String, String)> sorts;
  final ValueChanged<String> onGenre;
  final ValueChanged<String> onCountry;
  final ValueChanged<String> onYear;
  final ValueChanged<String> onSort;

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < 640 && !useLeanbackControls;
    final fields = [
      _FilterMenu(
        icon: Icons.category_rounded,
        value: genre,
        items: genres,
        onChanged: onGenre,
      ),
      _FilterMenu(
        icon: Icons.public_rounded,
        value: country,
        items: countries,
        onChanged: onCountry,
      ),
      _FilterMenu(
        icon: Icons.calendar_month_rounded,
        value: year,
        items: years,
        onChanged: onYear,
      ),
      _FilterMenu(
        icon: Icons.sort_rounded,
        value: sort,
        items: sorts,
        onChanged: onSort,
      ),
    ];
    if (compact) {
      return Column(
        children: [
          for (final field in fields)
            Padding(padding: const EdgeInsets.only(bottom: 8), child: field),
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < fields.length; i++) ...[
          Expanded(child: fields[i]),
          if (i != fields.length - 1) const SizedBox(width: 10),
        ],
      ],
    );
  }
}

class TabletDiscoveryStrip extends StatelessWidget {
  const TabletDiscoveryStrip({
    super.key,
    required this.selectedGenre,
    required this.selectedSort,
    required this.onGenre,
    required this.onSort,
  });

  final String selectedGenre;
  final String selectedSort;
  final ValueChanged<String> onGenre;
  final ValueChanged<String> onSort;

  static const genrePicks = [
    ('hanh-dong', 'Hành động', Icons.local_fire_department_rounded),
    ('tinh-cam', 'Tình cảm', Icons.favorite_rounded),
    ('kinh-di', 'Kinh dị', Icons.nightlight_round),
    ('hoat-hinh', 'Hoạt hình', Icons.animation_rounded),
    ('hai-huoc', 'Hài hước', Icons.sentiment_very_satisfied_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 86,
      child: ListView.separated(
        key: const PageStorageKey('tablet-discovery-strip'),
        scrollDirection: Axis.horizontal,
        itemCount: genrePicks.length + 2,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          if (index == 0) {
            return TabletDiscoveryTile(
              icon: Icons.auto_awesome_rounded,
              label: 'Đề xuất',
              selected: selectedSort == 'view_count',
              onTap: () => onSort('view_count'),
            );
          }
          if (index == 1) {
            return TabletDiscoveryTile(
              icon: Icons.schedule_rounded,
              label: 'Mới cập nhật',
              selected: selectedSort == 'created_at',
              onTap: () => onSort('created_at'),
            );
          }
          final item = genrePicks[index - 2];
          return TabletDiscoveryTile(
            icon: item.$3,
            label: item.$2,
            selected: selectedGenre == item.$1,
            onTap: () => onGenre(selectedGenre == item.$1 ? '' : item.$1),
          );
        },
      ),
    );
  }
}

class TabletDiscoveryTile extends StatelessWidget {
  const TabletDiscoveryTile({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 172,
      child: Material(
        color: selected
            ? CvColors.accent.withValues(alpha: .18)
            : Colors.white.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected
                    ? CvColors.accent.withValues(alpha: .72)
                    : Colors.white.withValues(alpha: .1),
              ),
            ),
            child: Row(
              children: [
                Icon(icon, color: selected ? CvColors.accent : Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      height: 1.1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class BrowseMeta {
  const BrowseMeta({
    required this.genres,
    required this.countries,
    required this.years,
  });

  final List<(String, String)> genres;
  final List<(String, String)> countries;
  final List<(String, String)> years;

  static final fallback = BrowseMeta(
    genres: _BrowseScreenState.defaultGenres,
    countries: _BrowseScreenState.defaultCountries,
    years: [
      ('', 'Tất cả năm'),
      for (var value = DateTime.now().year + 1; value >= 1990; value--)
        ('$value', '$value'),
    ],
  );
}

class _FilterMenu extends StatelessWidget {
  const _FilterMenu({
    required this.icon,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final IconData icon;
  final String value;
  final List<(String, String)> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final largeControls = useLeanbackControls;
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      style: TextStyle(
        color: CvColors.text,
        fontSize: largeControls ? 17 : 14,
        fontWeight: largeControls ? FontWeight.w800 : FontWeight.w500,
      ),
      decoration: InputDecoration(
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: largeControls
            ? Colors.white.withValues(alpha: .09)
            : CvColors.panel,
        contentPadding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: largeControls ? 18 : 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: largeControls
                ? Colors.white.withValues(alpha: .14)
                : Colors.transparent,
          ),
        ),
      ),
      dropdownColor: CvColors.panel,
      items: [
        for (final item in items)
          DropdownMenuItem(value: item.$1, child: Text(item.$2)),
      ],
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }
}

class FutureGrid extends StatelessWidget {
  const FutureGrid({
    super.key,
    required this.future,
    required this.cardWidth,
    required this.repo,
    this.touchColumns,
    this.onRetry,
    this.emptyMessage = 'Không tìm thấy phim phù hợp',
    this.emptyActionLabel,
    this.onEmptyAction,
  });
  final Future<List<Movie>> future;
  final double cardWidth;
  final MovieRepository repo;
  final int? touchColumns;
  final VoidCallback? onRetry;
  final String emptyMessage;
  final String? emptyActionLabel;
  final VoidCallback? onEmptyAction;

  @override
  Widget build(BuildContext context) {
    final gridPad = pagePadding(context);
    final useFixedTouchGrid =
        !useLeanbackControls && touchColumns != null && touchColumns! > 0;
    final columns = touchColumns ?? 2;
    final availableWidth =
        MediaQuery.sizeOf(context).width - gridPad.left - gridPad.right;
    const crossSpacing = 14.0;
    final fixedCardWidth = useFixedTouchGrid
        ? (availableWidth - crossSpacing * (columns - 1)) / columns
        : cardWidth;
    SliverGridDelegate gridDelegate(double width) {
      if (useFixedTouchGrid) {
        return SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 18,
          crossAxisSpacing: crossSpacing,
          mainAxisExtent: moviePosterCardHeight(width),
        );
      }
      return SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: width + 28,
        mainAxisSpacing: 18,
        crossAxisSpacing: crossSpacing,
        childAspectRatio: width / moviePosterCardHeight(width),
      );
    }

    return FutureBuilder<List<Movie>>(
      future: future,
      builder: (context, snapshot) {
        // Lỗi mạng/timeout: báo lỗi + nút thử lại thay vì skeleton loading vô hạn.
        if (snapshot.hasError) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Không tải được phim. Kiểm tra kết nối mạng.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: CvColors.muted),
                    ),
                    if (onRetry != null) ...[
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Thử lại'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return SliverPadding(
            padding: gridPad.copyWith(top: 20, bottom: 36),
            sliver: SliverGrid.builder(
              itemCount: 12,
              gridDelegate: gridDelegate(fixedCardWidth),
              itemBuilder: (context, index) => SkeletonBox(
                borderRadius: 8,
                width: fixedCardWidth,
                height: moviePosterCardHeight(fixedCardWidth),
              ),
            ),
          );
        }
        final movies = snapshot.data!;
        if (movies.isEmpty) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyActionState(
              message: emptyMessage,
              actionLabel: emptyActionLabel,
              onAction: onEmptyAction,
              icon: Icons.search_off_rounded,
            ),
          );
        }
        return SliverPadding(
          padding: gridPad.copyWith(bottom: 36),
          sliver: SliverGrid.builder(
            itemCount: movies.length,
            gridDelegate: gridDelegate(fixedCardWidth),
            itemBuilder: (context, index) => MoviePosterCard(
              movie: movies[index],
              width: fixedCardWidth,
              onTap: () => openDetail(context, repo, movies[index]),
            ),
          ),
        );
      },
    );
  }
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.repo});
  final MovieRepository repo;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<WatchItem>> items;

  @override
  void initState() {
    super.initState();
    items = _history();
  }

  Future<List<WatchItem>> _history() async {
    return mergedWatchHistory(widget.repo);
  }

  Future<void> _remove(WatchItem item) async {
    final current = await items;
    if (mounted) {
      setState(
        () => items = Future.value(
          current.where((e) => e.movieId != item.movieId).toList(),
        ),
      );
    }
    await LocalHistory.removeMovie(item.movieId);
    if (Api.instance.hasAuthToken) {
      try {
        await widget.repo.deleteHistoryMovie(item.movieId);
      } catch (_) {}
    }
  }

  Future<void> _clear() async {
    await LocalHistory.clear();
    if (Api.instance.hasAuthToken) {
      try {
        await widget.repo.clearHistory();
      } catch (_) {}
    }
    if (mounted) setState(() => items = _history());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<WatchItem>>(
      future: items,
      builder: (context, snapshot) {
        final list = (snapshot.data ?? const [])
            .where((e) => e.shouldShow)
            .toList();
        return CustomScrollView(
          key: const PageStorageKey('history-scroll'),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: pagePadding(context).copyWith(top: 36, bottom: 20),
                child: Row(
                  children: [
                    const Expanded(child: PageHeading('Xem tiếp')),
                    useLeanbackControls
                        ? TvActionButton(
                            icon: Icons.delete_outline_rounded,
                            label: 'Xoá lịch sử',
                            danger: true,
                            onPressed: () {
                              _clear();
                            },
                          )
                        : TextButton.icon(
                            onPressed: () async {
                              await _clear();
                            },
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('Xoá'),
                          ),
                  ],
                ),
              ),
            ),
            if (!snapshot.hasData)
              const SliverFillRemaining(
                child: Center(
                  child: CircularProgressIndicator(color: CvColors.accent),
                ),
              )
            else if (list.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyActionState(
                  message: 'Chưa có phim đang xem dở',
                  icon: Icons.history_rounded,
                ),
              )
            else
              SliverPadding(
                padding: pagePadding(context).copyWith(bottom: 36),
                sliver: SliverGrid.builder(
                  itemCount: list.length,
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: landscapeExtent(context) + 26,
                    mainAxisSpacing: 18,
                    crossAxisSpacing: 16,
                    childAspectRatio: 1.55,
                  ),
                  itemBuilder: (context, index) => ContinueCard(
                    item: list[index],
                    width: landscapeExtent(context),
                    onRemove: () => _remove(list[index]),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ResumeLoaderScreen(
                          repo: widget.repo,
                          item: list[index],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.repo});
  final MovieRepository repo;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final email = TextEditingController();
  final password = TextEditingController();
  Future<Map<String, dynamic>?>? meFuture;
  bool busy = false;
  Timer? oauthPollTimer;
  String? lastCallbackUrl;
  static const oauthChannel = MethodChannel('live.cineviet/oauth');

  @override
  void initState() {
    super.initState();
    meFuture = _me();
    _startOAuthPolling();
  }

  Future<Map<String, dynamic>?> _me() async {
    return await Api.instance.currentUser() ?? Api.instance.cachedUser();
  }

  Future<Map<String, dynamic>?> _benefits() async {
    try {
      final response = await Api.instance.dio.get('/donations/me');
      return response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> login() async {
    setState(() => busy = true);
    try {
      final res = await Api.instance.dio.post(
        '/auth/login',
        data: {
          'email': email.text.trim(),
          'password': password.text,
          'mobileKey': 'cineviet-mobile-app-v2',
        },
      );
      final token = cleanText(res.data['accessToken'] ?? res.data['token']);
      final refreshToken = cleanText(res.data['refreshToken']);
      if (token.isEmpty) throw Exception('Không nhận được token');
      await Api.instance.saveSession(token, refreshToken);
      final synced = await MovieRepository(
        Api.instance,
      ).syncLocalLibraryToCloud();
      setState(() => meFuture = _me());
      if (mounted) {
        showSnack(
          context,
          synced.history + synced.favorites > 0
              ? 'Đăng nhập thành công • đã đồng bộ ${synced.history} phim xem tiếp, ${synced.favorites} yêu thích'
              : 'Đăng nhập thành công',
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Đăng nhập chưa thành công');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> loginWithGoogle() async {
    setState(() => busy = true);
    try {
      if (!kIsWeb && (Platform.isAndroid || Platform.isWindows)) {
        final bridgeFile = File(windowsOAuthBridgePath);
        if (Platform.isWindows && await bridgeFile.exists()) {
          await bridgeFile.delete();
        }
        final opened = await launchUrl(
          Uri.parse('$apiBase/auth/google?desktop=1'),
          mode: LaunchMode.externalApplication,
        );
        if (!mounted) return;
        showSnack(
          context,
          opened
              ? 'Đã mở trình duyệt đăng nhập Google'
              : 'Không mở được trình duyệt Google',
        );
        setState(() => busy = false);
        return;
      }

      final google = GoogleSignIn(
        scopes: const ['email', 'profile'],
        serverClientId: googleServerClientId,
      );
      if (!kIsWeb && !Platform.isIOS) {
        await google.signOut();
      }
      final account = await google.signIn();
      if (account == null) return;
      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw Exception('Không lấy được Google ID token');
      }
      final res = await Api.instance.dio.post(
        '/auth/google/mobile',
        data: {'idToken': idToken, 'remember': true},
        options: Options(headers: {'X-Mobile-Key': 'cineviet-mobile-app-v2'}),
      );
      final token = cleanText(res.data['accessToken'] ?? res.data['token']);
      final refreshToken = cleanText(res.data['refreshToken']);
      if (token.isEmpty) throw Exception('Không nhận được token Google');
      await Api.instance.saveSession(token, refreshToken);
      final synced = await MovieRepository(
        Api.instance,
      ).syncLocalLibraryToCloud();
      setState(() => meFuture = _me());
      if (mounted) {
        showSnack(
          context,
          synced.history + synced.favorites > 0
              ? 'Đăng nhập Google thành công • đã đồng bộ ${synced.history} phim xem tiếp, ${synced.favorites} yêu thích'
              : 'Đăng nhập Google thành công',
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Đăng nhập Google chưa thành công');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _startOAuthPolling() {
    if (kIsWeb || !(Platform.isAndroid || Platform.isWindows)) return;
    oauthPollTimer = Timer.periodic(
      const Duration(milliseconds: 600),
      (_) => _consumeOAuthCallback(),
    );
    _consumeOAuthCallback();
  }

  Future<String> _readOAuthCallback() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        return cleanText(
          await oauthChannel.invokeMethod<String>('getLatestCallback'),
        );
      } catch (_) {
        return '';
      }
    }
    if (!kIsWeb && Platform.isWindows) {
      final file = File(windowsOAuthBridgePath);
      if (!await file.exists()) return '';
      final callbackUrl = (await file.readAsString()).trim();
      try {
        await file.delete();
      } catch (_) {
        await file.writeAsString('');
      }
      return callbackUrl;
    }
    return '';
  }

  Future<void> _consumeOAuthCallback() async {
    final callbackUrl = await _readOAuthCallback();
    if (callbackUrl.isEmpty ||
        callbackUrl == lastCallbackUrl ||
        !callbackUrl.startsWith('cineviet://auth/callback')) {
      return;
    }
    lastCallbackUrl = callbackUrl;
    try {
      final uri = Uri.parse(callbackUrl);
      final code = uri.queryParameters['code'] ?? '';
      if (code.isEmpty) throw Exception('Không nhận được mã Google');
      final res = await Api.instance.dio.get(
        '/auth/oauth-token',
        queryParameters: {'code': code},
        options: Options(headers: {'X-Mobile-Key': 'cineviet-mobile-app-v2'}),
      );
      final token = cleanText(res.data['accessToken'] ?? res.data['token']);
      final refreshToken = cleanText(res.data['refreshToken']);
      if (token.isEmpty) throw Exception('Không nhận được token Google');
      await Api.instance.saveSession(token, refreshToken);
      final synced = await MovieRepository(
        Api.instance,
      ).syncLocalLibraryToCloud();
      if (!mounted) return;
      setState(() => meFuture = _me());
      showSnack(
        context,
        synced.history + synced.favorites > 0
            ? 'Đăng nhập Google thành công • đã đồng bộ ${synced.history} phim xem tiếp, ${synced.favorites} yêu thích'
            : 'Đăng nhập Google thành công',
      );
    } catch (_) {
      if (mounted) showSnack(context, 'Không hoàn tất được đăng nhập Google');
    }
  }

  Future<void> logout() async {
    await Api.instance.clearToken();
    setState(() => meFuture = Future.value(null));
  }

  @override
  void dispose() {
    oauthPollTimer?.cancel();
    email.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: meFuture,
      builder: (context, snapshot) {
        final user = snapshot.data;
        final checkingSession =
            !snapshot.hasData &&
            snapshot.connectionState == ConnectionState.waiting;
        return ListView(
          key: const PageStorageKey('profile-scroll'),
          padding: pagePadding(context).copyWith(top: 36, bottom: 36),
          children: [
            const PageHeading('Của tôi'),
            const SizedBox(height: 22),
            if (checkingSession)
              const SessionRestoringPanel()
            else if (user == null)
              isTvBuild
                  ? TvLoginPanel(
                      onOpen: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TvPairingScreen(repo: widget.repo),
                        ),
                      ),
                    )
                  : LoginPanel(
                      email: email,
                      password: password,
                      busy: busy,
                      onLogin: login,
                      onGoogleLogin: loginWithGoogle,
                    ),
            if (user != null) ...[
              AccountPanel(
                user: user,
                onLogout: logout,
                onUpdated: (updated) =>
                    setState(() => meFuture = Future.value(updated)),
              ),
              const SizedBox(height: 14),
              BenefitsSummaryCard(load: _benefits),
            ],
            const SizedBox(height: 22),
            if (useLeanbackControls)
              TvProfileHub(
                repo: widget.repo,
                onRequireLogin: requireLogin,
                onOfflineDownloads: supportsOfflineDownloads
                    ? () async {
                        if (!await requireOfflineVip(context)) return;
                        if (!context.mounted) return;
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                OfflineDownloadsScreen(repo: widget.repo),
                          ),
                        );
                      }
                    : null,
              ),
            if (!useLeanbackControls) ...[
              if (supportsOfflineDownloads)
                ProfileTile(
                  icon: Icons.download_done_rounded,
                  title: 'Tải xuống',
                  subtitle: 'Xem phim khi không có mạng',
                  onTap: () async {
                    if (!await requireOfflineVip(context)) return;
                    if (!context.mounted) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            OfflineDownloadsScreen(repo: widget.repo),
                      ),
                    );
                  },
                ),
              ProfileTile(
                icon: Icons.favorite_rounded,
                title: 'Danh sách yêu thích',
                subtitle: '',
                onTap: () async {
                  if (!await requireLogin(context, 'Danh sách yêu thích')) {
                    return;
                  }
                  if (!context.mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FavoritesScreen(repo: widget.repo),
                    ),
                  );
                },
              ),
              ProfileTile(
                icon: Icons.playlist_play_rounded,
                title: 'Playlist của tôi',
                subtitle: '',
                onTap: () async {
                  if (!await requireLogin(context, 'Playlist')) return;
                  if (!context.mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PlaylistsScreen(repo: widget.repo),
                    ),
                  );
                },
              ),
              ProfileTile(
                icon: supportsTvQrScan
                    ? Icons.qr_code_scanner_rounded
                    : Icons.pin_rounded,
                title: supportsTvQrScan
                    ? 'Quét QR đăng nhập TV'
                    : 'Nhập mã đăng nhập TV',
                subtitle: '',
                onTap: () async {
                  if (!context.mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MobileTvPairingScreen(repo: widget.repo),
                    ),
                  );
                },
              ),
              ProfileTile(
                icon: Icons.volunteer_activism_rounded,
                title: 'Ủng hộ CineViet',
                subtitle: 'Đồng hành và nhận đặc quyền không quảng cáo',
                onTap: () => launchUrl(
                  Uri.parse('$siteBase/ung-ho'),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              ProfileTile(
                icon: Icons.system_update_alt_rounded,
                title: 'Kiểm tra cập nhật',
                subtitle: '',
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => UpdateInfoScreen())),
              ),
              ProfileTile(
                icon: Icons.language_rounded,
                title: 'Mở cineviet.live',
                subtitle: siteBase,
                onTap: () => launchUrl(
                  Uri.parse(siteBase),
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class BenefitsSummaryCard extends StatelessWidget {
  const BenefitsSummaryCard({super.key, required this.load});
  final Future<Map<String, dynamic>?> Function() load;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: load(),
      builder: (context, snapshot) {
        final data = snapshot.data;
        final entitlement = data?['entitlement'] is Map
            ? Map<String, dynamic>.from(data!['entitlement'] as Map)
            : <String, dynamic>{};
        final active = entitlement['active'] == true;
        final remaining = entitlement['remainingDays'];
        final detail = active
            ? (remaining == null
                  ? 'Đang hoạt động • Không thời hạn'
                  : 'Đang hoạt động • Còn $remaining ngày')
            : 'Chưa kích hoạt hoặc đã hết hạn';
        return Panel(
          child: Row(
            children: [
              const Icon(
                Icons.verified_rounded,
                color: CvColors.accent,
                size: 30,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Đặc quyền của tôi',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(detail, style: const TextStyle(color: CvColors.muted)),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('$siteBase/ung-ho'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.volunteer_activism_rounded, size: 18),
                label: Text(active ? 'Đồng hành tiếp' : 'Ủng hộ'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class TvProfileHub extends StatelessWidget {
  const TvProfileHub({
    super.key,
    required this.repo,
    required this.onRequireLogin,
    this.onOfflineDownloads,
  });

  final MovieRepository repo;
  final Future<bool> Function(BuildContext context, String feature)
  onRequireLogin;
  final VoidCallback? onOfflineDownloads;

  @override
  Widget build(BuildContext context) {
    final actions = <TvHubAction>[
      if (onOfflineDownloads != null)
        TvHubAction(
          icon: Icons.download_done_rounded,
          title: 'Tải xuống',
          subtitle: 'Xem phim khi không có mạng',
          onPressed: onOfflineDownloads!,
        ),
      TvHubAction(
        icon: Icons.history_rounded,
        title: 'Xem tiếp',
        subtitle: 'Lịch sử đang xem',
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => HistoryScreen(repo: repo))),
      ),
      TvHubAction(
        icon: Icons.favorite_rounded,
        title: 'Yêu thích',
        subtitle: 'Phim đã lưu',
        onPressed: () {
          () async {
            if (!await onRequireLogin(context, 'Danh sách yêu thích')) return;
            if (!context.mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => FavoritesScreen(repo: repo)),
            );
          }();
        },
      ),
      TvHubAction(
        icon: Icons.playlist_play_rounded,
        title: 'Playlist',
        subtitle: 'Bộ sưu tập của tôi',
        onPressed: () {
          () async {
            if (!await onRequireLogin(context, 'Playlist')) return;
            if (!context.mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => PlaylistsScreen(repo: repo)),
            );
          }();
        },
      ),
      TvHubAction(
        icon: Icons.volunteer_activism_rounded,
        title: 'Ủng hộ CineViet',
        subtitle: 'Đồng hành và nhận đặc quyền không quảng cáo',
        onPressed: () => launchUrl(
          Uri.parse('$siteBase/ung-ho'),
          mode: LaunchMode.externalApplication,
        ),
      ),
      TvHubAction(
        icon: Icons.system_update_alt_rounded,
        title: 'Cập nhật',
        subtitle: 'Kiểm tra bản mới',
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => UpdateInfoScreen())),
      ),
      TvHubAction(
        icon: Icons.language_rounded,
        title: 'CineViet live',
        subtitle: siteBase,
        onPressed: () => launchUrl(
          Uri.parse(siteBase),
          mode: LaunchMode.externalApplication,
        ),
      ),
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: actions.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 340,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 2.25,
      ),
      itemBuilder: (context, index) {
        final action = actions[index];
        return FocusButton(
          onPressed: action.onPressed,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: .12)),
            ),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: CvColors.accent.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(action.icon, color: CvColors.accent, size: 30),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        action.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        action.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: CvColors.muted),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: CvColors.soft),
              ],
            ),
          ),
        );
      },
    );
  }
}

class TvHubAction {
  const TvHubAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onPressed;
}

class SessionRestoringPanel extends StatelessWidget {
  const SessionRestoringPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Row(
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              color: CvColors.accent,
              strokeWidth: 3,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Đang vào tài khoản đã lưu...',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: .82),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TvLoginPanel extends StatelessWidget {
  const TvLoginPanel({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.tv_rounded, size: 64, color: CvColors.accent),
          const SizedBox(height: 16),
          const Text(
            'Đăng nhập TV bằng điện thoại',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          const Text(
            'Hiện QR và mã 6 số trên TV, sau đó dùng điện thoại đã đăng nhập để xác nhận.',
            textAlign: TextAlign.center,
            style: TextStyle(color: CvColors.muted),
          ),
          const SizedBox(height: 22),
          if (isTvBuild)
            TvActionButton(
              icon: Icons.qr_code_2_rounded,
              label: 'Đăng nhập nhanh',
              primary: true,
              onPressed: onOpen,
            )
          else
            FilledButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.qr_code_2_rounded),
              label: const Text('Đăng nhập nhanh bằng mã/QR'),
            ),
        ],
      ),
    );
  }
}

class LoginPanel extends StatelessWidget {
  const LoginPanel({
    super.key,
    required this.email,
    required this.password,
    required this.busy,
    required this.onLogin,
    required this.onGoogleLogin,
  });

  final TextEditingController email;
  final TextEditingController password;
  final bool busy;
  final VoidCallback onLogin;
  final VoidCallback onGoogleLogin;

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Đăng nhập CineViet',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: email,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Mật khẩu'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: busy ? null : onLogin,
            icon: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login_rounded),
            label: const Text('Đăng nhập'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: busy ? null : onGoogleLogin,
            icon: const Icon(Icons.g_mobiledata_rounded),
            label: const Text('Đăng nhập bằng Google'),
          ),
        ],
      ),
    );
  }
}

class AccountPanel extends StatelessWidget {
  const AccountPanel({
    super.key,
    required this.user,
    required this.onLogout,
    required this.onUpdated,
  });
  final Map<String, dynamic> user;
  final VoidCallback onLogout;
  final ValueChanged<Map<String, dynamic>> onUpdated;

  @override
  Widget build(BuildContext context) {
    final name = cleanText(user['name'] ?? user['email']);
    final avatar = userAvatarUrlFrom(user);
    final isAdmin = isAdminUser(user);
    final isVip = isVipUser(user) || isAdmin;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              UserAvatar(
                name: name,
                avatarUrl: avatar,
                radius: 34,
                isVip: isVip,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? 'CineViet user' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      cleanText(user['email']),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: CvColors.muted),
                    ),
                    const SizedBox(height: 9),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        key: const Key('account-membership-chip'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: isAdmin
                              ? const Color(0xFFFFC83D).withValues(alpha: 0.13)
                              : isVip
                              ? const Color(0xFF9B59FF).withValues(alpha: 0.16)
                              : CvColors.panel2,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: isAdmin
                                ? const Color(0xFFFFC83D).withValues(alpha: 0.7)
                                : isVip
                                ? const Color(0xFFB983FF).withValues(alpha: 0.8)
                                : CvColors.border,
                          ),
                        ),
                        child: Text(
                          vipLabel(user),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isAdmin
                                ? const Color(0xFFFFD76A)
                                : isVip
                                ? const Color(0xFFD8B4FE)
                                : CvColors.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(height: 1, color: CvColors.border),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ChangePasswordScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.lock_outline_rounded, size: 19),
                  label: const Text('Mật khẩu'),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: () async {
                    final updated = await Navigator.of(context)
                        .push<Map<String, dynamic>>(
                          MaterialPageRoute(
                            builder: (_) => ProfileEditScreen(user: user),
                          ),
                        );
                    if (updated != null) onUpdated(updated);
                  },
                  icon: const Icon(Icons.edit_rounded, size: 19),
                  label: const Text('Chỉnh sửa'),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: onLogout,
                  icon: const Icon(Icons.logout_rounded, size: 19),
                  label: const Text('Đăng xuất'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFFF7B86),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

bool isAdminUser(Map<String, dynamic> user) {
  final role = cleanText(
    user['role'] ?? user['user_role'] ?? user['type'],
  ).toLowerCase();
  return user['is_admin'] == true ||
      user['is_admin'] == 1 ||
      role == 'admin' ||
      role == 'administrator';
}

String vipLabel(Map<String, dynamic> user) {
  if (isAdminUser(user)) return 'Administrator';
  if (!isVipUser(user)) return 'Thành viên';
  final raw = cleanText(user['vip_expires_at'] ?? user['vipExpiresAt']);
  final parsed = DateTime.tryParse(raw)?.toLocal();
  if (parsed == null) return 'VIP';
  final day = parsed.day.toString().padLeft(2, '0');
  final month = parsed.month.toString().padLeft(2, '0');
  return 'VIP · hết hạn $day/$month/${parsed.year}';
}

bool isVipUser(Map<String, dynamic> user) =>
    user['is_vip'] == true ||
    user['is_vip'] == 1 ||
    cleanText(user['status']).toLowerCase() == 'vip';

String apiErrorMessage(Object error, String fallback) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map) {
      final message = cleanText(data['error'] ?? data['message']);
      if (message.isNotEmpty) return message;
    }
  }
  return fallback;
}

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final current = TextEditingController();
  final next = TextEditingController();
  final confirm = TextEditingController();
  bool busy = false;

  Future<void> save() async {
    if (next.text.length < 6 || next.text != confirm.text) {
      showSnack(context, 'Mật khẩu mới tối thiểu 6 ký tự và phải trùng nhau');
      return;
    }
    setState(() => busy = true);
    try {
      await Api.instance.dio.post(
        '/user/change-password',
        data: {'currentPassword': current.text, 'newPassword': next.text},
      );
      if (mounted) {
        showSnack(context, 'Đã đổi mật khẩu');
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, apiErrorMessage(error, 'Không đổi được mật khẩu'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    current.dispose();
    next.dispose();
    confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Đổi mật khẩu')),
    body: ListView(
      padding: pagePadding(context).copyWith(top: 24),
      children: [
        TextField(
          controller: current,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Mật khẩu hiện tại'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: next,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Mật khẩu mới'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: confirm,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Nhập lại mật khẩu mới'),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? 'Đang lưu...' : 'Đổi mật khẩu'),
        ),
      ],
    ),
  );
}

class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key, required this.user});
  final Map<String, dynamic> user;

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late final TextEditingController nameController;
  XFile? selectedImage;
  bool removeAvatar = false;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(
      text: cleanText(widget.user['name']),
    );
  }

  bool get canUseCamera =>
      !kIsWeb && !isTvBuild && (Platform.isAndroid || Platform.isIOS);

  Future<void> showAvatarPicker() async {
    if (busy) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final hasAvatar = userAvatarUrlFrom(widget.user).isNotEmpty;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_rounded),
                title: const Text('Chọn từ thư viện'),
                onTap: () {
                  Navigator.pop(context);
                  pickAvatar(ImageSource.gallery);
                },
              ),
              if (canUseCamera)
                ListTile(
                  leading: const Icon(Icons.photo_camera_rounded),
                  title: const Text('Chụp ảnh mới'),
                  onTap: () {
                    Navigator.pop(context);
                    pickAvatar(ImageSource.camera);
                  },
                ),
              if (selectedImage != null)
                ListTile(
                  leading: const Icon(Icons.undo_rounded),
                  title: const Text('Bỏ ảnh vừa chọn'),
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => selectedImage = null);
                  },
                ),
              if (removeAvatar)
                ListTile(
                  leading: const Icon(Icons.restore_rounded),
                  title: const Text('Giữ ảnh hiện tại'),
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => removeAvatar = false);
                  },
                ),
              if (hasAvatar)
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline_rounded,
                    color: CvColors.danger,
                  ),
                  title: const Text('Xoá ảnh đại diện'),
                  onTap: () {
                    Navigator.pop(context);
                    setState(() {
                      selectedImage = null;
                      removeAvatar = true;
                    });
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> pickAvatar(ImageSource source) async {
    final image = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 95,
    );
    if (image == null) return;
    try {
      final prepared = await prepareAvatarImage(image);
      if (mounted) {
        setState(() {
          selectedImage = prepared;
          removeAvatar = false;
        });
      }
    } catch (_) {
      if (mounted) showSnack(context, 'Không xử lý được ảnh đã chọn');
    }
  }

  Future<XFile> prepareAvatarImage(XFile source) async {
    final bytes = await source.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return source;
    final oriented = img.bakeOrientation(decoded);
    final side = math.min(oriented.width, oriented.height);
    final cropped = img.copyCrop(
      oriented,
      x: ((oriented.width - side) / 2).round(),
      y: ((oriented.height - side) / 2).round(),
      width: side,
      height: side,
    );
    final normalized = side > 1024
        ? img.copyResize(
            cropped,
            width: 1024,
            height: 1024,
            interpolation: img.Interpolation.average,
          )
        : cropped;
    final jpg = img.encodeJpg(normalized, quality: 88);
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/cineviet-avatar-${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(jpg, flush: true);
    return XFile(
      file.path,
      name: 'cineviet-avatar.jpg',
      mimeType: 'image/jpeg',
    );
  }

  Future<void> save() async {
    final name = nameController.text.trim();
    if (name.isEmpty) {
      showSnack(context, 'Tên hiển thị không được để trống');
      return;
    }
    setState(() => busy = true);
    try {
      final previousAvatar = userAvatarUrlFrom(widget.user);
      Map<String, dynamic> updated;
      if (selectedImage != null) {
        final form = FormData.fromMap({
          'avatar': await MultipartFile.fromFile(
            selectedImage!.path,
            filename: selectedImage!.name,
          ),
        });
        final response = await Api.instance.dio.post(
          '/user/avatar',
          data: form,
        );
        updated = Map<String, dynamic>.from(response.data as Map);
      } else {
        updated = Map<String, dynamic>.from(widget.user);
      }
      if (selectedImage != null || removeAvatar) {
        if (previousAvatar.isNotEmpty) {
          await CachedNetworkImage.evictFromCache(previousAvatar);
        }
      }
      final response = await Api.instance.dio.patch(
        '/user/profile',
        data: {'name': name, if (removeAvatar) 'avatar': ''},
      );
      updated = {
        ...updated,
        ...Map<String, dynamic>.from(response.data as Map),
      };
      final refreshed = await Api.instance.currentUser(allowRefresh: false);
      final nextAvatar = userAvatarUrlFrom(refreshed ?? updated);
      if (nextAvatar.isNotEmpty && nextAvatar != previousAvatar) {
        await CachedNetworkImage.evictFromCache(nextAvatar);
      }
      if (mounted) Navigator.of(context).pop(refreshed ?? updated);
    } catch (error) {
      if (mounted) {
        showSnack(context, apiErrorMessage(error, 'Không cập nhật được hồ sơ'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentAvatar = userAvatarUrlFrom(widget.user);
    final hasPreview = selectedImage != null;
    final avatarRemoved = removeAvatar && !hasPreview;
    final displayName = cleanText(
      nameController.text.trim().isEmpty
          ? widget.user['name']
          : nameController.text,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Chỉnh sửa hồ sơ')),
      body: ListView(
        padding: pagePadding(context).copyWith(top: 24, bottom: 32),
        children: [
          Center(
            child: Column(
              children: [
                GestureDetector(
                  onTap: busy ? null : showAvatarPicker,
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      UserAvatar(
                        name: displayName,
                        avatarUrl: avatarRemoved ? '' : currentAvatar,
                        imageProvider: hasPreview
                            ? FileImage(File(selectedImage!.path))
                            : null,
                        radius: 56,
                        isVip: isVipUser(widget.user),
                      ),
                      CircleAvatar(
                        radius: 17,
                        backgroundColor: CvColors.accent,
                        child: Icon(
                          hasPreview
                              ? Icons.check_rounded
                              : Icons.camera_alt_rounded,
                          color: CvColors.black,
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: busy ? null : showAvatarPicker,
                      icon: const Icon(Icons.add_a_photo_rounded),
                      label: const Text('Đổi ảnh'),
                    ),
                    if (hasPreview)
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () => setState(() => selectedImage = null),
                        icon: const Icon(Icons.close_rounded),
                        label: const Text('Bỏ ảnh chọn'),
                      ),
                    if (avatarRemoved)
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () => setState(() => removeAvatar = false),
                        icon: const Icon(Icons.restore_rounded),
                        label: const Text('Giữ ảnh hiện tại'),
                      ),
                  ],
                ),
                if (avatarRemoved) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Ảnh đại diện sẽ được xoá khi lưu',
                    style: TextStyle(color: CvColors.muted, fontSize: 12),
                  ),
                ] else if (hasPreview) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Ảnh sẽ được crop vuông và nén trước khi tải lên',
                    style: TextStyle(color: CvColors.muted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: nameController,
            enabled: !busy,
            decoration: const InputDecoration(labelText: 'Tên hiển thị'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          if (busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: busy ? null : save,
            icon: Icon(busy ? Icons.cloud_upload_rounded : Icons.save_rounded),
            label: Text(busy ? 'Đang lưu...' : 'Lưu thay đổi'),
          ),
        ],
      ),
    );
  }
}

class UserAvatar extends StatefulWidget {
  const UserAvatar({
    super.key,
    required this.name,
    required this.avatarUrl,
    this.radius = 22,
    this.imageProvider,
    this.isVip = false,
    this.showVipBadge = true,
  });

  final String name;
  final String avatarUrl;
  final double radius;
  final ImageProvider? imageProvider;
  final bool isVip;
  final bool showVipBadge;

  @override
  State<UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<UserAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController shimmer;

  @override
  void initState() {
    super.initState();
    shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
  }

  void syncAnimation() {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (widget.isVip && !reduceMotion) {
      if (!shimmer.isAnimating) shimmer.repeat();
    } else {
      shimmer.stop();
      shimmer.value = .18;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncAnimation();
  }

  @override
  void didUpdateWidget(covariant UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    syncAnimation();
  }

  @override
  void dispose() {
    shimmer.dispose();
    super.dispose();
  }

  Widget avatar(ImageProvider? provider, String initial) => CircleAvatar(
    radius: widget.radius,
    backgroundColor: CvColors.panel2,
    backgroundImage: provider,
    child: provider == null
        ? Text(
            initial.isEmpty ? 'C' : initial,
            style: TextStyle(
              color: Colors.white,
              fontSize: widget.radius * .78,
              fontWeight: FontWeight.w900,
            ),
          )
        : null,
  );

  @override
  Widget build(BuildContext context) {
    final initial = widget.name.characters.isEmpty
        ? ''
        : widget.name.characters.first.toUpperCase();
    final provider =
        widget.imageProvider ??
        (widget.avatarUrl.isNotEmpty
            ? CachedNetworkImageProvider(widget.avatarUrl)
            : null);
    if (!widget.isVip) return avatar(provider, initial);

    final radius = widget.radius;
    final compact = radius < 28;
    final frameSize = radius * 2 + (compact ? 7 : 10);
    final crownHeight = compact ? radius * .68 : radius * .92;
    final crownWidth = compact ? radius * 1.36 : radius * 1.32;
    final topSpace = widget.showVipBadge ? crownHeight * .68 : 2.0;
    final canvasWidth = frameSize + (compact ? 12 : 22);
    final canvasHeight = frameSize + topSpace + (compact ? 7 : 12);

    return SizedBox(
      width: canvasWidth,
      height: canvasHeight,
      child: AnimatedBuilder(
        animation: shimmer,
        builder: (context, _) {
          final phase = shimmer.value;
          final pulse = .5 + .5 * math.sin(phase * math.pi * 2);
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Positioned(
                top: topSpace,
                child: CustomPaint(
                  key: const ValueKey('user_avatar_vip_frame'),
                  painter: _RoyalAvatarFramePainter(
                    phase: phase,
                    pulse: pulse,
                    compact: compact,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(compact ? 3.5 : 5),
                    child: ClipOval(
                      child: Stack(
                        children: [
                          avatar(provider, initial),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: FractionalTranslation(
                                translation: Offset(phase * 3.2 - 1.6, 0),
                                child: Transform.rotate(
                                  angle: -.22,
                                  child: Container(
                                    width: radius * .55,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Colors.transparent,
                                          Colors.white.withValues(
                                            alpha: compact ? .28 : .34,
                                          ),
                                          Colors.transparent,
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.showVipBadge)
                Positioned(
                  top: 0,
                  child: Transform.rotate(
                    angle: math.sin(phase * math.pi * 2) * .052,
                    child: CustomPaint(
                      key: const ValueKey('user_avatar_vip_crown'),
                      size: Size(crownWidth, crownHeight),
                      painter: _RoyalCrownPainter(glow: pulse),
                    ),
                  ),
                ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    key: const ValueKey('user_avatar_vip_sparkle'),
                    painter: _RoyalSparklePainter(
                      phase: phase,
                      frameRect: Rect.fromCenter(
                        center: Offset(
                          canvasWidth / 2,
                          topSpace + frameSize / 2,
                        ),
                        width: frameSize,
                        height: frameSize,
                      ),
                      compact: compact,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RoyalAvatarFramePainter extends CustomPainter {
  const _RoyalAvatarFramePainter({
    required this.phase,
    required this.pulse,
    required this.compact,
  });
  final double phase;
  final double pulse;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outerRadius = size.shortestSide / 2;
    final glow = Paint()
      ..color = const Color(0xffffc95c).withValues(alpha: .18 + pulse * .22)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, compact ? 5 : 10);
    canvas.drawCircle(center, outerRadius - 1, glow);

    final outerRect = Rect.fromCircle(
      center: center,
      radius: outerRadius - 1.2,
    );
    final champagne = SweepGradient(
      transform: GradientRotation(phase * math.pi * 2),
      colors: const [
        Color(0xff7d4a08),
        Color(0xffffd77c),
        Color(0xfffff8d2),
        Color(0xffc98a20),
        Color(0xffffe6a0),
        Color(0xff7d4a08),
      ],
      stops: const [0, .22, .34, .53, .72, 1],
    ).createShader(outerRect);
    canvas.drawCircle(
      center,
      outerRadius - 2,
      Paint()
        ..shader = champagne
        ..style = PaintingStyle.stroke
        ..strokeWidth = compact ? 2.2 : 3.2,
    );
    canvas.drawCircle(
      center,
      outerRadius - (compact ? 4.2 : 5.6),
      Paint()
        ..color = const Color(0xfffff0b8).withValues(alpha: .9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = compact ? .7 : 1.15,
    );

    final orbitAngle = phase * math.pi * 2;
    final orbitRadius = outerRadius - 1.5;
    final dot =
        center +
        Offset(math.cos(orbitAngle), math.sin(orbitAngle)) * orbitRadius;
    canvas.drawCircle(
      dot,
      compact ? 1.6 : 2.2,
      Paint()
        ..color = Colors.white
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );
    canvas.drawCircle(dot, compact ? .9 : 1.35, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _RoyalAvatarFramePainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.compact != compact;
}

class _RoyalCrownPainter extends CustomPainter {
  const _RoyalCrownPainter({required this.glow});
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * .10, size.height * .82)
      ..lineTo(size.width * .04, size.height * .29)
      ..lineTo(size.width * .31, size.height * .49)
      ..lineTo(size.width * .50, size.height * .08)
      ..lineTo(size.width * .69, size.height * .49)
      ..lineTo(size.width * .96, size.height * .29)
      ..lineTo(size.width * .90, size.height * .82)
      ..quadraticBezierTo(
        size.width * .50,
        size.height * .96,
        size.width * .10,
        size.height * .82,
      )
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xffffc83d).withValues(alpha: .3 + glow * .22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xfffff3ad), Color(0xffffc23a), Color(0xff9b5b05)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xfffff1a8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(.7, size.width * .025),
    );
    final ruby = Offset(size.width * .5, size.height * .68);
    canvas.drawCircle(
      ruby,
      size.width * .09,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-.3, -.35),
          colors: [Color(0xffff9c9c), Color(0xffe3133c), Color(0xff760018)],
        ).createShader(Rect.fromCircle(center: ruby, radius: size.width * .1)),
    );
    canvas.drawCircle(
      ruby,
      size.width * .09,
      Paint()
        ..color = const Color(0xffffe28a)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(.6, size.width * .02),
    );
  }

  @override
  bool shouldRepaint(covariant _RoyalCrownPainter oldDelegate) =>
      oldDelegate.glow != glow;
}

class _RoyalSparklePainter extends CustomPainter {
  const _RoyalSparklePainter({
    required this.phase,
    required this.frameRect,
    required this.compact,
  });
  final double phase;
  final Rect frameRect;
  final bool compact;

  void drawSparkle(
    Canvas canvas,
    Offset center,
    double radius,
    double opacity,
  ) {
    if (opacity <= .02) return;
    final glowPaint = Paint()
      ..color = const Color(0xffffd45f).withValues(alpha: opacity * .85)
      ..strokeWidth = compact ? 2.8 : 4.5
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, compact ? 3.2 : 5.2);
    canvas.drawLine(
      center - Offset(radius, 0),
      center + Offset(radius, 0),
      glowPaint,
    );
    canvas.drawLine(
      center - Offset(0, radius),
      center + Offset(0, radius),
      glowPaint,
    );
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: opacity)
      ..strokeWidth = compact ? 1.15 : 1.55
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      center - Offset(radius, 0),
      center + Offset(radius, 0),
      paint,
    );
    canvas.drawLine(
      center - Offset(0, radius),
      center + Offset(0, radius),
      paint,
    );
    canvas.drawCircle(
      center,
      radius * .22,
      Paint()..color = Colors.white.withValues(alpha: opacity),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final points = [
      Offset(frameRect.left + 3, frameRect.top + frameRect.height * .27),
      Offset(frameRect.right - 1, frameRect.top + frameRect.height * .38),
      Offset(frameRect.left + frameRect.width * .18, frameRect.bottom - 2),
      Offset(frameRect.right - frameRect.width * .13, frameRect.bottom - 6),
    ];
    for (var index = 0; index < points.length; index++) {
      final wave = math.sin((phase * 4 - index) * math.pi * 2);
      final opacity = math.pow(math.max(0.0, wave), 1.7).toDouble();
      drawSparkle(canvas, points[index], compact ? 3.1 : 5.2, opacity);
    }
  }

  @override
  bool shouldRepaint(covariant _RoyalSparklePainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.frameRect != frameRect;
}

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key, required this.repo});
  final MovieRepository repo;

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  late Future<List<Movie>> future;

  @override
  void initState() {
    super.initState();
    future = widget.repo.favorites();
  }

  void reload() {
    setState(() => future = widget.repo.favorites());
  }

  Future<void> remove(Movie movie) async {
    final current = await future;
    setState(
      () => future = Future.value(
        current.where((item) => item.id != movie.id).toList(),
      ),
    );
    try {
      await widget.repo.toggleFavorite(movie, false);
      if (mounted) showSnack(context, 'Đã bỏ "${movie.title}" khỏi yêu thích');
    } catch (_) {
      if (mounted) setState(() => future = widget.repo.favorites());
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = movieCardExtent(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Yêu thích')),
      body: FutureBuilder<List<Movie>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return InlineErrorState(
              message: 'Không tải được danh sách yêu thích',
              onRetry: reload,
            );
          }
          if (!snapshot.hasData) {
            return CustomScrollView(
              slivers: [
                FutureGrid(future: future, cardWidth: width, repo: widget.repo),
              ],
            );
          }
          final movies = snapshot.data!;
          if (movies.isEmpty) {
            return const EmptyActionState(
              message: 'Chưa có phim yêu thích',
              icon: Icons.favorite_border_rounded,
            );
          }
          return GridView.builder(
            key: const PageStorageKey('favorites-grid'),
            padding: pagePadding(context).copyWith(top: 20, bottom: 36),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: width + 28,
              mainAxisSpacing: 18,
              crossAxisSpacing: 14,
              childAspectRatio: width / moviePosterCardHeight(width),
            ),
            itemCount: movies.length,
            itemBuilder: (context, index) {
              final movie = movies[index];
              return MoviePosterCard(
                movie: movie,
                width: width,
                onTap: () => openDetail(context, widget.repo, movie),
                onRemove: () => remove(movie),
                removeTooltip: 'Bỏ yêu thích',
              );
            },
          );
        },
      ),
    );
  }
}

class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key, required this.repo});
  final MovieRepository repo;

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  final name = TextEditingController();
  bool isPublic = false;
  late Future<List<CinePlaylist>> future;

  @override
  void initState() {
    super.initState();
    future = widget.repo.playlists();
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> create() async {
    if (!await requireLogin(context, 'Playlist')) return;
    final value = name.text.trim();
    if (value.isEmpty) return;
    try {
      await widget.repo.createPlaylist(value, isPublic: isPublic);
      name.clear();
      isPublic = false;
      setState(() => future = widget.repo.playlists());
      if (mounted) showSnack(context, 'Đã tạo playlist');
    } catch (_) {
      if (mounted) showSnack(context, 'Cần đăng nhập để tạo playlist');
    }
  }

  void reload() {
    setState(() => future = widget.repo.playlists());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playlist')),
      body: FutureBuilder<List<CinePlaylist>>(
        future: future,
        builder: (context, snapshot) {
          final playlists = snapshot.data ?? const <CinePlaylist>[];
          return ListView(
            key: const PageStorageKey('playlists-scroll'),
            padding: pagePadding(context).copyWith(top: 20, bottom: 40),
            children: [
              Panel(
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: name,
                            decoration: const InputDecoration(
                              labelText: 'Tên playlist mới',
                            ),
                            onSubmitted: (_) => create(),
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton.filled(
                          onPressed: create,
                          icon: const Icon(Icons.add_rounded),
                        ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: isPublic,
                      onChanged: (value) => setState(() => isPublic = value),
                      title: const Text('Công khai playlist'),
                      subtitle: const Text('Cho phép chia sẻ trên website'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              if (snapshot.hasError)
                InlineErrorState(
                  message: 'Không tải được playlist',
                  onRetry: reload,
                )
              else if (!snapshot.hasData)
                const LinearProgressIndicator(color: CvColors.accent)
              else if (playlists.isEmpty)
                const EmptyActionState(
                  message: 'Chưa có playlist hoặc chưa đăng nhập',
                  icon: Icons.playlist_add_rounded,
                )
              else
                for (final playlist in playlists)
                  ProfileTile(
                    icon: Icons.playlist_play_rounded,
                    title: playlist.name,
                    subtitle:
                        '${playlist.movieCount} phim${playlist.isPublic ? ' • public' : ''}',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PlaylistDetailScreen(
                          repo: widget.repo,
                          playlist: playlist,
                        ),
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class PlaylistDetailScreen extends StatefulWidget {
  const PlaylistDetailScreen({
    super.key,
    required this.repo,
    required this.playlist,
  });
  final MovieRepository repo;
  final CinePlaylist playlist;

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late Future<PlaylistDetail> future;

  @override
  void initState() {
    super.initState();
    future = widget.repo.playlistMovies(widget.playlist);
  }

  Future<void> toggleVisibility(PlaylistDetail detail) async {
    await widget.repo.updatePlaylistVisibility(
      detail.playlist.id,
      isPublic: !detail.playlist.isPublic,
    );
    if (mounted) {
      setState(() => future = widget.repo.playlistMovies(detail.playlist));
    }
  }

  Future<void> deletePlaylist(PlaylistDetail detail) async {
    await widget.repo.deletePlaylist(detail.playlist.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> removeMovie(PlaylistDetail detail, Movie movie) async {
    final current = await future;
    setState(
      () => future = Future.value(
        PlaylistDetail(
          playlist: current.playlist,
          movies: current.movies.where((item) => item.id != movie.id).toList(),
        ),
      ),
    );
    try {
      await widget.repo.removeFromPlaylist(detail.playlist.id, movie.id);
      if (mounted) showSnack(context, 'Đã xoá khỏi playlist');
    } catch (_) {
      if (mounted) {
        setState(() => future = widget.repo.playlistMovies(detail.playlist));
      }
    }
  }

  void reload() {
    setState(() => future = widget.repo.playlistMovies(widget.playlist));
  }

  ButtonStyle get _deletePlaylistStyle => OutlinedButton.styleFrom(
    foregroundColor: CvColors.danger,
    side: BorderSide(color: CvColors.danger.withValues(alpha: .72)),
  );

  @override
  Widget build(BuildContext context) {
    final width = movieCardExtent(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.playlist.name)),
      body: CustomScrollView(
        slivers: [
          FutureBuilder<PlaylistDetail>(
            future: future,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: InlineErrorState(
                    message: 'Không tải được playlist này',
                    onRetry: reload,
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const SliverFillRemaining(
                  child: Center(
                    child: CircularProgressIndicator(color: CvColors.accent),
                  ),
                );
              }
              final detail = snapshot.data!;
              if (detail.movies.isEmpty) {
                return SliverFillRemaining(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      EmptyActionState(
                        message: 'Playlist này chưa có phim',
                        icon: Icons.playlist_play_rounded,
                      ),
                      Wrap(
                        spacing: 10,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => toggleVisibility(detail),
                            icon: Icon(
                              detail.playlist.isPublic
                                  ? Icons.public_rounded
                                  : Icons.lock_rounded,
                            ),
                            label: Text(
                              detail.playlist.isPublic
                                  ? 'Công khai'
                                  : 'Riêng tư',
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => deletePlaylist(detail),
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('Xoá playlist'),
                            style: _deletePlaylistStyle,
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }
              return SliverList(
                delegate: SliverChildListDelegate([
                  Padding(
                    padding: pagePadding(context).copyWith(top: 20, bottom: 12),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => toggleVisibility(detail),
                          icon: Icon(
                            detail.playlist.isPublic
                                ? Icons.public_rounded
                                : Icons.lock_rounded,
                          ),
                          label: Text(
                            detail.playlist.isPublic ? 'Công khai' : 'Riêng tư',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => deletePlaylist(detail),
                          icon: const Icon(Icons.delete_outline_rounded),
                          label: const Text('Xoá playlist'),
                          style: _deletePlaylistStyle,
                        ),
                      ],
                    ),
                  ),
                  GridView.builder(
                    padding: pagePadding(context).copyWith(bottom: 36),
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: detail.movies.length,
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: width + 28,
                      mainAxisSpacing: 18,
                      crossAxisSpacing: 14,
                      childAspectRatio: width / moviePosterCardHeight(width),
                    ),
                    itemBuilder: (context, index) {
                      final movie = detail.movies[index];
                      return MoviePosterCard(
                        movie: movie,
                        width: width,
                        onTap: () => openDetail(context, widget.repo, movie),
                        onRemove: () => removeMovie(detail, movie),
                        removeTooltip: 'Xoá khỏi playlist',
                      );
                    },
                  ),
                ]),
              );
            },
          ),
        ],
      ),
    );
  }
}

class AddToPlaylistSheet extends StatefulWidget {
  const AddToPlaylistSheet({
    super.key,
    required this.repo,
    required this.movie,
  });
  final MovieRepository repo;
  final Movie movie;

  @override
  State<AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends State<AddToPlaylistSheet> {
  late Future<List<CinePlaylist>> future;

  @override
  void initState() {
    super.initState();
    future = widget.repo.playlists();
  }

  void reload() {
    setState(() => future = widget.repo.playlists());
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: pagePadding(context).copyWith(top: 18, bottom: 18),
        child: FutureBuilder<List<CinePlaylist>>(
          future: future,
          builder: (context, snapshot) {
            final playlists = snapshot.data ?? const <CinePlaylist>[];
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionTitle('Thêm vào playlist'),
                const SizedBox(height: 12),
                if (snapshot.hasError)
                  InlineErrorState(
                    message: 'Không tải được playlist',
                    onRetry: reload,
                  )
                else if (!snapshot.hasData)
                  const LinearProgressIndicator(color: CvColors.accent)
                else if (playlists.isEmpty)
                  const EmptyActionState(
                    message:
                        'Chưa có playlist. Tạo playlist trong mục Của tôi.',
                    icon: Icons.playlist_add_rounded,
                  )
                else
                  for (final playlist in playlists)
                    ListTile(
                      leading: const Icon(Icons.playlist_add_rounded),
                      title: Text(playlist.name),
                      subtitle: Text('${playlist.movieCount} phim'),
                      onTap: () async {
                        try {
                          await widget.repo.addToPlaylist(
                            playlist.id,
                            widget.movie.id,
                          );
                          if (context.mounted) {
                            Navigator.pop(context);
                            showSnack(context, 'Đã thêm vào ${playlist.name}');
                          }
                        } catch (_) {
                          if (context.mounted) {
                            showSnack(context, 'Không thêm được phim');
                          }
                        }
                      },
                    ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class UpdateInfoScreen extends StatefulWidget {
  const UpdateInfoScreen({super.key});

  @override
  State<UpdateInfoScreen> createState() => _UpdateInfoScreenState();
}

class _UpdateInfoScreenState extends State<UpdateInfoScreen> {
  static const _installerChannel = MethodChannel('live.cineviet/installer');
  late final Future<Map<String, dynamic>> future = loadUpdateInfo();
  bool downloading = false;
  double progress = 0;
  int receivedBytes = 0;
  int totalBytes = 0;
  double downloadSpeedBytes = 0;
  String? statusMessage;

  static Future<Map<String, dynamic>> loadUpdateInfo() async {
    final info = await PackageInfo.fromPlatform();
    final platform = isTvBuild
        ? 'android-tv'
        : (!kIsWeb && Platform.isWindows)
        ? 'windows'
        : (!kIsWeb && Platform.isIOS)
        ? 'ios'
        : 'android';
    final res = await Api.instance.dio.get(
      '/app/version',
      queryParameters: {
        'platform': platform,
        'build': info.buildNumber,
        'version': info.version,
      },
    );
    return {'local': info, 'remote': res.data, 'platform': platform};
  }

  static String _absoluteDownloadUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme) return trimmed;
    return Uri.parse(siteBase).resolve(trimmed).toString();
  }

  Future<void> _downloadAndInstall(String url) async {
    if (downloading) return;
    final downloadUrl = _absoluteDownloadUrl(url);
    setState(() {
      downloading = true;
      progress = 0;
      receivedBytes = 0;
      totalBytes = 0;
      downloadSpeedBytes = 0;
      statusMessage = 'Đang tải bản mới...';
    });
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/cineviet-update.apk');
        if (await file.exists()) await file.delete();
        final startedAt = Stopwatch()..start();
        await Dio().download(
          downloadUrl,
          file.path,
          onReceiveProgress: (received, total) {
            if (!mounted) return;
            final elapsed = math.max(startedAt.elapsedMilliseconds, 1);
            setState(() {
              receivedBytes = received;
              totalBytes = total > 0 ? total : totalBytes;
              progress = total > 0 ? received / total : 0;
              downloadSpeedBytes = received * 1000 / elapsed;
              statusMessage = total > 0
                  ? 'Đang tải ${_formatPercent(progress)}'
                  : 'Đang tải ${_formatBytes(received)}';
            });
          },
        );
        setState(() {
          progress = 1;
          receivedBytes = math.max(receivedBytes, file.lengthSync());
          totalBytes = math.max(totalBytes, receivedBytes);
          statusMessage = 'Đang kiểm tra file cập nhật...';
        });
        final apkInfo = await _installerChannel
            .invokeMapMethod<String, dynamic>('inspectApk', {
              'path': file.path,
            });
        if (apkInfo?['canUpdateCurrentApp'] != true) {
          final samePackage = apkInfo?['samePackage'] == true;
          throw PlatformException(
            code: samePackage ? 'signature_mismatch' : 'package_mismatch',
            message: samePackage
                ? 'APK tải về khác chữ ký với bản đang cài. Hãy build lại bằng đúng release keystore.'
                : 'APK tải về không đúng gói ứng dụng CineViet đang cài.',
          );
        }
        setState(() => statusMessage = 'Đã tải xong, đang mở trình cài đặt...');
        await _installerChannel.invokeMethod('installApk', {'path': file.path});
      } else if (!kIsWeb &&
          Platform.isWindows &&
          url.toLowerCase().endsWith('.exe')) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}\\cineviet-update-setup.exe');
        if (await file.exists()) await file.delete();
        final startedAt = Stopwatch()..start();
        await Dio().download(
          downloadUrl,
          file.path,
          onReceiveProgress: (received, total) {
            if (!mounted) return;
            final elapsed = math.max(startedAt.elapsedMilliseconds, 1);
            setState(() {
              receivedBytes = received;
              totalBytes = total > 0 ? total : totalBytes;
              progress = total > 0 ? received / total : 0;
              downloadSpeedBytes = received * 1000 / elapsed;
              statusMessage = total > 0
                  ? 'Đang tải ${_formatPercent(progress)}'
                  : 'Đang tải ${_formatBytes(received)}';
            });
          },
        );
        setState(() {
          progress = 1;
          receivedBytes = math.max(receivedBytes, file.lengthSync());
          totalBytes = math.max(totalBytes, receivedBytes);
        });
        setState(() => statusMessage = 'Đã tải xong, đang mở trình cài đặt...');
        await Process.start(
          file.path,
          const [],
          mode: ProcessStartMode.detached,
        );
      } else {
        await launchUrl(
          Uri.parse(downloadUrl),
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (e) {
      if (!mounted) return;
      final message = _installErrorMessage(e);
      setState(() => statusMessage = message);
      if (!_isBlockingInstallError(e)) {
        await launchUrl(
          Uri.parse(downloadUrl),
          mode: LaunchMode.externalApplication,
        );
      }
    } finally {
      if (mounted) setState(() => downloading = false);
    }
  }

  static bool _isBlockingInstallError(Object error) {
    return error is PlatformException &&
        (error.code == 'signature_mismatch' ||
            error.code == 'package_mismatch' ||
            error.code == 'invalid_apk' ||
            error.code == 'empty_apk');
  }

  static String _installErrorMessage(Object error) {
    if (error is PlatformException) {
      switch (error.code) {
        case 'signature_mismatch':
          return 'Không thể cài đè: APK khác chữ ký với bản đang cài. Cần build lại bằng đúng release keystore.';
        case 'package_mismatch':
          return 'Không thể cài đè: APK tải về không đúng gói ứng dụng CineViet đang cài.';
        case 'invalid_apk':
          return 'File cập nhật không phải APK hợp lệ. Vui lòng tải lại sau.';
        case 'empty_apk':
          return 'File cập nhật tải về bị rỗng. Vui lòng tải lại sau.';
      }
      final message = cleanText(error.message);
      if (message.isNotEmpty) return message;
    }
    return 'Không cài được tự động. Đang mở link tải...';
  }

  static String _formatPercent(double value) {
    return '${(value.clamp(0, 1) * 100).toStringAsFixed(0)}%';
  }

  static String _formatBytes(num bytes) {
    final value = bytes.toDouble();
    if (value >= 1024 * 1024 * 1024) {
      return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (value >= 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (value >= 1024) {
      return '${(value / 1024).toStringAsFixed(1)} KB';
    }
    return '${value.toStringAsFixed(0)} B';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cập nhật')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ListView(
              padding: pagePadding(context).copyWith(top: 24, bottom: 36),
              children: const [
                Panel(
                  child: Row(
                    children: [
                      Icon(Icons.wifi_off_rounded, color: CvColors.amber),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Chưa kiểm tra được cập nhật. Vui lòng thử lại sau.',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }
          if (!snapshot.hasData) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: CvColors.accent),
                  SizedBox(height: 14),
                  Text(
                    'Đang kiểm tra cập nhật',
                    style: TextStyle(color: CvColors.muted),
                  ),
                ],
              ),
            );
          }
          final local = snapshot.data!['local'] as PackageInfo;
          final remote = snapshot.data!['remote'];
          final latestVersion = cleanText(
            remote['latestVersion'] ??
                remote['version'] ??
                remote['versionName'],
          );
          final latestBuild = cleanText(
            remote['latestBuild'] ?? remote['build'] ?? remote['versionCode'],
          );
          final url = cleanText(remote['url'] ?? remote['downloadUrl']);
          final notes = cleanText(remote['notes'] ?? remote['releaseNotes']);
          final updateAvailable = remote['updateAvailable'] == true;
          final latestLabel = [
            if (latestVersion.isNotEmpty) latestVersion,
            if (latestBuild.isNotEmpty) '+$latestBuild',
          ].join();
          return ListView(
            padding: pagePadding(context).copyWith(top: 24),
            children: [
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Phiên bản hiện tại',
                      style: TextStyle(
                        color: CvColors.muted,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${local.version}+${local.buildNumber}',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      latestLabel.isEmpty
                          ? 'Máy chủ chưa trả về thông tin bản mới.'
                          : updateAvailable
                          ? 'Có bản mới: $latestLabel'
                          : 'Bạn đang dùng bản mới nhất: $latestLabel',
                      style: const TextStyle(color: CvColors.muted),
                    ),
                    if (notes.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(
                        notes,
                        style: const TextStyle(
                          color: CvColors.muted,
                          height: 1.45,
                        ),
                      ),
                    ],
                    if (url.isNotEmpty && updateAvailable) ...[
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: downloading
                            ? null
                            : () => _downloadAndInstall(url),
                        icon: downloading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.download_rounded),
                        label: Text(
                          downloading ? 'Đang tải...' : 'Cập nhật trong app',
                        ),
                      ),
                      if (statusMessage != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          statusMessage!,
                          style: TextStyle(
                            color: _isBlockingStatus(statusMessage!)
                                ? CvColors.danger
                                : CvColors.muted,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      if (downloading || receivedBytes > 0) ...[
                        const SizedBox(height: 12),
                        _UpdateProgressCard(
                          progress: progress,
                          receivedBytes: receivedBytes,
                          totalBytes: totalBytes,
                          speedBytes: downloadSpeedBytes,
                          active: downloading,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static bool _isBlockingStatus(String value) {
    return value.startsWith('Không thể cài đè') ||
        value.startsWith('File cập nhật');
  }
}

class _UpdateProgressCard extends StatelessWidget {
  const _UpdateProgressCard({
    required this.progress,
    required this.receivedBytes,
    required this.totalBytes,
    required this.speedBytes,
    required this.active,
  });

  final double progress;
  final int receivedBytes;
  final int totalBytes;
  final double speedBytes;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final hasTotal = totalBytes > 0;
    final safeProgress = progress.clamp(0, 1).toDouble();
    final percent = hasTotal
        ? _UpdateInfoScreenState._formatPercent(safeProgress)
        : 'Đang tải';
    final downloaded = _UpdateInfoScreenState._formatBytes(receivedBytes);
    final total = hasTotal
        ? _UpdateInfoScreenState._formatBytes(totalBytes)
        : '';
    final speed = speedBytes > 0
        ? '${_UpdateInfoScreenState._formatBytes(speedBytes)}/s'
        : '';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CvColors.ink,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CvColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                active
                    ? Icons.downloading_rounded
                    : Icons.download_done_rounded,
                color: CvColors.accent,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  percent,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                hasTotal ? '$downloaded / $total' : downloaded,
                style: const TextStyle(
                  color: CvColors.muted,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            minHeight: 8,
            value: hasTotal ? safeProgress : null,
            color: CvColors.accent,
            backgroundColor: CvColors.panel2,
            borderRadius: BorderRadius.circular(999),
          ),
          if (speed.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Tốc độ $speed',
              style: const TextStyle(
                color: CvColors.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class TvPairingScreen extends StatefulWidget {
  const TvPairingScreen({super.key, required this.repo});
  final MovieRepository repo;

  @override
  State<TvPairingScreen> createState() => _TvPairingScreenState();
}

class _TvPairingScreenState extends State<TvPairingScreen> {
  final approveCode = TextEditingController();
  TvLoginSession? session;
  Timer? pollTimer;
  bool busy = false;

  @override
  void dispose() {
    approveCode.dispose();
    pollTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (isTvBuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) => createTvSession());
    }
  }

  Future<void> createTvSession() async {
    setState(() => busy = true);
    try {
      final next = await widget.repo.createTvSession();
      pollTimer?.cancel();
      pollTimer = Timer.periodic(Duration(seconds: next.interval), (_) async {
        try {
          if (next.expiresAt != null &&
              DateTime.now().isAfter(next.expiresAt!)) {
            pollTimer?.cancel();
            return;
          }
          final ok = await widget.repo.pollTvSession(next);
          if (ok) {
            pollTimer?.cancel();
            if (mounted) {
              showSnack(context, 'TV đã đăng nhập thành công');
              Navigator.of(context).maybePop();
            }
          }
        } catch (_) {}
      });
      setState(() => session = next);
    } catch (_) {
      if (mounted) showSnack(context, 'Không tạo được mã đăng nhập TV');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> approve() async {
    if (!await requireLogin(context, 'Duyệt mã TV')) return;
    final code = approveCode.text.trim();
    if (code.isEmpty) return;
    setState(() => busy = true);
    try {
      await widget.repo.approveTvCode(code);
      if (mounted) {
        showSnack(context, 'Đã duyệt mã TV');
      }
    } catch (_) {
      if (mounted) {
        showSnack(context, 'Không duyệt được mã TV. Cần đăng nhập trước.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isTvBuild) {
      return MobileTvPairingScreen(repo: widget.repo);
    }
    final timeLeft = session?.expiresAt == null
        ? session?.expiresIn ?? 0
        : session!.expiresAt!
              .difference(DateTime.now())
              .inSeconds
              .clamp(0, 9999);
    final minutes = timeLeft ~/ 60;
    final seconds = timeLeft % 60;
    return Scaffold(
      appBar: AppBar(title: const Text('Đăng nhập TV')),
      body: ListView(
        padding: pagePadding(context).copyWith(top: 22, bottom: 40),
        children: [
          if (!isTvBuild) ...[
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Duyệt mã trên TV',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: approveCode,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Mã TV 6 số'),
                    onSubmitted: (_) => approve(),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: busy ? null : approve,
                    icon: const Icon(Icons.verified_rounded),
                    label: const Text('Xác nhận TV'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text(
                  'Đăng nhập trên TV',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Quét QR hoặc nhập mã 6 số trên điện thoại đã đăng nhập.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: CvColors.muted),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: busy ? null : createTvSession,
                  icon: const Icon(Icons.qr_code_2_rounded),
                  label: Text(session == null ? 'Tạo mã TV' : 'Tạo mã mới'),
                ),
                if (session != null) ...[
                  const SizedBox(height: 22),
                  if (session!.qrData.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: QrImageView(
                        data: session!.qrData,
                        version: QrVersions.auto,
                        size: isTvBuild ? 280 : 220,
                      ),
                    ),
                  const SizedBox(height: 20),
                  SelectableText(
                    session!.userCode,
                    style: TextStyle(
                      fontSize: isTvBuild ? 64 : 42,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 8,
                      color: CvColors.accent,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (session!.verificationUrl.isNotEmpty)
                    SelectableText(session!.verificationUrl),
                  const SizedBox(height: 8),
                  Text(
                    'Mã hết hạn sau: ${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
                    style: const TextStyle(color: CvColors.muted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MobileTvPairingScreen extends StatefulWidget {
  const MobileTvPairingScreen({super.key, required this.repo});
  final MovieRepository repo;

  @override
  State<MobileTvPairingScreen> createState() => _MobileTvPairingScreenState();
}

class _MobileTvPairingScreenState extends State<MobileTvPairingScreen> {
  final codeController = TextEditingController();
  MobileScannerController? scannerController;
  bool scanning = false;
  bool busy = false;
  String? error;

  bool get canScanQr => supportsTvQrScan;

  @override
  void initState() {
    super.initState();
    if (canScanQr) {
      scannerController = MobileScannerController();
      scanning = true;
    }
  }

  @override
  void dispose() {
    codeController.dispose();
    scannerController?.dispose();
    super.dispose();
  }

  String _codeFromQr(String raw) {
    final value = raw.trim();
    if (RegExp(r'^\d{6}$').hasMatch(value)) return value;
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map && decoded['type'] == 'cineviet_tv_pairing') {
        final code = cleanText(decoded['code']);
        if (RegExp(r'^\d{6}$').hasMatch(code)) return code;
      }
    } catch (_) {}
    return '';
  }

  void _onQrDetect(BarcodeCapture capture) {
    if (busy) return;
    final raw = capture.barcodes
        .map((barcode) => barcode.rawValue ?? '')
        .firstWhere((value) => value.trim().isNotEmpty, orElse: () => '');
    if (raw.isEmpty) return;
    final code = _codeFromQr(raw);
    if (code.isEmpty) {
      setState(() => error = 'QR này không phải mã đăng nhập TV CineViet.');
      return;
    }
    scannerController?.stop();
    unawaited(_approve(code));
  }

  Future<void> _approve(String code) async {
    if (busy) return;
    if (!await requireLogin(context, 'Xác nhận TV')) {
      if (scanning) scannerController?.start();
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.repo.approveTvCode(code);
      if (!mounted) return;
      showSnack(context, 'Đã xác nhận. TV sẽ tự đăng nhập sau vài giây.');
      Navigator.of(context).maybePop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        error = 'Không xác nhận được mã TV. Mã có thể sai hoặc đã hết hạn.';
      });
      if (scanning) scannerController?.start();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _submitManualCode() {
    final code = codeController.text.replaceAll(RegExp(r'\D'), '').trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => error = 'Nhập đúng mã TV 6 số.');
      return;
    }
    unawaited(_approve(code));
  }

  void _toggleMode() {
    if (!canScanQr) return;
    setState(() {
      scanning = !scanning;
      error = null;
    });
    if (scanning) {
      scannerController?.start();
    } else {
      scannerController?.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final showScanner = scanning && scannerController != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Đăng nhập TV'),
        actions: [
          if (canScanQr)
            IconButton(
              tooltip: showScanner ? 'Nhập mã' : 'Quét QR',
              onPressed: busy ? null : _toggleMode,
              icon: Icon(
                showScanner
                    ? Icons.keyboard_rounded
                    : Icons.qr_code_scanner_rounded,
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: showScanner ? _buildScanner() : _buildManualInput(),
      ),
    );
  }

  Widget _buildScanner() {
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              MobileScanner(
                controller: scannerController,
                onDetect: _onQrDetect,
              ),
              Center(
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: CvColors.accent, width: 3),
                  ),
                ),
              ),
              if (busy)
                Container(
                  color: Colors.black54,
                  child: const Center(
                    child: CircularProgressIndicator(color: CvColors.accent),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: pagePadding(context).copyWith(top: 16, bottom: 20),
          child: Panel(
            child: Column(
              children: [
                const Row(
                  children: [
                    Icon(Icons.qr_code_scanner_rounded, color: CvColors.accent),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Quét QR trên màn hình Android TV',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: const TextStyle(color: CvColors.danger)),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildManualInput() {
    return ListView(
      padding: pagePadding(context).copyWith(top: 36, bottom: 36),
      children: [
        Panel(
          child: Column(
            children: [
              const Icon(Icons.tv_rounded, size: 70, color: CvColors.accent),
              const SizedBox(height: 16),
              const Text(
                'Nhập mã TV',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              const Text(
                'Nhập mã 6 số đang hiển thị trên Android TV để đăng nhập TV bằng tài khoản này.',
                textAlign: TextAlign.center,
                style: TextStyle(color: CvColors.muted),
              ),
              const SizedBox(height: 22),
              TextField(
                controller: codeController,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                textAlign: TextAlign.center,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => _submitManualCode(),
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 8,
                ),
                decoration: const InputDecoration(
                  hintText: '000000',
                  counterText: '',
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(error!, style: const TextStyle(color: CvColors.danger)),
              ],
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: busy ? null : _submitManualCode,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_rounded),
                label: const Text('Xác nhận TV'),
              ),
              if (canScanQr) ...[
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: busy ? null : _toggleMode,
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: const Text('Quét QR thay vì nhập mã'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class WatchTogetherScreen extends StatefulWidget {
  const WatchTogetherScreen({
    super.key,
    required this.repo,
    this.prefillMovie,
    this.prefillServer,
    this.prefillEpisode,
    this.prefillServerIndex = 0,
  });
  final MovieRepository repo;
  final Movie? prefillMovie;
  final EpisodeServer? prefillServer;
  final EpisodeItem? prefillEpisode;
  final int prefillServerIndex;

  @override
  State<WatchTogetherScreen> createState() => _WatchTogetherScreenState();
}

class _WatchTogetherScreenState extends State<WatchTogetherScreen> {
  late Future<List<WatchRoom>> future;
  late Future<bool> loggedIn;
  final code = TextEditingController();
  EpisodeServer? selectedServer;
  EpisodeItem? selectedEpisode;
  bool createPublic = true;
  int maxMembers = 8;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    final servers = widget.prefillMovie?.episodes ?? const <EpisodeServer>[];
    selectedServer =
        widget.prefillServer ?? (servers.isNotEmpty ? servers.first : null);
    final episodes = selectedServer?.items ?? const <EpisodeItem>[];
    selectedEpisode =
        widget.prefillEpisode ?? (episodes.isNotEmpty ? episodes.first : null);
    loggedIn = isLoggedIn();
    future = widget.repo.publicRooms();
  }

  @override
  void didUpdateWidget(covariant WatchTogetherScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // IndexedStack keeps this State alive while the user logs in on the
    // Profile tab. Refresh the cached auth check whenever AppShell rebuilds
    // while switching back to Xem chung.
    loggedIn = isLoggedIn();
  }

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  Future<void> openRoom(String roomCode) async {
    if (!await requireLogin(context, 'Xem chung')) return;
    final value = roomCode.trim().toUpperCase();
    if (value.isEmpty) return;
    try {
      final room = await widget.repo.joinWatchRoom(value);
      if (!mounted) return;
      final videoUrl = room?.videoUrl.trim() ?? '';
      if (videoUrl.isEmpty) {
        showSnack(context, 'Phòng $value chưa có video để phát');
        return;
      }
      final title = room?.movieTitle.trim().isNotEmpty == true
          ? room!.movieTitle.trim()
          : 'Phòng xem chung $value';
      final movie = Movie(id: 0, title: title, slug: 'watch-together-$value');
      final episode = EpisodeItem(name: 'Đang xem', linkM3u8: videoUrl);
      final server = EpisodeServer(name: 'Xem chung', items: [episode]);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            repo: widget.repo,
            movie: movie,
            server: server,
            episode: episode,
            serverIndex: 0,
            watchTogetherState: room,
            watchTogetherCode: value,
          ),
        ),
      );
      showSnack(context, 'Đã vào phòng Xem chung $value');
    } catch (e) {
      if (mounted) {
        showSnack(context, e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  Future<void> createRoomFromMovie() async {
    final movie = widget.prefillMovie;
    final server = selectedServer;
    final episode = selectedEpisode;
    if (movie == null || server == null || episode == null) {
      showSnack(context, 'Chưa chọn phim/tập để tạo phòng');
      return;
    }
    if (!await requireLogin(context, 'Xem chung')) return;
    setState(() => busy = true);
    try {
      final result = await widget.repo.createWatchRoom(
        movie,
        episode.playUrl,
        hostName: 'CineViet',
        maxMembers: maxMembers,
        isPublic: createPublic,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            repo: widget.repo,
            movie: movie,
            server: server,
            episode: episode,
            serverIndex: widget.prefillMovie!.episodes
                .indexOf(server)
                .clamp(0, widget.prefillMovie!.episodes.length - 1),
            watchTogetherState: result.room,
            watchTogetherCode: result.code,
          ),
        ),
      );
      showSnack(context, 'Đã tạo phòng Xem chung ${result.code}');
    } catch (e) {
      if (mounted) {
        showSnack(context, e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: CvColors.black,
      child: FutureBuilder<bool>(
        future: loggedIn,
        builder: (context, authSnapshot) {
          if (!authSnapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: CvColors.accent),
            );
          }
          if (authSnapshot.data != true) {
            return ListView(
              padding: pagePadding(context).copyWith(top: 36, bottom: 40),
              children: const [
                PageHeading('Xem chung'),
                SizedBox(height: 18),
                LoginRequiredPanel(feature: 'Xem chung'),
              ],
            );
          }
          return RefreshIndicator(
            color: CvColors.accent,
            onRefresh: () async =>
                setState(() => future = widget.repo.publicRooms()),
            child: ListView(
              padding: pagePadding(context).copyWith(top: 36, bottom: 40),
              children: [
                Row(
                  children: [
                    if (widget.prefillMovie != null) ...[
                      IconButton.filledTonal(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      const SizedBox(width: 10),
                    ],
                    const Expanded(child: PageHeading('Xem chung')),
                    IconButton.filledTonal(
                      onPressed: () =>
                          setState(() => future = widget.repo.publicRooms()),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                if (widget.prefillMovie != null) ...[
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SectionTitle('Tạo phòng từ phim này'),
                        const SizedBox(height: 8),
                        Text(
                          widget.prefillMovie!.title,
                          style: const TextStyle(
                            color: CvColors.muted,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 14),
                        DropdownButtonFormField<EpisodeServer>(
                          initialValue: selectedServer,
                          decoration: const InputDecoration(
                            labelText: 'Server phim',
                            prefixIcon: Icon(Icons.dns_rounded),
                          ),
                          items: widget.prefillMovie!.episodes
                              .map(
                                (server) => DropdownMenuItem(
                                  value: server,
                                  child: Text(server.displayName),
                                ),
                              )
                              .toList(),
                          onChanged: busy
                              ? null
                              : (server) {
                                  if (server == null) return;
                                  setState(() {
                                    selectedServer = server;
                                    selectedEpisode = server.items.isNotEmpty
                                        ? server.items.first
                                        : null;
                                  });
                                },
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<EpisodeItem>(
                          initialValue: selectedEpisode,
                          decoration: const InputDecoration(
                            labelText: 'Chọn tập phim',
                            prefixIcon: Icon(Icons.video_library_rounded),
                          ),
                          items:
                              (selectedServer?.items ?? const <EpisodeItem>[])
                                  .map(
                                    (episode) => DropdownMenuItem(
                                      value: episode,
                                      child: Text(episode.displayName),
                                    ),
                                  )
                                  .toList(),
                          onChanged: busy
                              ? null
                              : (episode) =>
                                    setState(() => selectedEpisode = episode),
                        ),
                        const SizedBox(height: 14),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                              value: true,
                              icon: Icon(Icons.public_rounded),
                              label: Text('Công khai'),
                            ),
                            ButtonSegment(
                              value: false,
                              icon: Icon(Icons.lock_rounded),
                              label: Text('Riêng tư'),
                            ),
                          ],
                          selected: {createPublic},
                          onSelectionChanged: busy
                              ? null
                              : (values) =>
                                    setState(() => createPublic = values.first),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            const Text(
                              'Số người:',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                            for (final value in const [2, 4, 6, 8])
                              ChoiceChip(
                                label: Text('$value'),
                                selected: maxMembers == value,
                                showCheckmark: false,
                                onSelected: busy
                                    ? null
                                    : (_) => setState(() => maxMembers = value),
                              ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: busy ? null : createRoomFromMovie,
                            icon: const Icon(Icons.groups_rounded),
                            label: Text(
                              busy ? 'Đang tạo...' : 'Tạo phòng xem chung',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                Panel(
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: code,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                            labelText: 'Nhập mã phòng',
                          ),
                          onSubmitted: openRoom,
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filled(
                        onPressed: () => openRoom(code.text),
                        icon: const Icon(Icons.login_rounded),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const SectionTitle('Phòng public'),
                const SizedBox(height: 12),
                FutureBuilder<List<WatchRoom>>(
                  future: future,
                  builder: (context, snapshot) {
                    final rooms = snapshot.data ?? const <WatchRoom>[];
                    if (!snapshot.hasData) {
                      return const LinearProgressIndicator(
                        color: CvColors.accent,
                      );
                    }
                    if (rooms.isEmpty) {
                      return const EmptyState('Chưa có phòng public');
                    }
                    return Column(
                      children: [
                        for (final room in rooms)
                          ProfileTile(
                            icon: Icons.groups_rounded,
                            title: room.movieTitle,
                            subtitle:
                                '${room.code} • ${room.memberCount}/${room.maxMembers} người',
                            onTap: () => openRoom(room.code),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class LoginRequiredPanel extends StatelessWidget {
  const LoginRequiredPanel({super.key, required this.feature});
  final String feature;

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        children: [
          const Icon(Icons.lock_rounded, size: 48, color: CvColors.muted),
          const SizedBox(height: 12),
          Text(
            '$feature cần đăng nhập tài khoản CineViet',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          const SizedBox(height: 8),
          const Text(
            'Vào tab Của tôi để đăng nhập rồi quay lại dùng tính năng này.',
            textAlign: TextAlign.center,
            style: TextStyle(color: CvColors.muted),
          ),
        ],
      ),
    );
  }
}

class CollapsibleMovieDescription extends StatelessWidget {
  const CollapsibleMovieDescription({
    super.key,
    required this.description,
    required this.expanded,
    required this.onToggle,
    required this.collapsedLines,
  });

  final String description;
  final bool expanded;
  final VoidCallback onToggle;
  final int collapsedLines;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final textStyle = DefaultTextStyle.of(context).style.merge(
      const TextStyle(fontSize: 16, height: 1.48, color: CvColors.text),
    );
    final direction = Directionality.of(context);
    final width =
        MediaQuery.sizeOf(context).width - pagePadding(context).horizontal;
    final painter = TextPainter(
      text: TextSpan(text: description, style: textStyle),
      maxLines: collapsedLines,
      textDirection: direction,
      textScaler: textScaler,
    )..layout(maxWidth: width.clamp(240.0, 920.0));
    final canCollapse = painter.didExceedMaxLines;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Text(
            description,
            maxLines: expanded ? null : collapsedLines,
            overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: textStyle,
          ),
        ),
        if (canCollapse) ...[
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: onToggle,
            icon: Icon(
              expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 20,
            ),
            label: Text(expanded ? 'Ẩn bớt' : 'Hiện nội dung'),
            style: TextButton.styleFrom(
              foregroundColor: CvColors.accent,
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class MovieCollectionSelector extends StatelessWidget {
  const MovieCollectionSelector({
    super.key,
    required this.collection,
    required this.currentMovieId,
    required this.onSelected,
  });
  final MovieCollection collection;
  final int currentMovieId;
  final ValueChanged<MovieCollectionItem> onSelected;

  @override
  Widget build(BuildContext context) {
    final currentIndex = collection.items.indexWhere(
      (part) => part.movieId == currentMovieId || part.isCurrent,
    );
    final safeIndex = currentIndex >= 0 ? currentIndex : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Các phần',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 10),
        FocusButton(
          autofocus: true,
          borderRadius: 10,
          onPressed: () async {
            final selected = await showDialog<MovieCollectionItem>(
              context: context,
              builder: (dialogContext) => Dialog(
                backgroundColor: CvColors.panel,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: CvColors.border),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 620,
                    maxHeight: 520,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(8, 4, 8, 12),
                          child: Text(
                            'Chọn phần phim',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: collection.items.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 6),
                            itemBuilder: (_, index) {
                              final part = collection.items[index];
                              final active = index == safeIndex;
                              return FocusButton(
                                autofocus: active,
                                selected: active,
                                borderRadius: 10,
                                onPressed: () =>
                                    Navigator.pop(dialogContext, part),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 13,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${part.label} — ${part.title}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontWeight: active
                                                ? FontWeight.w900
                                                : FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      if (active)
                                        const Icon(
                                          Icons.check_rounded,
                                          color: CvColors.accent,
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            if (selected != null && selected.movieId != currentMovieId) {
              onSelected(selected);
            }
          },
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: CvColors.panel,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: CvColors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${collection.items[safeIndex].label} — ${collection.items[safeIndex].title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 10),
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: CvColors.muted,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class MovieDetailScreen extends StatefulWidget {
  const MovieDetailScreen({
    super.key,
    required this.repo,
    required this.initial,
    this.autoplay = false,
    this.heroTag,
    this.resumeOnOpen,
  });
  final MovieRepository repo;
  final Movie initial;
  final bool autoplay;
  final String? heroTag;
  final WatchItem? resumeOnOpen;

  @override
  State<MovieDetailScreen> createState() => _MovieDetailScreenState();
}

class _MovieDetailScreenState extends State<MovieDetailScreen> {
  late Future<Movie> future;
  int serverIndex = 0;
  int? favoriteMovieId;
  bool isFavorite = false;
  bool favoriteBusy = false;
  bool descriptionExpanded = false;
  int detailSectionIndex = 0;
  WatchItem? resumeItem;

  @override
  void initState() {
    super.initState();
    future = widget.repo.detail(widget.initial.routeKey);
    favoriteMovieId = widget.initial.id;
    refreshFavoriteState(widget.initial);
    refreshResumeState(widget.initial);
    future.then(refreshFavoriteState).catchError((_) {});
    future.then(refreshResumeState).catchError((_) {});
    if (widget.resumeOnOpen != null) {
      future
          .then((_) {
            if (!mounted) return;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) unawaited(openResume(widget.resumeOnOpen!));
            });
          })
          .catchError((_) {});
    }
    if (widget.autoplay) {
      future.then((movie) {
        if (!mounted) return;
        final server = movie.episodes.isNotEmpty ? movie.episodes.first : null;
        final episode = server?.items.isNotEmpty == true
            ? server!.items.first
            : null;
        if (server != null && episode != null) {
          openPlayer(context, widget.repo, movie, server, episode, 0);
        }
      });
    }
  }

  Future<void> selectCollectionPart(MovieCollectionItem part) async {
    final current = await future.catchError((_) => widget.initial);
    if (part.movieId == current.id || part.isCurrent) return;
    setState(() {
      future = widget.repo.detail(part.slug);
      serverIndex = 0;
      detailSectionIndex = 0;
      descriptionExpanded = false;
      resumeItem = null;
      favoriteMovieId = part.movieId;
      isFavorite = false;
    });
    future.then(refreshFavoriteState).catchError((_) {});
    future.then(refreshResumeState).catchError((_) {});
  }

  Future<void> refreshFavoriteState(Movie movie, {bool force = false}) async {
    if (movie.id <= 0) return;
    favoriteMovieId = movie.id;
    final expectedMovieId = movie.id;
    final favorited = await widget.repo.isFavorite(movie, force: force);
    if (!mounted || favoriteMovieId != expectedMovieId) return;
    setState(() {
      isFavorite = favorited;
      favoriteBusy = false;
    });
  }

  Future<void> refreshResumeState(Movie movie) async {
    final history = await mergedWatchHistory(widget.repo);
    final item = findWatchItemForMovie(history, movie);
    if (!mounted) return;
    setState(() => resumeItem = item);
  }

  Future<void> openResume(WatchItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ResumeLoaderScreen(repo: widget.repo, item: item),
      ),
    );
    if (!mounted) return;
    final movie = await future.catchError((_) => widget.initial);
    if (mounted) unawaited(refreshResumeState(movie));
  }

  Future<void> openEpisode(
    Movie movie,
    EpisodeServer server,
    EpisodeItem episode,
    int selectedServerIndex, {
    Duration? resume,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          repo: widget.repo,
          movie: movie,
          server: server,
          episode: episode,
          serverIndex: selectedServerIndex,
          resume: resume,
        ),
      ),
    );
    if (mounted) unawaited(refreshResumeState(movie));
  }

  Future<void> toggleFavorite(Movie movie) async {
    if (favoriteBusy) return;
    final next = !isFavorite;
    setState(() {
      favoriteMovieId = movie.id;
      isFavorite = next;
      favoriteBusy = true;
    });
    try {
      await widget.repo.toggleFavorite(movie, next);
      if (!mounted) return;
      showSnack(context, next ? 'Đã thêm yêu thích' : 'Đã bỏ yêu thích');
      setState(() => favoriteBusy = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        isFavorite = !next;
        favoriteBusy = false;
      });
      showSnack(
        context,
        next ? 'Không thêm được yêu thích' : 'Không bỏ được yêu thích',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<Movie>(
        future: future,
        builder: (context, snapshot) {
          final movie = snapshot.data ?? widget.initial;
          final servers = movie.episodes;
          final selectedServer = servers.isEmpty
              ? null
              : servers[serverIndex.clamp(0, servers.length - 1)];
          final detailWidth = MediaQuery.sizeOf(context).width;
          final usePortraitHero = detailWidth < 600 && !isTvBuild;
          final detailHeroUrl = usePortraitHero
              ? movie.posterUrl
              : movie.backdropUrl;
          final detailHeroFallbackUrl = usePortraitHero
              ? movie.posterFallbackUrl
              : movie.backdropFallbackUrl;
          final titleSize = isTvBuild
              ? 46.0
              : detailWidth < 390
              ? 30.0
              : detailWidth < 700
              ? 34.0
              : 42.0;
          final directors = cleanPeople(movie.directors);
          final cast = cleanPeople(
            movie.cast,
            exclude: directors.map((person) => person.name).toSet(),
          );
          final metaChips = [
            if (movie.releaseYear != null) '${movie.releaseYear}',
            if (movie.quality.isNotEmpty) movie.quality,
            if (movie.language.isNotEmpty) movie.language,
            if (movie.country.isNotEmpty) movie.country,
            if (movie.episodeCurrent.isNotEmpty) movie.episodeCurrent,
            if (movie.duration != null && movie.duration! > 0)
              '${movie.duration} phút',
          ];
          final detailTabs = <DetailSectionTab>[
            if (servers.isNotEmpty)
              DetailSectionTab(
                label: 'Tập phim',
                icon: Icons.playlist_play_rounded,
                builder: (_) => EpisodeSection(
                  movie: movie,
                  repo: widget.repo,
                  servers: servers,
                  serverIndex: serverIndex,
                  resumeItem: resumeItem,
                  onServerChanged: (value) =>
                      setState(() => serverIndex = value),
                  onEpisodeSelected: openEpisode,
                ),
              )
            else if (snapshot.hasData)
              const DetailSectionTab(
                label: 'Tập phim',
                icon: Icons.playlist_play_rounded,
                builder: _emptyEpisodeSection,
              ),
            if (directors.isNotEmpty || cast.isNotEmpty)
              DetailSectionTab(
                label: 'Diễn viên',
                icon: Icons.groups_rounded,
                builder: (_) => CrewSection(
                  repo: widget.repo,
                  directors: directors,
                  cast: cast.take(30).toList(),
                ),
              ),
            if (snapshot.hasData && !isTvBuild)
              DetailSectionTab(
                label: 'Bình luận',
                icon: Icons.forum_rounded,
                builder: (_) => SocialSection(repo: widget.repo, movie: movie),
              ),
            if (movie.related.isNotEmpty)
              DetailSectionTab(
                label: 'Đề xuất',
                icon: Icons.auto_awesome_rounded,
                builder: (_) => MovieRow(
                  title: 'Có thể bạn thích',
                  movies: movie.related,
                  repo: widget.repo,
                  padded: false,
                ),
              ),
          ];
          final activeDetailSectionIndex = detailTabs.isEmpty
              ? 0
              : detailSectionIndex.clamp(0, detailTabs.length - 1);
          return CustomScrollView(
            key: PageStorageKey('detail-scroll-${movie.id}'),
            slivers: [
              SliverAppBar(
                expandedHeight: math.min(
                  MediaQuery.sizeOf(context).height *
                      (usePortraitHero ? .72 : .58),
                  usePortraitHero ? 660 : 540,
                ),
                pinned: true,
                backgroundColor: Colors.black,
                flexibleSpace: FlexibleSpaceBar(
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      widget.heroTag != null
                          ? Hero(
                              tag: widget.heroTag!,
                              child: NetworkBackdrop(
                                url: detailHeroUrl,
                                fallbackUrl: detailHeroFallbackUrl,
                                fit: BoxFit.cover,
                              ),
                            )
                          : NetworkBackdrop(
                              url: detailHeroUrl,
                              fallbackUrl: detailHeroFallbackUrl,
                              fit: BoxFit.cover,
                            ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: .1),
                              CvColors.black,
                            ],
                            stops: const [.45, 1],
                          ),
                        ),
                      ),
                      Padding(
                        padding: pagePadding(context).copyWith(bottom: 32),
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 760),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  movie.title,
                                  style: TextStyle(
                                    fontSize: titleSize,
                                    height: 1.04,
                                    fontWeight: FontWeight.w900,
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (movie.titleEn.isNotEmpty &&
                                    movie.titleEn != movie.title) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    movie.titleEn,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: CvColors.muted,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                                if (metaChips.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: metaChips
                                        .map(
                                          (label) => InfoPill(
                                            label,
                                            prominent: label == movie.quality,
                                          ),
                                        )
                                        .toList(),
                                  ),
                                ],
                                const SizedBox(height: 16),
                                Wrap(
                                  spacing: useLeanbackControls ? 12 : 10,
                                  runSpacing: useLeanbackControls ? 12 : 10,
                                  children: [
                                    if (resumeItem != null)
                                      detailAction(
                                        icon: Icons.play_circle_fill_rounded,
                                        label:
                                            'Xem tiếp ${resumeItem!.progressPercent}%',
                                        primary: true,
                                        onPressed: () =>
                                            openResume(resumeItem!),
                                      ),
                                    detailAction(
                                      icon: Icons.play_arrow_rounded,
                                      label: resumeItem == null
                                          ? 'Phát'
                                          : 'Xem từ đầu',
                                      primary: resumeItem == null,
                                      onPressed:
                                          selectedServer == null ||
                                              selectedServer.items.isEmpty
                                          ? null
                                          : () => openEpisode(
                                              movie,
                                              selectedServer,
                                              selectedServer.items.first,
                                              serverIndex,
                                            ),
                                    ),
                                    if (supportsOfflineDownloads &&
                                        selectedServer != null &&
                                        selectedServer.supportsOfflineDownload)
                                      detailAction(
                                        icon: Icons.download_rounded,
                                        label: 'Tải xuống',
                                        onPressed: () async {
                                          if (!await requireOfflineVip(
                                            context,
                                          )) {
                                            return;
                                          }
                                          if (!context.mounted) return;
                                          await showModalBottomSheet<void>(
                                            context: context,
                                            backgroundColor: CvColors.ink,
                                            showDragHandle: true,
                                            isScrollControlled: true,
                                            builder: (_) =>
                                                OfflineEpisodePicker(
                                                  movie: movie,
                                                  servers: servers,
                                                  initialServerIndex:
                                                      serverIndex,
                                                ),
                                          );
                                        },
                                      ),
                                    detailAction(
                                      icon: isFavorite
                                          ? Icons.favorite_rounded
                                          : Icons.favorite_border_rounded,
                                      label: isFavorite
                                          ? 'Đã thích'
                                          : 'Yêu thích',
                                      color: isFavorite
                                          ? Colors.redAccent
                                          : null,
                                      onPressed: favoriteBusy
                                          ? null
                                          : () => toggleFavorite(movie),
                                    ),
                                    detailAction(
                                      icon: Icons.share_rounded,
                                      label: 'Chia sẻ',
                                      onPressed: () => launchUrl(
                                        Uri.parse(
                                          '$siteBase/movie/${movie.slug}',
                                        ),
                                        mode: LaunchMode.externalApplication,
                                      ),
                                    ),
                                    detailAction(
                                      icon: Icons.playlist_add_rounded,
                                      label: 'Playlist',
                                      onPressed: () async {
                                        if (!await requireLogin(
                                          context,
                                          'Playlist',
                                        )) {
                                          return;
                                        }
                                        if (!context.mounted) return;
                                        showModalBottomSheet(
                                          context: context,
                                          backgroundColor: CvColors.ink,
                                          showDragHandle: !isTvBuild,
                                          builder: (_) => AddToPlaylistSheet(
                                            repo: widget.repo,
                                            movie: movie,
                                          ),
                                        );
                                      },
                                    ),
                                    if (!isTvBuild)
                                      detailAction(
                                        icon: Icons.groups_rounded,
                                        label: 'Xem chung',
                                        onPressed:
                                            selectedServer == null ||
                                                selectedServer.items.isEmpty
                                            ? null
                                            : () async {
                                                if (!await requireLogin(
                                                  context,
                                                  'Xem chung',
                                                )) {
                                                  return;
                                                }
                                                if (context.mounted) {
                                                  Navigator.of(context).push(
                                                    MaterialPageRoute(
                                                      builder: (_) =>
                                                          WatchTogetherScreen(
                                                            repo: widget.repo,
                                                            prefillMovie: movie,
                                                            prefillServer:
                                                                selectedServer,
                                                            prefillEpisode:
                                                                selectedServer
                                                                    .items
                                                                    .first,
                                                            prefillServerIndex:
                                                                serverIndex,
                                                          ),
                                                    ),
                                                  );
                                                }
                                              },
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: pagePadding(context).copyWith(top: 20, bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (movie.description.isNotEmpty)
                        CollapsibleMovieDescription(
                          description: movie.description,
                          expanded: descriptionExpanded,
                          collapsedLines: 2,
                          onToggle: () => setState(
                            () => descriptionExpanded = !descriptionExpanded,
                          ),
                        ),
                      if ((movie.collection?.items.length ?? 0) >= 2) ...[
                        const SizedBox(height: 22),
                        MovieCollectionSelector(
                          collection: movie.collection!,
                          currentMovieId: movie.id,
                          onSelected: selectCollectionPart,
                        ),
                      ],
                      if (movie.genres.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: movie.genres
                              .map((e) => GenreChip(label: e))
                              .toList(),
                        ),
                      ],
                      if (!snapshot.hasData)
                        const Padding(
                          padding: EdgeInsets.only(top: 24),
                          child: LinearProgressIndicator(
                            color: CvColors.accent,
                          ),
                        ),
                      if (detailTabs.isNotEmpty) ...[
                        SizedBox(height: isTvBuild ? 30 : 24),
                        DetailSectionTabs(
                          tabs: detailTabs,
                          selectedIndex: activeDetailSectionIndex,
                          onSelected: (value) =>
                              setState(() => detailSectionIndex = value),
                        ),
                        SizedBox(height: isTvBuild ? 20 : 16),
                        detailTabs[activeDetailSectionIndex].builder(context),
                      ],
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 36)),
            ],
          );
        },
      ),
    );
  }

  Widget detailAction({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool primary = false,
    Color? color,
  }) {
    if (useLeanbackControls) {
      return TvActionButton(
        icon: icon,
        label: label,
        primary: primary,
        selected: color != null,
        onPressed: onPressed,
      );
    }
    if (primary) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: color == null
          ? null
          : OutlinedButton.styleFrom(
              foregroundColor: color,
              side: BorderSide(color: color.withValues(alpha: .7)),
            ),
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

Widget _emptyEpisodeSection(BuildContext context) {
  return const EmptyState('Phim này chưa có nguồn phát trong API');
}

class DetailSectionTab {
  const DetailSectionTab({
    required this.label,
    required this.icon,
    required this.builder,
  });

  final String label;
  final IconData icon;
  final WidgetBuilder builder;
}

class DetailSectionTabs extends StatelessWidget {
  const DetailSectionTabs({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<DetailSectionTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: isTvBuild ? 64 : 52,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        scrollDirection: Axis.horizontal,
        itemCount: tabs.length,
        separatorBuilder: (_, _) => SizedBox(width: isTvBuild ? 10 : 8),
        itemBuilder: (context, index) {
          final tab = tabs[index];
          final selected = index == selectedIndex;
          if (useLeanbackControls) {
            return TvFilterChip(
              label: tab.label,
              icon: tab.icon,
              selected: selected,
              onPressed: () => onSelected(index),
            );
          }
          return _DetailSectionTabButton(
            tab: tab,
            selected: index == selectedIndex,
            onPressed: () => onSelected(index),
          );
        },
      ),
    );
  }
}

class _DetailSectionTabButton extends StatelessWidget {
  const _DetailSectionTabButton({
    required this.tab,
    required this.selected,
    required this.onPressed,
  });

  final DetailSectionTab tab;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? CvColors.accent : CvColors.text;
    final background = selected
        ? CvColors.accent.withValues(alpha: .15)
        : CvColors.panel2.withValues(alpha: .72);
    final border = selected
        ? CvColors.accent.withValues(alpha: .72)
        : CvColors.borderLight.withValues(alpha: .72);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minWidth: 112),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: border),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(tab.icon, size: 17, color: foreground),
                  const SizedBox(width: 7),
                  Text(
                    tab.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w900,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: selected ? 34 : 16,
                height: 2,
                decoration: BoxDecoration(
                  color: selected
                      ? CvColors.accent
                      : CvColors.borderLight.withValues(alpha: .35),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String?> showTvEpisodeSearchDialog(
  BuildContext context,
  String initialQuery,
) {
  final controller = TextEditingController(text: initialQuery);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: CvColors.panel,
        title: const Text('Tìm tập'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            keyboardType: TextInputType.text,
            onSubmitted: (_) =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            decoration: InputDecoration(
              hintText: 'Nhập số hoặc tên tập',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(
                tooltip: 'Xóa tìm kiếm',
                onPressed: () => controller.clear(),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(initialQuery),
            child: const Text('Đóng'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(''),
            child: const Text('Xóa'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Áp dụng'),
          ),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}

Widget tvEpisodeSearchButton({
  required String query,
  required VoidCallback onPressed,
}) {
  final hasQuery = query.trim().isNotEmpty;
  return FocusButton(
    onPressed: onPressed,
    selected: hasQuery,
    child: Container(
      constraints: const BoxConstraints(minHeight: 54),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: hasQuery ? .1 : .06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: hasQuery
              ? CvColors.accent.withValues(alpha: .62)
              : CvColors.borderLight.withValues(alpha: .48),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, color: CvColors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              hasQuery ? 'Tìm: ${query.trim()}' : 'Tìm tập bằng số hoặc tên',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: hasQuery ? CvColors.text : CvColors.muted,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Icon(Icons.keyboard_return_rounded, color: CvColors.muted),
        ],
      ),
    ),
  );
}

class EpisodeSection extends StatefulWidget {
  const EpisodeSection({
    super.key,
    required this.movie,
    required this.repo,
    required this.servers,
    required this.serverIndex,
    required this.resumeItem,
    required this.onServerChanged,
    required this.onEpisodeSelected,
  });
  final Movie movie;
  final MovieRepository repo;
  final List<EpisodeServer> servers;
  final int serverIndex;
  final WatchItem? resumeItem;
  final ValueChanged<int> onServerChanged;
  final Future<void> Function(
    Movie movie,
    EpisodeServer server,
    EpisodeItem episode,
    int selectedServerIndex, {
    Duration? resume,
  })
  onEpisodeSelected;

  @override
  State<EpisodeSection> createState() => _EpisodeSectionState();
}

class _EpisodeSectionState extends State<EpisodeSection> {
  final searchController = TextEditingController();
  int? selectedRangeStart;
  String? selectedServerType;

  @override
  void didUpdateWidget(covariant EpisodeSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverIndex != widget.serverIndex ||
        oldWidget.servers != widget.servers) {
      final safeIndex = widget.serverIndex.clamp(0, widget.servers.length - 1);
      selectedServerType = widget.servers[safeIndex].typeName;
      selectedRangeStart = _initialRangeStart(widget.servers[safeIndex].items);
      searchController.clear();
    }
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  int? _initialRangeStart(List<EpisodeItem> episodes) =>
      episodes.length > 50 ? 1 : null;

  List<int> _rangeStarts(List<EpisodeItem> episodes) {
    if (episodes.length <= 50) return const [];
    final maxEpisode = episodes.indexed.fold<int>(0, (max, entry) {
      final number = episodeNumber(entry.$2.displayName);
      return math.max(max, number <= 1 ? entry.$1 + 1 : number);
    });
    final maxValue = math.max(maxEpisode, episodes.length);
    return [for (var start = 1; start <= maxValue; start += 50) start];
  }

  bool _matchesQuery(EpisodeItem episode, String query) {
    final value = query.trim().toLowerCase();
    if (value.isEmpty) return true;
    final number = episodeNumber(episode.displayName).toString();
    return episode.displayName.toLowerCase().contains(value) ||
        episode.name.toLowerCase().contains(value) ||
        number == value ||
        'tap $number'.contains(value) ||
        'tập $number'.contains(value);
  }

  bool _matchesRange(EpisodeItem episode, int index, {int? rangeStart}) {
    final start = rangeStart;
    if (start == null) return true;
    final number = episodeNumber(episode.displayName);
    final value = number <= 1 ? index + 1 : number;
    return value >= start && value < start + 50;
  }

  Future<void> _openTvSearchDialog() async {
    final next = await showTvEpisodeSearchDialog(
      context,
      searchController.text,
    );
    if (!mounted || next == null) return;
    setState(() {
      searchController.text = next;
      if (next.trim().isNotEmpty) selectedRangeStart = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = widget.serverIndex.clamp(
      0,
      widget.servers.length - 1,
    );
    final server = widget.servers[selectedIndex];
    selectedServerType ??= server.typeName;
    final serverTypes = widget.servers.map((e) => e.typeName).toSet().toList();
    final visibleServerIndexes = widget.servers.indexed
        .where((e) => e.$2.typeName == selectedServerType)
        .map((e) => e.$1);
    final ranges = _rangeStarts(server.items);
    selectedRangeStart ??= _initialRangeStart(server.items);
    final query = searchController.text;
    final effectiveRangeStart = query.trim().isEmpty
        ? selectedRangeStart
        : null;
    final visibleEntries = server.items.indexed
        .where(
          (entry) =>
              _matchesRange(
                entry.$2,
                entry.$1,
                rangeStart: effectiveRangeStart,
              ) &&
              _matchesQuery(entry.$2, query),
        )
        .toList();
    final width = MediaQuery.sizeOf(context).width;
    final columns = isTvBuild
        ? 5
        : width >= 1100
        ? 6
        : width >= 720
        ? 5
        : 3;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: SectionTitle('Tập phim')),
              if (widget.resumeItem != null)
                TextButton.icon(
                  onPressed: () {
                    final resumeServerIndex = widget.resumeItem!.serverIndex
                        .clamp(0, widget.servers.length - 1);
                    final resumeServer = widget.servers[resumeServerIndex];
                    if (resumeServer.items.isEmpty) return;
                    final resumeEpisode = resumeServer.items.firstWhere(
                      (episode) =>
                          episode.name == widget.resumeItem!.episodeName ||
                          episode.displayName == widget.resumeItem!.episodeName,
                      orElse: () => resumeServer.items.first,
                    );
                    widget.onServerChanged(resumeServerIndex);
                    widget.onEpisodeSelected(
                      widget.movie,
                      resumeServer,
                      resumeEpisode,
                      resumeServerIndex,
                      resume: Duration(
                        milliseconds: widget.resumeItem!.positionMs,
                      ),
                    );
                  },
                  icon: const Icon(Icons.play_circle_fill_rounded),
                  label: Text(
                    'Xem tiếp ${widget.resumeItem!.progressPercent}%',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final type in serverTypes)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(type),
                      selected: type == selectedServerType,
                      showCheckmark: false,
                      onSelected: (_) {
                        final i = widget.servers.indexWhere(
                          (e) => e.typeName == type,
                        );
                        if (i >= 0) {
                          setState(() => selectedServerType = type);
                          widget.onServerChanged(i);
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final i in visibleServerIndexes)
                  Padding(
                    padding: EdgeInsets.only(
                      right: useLeanbackControls ? 12 : 8,
                    ),
                    child: useLeanbackControls
                        ? TvFilterChip(
                            label: widget.servers[i].sourceName,
                            icon: Icons.storage_rounded,
                            selected: i == selectedIndex,
                            onPressed: () => widget.onServerChanged(i),
                          )
                        : ChoiceChip(
                            label: Text(widget.servers[i].sourceName),
                            selected: i == selectedIndex,
                            showCheckmark: false,
                            onSelected: (_) => widget.onServerChanged(i),
                          ),
                  ),
              ],
            ),
          ),
          if (server.items.length > 12) ...[
            const SizedBox(height: 14),
            if (isTvBuild)
              tvEpisodeSearchButton(
                query: query,
                onPressed: _openTvSearchDialog,
              )
            else
              TextField(
                controller: searchController,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
                keyboardType: TextInputType.text,
                decoration: InputDecoration(
                  hintText: 'Tìm tập, ví dụ: 120',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: query.trim().isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Xóa tìm kiếm',
                          onPressed: () {
                            searchController.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: .06),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
          ],
          if (ranges.isNotEmpty) ...[
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final start in ranges)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: useLeanbackControls
                          ? TvFilterChip(
                              label:
                                  '$start-${math.min(start + 49, server.items.length)}',
                              icon: Icons.view_week_rounded,
                              selected: selectedRangeStart == start,
                              onPressed: () =>
                                  setState(() => selectedRangeStart = start),
                            )
                          : ChoiceChip(
                              label: Text(
                                '$start-${math.min(start + 49, server.items.length)}',
                              ),
                              selected: selectedRangeStart == start,
                              showCheckmark: false,
                              onSelected: (_) =>
                                  setState(() => selectedRangeStart = start),
                            ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (visibleEntries.isEmpty)
            const EmptyState('Không tìm thấy tập phù hợp')
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: visibleEntries.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: isTvBuild ? 2.8 : 2.35,
              ),
              itemBuilder: (context, index) {
                final episode = visibleEntries[index].$2;
                final isResumeEpisode =
                    widget.resumeItem != null &&
                    widget.resumeItem!.serverIndex == selectedIndex &&
                    (widget.resumeItem!.episodeName == episode.name ||
                        widget.resumeItem!.episodeName == episode.displayName);
                return FocusButton(
                  onPressed: () => widget.onEpisodeSelected(
                    widget.movie,
                    server,
                    episode,
                    selectedIndex,
                    resume: isResumeEpisode
                        ? Duration(milliseconds: widget.resumeItem!.positionMs)
                        : null,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (isResumeEpisode)
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: CvColors.accent.withValues(alpha: .1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: CvColors.accent.withValues(alpha: .74),
                              ),
                            ),
                          ),
                        )
                      else
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: CvColors.panel2.withValues(alpha: .74),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: CvColors.borderLight.withValues(
                                  alpha: .48,
                                ),
                              ),
                            ),
                          ),
                        ),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            episode.displayName,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: isResumeEpisode
                                  ? FontWeight.w900
                                  : FontWeight.w800,
                              color: isResumeEpisode
                                  ? CvColors.accent
                                  : CvColors.text,
                              fontSize: isTvBuild ? 16 : 13.5,
                            ),
                          ),
                        ),
                      ),
                      if (isResumeEpisode)
                        Positioned(
                          top: 5,
                          right: 7,
                          child: Text(
                            '${widget.resumeItem!.progressPercent}%',
                            style: const TextStyle(
                              color: CvColors.accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class EpisodeGrid extends StatelessWidget {
  const EpisodeGrid({
    super.key,
    required this.movie,
    required this.repo,
    required this.server,
    required this.serverIndex,
  });
  final Movie movie;
  final MovieRepository repo;
  final EpisodeServer server;
  final int serverIndex;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final episode in server.items)
          SizedBox(
            width: isTvBuild ? 150 : 112,
            child: FocusButton(
              onPressed: () => openPlayer(
                context,
                repo,
                movie,
                server,
                episode,
                serverIndex,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Text(
                  episode.displayName,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class CrewSection extends StatelessWidget {
  const CrewSection({
    super.key,
    required this.repo,
    required this.directors,
    required this.cast,
  });

  final MovieRepository repo;
  final List<MoviePerson> directors;
  final List<MoviePerson> cast;

  void openPerson(BuildContext context, MoviePerson person) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BrowseScreen(repo: repo, initialSearch: person.name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (directors.isEmpty && cast.isEmpty) return const SizedBox.shrink();
    final compact = MediaQuery.sizeOf(context).width < 520;
    final itemWidth = isTvBuild
        ? 176.0
        : compact
        ? 118.0
        : 132.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.theater_comedy_rounded, color: CvColors.accent),
            const SizedBox(width: 8),
            const SectionTitle('Ê-kíp & diễn viên'),
          ],
        ),
        const SizedBox(height: 12),
        if (directors.isNotEmpty) ...[
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final person in directors.take(4))
                PersonRolePill(
                  person: person,
                  role: 'Đạo diễn',
                  icon: Icons.movie_creation_rounded,
                  onTap: () => openPerson(context, person),
                ),
            ],
          ),
          if (cast.isNotEmpty) const SizedBox(height: 18),
        ],
        if (cast.isNotEmpty) ...[
          Row(
            children: const [
              Icon(Icons.groups_rounded, size: 18, color: CvColors.muted),
              SizedBox(width: 7),
              Text(
                'Diễn viên',
                style: TextStyle(
                  color: CvColors.muted,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: isTvBuild ? 174 : 154,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: cast.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) => PersonCard(
                person: cast[index],
                width: itemWidth,
                onTap: () => openPerson(context, cast[index]),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class PersonRolePill extends StatelessWidget {
  const PersonRolePill({
    super.key,
    required this.person,
    required this.role,
    required this.icon,
    required this.onTap,
  });

  final MoviePerson person;
  final String role;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FocusButton(
    onPressed: onTap,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: CvColors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CvColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PersonAvatar(person: person, radius: 20),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 14, color: CvColors.accent),
                    const SizedBox(width: 5),
                    Text(
                      role,
                      style: const TextStyle(
                        color: CvColors.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  person.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          const Icon(
            Icons.chevron_right_rounded,
            color: CvColors.soft,
            size: 20,
          ),
        ],
      ),
    ),
  );
}

class PersonCard extends StatelessWidget {
  const PersonCard({
    super.key,
    required this.person,
    required this.width,
    required this.onTap,
  });

  final MoviePerson person;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: FocusButton(
      onPressed: onTap,
      child: Container(
        height: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CvColors.panel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: CvColors.border),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PersonAvatar(person: person, radius: isTvBuild ? 38 : 30),
            const SizedBox(height: 10),
            SizedBox(
              height: 36,
              child: Text(
                person.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                textScaler: TextScaler.noScaling,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.person, required this.radius});

  final MoviePerson person;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final initial = person.name.characters.isEmpty
        ? '?'
        : person.name.characters.first.toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: CvColors.panel2,
      backgroundImage: person.avatarUrl.isNotEmpty
          ? CachedNetworkImageProvider(person.avatarUrl)
          : null,
      child: person.avatarUrl.isEmpty
          ? Text(
              initial,
              style: TextStyle(
                fontSize: radius * .68,
                fontWeight: FontWeight.w900,
                color: CvColors.accent,
              ),
            )
          : null,
    );
  }
}

class SocialSection extends StatefulWidget {
  const SocialSection({super.key, required this.repo, required this.movie});
  final MovieRepository repo;
  final Movie movie;

  @override
  State<SocialSection> createState() => _SocialSectionState();
}

class _SocialSectionState extends State<SocialSection> {
  final comment = TextEditingController();
  late Future<List<MovieComment>> comments;
  late Future<RatingStats> rating;
  late Future<bool> loggedIn;
  int selectedRating = 0;
  bool spoiler = false;

  @override
  void initState() {
    super.initState();
    comments = widget.repo.comments(widget.movie.id);
    rating = widget.repo.ratingStats(widget.movie.id);
    loggedIn = isLoggedIn();
  }

  @override
  void dispose() {
    comment.dispose();
    super.dispose();
  }

  Future<void> submitComment() async {
    if (!await requireLogin(context, 'Bình luận')) return;
    final content = comment.text.trim();
    if (content.length < 2) return;
    try {
      await widget.repo.addComment(
        widget.movie.id,
        content,
        isSpoiler: spoiler,
      );
      comment.clear();
      setState(() => comments = widget.repo.comments(widget.movie.id));
      if (mounted) showSnack(context, 'Đã gửi bình luận');
    } catch (_) {
      if (mounted) showSnack(context, 'Cần đăng nhập để bình luận');
    }
  }

  Future<void> rate(int value) async {
    if (!await requireLogin(context, 'Chấm điểm')) return;
    setState(() => selectedRating = value);
    try {
      final next = await widget.repo.rateMovie(widget.movie.id, value);
      setState(() => rating = Future.value(next));
      if (mounted) showSnack(context, 'Đã chấm $value/10');
    } catch (_) {
      if (mounted) showSnack(context, 'Cần đăng nhập để chấm điểm');
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: loggedIn,
      builder: (context, authSnapshot) {
        final canInteract = authSnapshot.data == true;
        return Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle('Đánh giá & bình luận'),
              const SizedBox(height: 12),
              FutureBuilder<RatingStats>(
                future: rating,
                builder: (context, snapshot) {
                  final stats = snapshot.data;
                  final avg = stats == null
                      ? '—'
                      : stats.average.toStringAsFixed(1);
                  return Row(
                    children: [
                      Icon(
                        Icons.star_rounded,
                        color: CvColors.amber,
                        size: isTvBuild ? 30 : 24,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$avg / 10',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '(${stats?.total ?? 0} lượt)',
                        style: const TextStyle(color: CvColors.muted),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                children: [
                  for (var i = 1; i <= 10; i++)
                    IconButton(
                      tooltip: canInteract ? '$i/10' : 'Đăng nhập để chấm điểm',
                      onPressed: canInteract ? () => rate(i) : null,
                      icon: Icon(
                        i <= selectedRating
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        color: canInteract
                            ? CvColors.amber
                            : CvColors.muted.withValues(alpha: .55),
                      ),
                    ),
                ],
              ),
              if (!canInteract) ...[
                const SizedBox(height: 6),
                const Row(
                  children: [
                    Icon(Icons.lock_rounded, size: 18, color: CvColors.muted),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Đăng nhập để bình luận và chấm điểm.',
                        style: TextStyle(color: CvColors.muted),
                      ),
                    ),
                  ],
                ),
              ],
              const Divider(height: 26),
              TextField(
                controller: comment,
                enabled: canInteract,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: canInteract
                      ? 'Viết bình luận'
                      : 'Đăng nhập để bình luận',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilterChip(
                    label: const Text('Có spoiler'),
                    selected: spoiler,
                    onSelected: canInteract
                        ? (value) => setState(() => spoiler = value)
                        : null,
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: canInteract ? submitComment : null,
                    icon: const Icon(Icons.send_rounded),
                    label: const Text('Gửi'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              FutureBuilder<List<MovieComment>>(
                future: comments,
                builder: (context, snapshot) {
                  final rows = snapshot.data ?? const <MovieComment>[];
                  if (!snapshot.hasData) {
                    return const LinearProgressIndicator(
                      color: CvColors.accent,
                    );
                  }
                  if (rows.isEmpty) {
                    return const Text(
                      'Chưa có bình luận',
                      style: TextStyle(color: CvColors.muted),
                    );
                  }
                  return Column(
                    children: [
                      for (final item in rows.take(12))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              UserAvatar(
                                name: item.userName,
                                avatarUrl: item.userAvatar,
                                radius: 20,
                                isVip: item.isVip || item.isAdmin,
                                showVipBadge: true,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            item.userName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 15,
                                            ),
                                          ),
                                        ),
                                        if (item.likes > 0) ...[
                                          const SizedBox(width: 6),
                                          Text(
                                            '${item.likes} thích',
                                            style: const TextStyle(
                                              color: CvColors.muted,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    if (item.isAdmin || item.isVip) ...[
                                      const SizedBox(height: 4),
                                      _MembershipTag(
                                        label: item.isAdmin
                                            ? 'Administrator'
                                            : 'Chủ Tịch Donate',
                                        isAdmin: item.isAdmin,
                                      ),
                                    ],
                                    const SizedBox(height: 5),
                                    Text(
                                      item.isSpoiler
                                          ? '[Spoiler] ${item.content}'
                                          : item.content,
                                      style: const TextStyle(
                                        height: 1.35,
                                        color: CvColors.text,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MembershipTag extends StatelessWidget {
  const _MembershipTag({required this.label, required this.isAdmin});
  final String label;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: isAdmin
          ? const Color(0xFFFFC83D).withValues(alpha: .16)
          : const Color(0xFF9B59FF).withValues(alpha: .2),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(
        color: isAdmin ? const Color(0xFFFFC83D) : const Color(0xFFB983FF),
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.workspace_premium_rounded,
            size: 12,
            color: isAdmin ? const Color(0xFFFFD76A) : const Color(0xFFD8B4FE),
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: isAdmin
                  ? const Color(0xFFFFD76A)
                  : const Color(0xFFD8B4FE),
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    ),
  );
}

class ResumeLoaderScreen extends StatefulWidget {
  const ResumeLoaderScreen({super.key, required this.repo, required this.item});
  final MovieRepository repo;
  final WatchItem item;

  @override
  State<ResumeLoaderScreen> createState() => _ResumeLoaderScreenState();
}

class _ResumeLoaderScreenState extends State<ResumeLoaderScreen> {
  late final Future<Movie> _movieFuture;
  bool _openingPlayer = false;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _movieFuture = widget.repo.detail(
      item.slug.isNotEmpty ? item.slug : '${item.movieId}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return FutureBuilder<Movie>(
      future: _movieFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const LoadingPage(label: 'Đang mở phim');
        final movie = snapshot.data!;
        final server = movie.episodes.isNotEmpty
            ? movie.episodes[item.serverIndex.clamp(
                0,
                movie.episodes.length - 1,
              )]
            : null;
        final episode = server?.items.firstWhere(
          (e) =>
              e.name == item.episodeName || e.displayName == item.episodeName,
          orElse: () => server.items.first,
        );
        if (server == null || episode == null) {
          return const Scaffold(
            body: EmptyState('Không tìm thấy tập đang xem'),
          );
        }
        if (!_openingPlayer) {
          _openingPlayer = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => PlayerScreen(
                  repo: widget.repo,
                  movie: movie,
                  server: server,
                  episode: episode,
                  serverIndex: item.serverIndex.clamp(
                    0,
                    movie.episodes.length - 1,
                  ),
                  resume: Duration(milliseconds: item.positionMs),
                ),
              ),
            );
          });
        }
        return const LoadingPage(label: 'Đang mở player');
      },
    );
  }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.repo,
    required this.movie,
    required this.server,
    required this.episode,
    required this.serverIndex,
    this.resume,
    this.watchTogetherState,
    this.watchTogetherCode,
    this.offlineManifestPath,
  });

  final MovieRepository repo;
  final Movie movie;
  final EpisodeServer server;
  final EpisodeItem episode;
  final int serverIndex;
  final Duration? resume;
  final WatchTogetherState? watchTogetherState;
  final String? watchTogetherCode;
  final String? offlineManifestPath;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? controller;
  HttpServer? offlineMediaServer;
  Directory? offlineMediaRoot;
  Timer? saveTimer;
  Timer? controlsTimer;
  Timer? levelApplyTimer;
  Timer? deviceLevelSyncTimer;
  Timer? gestureHintTimer;
  final focusNode = FocusNode();
  final overlayFocusScopeNode = FocusScopeNode(
    debugLabel: 'player-overlay-controls',
  );
  final playButtonFocusNode = FocusNode(debugLabel: 'player-play-toggle');
  final seekBarFocusNode = FocusNode(debugLabel: 'player-seekbar');
  final backButtonFocusNode = FocusNode(debugLabel: 'player-back');
  final webViewPlayFocusNode = FocusNode(debugLabel: 'streamc-play-toggle');
  late EpisodeServer currentServer;
  late EpisodeItem currentEpisode;
  late int currentServerIndex;
  String? selectedAudioKey;
  String? selectedSubtitleLang;
  static const _playbackPrefsKey = 'cinevietPlaybackTrackPrefsV1';
  Map<String, dynamic> _playbackTrackPrefs = {};
  static const _defaultViSubtitleStyle = AppSubtitleStyle(
    size: 30,
    color: Colors.white,
    bottom: 7,
  );
  static const _defaultEnSubtitleStyle = AppSubtitleStyle(
    size: 25,
    color: Color(0xffffff99),
    bottom: 20,
  );
  AppSubtitleStyle viSubtitleStyle = _defaultViSubtitleStyle;
  AppSubtitleStyle enSubtitleStyle = _defaultEnSubtitleStyle;
  PlayerFitMode fitMode = PlayerFitMode.contain;
  bool controls = true;
  bool controlsLocked = false;
  bool autoNextEpisode = true;
  bool autoNextCancelledForEpisode = false;
  double playbackSpeed = 1.0;
  double appVolume = 1.0;
  double screenBrightness = 1.0;
  Offset? dragStart;
  Duration? dragStartPosition;
  double? dragStartBrightness;
  double? dragStartVolume;
  Duration? pendingSeekPosition;
  String? dragMode;
  String? gestureMode;
  double? gestureValue;
  double? pendingBrightness;
  double? pendingVolume;
  String? error;
  WatchTogetherState? watchRoomState;
  final watchChatController = TextEditingController();
  final watchMessages = <WatchTogetherMessage>[];
  bool watchChatVisible = !isTvBuild;
  bool applyingWatchSync = false;
  bool leavingPlayer = false;
  bool playerDisposed = false;
  String? lastWatchRoomFrom;
  int lastWatchSyncSentAt = 0;
  List<PlaybackUrlCandidate> activePlayableUrls = const [];
  int activePlayableUrlIndex = 0;
  WebViewController? webViewController;
  windows_webview.WebviewController? windowsWebViewController;
  String? activeWebViewUrl;
  IntroSkipData? introSkipData;
  String introSkipDataKey = '';
  final skippedIntroDbSegments = <String>{};
  bool recoveringPlayback = false;
  bool savingProgress = false;
  bool reportingPlaybackIssue = false;
  bool androidBrightnessSettingsPrompted = false;
  bool landscapeFullscreen = false;
  bool introSkipped = false;
  bool savedCurrentEpisodeProgress = false;
  int lastAutoNextPromptSecond = -1;
  int runtimeRecoveryAttempts = 0;
  int lastHistorySaveAtMs = 0;
  Duration? lastGoodPosition;
  static const introSkipSeconds = 72;
  String? playbackNotice;
  String? lastPlaybackError;
  late final String playbackSessionId =
      '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(999999)}';
  static const brightnessChannel = MethodChannel('live.cineviet/brightness');

  bool get isWatchTogether =>
      (widget.watchTogetherCode ?? watchRoomState?.code ?? '').isNotEmpty;
  bool get isWatchHost => MovieRepository.activeWatchRoomIsHost;
  String get watchRoomCode =>
      widget.watchTogetherCode ?? watchRoomState?.code ?? '';
  bool get supportsTouchLevels =>
      !isTvBuild &&
      (Platform.isAndroid || Platform.isIOS || Platform.isWindows);
  bool get usesPlayerVolume => Platform.isAndroid || Platform.isIOS;
  bool get usesWindowsBrightnessOverlay => supportsTouchLevels;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    currentServer = widget.server;
    currentEpisode = widget.episode;
    currentServerIndex = widget.serverIndex;
    _resetTrackSelectionForEpisode();
    unawaited(_loadPlaybackTrackPreference());
    unawaited(_loadSubtitleSettings());
    watchRoomState = widget.watchTogetherState;
    watchMessages.addAll(widget.watchTogetherState?.messages ?? const []);
    WakelockPlus.enable();
    _syncDeviceLevels();
    deviceLevelSyncTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted ||
          controlsLocked ||
          dragMode != null ||
          pendingBrightness != null ||
          pendingVolume != null) {
        return;
      }
      unawaited(_syncDeviceLevels());
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => focusNode.requestFocus(),
    );
    _bindWatchTogetherSocket();
    _loadIntroSkipSegments();
    _init();
  }

  static const _subtitlePrefsKey = 'cinevietSubtitleConfigApp';

  Future<void> _loadSubtitleSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_subtitlePrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        if (json.containsKey('vi') || json.containsKey('en')) {
          viSubtitleStyle = AppSubtitleStyle.fromJson(
            json['vi'],
            _defaultViSubtitleStyle,
          );
          enSubtitleStyle = AppSubtitleStyle.fromJson(
            json['en'],
            _defaultEnSubtitleStyle,
          );
        } else {
          // Migrate the first app settings format, which used one shared style.
          final legacy = AppSubtitleStyle(
            font: json['font'] is String ? json['font'] as String : 'Lora',
            size: ((json['size'] as num?)?.toDouble() ?? 18).clamp(10, 50),
            color: Color((json['color'] as num?)?.toInt() ?? 0xffffffff),
            bottom: 7,
          );
          viSubtitleStyle = legacy;
          enSubtitleStyle = legacy.copyWith(
            size: math.max(10, legacy.size - 5),
            color: const Color(0xffffff99),
            bottom: 20,
          );
        }
      });
    } catch (_) {}
  }

  Future<void> _saveSubtitleSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _subtitlePrefsKey,
      jsonEncode({
        'vi': viSubtitleStyle.toJson(),
        'en': enSubtitleStyle.toJson(),
      }),
    );
  }

  void _resetSubtitleSettings() {
    setState(() {
      viSubtitleStyle = _defaultViSubtitleStyle;
      enSubtitleStyle = _defaultEnSubtitleStyle;
    });
    unawaited(_saveSubtitleSettings());
  }

  bool _isTrustedPlayerEmbedUrl(String raw) {
    final parsed = Uri.tryParse(raw.trim());
    if (parsed == null || parsed.scheme != 'https') return false;
    final host = parsed.host.toLowerCase();
    final path = parsed.path.toLowerCase();
    final isStreamC = host.endsWith('streamc.xyz') && path.contains('/embed');
    final isPhimApi = host == 'player.phimapi.com' && path.contains('/player');
    return isStreamC || isPhimApi;
  }

  bool _isStreamCEmbedUrl(String raw) {
    final parsed = Uri.tryParse(raw.trim());
    if (parsed == null) return false;
    return parsed.host.toLowerCase().endsWith('streamc.xyz') &&
        parsed.path.toLowerCase().contains('/embed');
  }

  String? _webViewFallbackUrl(EpisodeItem episode) {
    // Chỉ mở WebView cho player embed đã allowlist. PhimAPI là fallback quan
    // trọng khi ExoPlayer không giải mã được HLS trên một số thiết bị Android.
    final embed = episode.linkEmbed.trim();
    if (_isTrustedPlayerEmbedUrl(embed)) return embed;
    final play = episode.playUrl.trim();
    if (_isTrustedPlayerEmbedUrl(play)) return play;
    return null;
  }

  EpisodeAudioSource? get _selectedAudioSource {
    final items = currentEpisode.audioSources;
    if (items.isEmpty) return null;
    final key = selectedAudioKey;
    if (key != null && key.isNotEmpty) {
      for (final item in items) {
        if (item.key == key) return item;
      }
    }
    return items.first;
  }

  EpisodeSubtitleTrack? get _selectedSubtitleTrack {
    final tracks = _selectedSubtitleTracks;
    return tracks.isEmpty ? null : tracks.first;
  }

  List<EpisodeSubtitleTrack> get _selectedSubtitleTracks {
    final tracks = currentEpisode.subtitles;
    final lang = selectedSubtitleLang;
    if (tracks.isEmpty || lang == null || lang == 'off') return const [];
    if (lang == 'dual') {
      EpisodeSubtitleTrack? vi;
      EpisodeSubtitleTrack? en;
      for (final track in tracks) {
        final key = track.lang.toLowerCase();
        if (key == 'vi') vi = track;
        if (key == 'en') en = track;
      }
      return [?vi, ?en];
    }
    for (final track in tracks) {
      if (track.lang == lang) return [track];
    }
    return const [];
  }

  bool _isSelectedEpisodeSource(EpisodeServer server, EpisodeItem episode) =>
      server.name == currentServer.name &&
      episode.name == currentEpisode.name &&
      episode.linkEmbed == currentEpisode.linkEmbed;

  String get _trackPreferenceMovieKey => 'movie:${widget.movie.id}';

  Future<void> _loadPlaybackTrackPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_playbackPrefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _playbackTrackPrefs = Map<String, dynamic>.from(jsonDecode(raw));
      } catch (_) {}
    }
    if (!mounted) return;
    _resetTrackSelectionForEpisode();
    setState(() {});
  }

  Future<void> _savePlaybackTrackPreference() async {
    final prefs = await SharedPreferences.getInstance();
    _playbackTrackPrefs[_trackPreferenceMovieKey] = {
      'audio': selectedAudioKey,
      'subtitle': selectedSubtitleLang,
    };
    await prefs.setString(_playbackPrefsKey, jsonEncode(_playbackTrackPrefs));
  }

  void _resetTrackSelectionForEpisode() {
    final saved = _playbackTrackPrefs[_trackPreferenceMovieKey];
    final savedAudio = saved is Map ? saved['audio']?.toString() : null;
    final savedSubtitle = saved is Map ? saved['subtitle']?.toString() : null;
    final audio = currentEpisode.audioSources;
    if (audio.isEmpty) {
      selectedAudioKey = null;
    } else {
      final original = audio.where(
        (item) => item.key.toLowerCase() == 'original',
      );
      final saved = savedAudio == null
          ? null
          : audio.where((item) => item.key == savedAudio).firstOrNull;
      selectedAudioKey =
          saved?.key ??
          (original.isNotEmpty ? original.first.key : audio.first.key);
    }

    final subtitles = currentEpisode.subtitles;
    if (subtitles.isEmpty) {
      selectedSubtitleLang = null;
    } else {
      final vi = subtitles.where((item) => item.lang.toLowerCase() == 'vi');
      final en = subtitles.where((item) => item.lang.toLowerCase() == 'en');
      final savedAvailable = savedSubtitle == 'off' || savedSubtitle == 'dual'
          ? savedSubtitle
          : subtitles.any((item) => item.lang == savedSubtitle)
          ? savedSubtitle
          : null;
      selectedSubtitleLang =
          savedAvailable ??
          (vi.isNotEmpty && en.isNotEmpty
              ? 'dual'
              : vi.isNotEmpty
              ? vi.first.lang
              : subtitles.first.lang);
    }
  }

  String _playUrlForEpisode(EpisodeServer server, EpisodeItem episode) {
    if (_isSelectedEpisodeSource(server, episode)) {
      final audioUrl = _selectedAudioSource?.url.trim() ?? '';
      if (audioUrl.isNotEmpty) return audioUrl;
    }
    return episode.playUrl;
  }

  String _absoluteMediaUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    final parsed = Uri.tryParse(value);
    if (parsed == null) return value;
    if (parsed.hasScheme) return parsed.toString();
    if (value.startsWith('//')) return 'https:$value';
    return Uri.parse('$siteBase/').resolve(value).toString();
  }

  Future<ClosedCaptionFile> _closedCaptionFileForTrack(
    EpisodeSubtitleTrack track,
  ) async {
    final rawUrl = track.url.trim();
    // Offline metadata stores an absolute platform path. Do not pass it to
    // Dio: Windows paths such as `C:\\Users\\...` (or paths beginning with
    // `/Users/...` from older builds) are not network URLs and Dio reports
    // `No host specified in URI`.
    final localPath = rawUrl.startsWith('file://')
        ? Uri.tryParse(rawUrl)?.toFilePath()
        : rawUrl;
    if (localPath != null && localPath.isNotEmpty) {
      final file = File(localPath);
      if (await file.exists()) {
        final contents = await file.readAsString();
        return track.format.toLowerCase().contains('srt')
            ? SubRipCaptionFile(contents)
            : WebVTTCaptionFile(contents);
      }
    }
    final res = await Dio(
      BaseOptions(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 12),
      ),
    ).get<String>(_absoluteMediaUrl(track.url));
    final contents = res.data ?? '';
    if (track.format.toLowerCase().contains('srt')) {
      return SubRipCaptionFile(contents);
    }
    return WebVTTCaptionFile(contents);
  }

  Future<ClosedCaptionFile>? _closedCaptionFileForSelectedTracks() {
    final tracks = _selectedSubtitleTracks;
    if (tracks.isEmpty) return null;
    if (tracks.length == 1) return _closedCaptionFileForTrack(tracks.first);
    return Future.wait(
      tracks.map(_closedCaptionFileForTrack),
    ).then((files) => BilingualCaptionFile(files[0], files[1]));
  }

  bool _isInitialEpisodeForResume() {
    return currentServerIndex == widget.serverIndex &&
        currentEpisode.name == widget.episode.name &&
        currentEpisode.linkM3u8 == widget.episode.linkM3u8 &&
        currentEpisode.linkEmbed == widget.episode.linkEmbed;
  }

  Duration? _initialResumeForCurrentEpisode() {
    final resume = widget.resume;
    if (resume == null || resume.inSeconds <= 3) return null;
    return _isInitialEpisodeForResume() ? resume : null;
  }

  List<String> _playableUrls(String raw) {
    final urls = <String>[];

    void add(String value) {
      final text = _absoluteMediaUrl(value);
      if (text.isEmpty || urls.contains(text)) return;
      urls.add(text);
    }

    final absoluteRaw = _absoluteMediaUrl(raw);
    final parsed = Uri.tryParse(absoluteRaw);
    final rawPath = parsed?.path.toLowerCase() ?? '';
    final rawHost = parsed?.host.toLowerCase() ?? '';
    final rawLooksPlayable =
        rawPath.contains('.m3u8') ||
        rawPath.contains('.mp4') ||
        rawPath.contains('.mkv') ||
        rawPath.contains('.webm') ||
        rawPath.contains('/api/stream');
    final rawIsKnownEmbedOnly =
        rawHost.contains('streamc.xyz') && rawPath.contains('/embed');
    final nested = parsed?.queryParameters['url'];
    final decodedNested = nested != null && nested.isNotEmpty
        ? Uri.decodeFull(nested)
        : '';
    final directM3u8 = rawPath.contains('.m3u8')
        ? absoluteRaw
        : (Uri.tryParse(decodedNested)?.path.toLowerCase().contains('.m3u8') ??
              false)
        ? decodedNested
        : '';

    // Prefer the backend stream proxy for HLS so KKPhim ad segments are
    // stripped server-side before the native player receives the manifest.
    if (directM3u8.isNotEmpty && !directM3u8.contains('/api/stream')) {
      add('$apiBase/stream?url=${Uri.encodeComponent(directM3u8)}');
    }
    if (rawLooksPlayable && !rawIsKnownEmbedOnly) add(absoluteRaw);
    if (decodedNested.isNotEmpty) add(decodedNested);

    return urls;
  }

  String _qualityLabelFor(EpisodeServer server, EpisodeItem episode) {
    final haystack =
        '${episode.filename} ${episode.name} ${server.name} '
                '${episode.linkM3u8} ${episode.linkEmbed}'
            .toLowerCase();
    if (haystack.contains('2160') || haystack.contains('4k')) return '4K';
    if (haystack.contains('1080') ||
        haystack.contains('fhd') ||
        haystack.contains('fullhd')) {
      return '1080p';
    }
    if (haystack.contains('720') || RegExp(r'\bhd\b').hasMatch(haystack)) {
      return '720p';
    }
    if (haystack.contains('480')) return '480p';
    if (haystack.contains('360')) return '360p';
    if (haystack.contains('cam') || haystack.contains('ts')) return 'CAM';
    final movieQuality = widget.movie.quality.trim();
    return movieQuality.isEmpty ? 'Auto' : movieQuality;
  }

  int _qualityRank(String label) {
    final text = label.toLowerCase();
    if (text.contains('cam') || text.contains('ts')) return 120;
    if (text.contains('4k') || text.contains('2160')) return 2160;
    if (text.contains('1080') || text.contains('fhd')) return 1080;
    if (text.contains('720') || text == 'hd') return 720;
    if (text.contains('480')) return 480;
    if (text.contains('360')) return 360;
    return 600;
  }

  bool _isSameEpisode(EpisodeItem a, EpisodeItem b) {
    final an = episodeNumber(a.displayName);
    final bn = episodeNumber(b.displayName);
    if (an == bn && an > 1) return true;
    if (a.name.trim().toLowerCase() == b.name.trim().toLowerCase()) return true;
    return an == bn &&
        (a.displayName.toLowerCase().contains('full') ||
            b.displayName.toLowerCase().contains('full'));
  }

  EpisodeItem? _matchingEpisodeInServer(EpisodeServer server) {
    final exact = server.items.where(
      (item) =>
          item.name == currentEpisode.name ||
          item.linkM3u8 == currentEpisode.linkM3u8 ||
          item.linkEmbed == currentEpisode.linkEmbed,
    );
    if (exact.isNotEmpty) return exact.first;
    final byNumber = server.items.where(
      (item) => _isSameEpisode(item, currentEpisode),
    );
    if (byNumber.isNotEmpty) return byNumber.first;
    return null;
  }

  void _addPlaybackSource(
    List<PlaybackSourceCandidate> sources, {
    required EpisodeServer server,
    required EpisodeItem episode,
    required int serverIndex,
  }) {
    final urls = _playableUrls(_playUrlForEpisode(server, episode));
    final webViewUrl = _webViewFallbackUrl(episode);
    if (urls.isEmpty && webViewUrl == null) return;
    final quality = _qualityLabelFor(server, episode);
    sources.add(
      PlaybackSourceCandidate(
        server: server,
        episode: episode,
        serverIndex: serverIndex,
        qualityLabel: quality,
        qualityRank: _qualityRank(quality),
        sourceLabel: server.displayName,
        urls: urls,
        webViewUrl: webViewUrl,
      ),
    );
  }

  List<PlaybackSourceCandidate> _currentPlaybackSources() {
    final sources = <PlaybackSourceCandidate>[];
    _addPlaybackSource(
      sources,
      server: currentServer,
      episode: currentEpisode,
      serverIndex: currentServerIndex,
    );
    for (var i = 0; i < widget.movie.episodes.length; i++) {
      if (i == currentServerIndex) continue;
      final server = widget.movie.episodes[i];
      final episode = _matchingEpisodeInServer(server);
      if (episode == null) continue;
      _addPlaybackSource(
        sources,
        server: server,
        episode: episode,
        serverIndex: i,
      );
    }
    return sources;
  }

  List<PlaybackUrlCandidate> _playbackUrlCandidates() {
    final selected = _currentPlaybackSources();
    final urls = <PlaybackUrlCandidate>[];
    final seen = <String>{};
    for (final source in selected) {
      for (final url in source.urls) {
        if (seen.add(url)) {
          urls.add(PlaybackUrlCandidate(source: source, url: url));
        }
      }
    }
    return urls;
  }

  String _sourceType(String url) {
    if (_isStreamCEmbedUrl(url)) return 'streamc_webview';
    final parsed = Uri.tryParse(url);
    if (parsed == null) return 'unknown';
    if (parsed.path.toLowerCase().contains('.m3u8')) return 'm3u8';
    if (parsed.path.contains('/api/stream')) return 'proxy';
    if (parsed.host.contains('phimapi.com')) return 'embed';
    return parsed.host.isEmpty ? 'unknown' : parsed.host;
  }

  void _trackPlaybackEvent(
    String eventType, {
    String errorCode = '',
    String errorMessage = '',
  }) {
    final active = activePlayableUrls.isNotEmpty
        ? activePlayableUrls[activePlayableUrlIndex
              .clamp(0, activePlayableUrls.length - 1)
              .toInt()]
        : null;
    final url = active?.url ?? currentEpisode.playUrl;
    final source = active?.source;
    unawaited(
      widget.repo.reportPlaybackEvent(
        movie: widget.movie,
        server: source?.server ?? currentServer,
        episode: source?.episode ?? currentEpisode,
        eventType: eventType,
        errorCode: errorCode,
        errorMessage: errorMessage,
        sourceType: _sourceType(url),
        sourceLabel: source?.displayName ?? currentServer.displayName,
        sourceMode: currentServer.displayName,
        sessionId: playbackSessionId,
      ),
    );
  }

  Future<void> _injectWebViewPlaybackAssist({Duration? resume}) async {
    final wc = webViewController;
    final wwc = windowsWebViewController;
    if (wc == null && wwc == null) return;
    final resumeSec =
        (resume ?? lastGoodPosition ?? _initialResumeForCurrentEpisode())
            ?.inSeconds ??
        0;
    final script =
        '''
        (function () {
          try {
            var resumeAt = $resumeSec;
            var tries = 0;
            var selectors = [
              '.jw-icon-playback',
              '.jw-display-icon-container',
              '.jwplayer .jw-display-icon-display',
              '.vjs-big-play-button',
              '.plyr__control[data-plyr="play"]',
              'button[aria-label*="Play"]',
              'button[title*="Play"]',
              '.play',
              '.play-button'
            ];
            var tvFocusIndex = Number.isFinite(window.__cvTvFocusIndex)
              ? window.__cvTvFocusIndex
              : -1;
            function isVisible(el) {
              try {
                var rect = el.getBoundingClientRect();
                var style = window.getComputedStyle(el);
                return rect.width > 2 && rect.height > 2 &&
                  style.visibility !== 'hidden' &&
                  style.display !== 'none' &&
                  style.opacity !== '0';
              } catch (_) {
                return false;
              }
            }
            function labelOf(el) {
              try {
                return [
                  el.innerText,
                  el.textContent,
                  el.getAttribute('aria-label'),
                  el.getAttribute('title'),
                  el.getAttribute('data-title'),
                  el.getAttribute('data-text'),
                  el.value,
                  el.className
                ].join(' ').toLowerCase();
              } catch (_) {
                return '';
              }
            }
            function documents() {
              var docs = [document];
              try {
                Array.prototype.slice.call(document.querySelectorAll('iframe')).forEach(function (frame) {
                  try {
                    var doc = frame.contentDocument || frame.contentWindow.document;
                    if (doc) docs.push(doc);
                  } catch (_) {}
                });
              } catch (_) {}
              return docs;
            }
            function queryAllDeep(root, selector) {
              var result = [];
              function walk(node) {
                if (!node) return;
                try {
                  if (node.querySelectorAll) {
                    result = result.concat(Array.prototype.slice.call(node.querySelectorAll(selector)));
                  }
                } catch (_) {}
                try {
                  var all = node.querySelectorAll ? Array.prototype.slice.call(node.querySelectorAll('*')) : [];
                  all.forEach(function (el) {
                    try {
                      if (el.shadowRoot) walk(el.shadowRoot);
                    } catch (_) {}
                  });
                } catch (_) {}
              }
              walk(root);
              return result;
            }
            function focusables(root) {
              var selector = [
                'button',
                'a[href]',
                '[role="button"]',
                '[tabindex]',
                '[onclick]',
                '[aria-label]',
                  'input[type="button"]',
                  'input[type="submit"]',
                '[class*="skip" i]',
                '[id*="skip" i]',
                '[data-skip]',
                '[data-role*="skip" i]',
                '[aria-label*="skip" i]',
                '[title*="skip" i]',
                '[class*="continue" i]',
                '[id*="continue" i]',
                '[class*="resume" i]',
                '[id*="resume" i]',
                '.btn',
                '.button',
                '.skip',
                '.skip-ad',
                '.skipad',
                '.skip-ads',
                '.ads-skip',
                '.ad-skip',
                '.continue',
                '.resume',
                '.confirm',
                '.close',
                '.ok',
                '.restart',
                '.modal button',
                '.dialog button',
                '.swal2-confirm',
                '.swal2-cancel',
                '.swal-button',
                '.jw-button-color',
                '.jw-icon',
                '.jw-display-icon-container',
                '.vjs-big-play-button',
                '.plyr__control'
              ].join(',');
              root = root || document;
              var view = root.defaultView || window;
              var nodes = queryAllDeep(root, selector)
                .filter(function (el) {
                  if (!isVisible(el)) return false;
                  var rect = el.getBoundingClientRect();
                  return rect.left < view.innerWidth &&
                    rect.right > 0 &&
                    rect.top < view.innerHeight &&
                    rect.bottom > 0;
                });
              var seen = [];
              return nodes.filter(function (el) {
                if (seen.indexOf(el) >= 0) return false;
                seen.push(el);
                return true;
              });
            }
            function centerScore(el) {
              try {
                var rect = el.getBoundingClientRect();
                var cx = rect.left + rect.width / 2;
                var cy = rect.top + rect.height / 2;
                var dx = Math.abs(cx - window.innerWidth / 2) / Math.max(1, window.innerWidth);
                var dy = Math.abs(cy - window.innerHeight / 2) / Math.max(1, window.innerHeight);
                var area = Math.min(1, (rect.width * rect.height) / Math.max(1, window.innerWidth * window.innerHeight));
                return (1 - dx) + (1 - dy) + area;
              } catch (_) {
                return 0;
              }
            }
            function preferredIndex(items) {
              var preferred = [
                /(bỏ qua quảng cáo|bo qua quang cao|skip ad|skip ads|skip)/i,
                /(xem tiếp|xem tiep|continue|resume)/i,
                /(đồng ý|dong y|ok|okay|tiếp tục|tiep tuc|confirm|close)/i,
                /(xem lại|xem lai|từ đầu|tu dau|restart|retry|thử lại|thu lai)/i,
                /(phát|play|watch)/i
              ];
              for (var p = 0; p < preferred.length; p += 1) {
                for (var i = 0; i < items.length; i += 1) {
                  if (preferred[p].test(labelOf(items[i]))) return i;
                }
              }
              if (!items.length) return -1;
              var best = 0;
              var bestScore = centerScore(items[0]);
              for (var j = 1; j < items.length; j += 1) {
                var score = centerScore(items[j]);
                if (score > bestScore) {
                  best = j;
                  bestScore = score;
                }
              }
              return best;
            }
            function setFocusIndex(index, items) {
              if (!items || !items.length) return false;
              tvFocusIndex = (index + items.length) % items.length;
              window.__cvTvFocusIndex = tvFocusIndex;
              markFocus(items[tvFocusIndex]);
              return true;
            }
            function keyForAction(action) {
              if (action === 'select') return { key: 'Enter', code: 'Enter', keyCode: 13, which: 13 };
              if (action === 'left') return { key: 'ArrowLeft', code: 'ArrowLeft', keyCode: 37, which: 37 };
              if (action === 'up') return { key: 'ArrowUp', code: 'ArrowUp', keyCode: 38, which: 38 };
              if (action === 'right') return { key: 'ArrowRight', code: 'ArrowRight', keyCode: 39, which: 39 };
              return { key: 'ArrowDown', code: 'ArrowDown', keyCode: 40, which: 40 };
            }
            function dispatchKey(target, action) {
              var data = keyForAction(action);
              ['keydown','keypress','keyup'].forEach(function (type) {
                try {
                  target.dispatchEvent(new KeyboardEvent(type, {
                    key: data.key,
                    code: data.code,
                    keyCode: data.keyCode,
                    which: data.which,
                    bubbles: true,
                    cancelable: true
                  }));
                } catch (_) {}
              });
            }
            function activate(el) {
              if (!el) return false;
              try { markFocus(el); } catch (_) {}
              ['pointerdown','mousedown','mouseup','pointerup','click'].forEach(function (type) {
                try {
                  el.dispatchEvent(new MouseEvent(type, {
                    view: window,
                    bubbles: true,
                    cancelable: true
                  }));
                } catch (_) {}
              });
              try { el.click(); } catch (_) {}
              return true;
            }
            function directPreferredAction() {
              var docs = documents();
              for (var d = 0; d < docs.length; d += 1) {
                var items = focusables(docs[d]);
                for (var i = 0; i < items.length; i += 1) {
                  if (/(bỏ qua quảng cáo|bo qua quang cao|skip[-_ ]?ad|skip[-_ ]?ads|skip quảng cáo|skip quang cao|close[-_ ]?ad|đóng quảng cáo|dong quang cao|tắt quảng cáo|tat quang cao)/i.test(labelOf(items[i]))) {
                    return activate(items[i]);
                  }
                }
              }
              return false;
            }
            window.__cvDirectPreferredAction = directPreferredAction;
            function directResumeAction() {
              if (resumeAt <= 3) return false;
              var docs = documents();
              for (var d = 0; d < docs.length; d += 1) {
                var items = focusables(docs[d]);
                for (var i = 0; i < items.length; i += 1) {
                  if (/(xem tiếp|xem tiep|continue|resume)/i.test(labelOf(items[i]))) {
                    return activate(items[i]);
                  }
                }
              }
              return false;
            }
            window.__cvDirectResumeAction = directResumeAction;
            function markFocus(el) {
              try {
                document.querySelectorAll('[data-cv-tv-focus="1"]').forEach(function (old) {
                  old.removeAttribute('data-cv-tv-focus');
                  old.style.outline = old.dataset.cvOldOutline || '';
                  old.style.boxShadow = old.dataset.cvOldBoxShadow || '';
                });
                if (!el) return;
                el.dataset.cvOldOutline = el.style.outline || '';
                el.dataset.cvOldBoxShadow = el.style.boxShadow || '';
                el.dataset.cvTvFocus = '1';
                el.style.outline = '4px solid #f6c453';
                el.style.boxShadow = '0 0 0 6px rgba(246,196,83,.28)';
                try { el.focus({ preventScroll: false }); } catch (_) { try { el.focus(); } catch (__) {} }
                try { el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'smooth' }); } catch (_) {}
              } catch (_) {}
            }
            window.__cvTvRemote = function (action) {
              try {
                var items = focusables(document);
                if (!items.length) {
                  return false;
                }
                if (tvFocusIndex < 0 || tvFocusIndex >= items.length || !isVisible(items[tvFocusIndex])) {
                  tvFocusIndex = preferredIndex(items);
                  setFocusIndex(tvFocusIndex, items);
                }
                if (action === 'right' || action === 'down') {
                  return setFocusIndex(tvFocusIndex + 1, items);
                }
                if (action === 'left' || action === 'up') {
                  return setFocusIndex(tvFocusIndex - 1, items);
                }
                if (action === 'select') {
                  var target = items[tvFocusIndex] || items[preferredIndex(items)];
                  return activate(target);
                }
              } catch (_) {}
              return false;
            };
            if (!window.__cvTvRemoteListenerInstalled) {
              window.__cvTvRemoteListenerInstalled = true;
              document.addEventListener('keydown', function (event) {
                try {
                  if (window.__cvTvDispatching) return;
                  var map = {
                    ArrowRight: 'right',
                    ArrowLeft: 'left',
                    ArrowUp: 'up',
                    ArrowDown: 'down',
                    Enter: 'select',
                    ' ': 'select'
                  };
                  var action = map[event.key] || map[event.code];
                  if (!action) return;
                  if (window.__cvTvRemote(action)) {
                    event.preventDefault();
                    event.stopPropagation();
                  }
                } catch (_) {}
              }, true);
            }
            function installSkipObserver(root) {
              try {
                var target = root.documentElement || root.body;
                if (!target || target.__cvAutoSkipObserver) return;
                var skipScheduled = false;
                target.__cvAutoSkipObserver = new MutationObserver(function () {
                  if (skipScheduled) return;
                  skipScheduled = true;
                  setTimeout(function () {
                    skipScheduled = false;
                    directPreferredAction();
                    directResumeAction();
                  }, 350);
                });
                target.__cvAutoSkipObserver.observe(target, {
                  childList: true,
                  subtree: true,
                  attributes: true,
                  attributeFilter: ['style', 'class', 'aria-label', 'title']
                });
                setTimeout(function () {
                  try {
                    target.__cvAutoSkipObserver.disconnect();
                    target.__cvAutoSkipObserver = null;
                  } catch (_) {}
                }, 70000);
              } catch (_) {}
            }
            function installViewportFix(root) {
              try {
                var doc = root || document;
                var head = doc.head || doc.documentElement;
                if (!head || doc.getElementById('__cvViewportFix')) return;
                var style = doc.createElement('style');
                style.id = '__cvViewportFix';
                style.textContent = [
                  'html,body{margin:0!important;padding:0!important;width:100vw!important;height:100vh!important;overflow:hidden!important;background:#000!important;}',
                  'body>iframe:only-child,iframe[src*="streamc"],iframe[src*="embed"]{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;border:0!important;background:#000!important;}',
                  '#player,.player,.jwplayer,.jw-wrapper,.jw-media,.jw-preview,.video-js,.plyr,.dplayer{width:100vw!important;height:100vh!important;max-width:100vw!important;max-height:100vh!important;background:#000!important;}',
                  '.jw-aspect,.jwplayer.jw-flag-aspect-mode{height:100vh!important;padding-top:0!important;}',
                  'video{width:100%!important;height:100%!important;object-fit:contain!important;background:#000!important;}'
                ].join('\\n');
                head.appendChild(style);
              } catch (_) {}
            }
            function setupVideo(v) {
              try {
                v.setAttribute('playsinline', '');
                v.setAttribute('webkit-playsinline', '');
                v.autoplay = true;
                v.preload = 'auto';
                try { v.webkitEnterFullscreen = function () {}; } catch (_) {}
                try { v.webkitEnterFullScreen = function () {}; } catch (_) {}
                if (resumeAt > 3 && !v.dataset.cvResumed) {
                  var doSeek = function () {
                    try {
                      if (isFinite(v.duration) && v.duration > 0 && resumeAt < v.duration - 5) {
                        v.currentTime = resumeAt;
                        v.dataset.cvResumed = '1';
                      }
                    } catch (_) {}
                  };
                  if (isFinite(v.duration) && v.duration > 0) { doSeek(); }
                  else { v.addEventListener('loadedmetadata', doSeek, { once: true }); }
                }
                if (v.paused && !v.dataset.cvPlayAttempted) {
                  v.dataset.cvPlayAttempted = '1';
                  var playPromise = v.play && v.play();
                  if (playPromise && playPromise.catch) {
                    playPromise.catch(function () {});
                  }
                }
              } catch (_) {}
            }
            function clickPlayControls(root) {
              if (window.__cvInitialPlayTried) return false;
              var clicked = false;
              selectors.some(function (selector) {
                try {
                  return Array.prototype.slice.call(root.querySelectorAll(selector)).some(function (el) {
                    if (!isVisible(el)) return false;
                    if (/(pause|tạm dừng|tam dung)/i.test(labelOf(el))) return false;
                    window.__cvInitialPlayTried = true;
                    try { el.click(); } catch (_) {}
                    clicked = true;
                    return true;
                  });
                } catch (_) {}
                return false;
              });
              return clicked;
            }
            function attempt() {
              tries += 1;
              try {
                installViewportFix(document);
                document.querySelectorAll('video').forEach(setupVideo);
                directPreferredAction();
                directResumeAction();
                var hasActiveVideo = Array.prototype.slice.call(document.querySelectorAll('video')).some(function (v) {
                  try { return !v.paused || v.readyState > 1; } catch (_) { return false; }
                });
                if (!window.__cvClickedInitialPlay && !hasActiveVideo) {
                  window.__cvClickedInitialPlay = clickPlayControls(document);
                }
                document.querySelectorAll('iframe').forEach(function (frame) {
                  try {
                    var doc = frame.contentDocument || frame.contentWindow.document;
                    if (doc) {
                      installViewportFix(doc);
                      doc.querySelectorAll('video').forEach(setupVideo);
                      var frameHasActiveVideo = Array.prototype.slice.call(doc.querySelectorAll('video')).some(function (v) {
                        try { return !v.paused || v.readyState > 1; } catch (_) { return false; }
                      });
                      if (!window.__cvClickedInitialPlay && !frameHasActiveVideo) {
                        window.__cvClickedInitialPlay = clickPlayControls(doc);
                      }
                      installSkipObserver(doc);
                    }
                  } catch (_) {}
                });
                ['requestFullscreen','webkitRequestFullscreen','webkitEnterFullscreen','webkitEnterFullScreen','mozRequestFullScreen','msRequestFullscreen'].forEach(function (name) {
                  try {
                    if (Element.prototype[name]) Element.prototype[name] = function () { return Promise.resolve && Promise.resolve(); };
                  } catch (_) {}
                });
              } catch (_) {}
              if (tries < 30) setTimeout(attempt, 500);
            }
            attempt();
            documents().forEach(installViewportFix);
            documents().forEach(installSkipObserver);
            setTimeout(function () {
              try {
                var items = focusables(document);
                var index = preferredIndex(items);
                if (index >= 0) {
                  tvFocusIndex = index;
                  markFocus(items[index]);
                }
              } catch (_) {}
            }, 800);
          } catch (_) {}
        })();
      ''';
    try {
      if (wc != null) {
        await wc.runJavaScript(script);
      } else {
        await wwc!.executeScript(script);
      }
    } catch (_) {}
  }

  bool _webViewScriptResultAsBool(Object? raw) {
    final text = raw?.toString().trim().toLowerCase() ?? '';
    return text == 'true' || text == '"true"' || text == '1';
  }

  Future<bool> _sendWebViewTvRemoteKey(String action) async {
    final wc = webViewController;
    final wwc = windowsWebViewController;
    if (wc == null && wwc == null) return false;
    final safeAction = action.replaceAll(RegExp(r'[^a-z]'), '');
    final script =
        "(function () { try { return !!(window.__cvTvRemote && window.__cvTvRemote('$safeAction')); } catch (_) { return false; } })();";
    try {
      if (wc != null) {
        return _webViewScriptResultAsBool(
          await wc.runJavaScriptReturningResult(script),
        );
      } else {
        return _webViewScriptResultAsBool(await wwc!.executeScript(script));
      }
    } catch (_) {
      await _injectWebViewPlaybackAssist();
      return false;
    }
  }

  Future<void> _skipWebViewAd({bool showControls = true}) async {
    final wc = webViewController;
    final wwc = windowsWebViewController;
    if (wc == null && wwc == null) return;
    const script = '''
      (function () {
        try {
          if (window.__cvDirectPreferredAction && window.__cvDirectPreferredAction()) {
            return true;
          }
          var labels = /(bỏ qua quảng cáo|bo qua quang cao|skip[-_ ]?ad|skip[-_ ]?ads|skip quảng cáo|skip quang cao|close[-_ ]?ad|đóng quảng cáo|dong quang cao|tắt quảng cáo|tat quang cao)/i;
          var selector = [
            'button', 'a[href]', '[role="button"]', '[onclick]', '[tabindex]',
            '[class*="skip" i]', '[id*="skip" i]', '[data-skip]',
            '[aria-label*="skip" i]', '[title*="skip" i]',
            '.skip', '.skip-ad', '.skipad', '.skip-ads', '.ads-skip', '.ad-skip',
            '.continue', '.resume', '.close', '.ok'
          ].join(',');
          function visible(el) {
            try {
              var r = el.getBoundingClientRect();
              var s = getComputedStyle(el);
              return r.width > 2 && r.height > 2 && s.display !== 'none' &&
                s.visibility !== 'hidden' && s.opacity !== '0';
            } catch (_) { return false; }
          }
          function label(el) {
            try {
              return [el.innerText, el.textContent, el.className, el.id,
                el.getAttribute('aria-label'), el.getAttribute('title'),
                el.getAttribute('data-title'), el.getAttribute('data-text')]
                .join(' ').toLowerCase();
            } catch (_) { return ''; }
          }
          function roots(doc) {
            var list = [doc];
            try {
              Array.prototype.slice.call(doc.querySelectorAll('*')).forEach(function (el) {
                try { if (el.shadowRoot) list.push(el.shadowRoot); } catch (_) {}
              });
            } catch (_) {}
            return list;
          }
          function activate(el) {
            try { el.scrollIntoView({ block: 'center', inline: 'center' }); } catch (_) {}
            ['pointerdown','mousedown','mouseup','pointerup','click'].forEach(function (type) {
              try { el.dispatchEvent(new MouseEvent(type, { view: window, bubbles: true, cancelable: true })); } catch (_) {}
            });
            try { el.click(); } catch (_) {}
            return true;
          }
          function scan(doc) {
            var rs = roots(doc);
            for (var r = 0; r < rs.length; r += 1) {
              var nodes = [];
              try { nodes = Array.prototype.slice.call(rs[r].querySelectorAll(selector)); } catch (_) {}
              for (var i = 0; i < nodes.length; i += 1) {
                if (visible(nodes[i]) && labels.test(label(nodes[i]))) return activate(nodes[i]);
              }
            }
            return false;
          }
          if (scan(document)) return true;
          var frames = Array.prototype.slice.call(document.querySelectorAll('iframe'));
          for (var f = 0; f < frames.length; f += 1) {
            try {
              var doc = frames[f].contentDocument || frames[f].contentWindow.document;
              if (doc && scan(doc)) return true;
            } catch (_) {}
          }
        } catch (_) {}
        return false;
      })();
    ''';
    try {
      if (wc != null) {
        await wc.runJavaScriptReturningResult(script);
      } else {
        await wwc!.executeScript(script);
      }
    } catch (_) {
      await _injectWebViewPlaybackAssist();
    }
    if (showControls) _showControls();
  }

  Future<void> _runWebViewScript(String script) async {
    final wc = webViewController;
    final wwc = windowsWebViewController;
    if (wc == null && wwc == null) return;
    try {
      if (wc != null) {
        await wc.runJavaScript(script);
      } else {
        await wwc!.executeScript(script);
      }
    } catch (_) {
      await _injectWebViewPlaybackAssist();
    }
  }

  Future<void> _controlWebViewPlayback(String action, {int seconds = 0}) async {
    final safeAction = action.replaceAll(RegExp(r'[^a-z_]'), '');
    final safeSeconds = seconds.clamp(-600, 600).toInt();
    await _runWebViewScript('''
      (function () {
        try {
          function videos(root) {
            var result = [];
            try {
              result = result.concat(Array.prototype.slice.call(root.querySelectorAll('video')));
            } catch (_) {}
            try {
              Array.prototype.slice.call(root.querySelectorAll('iframe')).forEach(function (frame) {
                try {
                  var doc = frame.contentDocument || frame.contentWindow.document;
                  if (doc) result = result.concat(videos(doc));
                } catch (_) {}
              });
            } catch (_) {}
            return result;
          }
          function firstVideo() {
            var list = videos(document).filter(function (v) {
              try { return isFinite(v.duration) || !v.paused || v.readyState > 0; } catch (_) { return false; }
            });
            return list[0] || null;
          }
          function clickPlaybackButton() {
            var selectors = [
              '.jw-icon-playback',
              '.jw-display-icon-container',
              '.jwplayer .jw-display-icon-display',
              '.vjs-play-control',
              '.vjs-big-play-button',
              '.plyr__control[data-plyr="play"]',
              'button[aria-label*="Play"]',
              'button[aria-label*="Pause"]',
              'button[title*="Play"]',
              'button[title*="Pause"]'
            ];
            for (var i = 0; i < selectors.length; i += 1) {
              var items = Array.prototype.slice.call(document.querySelectorAll(selectors[i]));
              for (var j = 0; j < items.length; j += 1) {
                try {
                  var rect = items[j].getBoundingClientRect();
                  if (rect.width > 2 && rect.height > 2) {
                    items[j].click();
                    return true;
                  }
                } catch (_) {}
              }
            }
            return false;
          }
          var action = '$safeAction';
          var v = firstVideo();
          if (action === 'toggle') {
            if (v) {
              if (v.paused) { try { v.play(); } catch (_) {} }
              else { try { v.pause(); } catch (_) {} }
              return true;
            }
            return clickPlaybackButton();
          }
          if (action === 'seek') {
            if (v && isFinite(v.duration) && v.duration > 0) {
              var next = Math.max(0, Math.min(v.duration, (v.currentTime || 0) + $safeSeconds));
              v.currentTime = next;
              return true;
            }
            try {
              var key = $safeSeconds >= 0 ? 'ArrowRight' : 'ArrowLeft';
              ['keydown','keypress','keyup'].forEach(function (type) {
                document.dispatchEvent(new KeyboardEvent(type, {
                  key: key,
                  code: key,
                  keyCode: key === 'ArrowRight' ? 39 : 37,
                  which: key === 'ArrowRight' ? 39 : 37,
                  bubbles: true,
                  cancelable: true
                }));
              });
            } catch (_) {}
          }
        } catch (_) {}
        return false;
      })();
    ''');
    if (action == 'toggle') {
      await _saveWebView();
    } else if (action == 'seek') {
      await _saveWebView();
    }
  }

  Future<void> _openWebViewSource(PlaybackSourceCandidate source) async {
    final url = source.webViewUrl;
    if (url == null || url.isEmpty) return;
    if (!kIsWeb && Platform.isWindows) {
      final controller = windows_webview.WebviewController();
      await controller.initialize();
      await controller.setBackgroundColor(Colors.black);
      await controller.setPopupWindowPolicy(
        windows_webview.WebviewPopupWindowPolicy.deny,
      );
      await controller.loadUrl(url);
      currentServer = source.server;
      currentEpisode = source.episode;
      currentServerIndex = source.serverIndex;
      _loadIntroSkipSegments();
      activePlayableUrls = const [];
      activePlayableUrlIndex = 0;
      webViewController = null;
      await windowsWebViewController?.dispose();
      windowsWebViewController = controller;
      activeWebViewUrl = url;
      playbackNotice = null;
      error = null;
      saveTimer?.cancel();
      saveTimer = Timer.periodic(const Duration(seconds: 20), (_) => _save());
      _trackPlaybackEvent('webview_windows_start');
      if (mounted) setState(() {});
      _scheduleControlsHide();
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 700), () async {
          await _injectWebViewPlaybackAssist();
          await _skipWebViewAd(showControls: false);
        }),
      );
      for (final delay in const [2, 4, 6, 9, 12, 16, 22, 30, 45, 60]) {
        unawaited(
          Future<void>.delayed(
            Duration(seconds: delay),
            () => _skipWebViewAd(showControls: false),
          ),
        );
      }
      return;
    }
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }
    final controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 13; CineViet) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final requested = Uri.tryParse(request.url);
            final initial = Uri.tryParse(url);
            final host = requested?.host.toLowerCase() ?? '';
            final initialHost = initial?.host.toLowerCase() ?? '';
            final isTrustedPlayerFrame =
                host == initialHost ||
                host.endsWith('.streamc.xyz') ||
                host == 'player.phimapi.com';
            if (request.isMainFrame && !isTrustedPlayerFrame) {
              // Chặn popup/redirect quảng cáo chiếm toàn màn hình. Tài nguyên phụ
              // (JS/CDN/ads iframe) vẫn để trang tự xử lý để player StreamC chạy.
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (_) {
            // StreamC/JWPlayer có fullscreen HTML riêng; khi vào fullscreen đó
            // Flutter không còn vẽ được nút back của app. Giữ video inline để
            // nút back native overlay bên dưới luôn hoạt động.
            unawaited(_injectWebViewPlaybackAssist());
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            lastPlaybackError = '${error.errorCode}: ${error.description}';
            _trackPlaybackEvent(
              'webview_error',
              errorCode: '${error.errorCode}',
              errorMessage: error.description,
            );
          },
        ),
      )
      ..loadRequest(
        Uri.parse(url),
        headers: const {
          'Referer': 'https://cineviet.live/',
          'Origin': 'https://cineviet.live',
        },
      );
    if (controller.platform is AndroidWebViewController) {
      await (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
    currentServer = source.server;
    currentEpisode = source.episode;
    currentServerIndex = source.serverIndex;
    _loadIntroSkipSegments();
    activePlayableUrls = const [];
    activePlayableUrlIndex = 0;
    webViewController = controller;
    activeWebViewUrl = url;
    playbackNotice = null;
    error = null;
    // WebView không có controller native nên cần timer riêng để lưu "Xem tiếp".
    saveTimer?.cancel();
    saveTimer = Timer.periodic(const Duration(seconds: 20), (_) => _save());
    _trackPlaybackEvent('webview_start');
    if (mounted) setState(() {});
    if (isTvBuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focusNode.requestFocus();
      });
    }
    _scheduleControlsHide();
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 900), () async {
        await _injectWebViewPlaybackAssist();
        await _skipWebViewAd(showControls: false);
      }),
    );
    for (final delay in const [2, 4, 6, 9, 12, 16, 22, 30, 45, 60]) {
      unawaited(
        Future<void>.delayed(
          Duration(seconds: delay),
          () => _skipWebViewAd(showControls: false),
        ),
      );
    }
  }

  Future<void> _init({int startUrlIndex = 0, Duration? startAt}) async {
    if (playerDisposed || leavingPlayer) return;
    Object? lastError;
    if (mounted) {
      setState(() {
        error = null;
        playbackNotice = startUrlIndex > 0
            ? 'Đang thử nguồn dự phòng...'
            : 'Đang tải nguồn phát...';
      });
    }
    saveTimer?.cancel();
    controller?.removeListener(_handlePlayerTick);
    await controller?.dispose();
    controller = null;
    webViewController = null;
    await windowsWebViewController?.dispose();
    windowsWebViewController = null;
    activeWebViewUrl = null;
    if (currentEpisode.linkM3u8.isEmpty &&
        currentEpisode.linkEmbed.isNotEmpty) {
      final source = _currentPlaybackSources().firstWhere(
        (item) =>
            item.serverIndex == currentServerIndex && item.webViewUrl != null,
        orElse: () => const PlaybackSourceCandidate(
          server: EpisodeServer(name: '', items: []),
          episode: EpisodeItem(name: ''),
          serverIndex: -1,
          qualityLabel: '',
          qualityRank: 0,
          sourceLabel: '',
          urls: [],
        ),
      );
      if (source.serverIndex >= 0) {
        await _openWebViewSource(source);
        return;
      }
    }
    final offlinePath = widget.offlineManifestPath?.trim() ?? '';
    if (offlinePath.isNotEmpty) {
      try {
        final selectedLocalAudio = _selectedAudioSource?.url.trim() ?? '';
        final playbackPath =
            selectedLocalAudio.startsWith('/') &&
                await File(selectedLocalAudio).exists()
            ? selectedLocalAudio
            : offlinePath;
        final localFile = File(playbackPath);
        if (!await localFile.exists()) {
          throw Exception('Tệp tải xuống không còn tồn tại');
        }
        final VideoPlayerController next;
        if (Platform.isIOS || Platform.isWindows) {
          final localUrl = await _serveOfflineMedia(localFile);
          next = VideoPlayerController.networkUrl(
            localUrl,
            formatHint: VideoFormat.hls,
            closedCaptionFile: _closedCaptionFileForSelectedTracks(),
          );
        } else {
          next = VideoPlayerController.file(
            localFile,
            closedCaptionFile: _closedCaptionFileForSelectedTracks(),
          );
        }
        controller = next;
        await next.initialize().timeout(const Duration(seconds: 45));
        if (playerDisposed || leavingPlayer || !mounted) {
          await next.dispose();
          if (identical(controller, next)) controller = null;
          return;
        }
        await next.setPlaybackSpeed(playbackSpeed);
        await next.setVolume(usesPlayerVolume ? appVolume : 1.0);
        final resume = _initialResumeForCurrentEpisode();
        if (resume != null && resume.inSeconds > 3) await next.seekTo(resume);
        await next.play();
        next.addListener(_handlePlayerTick);
        saveTimer = Timer.periodic(const Duration(seconds: 20), (_) => _save());
        playbackNotice = null;
        if (mounted) setState(() {});
        return;
      } catch (localError) {
        if (mounted) {
          setState(() {
            error = 'Không mở được bản tải xuống: $localError';
            playbackNotice = null;
          });
        }
        return;
      }
    }
    activePlayableUrls = _playbackUrlCandidates();
    if (activePlayableUrls.isEmpty) {
      // Link trực tiếp của server đang chọn không phát được native → thử
      // WebView fallback (StreamC/NguồnC) của chính tập đang xem.
      final webViewSource = _currentPlaybackSources().firstWhere(
        (source) => source.webViewUrl != null,
        orElse: () => const PlaybackSourceCandidate(
          server: EpisodeServer(name: '', items: []),
          episode: EpisodeItem(
            name: '',
            filename: '',
            linkM3u8: '',
            linkEmbed: '',
          ),
          serverIndex: -1,
          qualityLabel: '',
          qualityRank: 0,
          sourceLabel: '',
          urls: [],
        ),
      );
      if (webViewSource.serverIndex >= 0 && webViewSource.webViewUrl != null) {
        await _openWebViewSource(webViewSource);
        return;
      }
      lastError = 'source_empty';
      _trackPlaybackEvent(
        'source_empty',
        errorCode: 'no_playable_source',
        errorMessage:
            'No playable URL for ${currentServer.displayName} / ${currentEpisode.displayName}',
      );
    }
    for (
      var index = startUrlIndex.clamp(0, activePlayableUrls.length).toInt();
      index < activePlayableUrls.length;
      index++
    ) {
      final candidate = activePlayableUrls[index];
      final url = candidate.url;
      activePlayableUrlIndex = index;
      try {
        final parsed = Uri.tryParse(url);
        if (parsed == null || !parsed.hasScheme) {
          lastError = 'Invalid playback URL';
          _trackPlaybackEvent(
            'invalid_url',
            errorCode: 'invalid_playback_url',
            errorMessage: url.length > 300 ? url.substring(0, 300) : url,
          );
          continue;
        }
        final captionFile =
            _isSelectedEpisodeSource(
              candidate.source.server,
              candidate.source.episode,
            )
            ? _closedCaptionFileForSelectedTracks()
            : null;
        final isHls =
            parsed.path.toLowerCase().contains('.m3u8') ||
            parsed.path.contains('/stream/vicdn/manifest');
        final next = VideoPlayerController.networkUrl(
          parsed,
          formatHint: isHls ? VideoFormat.hls : null,
          closedCaptionFile: captionFile,
        );
        controller = next;
        await next.initialize().timeout(const Duration(seconds: 18));
        if (playerDisposed || leavingPlayer || !mounted) {
          await next.dispose();
          if (identical(controller, next)) controller = null;
          return;
        }
        await next.setPlaybackSpeed(playbackSpeed);
        await next.setVolume(usesPlayerVolume ? appVolume : 1.0);
        if (isWatchTogether && !isWatchHost && watchRoomState != null) {
          final target = Duration(
            milliseconds: (watchRoomState!.currentTime * 1000).round(),
          );
          if (target > Duration.zero) await next.seekTo(target);
        }
        final resume = _initialResumeForCurrentEpisode();
        final recoveryPosition = startAt ?? lastGoodPosition;
        if (!isWatchTogether &&
            recoveryPosition != null &&
            recoveryPosition.inSeconds > 3) {
          await next.seekTo(recoveryPosition);
        } else if (!isWatchTogether && resume != null && resume.inSeconds > 3) {
          await next.seekTo(resume);
        }
        if (isWatchTogether && !isWatchHost && watchRoomState != null) {
          if (watchRoomState!.playing) {
            await next.play();
          } else {
            await next.pause();
          }
        } else {
          await next.play();
        }
        currentServer = candidate.source.server;
        currentEpisode = candidate.source.episode;
        currentServerIndex = candidate.source.serverIndex;
        _loadIntroSkipSegments();
        recoveringPlayback = false;
        next.addListener(_handlePlayerTick);
        saveTimer = Timer.periodic(const Duration(seconds: 20), (_) => _save());
        _scheduleControlsHide();
        _trackPlaybackEvent('playback_start');
        playbackNotice = null;
        if (mounted) setState(() {});
        if (isTvBuild) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !controls || controlsLocked) return;
            playButtonFocusNode.requestFocus();
          });
        }
        return;
      } on TimeoutException catch (e) {
        lastError = e;
        _trackPlaybackEvent(
          'init_timeout',
          errorCode: 'player_init_timeout',
          errorMessage: e.message ?? '$e',
        );
        controller?.removeListener(_handlePlayerTick);
        await controller?.dispose();
        controller = null;
      } catch (e) {
        lastError = e;
        _trackPlaybackEvent(
          'init_error',
          errorCode: e.runtimeType.toString(),
          errorMessage: '$e',
        );
        controller?.removeListener(_handlePlayerTick);
        await controller?.dispose();
        controller = null;
      }
    }
    final webViewSource = _currentPlaybackSources().firstWhere(
      (source) => source.webViewUrl != null,
      orElse: () => const PlaybackSourceCandidate(
        server: EpisodeServer(name: '', items: []),
        episode: EpisodeItem(
          name: '',
          filename: '',
          linkM3u8: '',
          linkEmbed: '',
        ),
        serverIndex: -1,
        qualityLabel: '',
        qualityRank: 0,
        sourceLabel: '',
        urls: [],
      ),
    );
    if (webViewSource.serverIndex >= 0 && webViewSource.webViewUrl != null) {
      _trackPlaybackEvent(
        'auto_recover_source',
        errorCode: 'webview_fallback',
        errorMessage:
            'Native sources failed; opening ${webViewSource.displayName}',
      );
      await _openWebViewSource(webViewSource);
      return;
    }
    debugPrint('CineViet player error: $lastError');
    _trackPlaybackEvent(
      startUrlIndex > 0 || startAt != null ? 'recover_failed' : 'init_failed',
      errorCode: lastError.runtimeType.toString(),
      errorMessage: '$lastError',
    );
    if (mounted) {
      setState(() {
        playbackNotice = null;
        lastPlaybackError = '$lastError';
        error = 'Không mở được nguồn phát này. Hãy thử nguồn hoặc tập khác.';
      });
    }
  }

  void _handlePlayerTick() {
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    lastGoodPosition = c.value.position;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (c.value.position.inSeconds >= 3 &&
        (!savedCurrentEpisodeProgress || now - lastHistorySaveAtMs >= 5000)) {
      savedCurrentEpisodeProgress = true;
      lastHistorySaveAtMs = now;
      unawaited(_save());
    }
    if (c.value.hasError) {
      unawaited(_recoverPlayback(c.value.errorDescription));
      return;
    }
    final remaining = _autoNextRemainingSeconds;
    if (_shouldShowAutoNextPrompt && remaining != lastAutoNextPromptSecond) {
      lastAutoNextPromptSecond = remaining;
      if (mounted) setState(() {});
    }
    _maybeAutoNext();
  }

  Future<void> _recoverPlayback(String? reason) async {
    if (recoveringPlayback || leavingPlayer || !mounted) return;
    recoveringPlayback = true;
    runtimeRecoveryAttempts += 1;
    final position = controller?.value.position ?? lastGoodPosition;
    final message = reason ?? 'unknown';
    lastPlaybackError = message;
    _trackPlaybackEvent(
      'runtime_error',
      errorCode: 'video_player_runtime_error',
      errorMessage: message,
    );
    debugPrint(
      'CineViet player runtime error: $message '
      '(attempt $runtimeRecoveryAttempts)',
    );
    if (runtimeRecoveryAttempts <= 3 &&
        activePlayableUrlIndex + 1 < activePlayableUrls.length) {
      if (mounted) {
        setState(() => playbackNotice = 'Nguồn lỗi, đang thử nguồn khác...');
      }
      _trackPlaybackEvent('auto_recover_source');
      await _init(startUrlIndex: activePlayableUrlIndex + 1, startAt: position);
      if (controller != null || activeWebViewUrl != null) return;
    }
    final webViewSource = _currentPlaybackSources().firstWhere(
      (source) => source.webViewUrl != null,
      orElse: () => const PlaybackSourceCandidate(
        server: EpisodeServer(name: '', items: []),
        episode: EpisodeItem(name: ''),
        serverIndex: -1,
        qualityLabel: '',
        qualityRank: 0,
        sourceLabel: '',
        urls: [],
      ),
    );
    if (webViewSource.serverIndex >= 0 && webViewSource.webViewUrl != null) {
      _trackPlaybackEvent(
        'auto_recover_source',
        errorCode: 'runtime_webview_fallback',
        errorMessage: message,
      );
      await _openWebViewSource(webViewSource);
      recoveringPlayback = false;
      return;
    }
    if (mounted) {
      _trackPlaybackEvent(
        'recover_failed',
        errorCode: 'source_recovery_exhausted',
        errorMessage: message,
      );
      setState(() {
        playbackNotice = null;
        error =
            'Nguồn phát bị lỗi trên thiết bị này. Hãy thử nguồn hoặc tập khác.';
      });
      _showControls();
    }
    recoveringPlayback = false;
  }

  Future<void> _save() async {
    if (savingProgress) return;
    savingProgress = true;
    try {
      await _saveUnlocked();
    } finally {
      savingProgress = false;
    }
  }

  Future<void> _saveUnlocked() async {
    final c = controller;
    if (c == null || !c.value.isInitialized) {
      // Nguồn WebView (NguồnC/StreamC) không có controller native -> đọc tiến độ
      // trực tiếp từ thẻ <video> trong trang qua JS để vẫn lưu "Xem tiếp".
      if (activeWebViewUrl != null) await _saveWebView();
      return;
    }
    _emitWatchSync();
    final item = WatchItem(
      movieId: widget.movie.id,
      slug: widget.movie.slug,
      title: widget.movie.title,
      poster: widget.movie.posterUrl,
      backdrop: widget.movie.backdropUrl,
      serverName: currentServer.name,
      serverIndex: currentServerIndex,
      episodeName: currentEpisode.name,
      streamUrl: currentEpisode.playUrl,
      positionMs: c.value.position.inMilliseconds,
      durationMs: c.value.duration.inMilliseconds,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await LocalHistory.upsert(item);
    if (Api.instance.hasAuthToken) {
      await widget.repo.syncWatch(item);
    }
  }

  // Lưu tiến độ khi phát bằng WebView (NguồnC/StreamC). Đọc currentTime/duration
  // của thẻ <video> đầu tiên; nếu chưa phát (<3s) hoặc chưa có video thì bỏ qua.
  Future<void> _saveWebView() async {
    final wc = webViewController;
    final wwc = windowsWebViewController;
    if (wc == null && wwc == null) return;
    double posSec = 0;
    double durSec = 0;
    try {
      final script = '''
        (function () {
          try {
            function videos(root) {
              var result = [];
              try {
                result = result.concat(Array.prototype.slice.call(root.querySelectorAll('video')));
              } catch (_) {}
              try {
                Array.prototype.slice.call(root.querySelectorAll('iframe')).forEach(function (frame) {
                  try {
                    var doc = frame.contentDocument || frame.contentWindow.document;
                    if (doc) result = result.concat(videos(doc));
                  } catch (_) {}
                });
              } catch (_) {}
              return result;
            }
            var v = videos(document).filter(function (item) {
              try { return isFinite(item.currentTime) && (isFinite(item.duration) || item.readyState > 0); }
              catch (_) { return false; }
            }).sort(function (a, b) {
              try { return (b.currentTime || 0) - (a.currentTime || 0); }
              catch (_) { return 0; }
            })[0];
            if (!v) return '0|0';
            var ct = isFinite(v.currentTime) ? v.currentTime : 0;
            var d = isFinite(v.duration) ? v.duration : 0;
            return ct + '|' + d;
          } catch (e) { return '0|0'; }
        })();
      ''';
      final raw = wc != null
          ? await wc.runJavaScriptReturningResult(script)
          : await wwc!.executeScript(script);
      final text = raw.toString().replaceAll('"', '');
      final parts = text.split('|');
      if (parts.length == 2) {
        posSec = double.tryParse(parts[0]) ?? 0;
        durSec = double.tryParse(parts[1]) ?? 0;
      }
    } catch (_) {
      return;
    }
    if (posSec < 3) return;
    _emitWatchSync();
    final item = WatchItem(
      movieId: widget.movie.id,
      slug: widget.movie.slug,
      title: widget.movie.title,
      poster: widget.movie.posterUrl,
      backdrop: widget.movie.backdropUrl,
      serverName: currentServer.name,
      serverIndex: currentServerIndex,
      episodeName: currentEpisode.name,
      streamUrl: currentEpisode.playUrl,
      positionMs: (posSec * 1000).round(),
      durationMs: (durSec * 1000).round(),
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await LocalHistory.upsert(item);
    if (Api.instance.hasAuthToken) {
      await widget.repo.syncWatch(item);
    }
  }

  void _scheduleControlsHide() {
    controlsTimer?.cancel();
    controlsTimer = Timer(const Duration(seconds: 5), () {
      if (mounted &&
          (controller?.value.isPlaying == true || activeWebViewUrl != null) &&
          !controlsLocked) {
        setState(() => controls = false);
      }
    });
  }

  void _showControls() {
    if (controlsLocked) return;
    setState(() => controls = true);
    if (isTvBuild) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !controls || controlsLocked) return;
        final primaryFocus = FocusManager.instance.primaryFocus;
        if (primaryFocus == null || primaryFocus == focusNode) {
          if (activeWebViewUrl != null) {
            webViewPlayFocusNode.requestFocus();
          } else {
            playButtonFocusNode.requestFocus();
          }
        }
      });
    }
    _scheduleControlsHide();
  }

  void _moveTvOverlayFocus({required bool forward}) {
    _showControls();
    if (!isTvBuild) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final primaryFocus = FocusManager.instance.primaryFocus;
      if (primaryFocus == null || primaryFocus == focusNode) {
        playButtonFocusNode.requestFocus();
        return;
      }
      final scope = overlayFocusScopeNode;
      if (forward) {
        scope.nextFocus();
      } else {
        scope.previousFocus();
      }
    });
  }

  void _toggleControlsLock() {
    setState(() {
      controlsLocked = !controlsLocked;
      controls = !controlsLocked;
      dragStart = null;
      dragStartPosition = null;
      dragStartBrightness = null;
      dragStartVolume = null;
      pendingSeekPosition = null;
      dragMode = null;
      gestureMode = null;
      gestureValue = null;
      pendingBrightness = null;
      pendingVolume = null;
    });
    levelApplyTimer?.cancel();
    gestureHintTimer?.cancel();
    if (controlsLocked) {
      controlsTimer?.cancel();
    } else {
      _scheduleControlsHide();
    }
  }

  Duration _clampPosition(Duration value, Duration duration) {
    if (value < Duration.zero) return Duration.zero;
    if (duration > Duration.zero && value > duration) return duration;
    return value;
  }

  Future<void> _seekBy(Duration offset, {bool showControls = true}) async {
    if (activeWebViewUrl != null) {
      await _controlWebViewPlayback('seek', seconds: offset.inSeconds);
      return;
    }
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    await c.seekTo(_clampPosition(c.value.position + offset, c.value.duration));
    _emitWatchSync(force: true);
    unawaited(_save());
    if (showControls) _showControls();
  }

  String _introSkipLookupKey() {
    final episodeNo = episodeNumber(currentEpisode.displayName);
    final seasonNo = widget.movie.partNumber ?? 1;
    return '${widget.movie.id}:$seasonNo:$episodeNo:${currentEpisode.name}';
  }

  void _loadIntroSkipSegments() {
    final lookupKey = _introSkipLookupKey();
    if (introSkipDataKey == lookupKey) return;
    introSkipDataKey = lookupKey;
    introSkipData = null;
    skippedIntroDbSegments.clear();
    if (!widget.movie.isSeriesLike || widget.movie.id <= 0) return;
    final episodeNo = episodeNumber(currentEpisode.displayName);
    if (episodeNo <= 0) return;
    unawaited(() async {
      final data = await widget.repo.introSkipSegments(
        movie: widget.movie,
        episode: currentEpisode,
      );
      if (!mounted || introSkipDataKey != lookupKey) return;
      setState(() => introSkipData = data);
    }());
  }

  IntroSkipSegment? _activeIntroSkipSegment(VideoPlayerController? c) {
    if (activeWebViewUrl != null || c == null || !c.value.isInitialized) {
      return null;
    }
    final data = introSkipData;
    if (data == null) return null;
    final position = c.value.position;
    final duration = c.value.duration;
    for (final segment in data.segments) {
      if (skippedIntroDbSegments.contains(segment.key)) continue;
      if (duration > Duration.zero && segment.start >= duration) continue;
      final visibleFrom = segment.start - const Duration(seconds: 2);
      final from = visibleFrom < Duration.zero ? Duration.zero : visibleFrom;
      if (position >= from && position < segment.end) return segment;
    }
    return null;
  }

  bool _shouldShowFallbackIntroSkip(VideoPlayerController? c) {
    if (introSkipData?.hasSegments == true) return false;
    if (introSkipped || c == null || !c.value.isInitialized) return false;
    if (activeWebViewUrl != null) return false;
    if (c.value.duration.inSeconds <= introSkipSeconds) return false;
    final seconds = c.value.position.inSeconds;
    return seconds >= 1 && seconds < introSkipSeconds;
  }

  Future<void> _skipIntro() async {
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    final segment = _activeIntroSkipSegment(c);
    final target = segment?.end ?? const Duration(seconds: introSkipSeconds);
    if (segment == null) {
      introSkipped = true;
    } else {
      skippedIntroDbSegments.add(segment.key);
    }
    await c.seekTo(_clampPosition(target, c.value.duration));
    _emitWatchSync(force: true);
    unawaited(_save());
    if (mounted) setState(() {});
  }

  void _clearGestureHintSoon() {
    gestureHintTimer?.cancel();
    gestureHintTimer = Timer(const Duration(milliseconds: 620), () {
      if (!mounted) return;
      setState(() {
        gestureMode = null;
        gestureValue = null;
      });
    });
  }

  void _showSeekHint({required bool forward}) {
    gestureHintTimer?.cancel();
    HapticFeedback.selectionClick();
    setState(() {
      controls = false;
      gestureMode = forward ? 'forward' : 'back';
      gestureValue = 1.0;
    });
    _clearGestureHintSoon();
  }

  int get _autoNextRemainingSeconds {
    final c = controller;
    if (c == null || !c.value.isInitialized || c.value.hasError) return 0;
    final duration = c.value.duration;
    if (duration.inSeconds <= 20) return 0;
    final remaining = duration - c.value.position;
    return remaining.inSeconds.clamp(0, 999).toInt();
  }

  bool get _shouldShowAutoNextPrompt {
    final index = _currentEpisodeIndex;
    return autoNextEpisode &&
        !autoNextCancelledForEpisode &&
        index >= 0 &&
        index < currentServer.items.length - 1 &&
        _autoNextRemainingSeconds > 0 &&
        _autoNextRemainingSeconds <= 18;
  }

  void _cancelAutoNextForEpisode() {
    setState(() => autoNextCancelledForEpisode = true);
    _showControls();
  }

  void _maybeAutoNext() {
    final c = controller;
    if (!autoNextEpisode ||
        autoNextCancelledForEpisode ||
        c == null ||
        !c.value.isInitialized ||
        c.value.hasError) {
      return;
    }
    final duration = c.value.duration;
    if (duration.inSeconds <= 20) return;
    final remaining = duration - c.value.position;
    if (remaining.inSeconds <= 2 && !c.value.isPlaying) {
      _playSibling(1);
    }
  }

  String _formatSpeed(double value) => value == 1.0
      ? '1x'
      : '${value.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '').replaceFirst(RegExp(r'\\.0$'), '')}x';

  Future<void> _setPlaybackSpeed(double value) async {
    playbackSpeed = value;
    try {
      await controller?.setPlaybackSpeed(value);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _selectAudioSource(String key) async {
    final position = controller?.value.position ?? lastGoodPosition;
    setState(() {
      selectedAudioKey = key;
      unawaited(_savePlaybackTrackPreference());
      controls = true;
      playbackNotice = 'Đang đổi audio...';
    });
    runtimeRecoveryAttempts = 0;
    await _init(startAt: position);
  }

  Future<void> _selectSubtitleTrack(String? lang) async {
    selectedSubtitleLang = lang ?? 'off';
    unawaited(_savePlaybackTrackPreference());
    try {
      await controller?.setClosedCaptionFile(
        _closedCaptionFileForSelectedTracks(),
      );
    } catch (e) {
      lastPlaybackError = '$e';
      if (mounted) showSnack(context, 'Không tải được phụ đề');
    }
    if (mounted) setState(() {});
  }

  Future<void> _syncDeviceLevels() async {
    if (!supportsTouchLevels) return;
    try {
      final brightness = await brightnessChannel.invokeMethod<double>('get');
      if (brightness != null && mounted) {
        setState(() => screenBrightness = brightness.clamp(0.0, 1.0));
      }
    } catch (_) {}
    try {
      final volume = await brightnessChannel.invokeMethod<double>('getVolume');
      if (volume != null && mounted) {
        appVolume = volume.clamp(0.0, 1.0);
        await controller?.setVolume(usesPlayerVolume ? appVolume : 1.0);
        setState(() {});
      }
    } catch (_) {}
  }

  Future<double?> _setBrightness(double value) async {
    final next = value.clamp(0.0, 1.0);
    try {
      final actual = await brightnessChannel.invokeMethod<double>('set', {
        'value': next,
      });
      return actual?.clamp(0.0, 1.0);
    } catch (_) {}
    return null;
  }

  Future<void> _requestAndroidBrightnessSyncPermissionIfNeeded() async {
    if (!Platform.isAndroid || androidBrightnessSettingsPrompted) return;
    try {
      final canWrite = await brightnessChannel.invokeMethod<bool>(
        'canWriteSettings',
      );
      if (canWrite == true) return;
      androidBrightnessSettingsPrompted = true;
      await brightnessChannel.invokeMethod<bool>('requestWriteSettings');
    } catch (_) {}
  }

  Future<double?> _setVolume(double value, {bool showSystemUi = false}) async {
    final next = value.clamp(0.0, 1.0);
    try {
      final actual = await brightnessChannel.invokeMethod<double>('setVolume', {
        'value': next,
        'showUi': showSystemUi,
      });
      return actual?.clamp(0.0, 1.0);
    } catch (_) {}
    return null;
  }

  void _scheduleLevelApply() {
    if (levelApplyTimer?.isActive ?? false) return;
    levelApplyTimer = Timer(
      const Duration(milliseconds: 45),
      _applyPendingLevels,
    );
  }

  Future<void> _applyPendingLevels({bool settle = false}) async {
    levelApplyTimer?.cancel();
    levelApplyTimer = null;

    final brightness = pendingBrightness;
    final volume = pendingVolume;
    pendingBrightness = null;
    pendingVolume = null;

    if (brightness != null) {
      if (settle) {
        unawaited(_requestAndroidBrightnessSyncPermissionIfNeeded());
      }
      final actual = await _setBrightness(brightness);
      if (settle && mounted && actual != null) {
        setState(() {
          screenBrightness = actual;
          if (gestureMode == 'brightness') gestureValue = actual;
        });
      }
    }

    if (volume != null) {
      final actual = await _setVolume(volume, showSystemUi: settle);
      try {
        await controller?.setVolume(usesPlayerVolume ? volume : 1.0);
      } catch (_) {}
      if (settle && mounted) {
        final settled = (usesPlayerVolume ? volume : actual ?? volume).clamp(
          0.0,
          1.0,
        );
        setState(() {
          appVolume = settled;
          if (gestureMode == 'volume') gestureValue = settled;
        });
        try {
          await controller?.setVolume(usesPlayerVolume ? settled : 1.0);
        } catch (_) {}
      }
    }
  }

  void _togglePlay() {
    if (activeWebViewUrl != null) {
      unawaited(_controlWebViewPlayback('toggle'));
      _showControls();
      return;
    }
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    c.value.isPlaying ? c.pause() : c.play();
    _emitWatchSync(force: true);
    unawaited(_save());
    _showControls();
  }

  Future<void> _setPlayerVolume(double value, {bool showHint = true}) async {
    final next = value.clamp(0.0, 1.0);
    appVolume = next;
    pendingVolume = next;
    try {
      await controller?.setVolume(usesPlayerVolume ? next : 1.0);
    } catch (_) {}
    if (showHint && mounted) {
      setState(() {
        gestureMode = 'volume';
        gestureValue = next;
      });
    }
    unawaited(_applyPendingLevels(settle: true));
    _showControls();
  }

  void _toggleMute() {
    _setPlayerVolume(appVolume > .02 ? 0 : 1);
  }

  void _nudgeVolume(double delta) {
    _setPlayerVolume(appVolume + delta);
  }

  void _bindWatchTogetherSocket() {
    final socket = MovieRepository.activeWatchRoomSocket;
    if (!isWatchTogether || socket == null) return;
    socket.off('room-state');
    socket.off('chat-message');
    socket.on('room-state', (data) {
      if (!mounted || data is! Map) return;
      final map = Map<String, dynamic>.from(data);
      final state = WatchTogetherState.fromJson(map);
      lastWatchRoomFrom = cleanText(map['_from']);
      setState(() {
        watchRoomState = state;
        watchMessages
          ..clear()
          ..addAll(state.messages);
      });
      _applyWatchRoomSync(state);
    });
    socket.on('chat-message', (data) {
      if (!mounted || data is! Map) return;
      final message = WatchTogetherMessage.fromJson(
        Map<String, dynamic>.from(data),
      );
      setState(() {
        final exists = watchMessages.any((item) => item.id == message.id);
        if (!exists) watchMessages.add(message);
      });
    });
  }

  Future<void> _applyWatchRoomSync(WatchTogetherState state) async {
    if (!isWatchTogether || isWatchHost) return;
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    final from = lastWatchRoomFrom;
    final activeId = MovieRepository.activeWatchRoomSocketId;
    if (from != null && activeId != null && from == activeId) return;
    final target = Duration(milliseconds: (state.currentTime * 1000).round());
    final diffMs = (target - c.value.position).inMilliseconds.abs();
    applyingWatchSync = true;
    try {
      if (diffMs > 3000) await c.seekTo(target);
      if (state.playing && !c.value.isPlaying) {
        await c.play();
      } else if (!state.playing && c.value.isPlaying) {
        await c.pause();
      }
    } catch (_) {
    } finally {
      applyingWatchSync = false;
    }
  }

  void _emitWatchSync({bool force = false}) {
    if (!isWatchTogether || !isWatchHost || applyingWatchSync) return;
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - lastWatchSyncSentAt < 1500) return;
    lastWatchSyncSentAt = now;
    widget.repo.syncWatchRoomState(
      currentTime: c.value.position.inMilliseconds / 1000,
      playing: c.value.isPlaying,
    );
  }

  void _sendWatchMessage() {
    final text = watchChatController.text.trim();
    if (text.isEmpty) return;
    widget.repo.sendWatchRoomMessage(text);
    watchChatController.clear();
    _showControls();
  }

  Future<void> _closeWatchRoomIfNeeded() async {
    if (!isWatchTogether) return;
    await widget.repo.closeWatchRoom(forceDelete: isWatchHost);
  }

  void _stopPlaybackNow() {
    final c = controller;
    if (c == null) return;
    try {
      c.pause();
    } catch (_) {}
    try {
      c.setVolume(0);
    } catch (_) {}
  }

  Future<void> _disposePlaybackNow() async {
    final c = controller;
    if (c == null) return;
    controller = null;
    c.removeListener(_handlePlayerTick);
    try {
      await c.pause();
    } catch (_) {}
    try {
      await c.setVolume(0);
    } catch (_) {}
    try {
      await c.dispose();
    } catch (_) {}
  }

  Future<void> _stopWebViewNow() async {
    final wc = webViewController;
    final wwc = windowsWebViewController;
    if (wc == null && wwc == null) return;
    const script = '''
      (function () {
        try {
          document.querySelectorAll('video').forEach(function (v) {
            try { v.pause(); } catch (_) {}
            try { v.removeAttribute('src'); } catch (_) {}
            try { v.load(); } catch (_) {}
          });
        } catch (_) {}
      })();
    ''';
    try {
      if (wc != null) {
        await wc
            .runJavaScript(script)
            .timeout(const Duration(milliseconds: 700));
        // Tránh load about:blank trên Android TV: một số WebView/Chromium
        // vendor crash khi thoát khỏi embed đang giữ fullscreen/media session.
        await wc
            .runJavaScript('document.body.innerHTML = "";')
            .timeout(const Duration(milliseconds: 700));
      } else {
        await wwc!
            .executeScript(script)
            .timeout(const Duration(milliseconds: 700));
        await wwc
            .loadUrl('about:blank')
            .timeout(const Duration(milliseconds: 700));
        await wwc.dispose().timeout(const Duration(milliseconds: 700));
        windowsWebViewController = null;
      }
    } catch (_) {}
    webViewController = null;
    activeWebViewUrl = null;
  }

  Future<void> _setLandscapeFullscreen(bool enabled) async {
    if (isTvBuild || kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    if (landscapeFullscreen == enabled) return;
    landscapeFullscreen = enabled;
    await SystemChrome.setPreferredOrientations(
      enabled
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : DeviceOrientation.values,
    );
    if (mounted) setState(() {});
  }

  Future<void> _exitPlayer() async {
    if (leavingPlayer) return;
    leavingPlayer = true;
    if (mounted) setState(() {});
    // Silence playback synchronously before waiting for history/network work.
    // Otherwise Back can leave audio audible for up to the save timeout.
    _stopPlaybackNow();
    final disposePlayback = _disposePlaybackNow();
    final stopWebView = _stopWebViewNow();
    try {
      await _save().timeout(const Duration(seconds: 2));
    } catch (_) {}
    await Future.wait([disposePlayback, stopWebView]);
    await _setLandscapeFullscreen(false);
    if (mounted) setState(() {});
    if (isWatchTogether) {
      try {
        await _closeWatchRoomIfNeeded().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _retryPlayback() async {
    runtimeRecoveryAttempts = 0;
    lastGoodPosition = null;
    lastPlaybackError = null;
    _trackPlaybackEvent('manual_retry');
    await _init();
  }

  Future<void> _reportPlaybackIssue() async {
    if (reportingPlaybackIssue) return;
    reportingPlaybackIssue = true;
    if (mounted) setState(() {});
    final message = [
      'App v2 player error',
      'Phim: ${widget.movie.title}',
      'Tập: ${currentEpisode.displayName}',
      'Server: ${currentServer.displayName}',
      if (lastPlaybackError?.isNotEmpty == true)
        'Lỗi: ${lastPlaybackError!.trim()}',
    ].join(' | ');
    try {
      await widget.repo.reportWatch(
        movie: widget.movie,
        server: currentServer,
        episode: currentEpisode,
        message: message,
      );
      _trackPlaybackEvent('user_report_sent');
      if (mounted) showSnack(context, 'Đã gửi báo lỗi phim');
    } catch (_) {
      _trackPlaybackEvent(
        'user_report_failed',
        errorCode: 'report_watch_failed',
        errorMessage: message,
      );
      if (mounted) showSnack(context, 'Chưa gửi được báo lỗi');
    } finally {
      reportingPlaybackIssue = false;
      if (mounted) setState(() {});
    }
  }

  void _onPanStart(DragStartDetails details) {
    if (!supportsTouchLevels || controlsLocked) return;
    gestureHintTimer?.cancel();
    final c = controller;
    dragStart = details.localPosition;
    dragStartPosition = c?.value.position;
    dragStartBrightness = screenBrightness;
    dragStartVolume = appVolume;
    dragMode = null;
    pendingSeekPosition = null;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!supportsTouchLevels || controlsLocked) return;
    final c = controller;
    final start = dragStart;
    if (c == null || !c.value.isInitialized || start == null) return;
    final size = MediaQuery.sizeOf(context);
    final dx = details.localPosition.dx - start.dx;
    final dy = details.localPosition.dy - start.dy;
    if (dragMode == null) {
      final horizontal = dx.abs();
      final vertical = dy.abs();
      if (vertical > 12 && vertical >= horizontal * .72) {
        dragMode = 'level';
        controls = false;
        HapticFeedback.selectionClick();
      } else if (horizontal > 20 && horizontal > vertical * 1.15) {
        dragMode = 'seek';
        controls = false;
        HapticFeedback.selectionClick();
      }
    }
    if (dragMode == null) return;
    if (dragMode == 'seek') {
      final duration = c.value.duration;
      if (duration.inMilliseconds <= 0) return;
      final deltaSeconds = (dx / size.width * 180).round();
      final startPosition = dragStartPosition ?? c.value.position;
      pendingSeekPosition = _clampPosition(
        startPosition + Duration(seconds: deltaSeconds),
        duration,
      );
      setState(() {
        gestureMode = deltaSeconds >= 0 ? 'forward' : 'back';
        gestureValue = deltaSeconds.abs().clamp(0, 180) / 180;
      });
      return;
    }
    final change = -dy / size.height * 1.08;
    if (start.dx < size.width / 2) {
      final base = dragStartBrightness ?? screenBrightness;
      final next = (base + change).clamp(0.0, 1.0);
      setState(() {
        screenBrightness = next;
        gestureMode = 'brightness';
        gestureValue = next;
      });
      pendingBrightness = next;
      _scheduleLevelApply();
    } else {
      final base = dragStartVolume ?? appVolume;
      final next = (base + change).clamp(0.0, 1.0);
      unawaited(controller?.setVolume(next) ?? Future<void>.value());
      setState(() {
        appVolume = next;
        gestureMode = 'volume';
        gestureValue = next;
      });
      pendingVolume = next;
      _scheduleLevelApply();
    }
  }

  void _onPanEnd(DragEndDetails details) {
    if (!supportsTouchLevels || controlsLocked) return;
    final finishedMode = dragMode;
    final target = pendingSeekPosition;
    if (dragMode == 'seek' && target != null) {
      controller?.seekTo(target);
      _emitWatchSync(force: true);
      unawaited(_save());
    }
    unawaited(_applyPendingLevels(settle: true));
    setState(() {
      dragStart = null;
      dragStartPosition = null;
      dragStartBrightness = null;
      dragStartVolume = null;
      pendingSeekPosition = null;
      dragMode = null;
    });
    _clearGestureHintSoon();
    if (finishedMode == 'seek') _showControls();
  }

  void _onDoubleTapDown(TapDownDetails details) {
    if (!supportsTouchLevels || controlsLocked) return;
    final width = MediaQuery.sizeOf(context).width;
    final forward = details.localPosition.dx >= width / 2;
    _showSeekHint(forward: forward);
    unawaited(
      _seekBy(Duration(seconds: forward ? 10 : -10), showControls: false),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(_save());
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(WakelockPlus.enable());
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      unawaited(_syncDeviceLevels());
      _scheduleControlsHide();
    }
  }

  int get _currentEpisodeIndex {
    final items = currentServer.items;
    final byUrl = items.indexWhere(
      (e) =>
          e.name == currentEpisode.name &&
          e.linkM3u8 == currentEpisode.linkM3u8 &&
          e.linkEmbed == currentEpisode.linkEmbed,
    );
    return byUrl >= 0
        ? byUrl
        : items.indexWhere((e) => e.name == currentEpisode.name);
  }

  String get _activeSourceLabel {
    if (activeWebViewUrl != null) {
      return '${currentServer.displayName} • WebView';
    }
    if (activePlayableUrls.isNotEmpty) {
      final source =
          activePlayableUrls[activePlayableUrlIndex
                  .clamp(0, activePlayableUrls.length - 1)
                  .toInt()]
              .source;
      final audio = _selectedAudioSource?.label ?? '';
      return audio.isEmpty
          ? source.qualityLabel
          : '${source.qualityLabel} • $audio';
    }
    return currentServer.displayName;
  }

  Future<void> _switchTo(EpisodeServer server, EpisodeItem episode) async {
    await _save();
    final serverIndex = widget.movie.episodes.indexOf(server);
    setState(() {
      currentServer = server;
      currentEpisode = episode;
      currentServerIndex = serverIndex < 0 ? currentServerIndex : serverIndex;
      _resetTrackSelectionForEpisode();
      controls = true;
      error = null;
      introSkipped = false;
      introSkipData = null;
      introSkipDataKey = '';
      skippedIntroDbSegments.clear();
      savedCurrentEpisodeProgress = false;
      autoNextCancelledForEpisode = false;
      lastAutoNextPromptSecond = -1;
    });
    runtimeRecoveryAttempts = 0;
    lastHistorySaveAtMs = 0;
    lastGoodPosition = null;
    _loadIntroSkipSegments();
    await _init();
  }

  EpisodeItem? _siblingEpisode(int offset) {
    final index = _currentEpisodeIndex;
    final next = index + offset;
    if (index < 0 || next < 0 || next >= currentServer.items.length) {
      return null;
    }
    return currentServer.items[next];
  }

  void _playSibling(int offset) {
    final episode = _siblingEpisode(offset);
    if (episode == null) return;
    _switchTo(currentServer, episode);
  }

  void _cycleFitMode() {
    setState(() {
      fitMode = switch (fitMode) {
        PlayerFitMode.contain => PlayerFitMode.cover,
        PlayerFitMode.cover => PlayerFitMode.stretch,
        PlayerFitMode.stretch => PlayerFitMode.contain,
      };
    });
    _showControls();
  }

  Future<void> _showEpisodeSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: CvColors.ink,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => PlayerEpisodeSheet(
        repo: widget.repo,
        movie: widget.movie,
        currentServer: currentServer,
        currentEpisode: currentEpisode,
        onSelect: (server, episode) {
          Navigator.of(context).pop();
          _switchTo(server, episode);
        },
      ),
    );
    _showControls();
  }

  Future<void> _showSettingsSheet() async {
    const speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: CvColors.ink,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .82,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                18,
                0,
                18,
                24 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionTitle('Cài đặt player'),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: autoNextEpisode,
                    title: const Text('Tự chuyển tập'),
                    subtitle: const Text('Tự phát tập tiếp theo khi hết tập'),
                    onChanged: (value) {
                      setState(() => autoNextEpisode = value);
                      setSheetState(() {});
                    },
                  ),
                  if (currentEpisode.audioSources.isNotEmpty) ...[
                    const Divider(height: 24),
                    const Text(
                      'Âm thanh',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final audio in currentEpisode.audioSources)
                          ChoiceChip(
                            label: Text(audio.label),
                            selected: selectedAudioKey == audio.key,
                            showCheckmark: false,
                            onSelected: (_) async {
                              await _selectAudioSource(audio.key);
                              setSheetState(() {});
                            },
                          ),
                      ],
                    ),
                  ],
                  if (currentEpisode.subtitles.isNotEmpty) ...[
                    const Divider(height: 24),
                    const Text(
                      'Phụ đề',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('Tắt'),
                          selected:
                              selectedSubtitleLang == null ||
                              selectedSubtitleLang == 'off',
                          showCheckmark: false,
                          onSelected: (_) async {
                            await _selectSubtitleTrack('off');
                            setSheetState(() {});
                          },
                        ),
                        if (currentEpisode.subtitles.any(
                              (item) => item.lang.toLowerCase() == 'vi',
                            ) &&
                            currentEpisode.subtitles.any(
                              (item) => item.lang.toLowerCase() == 'en',
                            ))
                          ChoiceChip(
                            label: const Text('Song ngữ VI + EN'),
                            selected: selectedSubtitleLang == 'dual',
                            showCheckmark: false,
                            onSelected: (_) async {
                              await _selectSubtitleTrack('dual');
                              setSheetState(() {});
                            },
                          ),
                        for (final subtitle in currentEpisode.subtitles)
                          ChoiceChip(
                            label: Text(subtitle.label),
                            selected: selectedSubtitleLang == subtitle.lang,
                            showCheckmark: false,
                            onSelected: (_) async {
                              await _selectSubtitleTrack(subtitle.lang);
                              setSheetState(() {});
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await _showSubtitleSettingsSheet();
                        setSheetState(() {});
                      },
                      icon: const Icon(Icons.subtitles_rounded),
                      label: const Text('Cài đặt phụ đề'),
                    ),
                  ],
                  const Divider(height: 24),
                  const Text(
                    'Tốc độ phát',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 520 ? 4 : 3;
                      final itemWidth =
                          (constraints.maxWidth - (columns - 1) * 8) / columns;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final speed in speeds)
                            SizedBox(
                              width: itemWidth,
                              child: ChoiceChip(
                                label: Center(
                                  child: Text(
                                    speed == 1.0 ? '1x' : _formatSpeed(speed),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                selected: playbackSpeed == speed,
                                showCheckmark: false,
                                onSelected: (_) async {
                                  await _setPlaybackSpeed(speed);
                                  setSheetState(() {});
                                },
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  Text(
                    playbackSpeed == 1.0
                        ? 'Đang phát tốc độ bình thường'
                        : 'Đang phát ${_formatSpeed(playbackSpeed)}',
                    style: const TextStyle(color: CvColors.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    _showControls();
  }

  Future<void> _showSubtitleSettingsSheet() async {
    var language = 'vi';
    const fonts = ['Lora', 'Plus Jakarta Sans', 'Arial', 'Tahoma'];
    const colors = [
      Colors.white,
      Color(0xffffff99),
      Color(0xffffeb3b),
      Color(0xff80d8ff),
      Color(0xffffb3c7),
    ];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: CvColors.ink,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) {
          final style = language == 'vi' ? viSubtitleStyle : enSubtitleStyle;
          void update(AppSubtitleStyle value) {
            setState(() {
              if (language == 'vi') {
                viSubtitleStyle = value;
              } else {
                enSubtitleStyle = value;
              }
            });
            setSheetState(() {});
            unawaited(_saveSubtitleSettings());
          }

          Widget settingsSlider({
            required double value,
            required double min,
            required double max,
            required int divisions,
            required ValueChanged<double> onChanged,
          }) {
            final slider = Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            );
            if (!isTvBuild) return slider;

            final step = (max - min) / divisions;
            return Focus(
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                  return KeyEventResult.ignored;
                }
                final key = event.logicalKey;
                if (key == LogicalKeyboardKey.arrowLeft) {
                  onChanged((value - step).clamp(min, max));
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowRight) {
                  onChanged((value + step).clamp(min, max));
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowUp) {
                  node.focusInDirection(TraversalDirection.up);
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowDown) {
                  node.focusInDirection(TraversalDirection.down);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: ExcludeFocus(child: slider),
            );
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionTitle('Cài đặt phụ đề'),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'vi', label: Text('Phụ đề chính')),
                      ButtonSegment(value: 'en', label: Text('Song ngữ / Anh')),
                    ],
                    selected: {language},
                    onSelectionChanged: (value) =>
                        setSheetState(() => language = value.first),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: 24,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: CvColors.borderLight),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 42),
                          child: Text(
                            'Đây là nội dung phụ đề mẫu',
                            textAlign: TextAlign.center,
                            style: _subtitleTextStyle(viSubtitleStyle),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 42),
                          child: Text(
                            'Subtitle preview',
                            textAlign: TextAlign.center,
                            style: _subtitleTextStyle(enSubtitleStyle),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    language == 'vi' ? 'Phụ đề chính' : 'Song ngữ / Phụ đề Anh',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Font chữ',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final font in fonts)
                        ChoiceChip(
                          label: Text(font, style: TextStyle(fontFamily: font)),
                          selected: style.font == font,
                          showCheckmark: false,
                          onSelected: (_) => update(style.copyWith(font: font)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Cỡ chữ: ${style.size.round()}px'),
                  settingsSlider(
                    value: style.size,
                    min: 10,
                    max: language == 'vi' ? 50 : 40,
                    divisions: language == 'vi' ? 40 : 30,
                    onChanged: (value) => update(style.copyWith(size: value)),
                  ),
                  const Text(
                    'Màu chữ',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      for (final color in colors)
                        InkWell(
                          onTap: () => update(style.copyWith(color: color)),
                          onFocusChange: (focused) {
                            if (isTvBuild && focused && style.color != color) {
                              update(style.copyWith(color: color));
                            }
                          },
                          borderRadius: BorderRadius.circular(999),
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: style.color == color
                                    ? CvColors.accent
                                    : Colors.white24,
                                width: style.color == color ? 3 : 1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Vị trí: ${style.bottom.round()}% từ cạnh dưới'),
                  settingsSlider(
                    value: style.bottom,
                    min: 2,
                    max: 30,
                    divisions: 28,
                    onChanged: (value) => update(style.copyWith(bottom: value)),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () {
                          _resetSubtitleSettings();
                          setSheetState(() {});
                        },
                        icon: const Icon(Icons.restart_alt_rounded),
                        label: const Text('Reset tất cả'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Lưu cài đặt'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    _showControls();
  }

  TextStyle _subtitleTextStyle(AppSubtitleStyle style) => TextStyle(
    color: style.color,
    fontFamily: style.font,
    fontSize: style.size,
    fontWeight: FontWeight.w700,
    height: 1.2,
    shadows: const [
      Shadow(offset: Offset(0, 1), blurRadius: 4, color: Colors.black),
      Shadow(offset: Offset(0, 2), blurRadius: 8, color: Colors.black),
    ],
  );

  Widget _buildStyledCaption(String text) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    final dual = selectedSubtitleLang == 'dual';
    final blocks = dual
        ? text.split(BilingualCaptionFile.separator)
        : <String>[text];
    // Trong chế độ song ngữ, dòng đầu là track Việt và dòng sau là track Anh.
    // Giá trị bottom lớn hơn nằm cao hơn trên màn hình, nên luôn dành vị trí
    // cao cho tiếng Việt để đồng nhất với player website.
    final dualViBottom = math.max(
      viSubtitleStyle.bottom,
      enSubtitleStyle.bottom,
    );
    final dualEnBottom = math.min(
      viSubtitleStyle.bottom,
      enSubtitleStyle.bottom,
    );
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        for (var index = 0; index < blocks.length; index++)
          Positioned(
            left: 0,
            right: 0,
            bottom:
                MediaQuery.sizeOf(context).height *
                ((dual && index > 0
                        ? dualEnBottom
                        : dual
                        ? dualViBottom
                        : selectedSubtitleLang == 'en'
                        ? enSubtitleStyle.bottom
                        : viSubtitleStyle.bottom) /
                    100),
            child: Text(
              blocks[index].trim(),
              textAlign: TextAlign.center,
              style: _subtitleTextStyle(
                dual && index > 0
                    ? enSubtitleStyle
                    : selectedSubtitleLang == 'en'
                    ? enSubtitleStyle
                    : viSubtitleStyle,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMobileWebView(WebViewController controller) {
    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: false,
      child: WebViewWidget(controller: controller),
    );
  }

  Future<Uri> _serveOfflineMedia(File manifest) async {
    final root = File(widget.offlineManifestPath!).parent;
    if (offlineMediaServer == null || offlineMediaRoot?.path != root.path) {
      await offlineMediaServer?.close(force: true);
      offlineMediaRoot = root;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      offlineMediaServer = server;
      unawaited(
        server.forEach((request) async {
          final relative = Uri.decodeComponent(
            request.uri.path,
          ).replaceFirst(RegExp(r'^/+'), '');
          final candidate = File('${root.path}/$relative');
          final resolvedRoot = root.absolute.path;
          final resolvedFile = candidate.absolute.path;
          if (!resolvedFile.startsWith(
                '$resolvedRoot${Platform.pathSeparator}',
              ) ||
              !await candidate.exists()) {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            return;
          }
          final extension = candidate.path.split('.').last.toLowerCase();
          request.response.headers.contentType = switch (extension) {
            'm3u8' => ContentType('application', 'vnd.apple.mpegurl'),
            'ts' => ContentType('video', 'mp2t'),
            'vtt' => ContentType('text', 'vtt'),
            _ => ContentType.binary,
          };
          final fileLength = await candidate.length();
          request.response.headers.set('Accept-Ranges', 'bytes');
          final range = request.headers.value('range');
          final match = range == null
              ? null
              : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
          var start = 0;
          var end = fileLength - 1;
          if (match != null) {
            start = int.tryParse(match.group(1)!) ?? 0;
            final requestedEnd = match.group(2) ?? '';
            if (requestedEnd.isNotEmpty) {
              end = int.tryParse(requestedEnd) ?? end;
            }
            if (start >= fileLength || start > end) {
              request.response.statusCode =
                  HttpStatus.requestedRangeNotSatisfiable;
              request.response.headers.set(
                'Content-Range',
                'bytes */$fileLength',
              );
              await request.response.close();
              return;
            }
            end = math.min(end, fileLength - 1);
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              'Content-Range',
              'bytes $start-$end/$fileLength',
            );
          }
          request.response.contentLength = end - start + 1;
          await request.response.addStream(candidate.openRead(start, end + 1));
          await request.response.close();
        }),
      );
    }
    final relative = manifest.absolute.path.substring(
      offlineMediaRoot!.absolute.path.length + 1,
    );
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: offlineMediaServer!.port,
      pathSegments: relative.split(Platform.pathSeparator),
    );
  }

  @override
  void dispose() {
    playerDisposed = true;
    leavingPlayer = true;
    _stopPlaybackNow();
    unawaited(offlineMediaServer?.close(force: true));
    unawaited(_stopWebViewNow());
    _save();
    controlsTimer?.cancel();
    levelApplyTimer?.cancel();
    gestureHintTimer?.cancel();
    deviceLevelSyncTimer?.cancel();
    saveTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (isWatchTogether && !leavingPlayer) {
      widget.repo.closeWatchRoom(forceDelete: isWatchHost);
    }
    focusNode.dispose();
    overlayFocusScopeNode.dispose();
    playButtonFocusNode.dispose();
    seekBarFocusNode.dispose();
    backButtonFocusNode.dispose();
    webViewPlayFocusNode.dispose();
    watchChatController.dispose();
    controller?.removeListener(_handlePlayerTick);
    controller?.dispose();
    windowsWebViewController?.dispose();
    WakelockPlus.disable();
    if (supportsTouchLevels) {
      brightnessChannel.invokeMethod<double>('reset').catchError((_) => null);
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (landscapeFullscreen) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final introSegment = _activeIntroSkipSegment(c);
    final showIntroSkip =
        introSegment != null || _shouldShowFallbackIntroSkip(c);
    return PopScope(
      // Luôn chặn pop mặc định. Khi rời player, chỉ _exitPlayer() được phép
      // pop đúng một lần; tránh Back hệ thống + KeyboardListener pop liên tiếp
      // làm bay qua trang chi tiết về Home.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || leavingPlayer) return;
        unawaited(_exitPlayer());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: KeyboardListener(
          focusNode: focusNode,
          onKeyEvent: (event) {
            if (event is! KeyDownEvent) return;
            final key = event.logicalKey;
            final playerRouteIsCurrent =
                ModalRoute.of(context)?.isCurrent ?? true;
            if (!playerRouteIsCurrent) return;
            // Back phải hoạt động trên WebView StreamC cả khi không có native
            // VideoPlayer controller (Android TV remote, Windows Esc/back, keyboard).
            if (key == LogicalKeyboardKey.escape ||
                key == LogicalKeyboardKey.goBack ||
                key == LogicalKeyboardKey.browserBack) {
              unawaited(_exitPlayer());
              return;
            }
            if (activeWebViewUrl != null && isTvBuild) {
              final primaryFocus = FocusManager.instance.primaryFocus;
              final playerHasPrimaryFocus =
                  primaryFocus == null || primaryFocus == focusNode;
              if (key == LogicalKeyboardKey.select ||
                  key == LogicalKeyboardKey.enter) {
                if (controls && !playerHasPrimaryFocus) return;
                _showControls();
                return;
              }
              if (key == LogicalKeyboardKey.space ||
                  key == LogicalKeyboardKey.mediaPlayPause ||
                  key == LogicalKeyboardKey.mediaPlay ||
                  key == LogicalKeyboardKey.keyK) {
                _togglePlay();
                return;
              }
              if (key == LogicalKeyboardKey.arrowRight ||
                  key == LogicalKeyboardKey.mediaFastForward ||
                  key == LogicalKeyboardKey.keyL) {
                _seekBy(const Duration(seconds: 10));
                return;
              }
              if (key == LogicalKeyboardKey.arrowLeft ||
                  key == LogicalKeyboardKey.mediaRewind ||
                  key == LogicalKeyboardKey.keyJ) {
                _seekBy(const Duration(seconds: -10));
                return;
              }
              final webViewAction = key == LogicalKeyboardKey.arrowUp
                  ? 'up'
                  : key == LogicalKeyboardKey.arrowDown
                  ? 'down'
                  : null;
              if (webViewAction != null) {
                if (controls && !controlsLocked) {
                  controlsTimer?.cancel();
                  setState(() => controls = false);
                }
                unawaited(_sendWebViewTvRemoteKey(webViewAction));
                return;
              }
            }
            if (c == null) return;
            final primaryFocus = FocusManager.instance.primaryFocus;
            final playerHasPrimaryFocus =
                primaryFocus == null || primaryFocus == focusNode;
            final directionalKey =
                key == LogicalKeyboardKey.arrowRight ||
                key == LogicalKeyboardKey.arrowLeft ||
                key == LogicalKeyboardKey.arrowUp ||
                key == LogicalKeyboardKey.arrowDown;
            if (isTvBuild && !playerHasPrimaryFocus && directionalKey) {
              if (key == LogicalKeyboardKey.arrowUp) {
                if (controls && !controlsLocked) {
                  controlsTimer?.cancel();
                  setState(() => controls = false);
                } else {
                  _showControls();
                }
                return;
              }
              if (key == LogicalKeyboardKey.arrowDown) return;
              _showControls();
              return;
            }
            if (isTvBuild &&
                controls &&
                !controlsLocked &&
                key == LogicalKeyboardKey.arrowRight) {
              _moveTvOverlayFocus(forward: true);
              return;
            }
            if (isTvBuild &&
                controls &&
                !controlsLocked &&
                key == LogicalKeyboardKey.arrowLeft) {
              _moveTvOverlayFocus(forward: false);
              return;
            }
            if (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.space ||
                key == LogicalKeyboardKey.mediaPlayPause ||
                key == LogicalKeyboardKey.mediaPlay ||
                key == LogicalKeyboardKey.keyK) {
              if (playerHasPrimaryFocus || key == LogicalKeyboardKey.keyK) {
                _togglePlay();
              }
            }
            if (key == LogicalKeyboardKey.arrowRight ||
                key == LogicalKeyboardKey.mediaFastForward ||
                key == LogicalKeyboardKey.keyL) {
              _seekBy(const Duration(seconds: 10));
            }
            if (key == LogicalKeyboardKey.arrowLeft ||
                key == LogicalKeyboardKey.mediaRewind ||
                key == LogicalKeyboardKey.keyJ) {
              _seekBy(const Duration(seconds: -10));
            }
            if (key == LogicalKeyboardKey.arrowUp) {
              if (isTvBuild && playerHasPrimaryFocus) {
                _moveTvOverlayFocus(forward: false);
              } else {
                _showControls();
              }
            }
            if (key == LogicalKeyboardKey.arrowDown) {
              if (isTvBuild && playerHasPrimaryFocus) {
                _moveTvOverlayFocus(forward: true);
              } else {
                _showControls();
              }
            }
            if (key == LogicalKeyboardKey.keyN ||
                key == LogicalKeyboardKey.mediaTrackNext) {
              _playSibling(1);
            }
            if (key == LogicalKeyboardKey.keyP ||
                key == LogicalKeyboardKey.mediaTrackPrevious) {
              _playSibling(-1);
            }
            if (!isTvBuild) {
              if (key == LogicalKeyboardKey.keyM) _toggleMute();
              if (key == LogicalKeyboardKey.keyF) _cycleFitMode();
              if (key == LogicalKeyboardKey.keyE) _showEpisodeSheet();
            }
            if (isWindowsDesktop) {
              if (key == LogicalKeyboardKey.arrowUp) _nudgeVolume(.08);
              if (key == LogicalKeyboardKey.arrowDown) _nudgeVolume(-.08);
            }
          },
          child: MouseRegion(
            cursor: isWindowsDesktop
                ? SystemMouseCursors.click
                : MouseCursor.defer,
            onHover: isWindowsDesktop ? (_) => _showControls() : null,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              onDoubleTapDown: _onDoubleTapDown,
              onTap: () {
                if (controlsLocked) return;
                setState(() => controls = !controls);
                if (controls) _scheduleControlsHide();
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (error != null)
                    PlayerErrorView(
                      message: error!,
                      movieTitle: widget.movie.title,
                      episodeLabel: currentEpisode.displayName,
                      serverLabel: currentServer.displayName,
                      reporting: reportingPlaybackIssue,
                      canPrevious: _siblingEpisode(-1) != null,
                      canNext: _siblingEpisode(1) != null,
                      onRetry: _retryPlayback,
                      onChangeSource: _showEpisodeSheet,
                      onPrevious: () => _playSibling(-1),
                      onNext: () => _playSibling(1),
                      onReport: _reportPlaybackIssue,
                    )
                  else if (activeWebViewUrl != null &&
                      windowsWebViewController != null)
                    windows_webview.Webview(windowsWebViewController!)
                  else if (activeWebViewUrl != null &&
                      webViewController != null)
                    _buildMobileWebView(webViewController!)
                  else if (c == null || !c.value.isInitialized)
                    const Center(
                      child: CircularProgressIndicator(color: CvColors.accent),
                    )
                  else
                    Center(
                      child: _FittedVideo(controller: c, fitMode: fitMode),
                    ),
                  if (activeWebViewUrl == null &&
                      c != null &&
                      c.value.isInitialized &&
                      _selectedSubtitleTrack != null)
                    Positioned(
                      left: 24,
                      right: 24,
                      top: 0,
                      bottom: controls ? 118 : 0,
                      child: IgnorePointer(
                        child: ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: c,
                          builder: (context, value, _) =>
                              _buildStyledCaption(value.caption.text),
                        ),
                      ),
                    ),
                  if (activeWebViewUrl != null && !controlsLocked)
                    Positioned(
                      top: 12,
                      left: 12,
                      child: SafeArea(
                        child: Material(
                          color: Colors.black.withValues(alpha: .58),
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: IconButton(
                            tooltip: 'Quay lại',
                            color: Colors.white,
                            iconSize: 28,
                            onPressed: _exitPlayer,
                            icon: const Icon(Icons.arrow_back_rounded),
                          ),
                        ),
                      ),
                    ),
                  if (activeWebViewUrl == null &&
                      usesWindowsBrightnessOverlay &&
                      screenBrightness < .99)
                    IgnorePointer(
                      child: ColoredBox(
                        color: Colors.black.withValues(
                          alpha: ((1 - screenBrightness) * .58).clamp(.0, .58),
                        ),
                      ),
                    ),
                  if (showIntroSkip && !controlsLocked)
                    IntroSkipButton(
                      label: introSegment?.buttonLabel ?? 'Bỏ qua intro',
                      onPressed: _skipIntro,
                    ),
                  if (controls && !controlsLocked)
                    FocusScope(
                      node: overlayFocusScopeNode,
                      child: FocusTraversalGroup(
                        policy: OrderedTraversalPolicy(),
                        child: PlayerOverlay(
                          controller: c,
                          title: widget.movie.title,
                          episode:
                              '${currentServer.displayName} • ${currentEpisode.displayName}',
                          sourceLabel: _activeSourceLabel,
                          dimBackground: activeWebViewUrl == null,
                          fitLabel: fitMode.label,
                          canPrevious: _currentEpisodeIndex > 0,
                          canNext:
                              _currentEpisodeIndex >= 0 &&
                              _currentEpisodeIndex <
                                  currentServer.items.length - 1,
                          onPlayPause: _togglePlay,
                          onReplay: () => _seekBy(const Duration(seconds: -10)),
                          onForward: () => _seekBy(const Duration(seconds: 10)),
                          onFocusBack: () => backButtonFocusNode.requestFocus(),
                          onFocusPrimaryControl: () =>
                              playButtonFocusNode.requestFocus(),
                          onFocusSeekBar: () => seekBarFocusNode.requestFocus(),
                          onPrevious: () => _playSibling(-1),
                          onNext: () => _playSibling(1),
                          onEpisodes: _showEpisodeSheet,
                          onSettings: _showSettingsSheet,
                          onFit: _cycleFitMode,
                          landscapeFullscreen: landscapeFullscreen,
                          onToggleFullscreen: isTvBuild
                              ? null
                              : () => unawaited(
                                  _setLandscapeFullscreen(!landscapeFullscreen),
                                ),
                          onBack: _exitPlayer,
                          playFocusNode: playButtonFocusNode,
                          seekBarFocusNode: seekBarFocusNode,
                          backFocusNode: backButtonFocusNode,
                        ),
                      ),
                    ),
                  if (activeWebViewUrl != null &&
                      isTvBuild &&
                      controls &&
                      !controlsLocked)
                    _buildWebViewTvControls(),
                  if (supportsTouchLevels && controls && !controlsLocked)
                    _buildLockButton(locked: false),
                  if (supportsTouchLevels && controlsLocked)
                    _buildLockButton(locked: true),
                  if (isWatchTogether) _buildWatchTogetherChatPanel(),
                  if (!controlsLocked &&
                      dragMode == 'seek' &&
                      pendingSeekPosition != null &&
                      c != null &&
                      c.value.isInitialized)
                    SeekPreviewBar(
                      position: pendingSeekPosition!,
                      duration: c.value.duration,
                    ),
                  if (!controlsLocked &&
                      gestureMode != null &&
                      gestureValue != null)
                    GestureLevelHint(mode: gestureMode!, value: gestureValue!),
                  if (_shouldShowAutoNextPrompt && c != null)
                    AutoNextPrompt(
                      nextEpisode: _siblingEpisode(1)?.displayName ?? 'Tập sau',
                      remainingSeconds: _autoNextRemainingSeconds,
                      onPlayNow: () => _playSibling(1),
                      onCancel: _cancelAutoNextForEpisode,
                    ),
                  if (playbackNotice != null && error == null)
                    PlaybackNotice(message: playbackNotice!),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWebViewTvControls() => Positioned(
    left: 20,
    right: 20,
    bottom: 22,
    child: SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .72),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: .12)),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FocusButton(
                  focusNode: webViewPlayFocusNode,
                  autofocus: true,
                  onPressed: _togglePlay,
                  child: const _WebViewTvControlTile(
                    icon: Icons.play_arrow_rounded,
                    label: 'Play/Pause',
                  ),
                ),
                const SizedBox(width: 8),
                FocusButton(
                  onPressed: () => _seekBy(const Duration(seconds: -10)),
                  child: const _WebViewTvControlTile(
                    icon: Icons.replay_10_rounded,
                    label: 'Lùi',
                  ),
                ),
                const SizedBox(width: 8),
                FocusButton(
                  onPressed: () => _seekBy(const Duration(seconds: 10)),
                  child: const _WebViewTvControlTile(
                    icon: Icons.forward_10_rounded,
                    label: 'Tới',
                  ),
                ),
                const SizedBox(width: 8),
                FocusButton(
                  onPressed: () => _playSibling(1),
                  child: const _WebViewTvControlTile(
                    icon: Icons.skip_next_rounded,
                    label: 'Tập kế',
                  ),
                ),
                const SizedBox(width: 8),
                FocusButton(
                  onPressed: _showEpisodeSheet,
                  child: const _WebViewTvControlTile(
                    icon: Icons.video_library_rounded,
                    label: 'Tập',
                  ),
                ),
                const SizedBox(width: 8),
                FocusButton(
                  onPressed: () => unawaited(_exitPlayer()),
                  child: const _WebViewTvControlTile(
                    icon: Icons.arrow_back_rounded,
                    label: 'Thoát',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildWatchTogetherChatPanel() {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 720;
    final panelWidth = (compact ? width * .52 : 360.0).clamp(260.0, 380.0);
    return Positioned(
      top: compact ? 16 : 24,
      right: compact ? 12 : 24,
      bottom: compact ? 84 : 110,
      width: panelWidth,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: watchChatVisible
            ? WatchTogetherChatPanel(
                key: const ValueKey('watch-chat-panel'),
                code: watchRoomCode,
                messages: watchMessages,
                inputController: watchChatController,
                onSend: () {
                  _sendWatchMessage();
                  FocusManager.instance.primaryFocus?.unfocus();
                },
                onHide: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  setState(() => watchChatVisible = false);
                },
              )
            : Align(
                key: const ValueKey('watch-chat-toggle'),
                alignment: Alignment.topRight,
                child: WatchChatToggleButton(
                  code: watchRoomCode,
                  count: watchMessages.length,
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    setState(() => watchChatVisible = true);
                  },
                ),
              ),
      ),
    );
  }

  Widget _buildLockButton({required bool locked}) => Positioned(
    left: 16,
    top: 0,
    bottom: 0,
    child: SafeArea(
      child: Center(
        child: IconButton.filledTonal(
          tooltip: locked ? 'Mở khóa cử chỉ' : 'Khóa cử chỉ',
          onPressed: _toggleControlsLock,
          icon: Icon(locked ? Icons.lock_open_rounded : Icons.lock_rounded),
        ),
      ),
    ),
  );
}

class IntroSkipButton extends StatelessWidget {
  const IntroSkipButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Positioned(
    right: 20,
    bottom: 118,
    child: SafeArea(
      child: FilledButton.icon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: .72),
          foregroundColor: CvColors.text,
          side: const BorderSide(color: CvColors.borderLight),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: const Icon(Icons.fast_forward_rounded, size: 18),
        label: Text(label, style: TextStyle(fontWeight: FontWeight.w900)),
      ),
    ),
  );
}

class _WebViewTvControlTile extends StatelessWidget {
  const _WebViewTvControlTile({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 96, minHeight: 54),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.white.withValues(alpha: .12)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 22, color: CvColors.accent),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textScaler: TextScaler.noScaling,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
        ),
      ],
    ),
  );
}

class AutoNextPrompt extends StatelessWidget {
  const AutoNextPrompt({
    super.key,
    required this.nextEpisode,
    required this.remainingSeconds,
    required this.onPlayNow,
    required this.onCancel,
  });

  final String nextEpisode;
  final int remainingSeconds;
  final VoidCallback onPlayNow;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Positioned(
    right: 20,
    bottom: 118,
    child: SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .78),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: CvColors.accent.withValues(alpha: .38)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .32),
                blurRadius: 22,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.skip_next_rounded, color: CvColors.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Tự chuyển sau ${remainingSeconds}s',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  nextEpisode,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: CvColors.muted),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.icon(
                      autofocus: isTvBuild,
                      onPressed: onPlayNow,
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: const Text('Xem ngay'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(onPressed: onCancel, child: const Text('Huỷ')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class PlaybackNotice extends StatelessWidget {
  const PlaybackNotice({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 20,
    right: 20,
    bottom: 28,
    child: SafeArea(
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .72),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: .12)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: CvColors.accent,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class PlayerErrorView extends StatelessWidget {
  const PlayerErrorView({
    super.key,
    required this.message,
    required this.movieTitle,
    required this.episodeLabel,
    required this.serverLabel,
    required this.reporting,
    required this.canPrevious,
    required this.canNext,
    required this.onRetry,
    required this.onChangeSource,
    required this.onPrevious,
    required this.onNext,
    required this.onReport,
  });

  final String message;
  final String movieTitle;
  final String episodeLabel;
  final String serverLabel;
  final bool reporting;
  final bool canPrevious;
  final bool canNext;
  final VoidCallback onRetry;
  final VoidCallback onChangeSource;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 620;
    final actions = [
      FilledButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Thử lại'),
      ),
      OutlinedButton.icon(
        onPressed: canPrevious ? onPrevious : null,
        icon: const Icon(Icons.skip_previous_rounded),
        label: const Text('Tập trước'),
      ),
      OutlinedButton.icon(
        onPressed: canNext ? onNext : null,
        icon: const Icon(Icons.skip_next_rounded),
        label: const Text('Tập sau'),
      ),
      OutlinedButton.icon(
        onPressed: onChangeSource,
        icon: const Icon(Icons.video_library_rounded),
        label: Text(compact ? 'Tập' : 'Chọn tập/server'),
      ),
      OutlinedButton.icon(
        onPressed: reporting ? null : onReport,
        icon: reporting
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.flag_rounded),
        label: const Text('Báo lỗi'),
      ),
    ];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 54,
                color: CvColors.amber,
              ),
              const SizedBox(height: 14),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$movieTitle • $episodeLabel • $serverLabel',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: CvColors.muted),
              ),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: actions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PlayerOverlay extends StatelessWidget {
  const PlayerOverlay({
    super.key,
    required this.controller,
    required this.title,
    required this.episode,
    required this.sourceLabel,
    this.dimBackground = true,
    required this.fitLabel,
    required this.canPrevious,
    required this.canNext,
    required this.onPlayPause,
    required this.onReplay,
    required this.onForward,
    required this.onFocusBack,
    required this.onFocusPrimaryControl,
    required this.onFocusSeekBar,
    required this.onPrevious,
    required this.onNext,
    required this.onEpisodes,
    required this.onSettings,
    required this.onFit,
    required this.landscapeFullscreen,
    this.onToggleFullscreen,
    this.playFocusNode,
    this.seekBarFocusNode,
    this.backFocusNode,
    this.onBack,
  });
  final VideoPlayerController? controller;
  final String title;
  final String episode;
  final String sourceLabel;
  final bool dimBackground;
  final String fitLabel;
  final bool canPrevious;
  final bool canNext;
  final VoidCallback onPlayPause;
  final VoidCallback onReplay;
  final VoidCallback onForward;
  final VoidCallback onFocusBack;
  final VoidCallback onFocusPrimaryControl;
  final VoidCallback onFocusSeekBar;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onEpisodes;
  final VoidCallback onSettings;
  final VoidCallback onFit;
  final bool landscapeFullscreen;
  final VoidCallback? onToggleFullscreen;
  final FocusNode? playFocusNode;
  final FocusNode? seekBarFocusNode;
  final FocusNode? backFocusNode;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: dimBackground
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: .72),
                  Colors.transparent,
                  Colors.black.withValues(alpha: .82),
                ],
              )
            : null,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton.filledTonal(
                    focusNode: backFocusNode,
                    onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          '$episode • $sourceLabel',
                          style: const TextStyle(color: CvColors.muted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (onToggleFullscreen != null)
                    IconButton.filledTonal(
                      tooltip: landscapeFullscreen
                          ? 'Thoát màn hình ngang'
                          : 'Xem toàn màn hình ngang',
                      onPressed: onToggleFullscreen,
                      icon: Icon(
                        landscapeFullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                      ),
                    ),
                ],
              ),
              const Spacer(),
              if (c != null && c.value.isInitialized)
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: c,
                  builder: (context, value, _) => Column(
                    children: [
                      PlayerSeekBar(
                        controller: c,
                        onSeekBackward: onReplay,
                        onSeekForward: onForward,
                        onFocusBack: onFocusBack,
                        focusNode: seekBarFocusNode,
                        onFocusPrimaryControl: onFocusPrimaryControl,
                      ),
                      const SizedBox(height: 12),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final compact = constraints.maxWidth < 640;
                          final buttons = [
                            PlayerControlButton(
                              icon: Icons.video_library_rounded,
                              label: 'Tập',
                              onPressed: onEpisodes,
                            ),
                            PlayerControlButton(
                              icon: Icons.skip_previous_rounded,
                              label: 'Trước',
                              onPressed: canPrevious ? onPrevious : null,
                            ),
                            PlayerControlButton(
                              icon: Icons.replay_10_rounded,
                              label: 'Lùi',
                              onPressed: onReplay,
                            ),
                            FocusButton(
                              focusNode: playFocusNode,
                              autofocus: isTvBuild,
                              onPressed: onPlayPause,
                              child: SizedBox.square(
                                dimension: compact ? 54 : 62,
                                child: Center(
                                  child: Icon(
                                    value.isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    size: compact ? 28 : 34,
                                  ),
                                ),
                              ),
                            ),
                            PlayerControlButton(
                              icon: Icons.forward_10_rounded,
                              label: 'Tới',
                              onPressed: onForward,
                            ),
                            PlayerControlButton(
                              icon: Icons.skip_next_rounded,
                              label: 'Sau',
                              onPressed: canNext ? onNext : null,
                            ),
                            PlayerControlButton(
                              icon: Icons.fit_screen_rounded,
                              label: fitLabel,
                              onPressed: onFit,
                            ),
                            PlayerControlButton(
                              icon: Icons.settings_rounded,
                              label: 'Cài đặt',
                              onPressed: onSettings,
                            ),
                          ];
                          final visibleButtons = compact
                              ? [
                                  buttons[0],
                                  buttons[1],
                                  buttons[2],
                                  buttons[3],
                                  buttons[4],
                                  buttons[5],
                                  buttons[7],
                                ]
                              : buttons;
                          return Row(
                            children: [
                              Expanded(
                                child: Focus(
                                  onKeyEvent: (_, event) {
                                    if (event is KeyDownEvent &&
                                        event.logicalKey ==
                                            LogicalKeyboardKey.arrowUp) {
                                      onFocusSeekBar();
                                      return KeyEventResult.handled;
                                    }
                                    return KeyEventResult.ignored;
                                  },
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(children: visibleButtons),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '${fmtDuration(value.position)} / ${fmtDuration(value.duration)}',
                                style: const TextStyle(
                                  fontFeatures: [FontFeature.tabularFigures()],
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class PlayerSeekBar extends StatefulWidget {
  const PlayerSeekBar({
    super.key,
    required this.controller,
    this.focusNode,
    required this.onSeekBackward,
    required this.onSeekForward,
    required this.onFocusBack,
    required this.onFocusPrimaryControl,
  });

  final VideoPlayerController controller;
  final FocusNode? focusNode;
  final VoidCallback onSeekBackward;
  final VoidCallback onSeekForward;
  final VoidCallback onFocusBack;
  final VoidCallback onFocusPrimaryControl;

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar> {
  bool focused = false;
  double? dragValueMs;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (value) => setState(() => focused = value),
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.mediaRewind) {
          widget.onSeekBackward();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
            event.logicalKey == LogicalKeyboardKey.mediaFastForward) {
          widget.onSeekForward();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          widget.onFocusBack();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          widget.onFocusPrimaryControl();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(
          horizontal: focused && isTvBuild ? 8 : 0,
          vertical: focused && isTvBuild ? 8 : 0,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: focused && isTvBuild
              ? Border.all(color: CvColors.accent, width: 2)
              : null,
          boxShadow: focused && isTvBuild
              ? [
                  BoxShadow(
                    color: CvColors.accent.withValues(alpha: .28),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) {
            final durationMs = value.duration.inMilliseconds;
            final positionMs = value.position.inMilliseconds.clamp(
              0,
              durationMs > 0 ? durationMs : 1,
            );
            final max = durationMs > 0 ? durationMs.toDouble() : 1.0;
            final sliderValue = (dragValueMs ?? positionMs.toDouble()).clamp(
              0.0,
              max,
            );
            final slider = Slider(
              value: sliderValue,
              min: 0,
              max: max,
              onChanged: durationMs <= 0
                  ? null
                  : (nextMs) => setState(() => dragValueMs = nextMs),
              onChangeEnd: durationMs <= 0
                  ? null
                  : (nextMs) async {
                      final wasPlaying = widget.controller.value.isPlaying;
                      setState(() => dragValueMs = null);
                      await widget.controller.seekTo(
                        Duration(milliseconds: nextMs.round()),
                      );
                      if (wasPlaying && !widget.controller.value.isPlaying) {
                        await widget.controller.play();
                      }
                    },
            );
            return SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: focused && isTvBuild ? 7 : 4,
                activeTrackColor: CvColors.accent,
                inactiveTrackColor: Colors.white.withValues(alpha: .28),
                thumbColor: Colors.transparent,
                overlayColor: Colors.transparent,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 0),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
              ),
              child: isTvBuild ? ExcludeFocus(child: slider) : slider,
            );
          },
        ),
      ),
    );
  }
}

class PlayerControlButton extends StatelessWidget {
  const PlayerControlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: label,
      child: Opacity(
        opacity: enabled ? 1 : .38,
        child: FocusButton(
          onPressed: enabled ? onPressed! : () {},
          child: SizedBox.square(
            dimension: isTvBuild ? 54 : 48,
            child: Center(child: Icon(icon)),
          ),
        ),
      ),
    );
  }
}

class WatchTogetherChatPanel extends StatelessWidget {
  const WatchTogetherChatPanel({
    super.key,
    required this.code,
    required this.messages,
    required this.inputController,
    required this.onSend,
    required this.onHide,
  });

  final String code;
  final List<WatchTogetherMessage> messages;
  final TextEditingController inputController;
  final VoidCallback onSend;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final recent = messages.length > 80
        ? messages.sublist(messages.length - 80)
        : messages;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .62),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: .14)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.groups_rounded,
                      color: CvColors.accent,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Chat xem chung',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                          Text(
                            'Mã phòng: $code',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: CvColors.accent,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: onHide,
                      tooltip: 'Ẩn chat',
                      icon: const Icon(Icons.keyboard_arrow_right_rounded),
                    ),
                  ],
                ),
              ),
              Divider(color: Colors.white.withValues(alpha: .10), height: 1),
              Expanded(
                child: recent.isEmpty
                    ? const Center(
                        child: Text(
                          'Chưa có tin nhắn',
                          style: TextStyle(color: CvColors.muted),
                        ),
                      )
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                        itemCount: recent.length,
                        itemBuilder: (context, index) {
                          final message = recent[recent.length - 1 - index];
                          return WatchMessageBubble(message: message);
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: inputController,
                        minLines: 1,
                        maxLines: 2,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => onSend(),
                        onTapOutside: (_) =>
                            FocusManager.instance.primaryFocus?.unfocus(),
                        decoration: InputDecoration(
                          hintText: 'Nhắn tin...',
                          isDense: true,
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: .08),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 42,
                      height: 42,
                      child: FilledButton(
                        onPressed: onSend,
                        style: FilledButton.styleFrom(
                          padding: EdgeInsets.zero,
                          backgroundColor: CvColors.accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Icon(Icons.send_rounded, size: 19),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class WatchMessageBubble extends StatelessWidget {
  const WatchMessageBubble({super.key, required this.message});
  final WatchTogetherMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.isSystem) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          message.payload,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: CvColors.muted,
            fontSize: 12,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: .08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message.userName?.trim().isNotEmpty == true
                ? message.userName!.trim()
                : 'Thành viên',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: CvColors.accent,
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 3),
          Text(message.payload, style: const TextStyle(height: 1.25)),
        ],
      ),
    );
  }
}

class WatchChatToggleButton extends StatelessWidget {
  const WatchChatToggleButton({
    super.key,
    required this.code,
    required this.count,
    required this.onTap,
  });

  final String code;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: .68),
    borderRadius: BorderRadius.circular(999),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.chat_bubble_rounded, color: CvColors.accent),
            const SizedBox(width: 8),
            Text(
              count > 0 ? '$code • $count' : code,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    ),
  );
}

class SeekPreviewBar extends StatelessWidget {
  const SeekPreviewBar({
    super.key,
    required this.position,
    required this.duration,
  });

  final Duration position;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds;
    final progress = totalMs <= 0
        ? 0.0
        : (position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    return Positioned(
      left: 28,
      right: 28,
      bottom: 26,
      child: SafeArea(
        minimum: const EdgeInsets.only(bottom: 12),
        child: IgnorePointer(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .58),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .10),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          fmtDuration(position),
                          style: const TextStyle(
                            fontFeatures: [FontFeature.tabularFigures()],
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          fmtDuration(duration),
                          style: const TextStyle(
                            color: CvColors.muted,
                            fontFeatures: [FontFeature.tabularFigures()],
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 9),
                    SizedBox(
                      height: 5,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: progress,
                          color: CvColors.accent,
                          backgroundColor: Colors.white.withValues(alpha: .20),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GestureLevelHint extends StatelessWidget {
  const GestureLevelHint({super.key, required this.mode, required this.value});
  final String mode;
  final double value;

  @override
  Widget build(BuildContext context) {
    final isBrightness = mode == 'brightness';
    final isVolume = mode == 'volume';
    final icon = isBrightness
        ? Icons.brightness_6_rounded
        : isVolume
        ? Icons.volume_up_rounded
        : mode == 'forward'
        ? Icons.forward_10_rounded
        : Icons.replay_10_rounded;
    if (isBrightness || isVolume) {
      return IgnorePointer(
        child: Align(
          alignment: isBrightness
              ? Alignment.centerLeft
              : Alignment.centerRight,
          child: SafeArea(
            minimum: const EdgeInsets.symmetric(horizontal: 28),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(
                  width: 54,
                  height: 164,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .58),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .12),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, color: Colors.white, size: 25),
                      const SizedBox(height: 14),
                      _VerticalLevelBar(value: value),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Center(
      child: IgnorePointer(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .58),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white.withValues(alpha: .12)),
              ),
              child: Icon(icon, color: Colors.white, size: 34),
            ),
          ),
        ),
      ),
    );
  }
}

class _VerticalLevelBar extends StatelessWidget {
  const _VerticalLevelBar({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);
    return Container(
      width: 6,
      height: 92,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .22),
        borderRadius: BorderRadius.circular(999),
      ),
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: clamped,
        alignment: Alignment.bottomCenter,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: CvColors.accent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: const SizedBox(width: 6),
        ),
      ),
    );
  }
}

enum PlayerFitMode {
  contain,
  cover,
  stretch;

  String get label => switch (this) {
    PlayerFitMode.contain => 'Gốc',
    PlayerFitMode.cover => 'Đầy',
    PlayerFitMode.stretch => 'Kéo',
  };
}

class _FittedVideo extends StatelessWidget {
  const _FittedVideo({required this.controller, required this.fitMode});

  final VideoPlayerController controller;
  final PlayerFitMode fitMode;

  @override
  Widget build(BuildContext context) {
    final aspect = controller.value.aspectRatio == 0
        ? 16 / 9
        : controller.value.aspectRatio;
    if (fitMode == PlayerFitMode.stretch) {
      return SizedBox.expand(child: VideoPlayer(controller));
    }
    return SizedBox.expand(
      child: FittedBox(
        fit: fitMode == PlayerFitMode.cover ? BoxFit.cover : BoxFit.contain,
        child: SizedBox(
          width: aspect,
          height: 1,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}

class PlayerEpisodeSheet extends StatefulWidget {
  const PlayerEpisodeSheet({
    super.key,
    required this.repo,
    required this.movie,
    required this.currentServer,
    required this.currentEpisode,
    required this.onSelect,
  });

  final MovieRepository repo;
  final Movie movie;
  final EpisodeServer currentServer;
  final EpisodeItem currentEpisode;
  final void Function(EpisodeServer server, EpisodeItem episode) onSelect;

  @override
  State<PlayerEpisodeSheet> createState() => _PlayerEpisodeSheetState();
}

class _PlayerEpisodeSheetState extends State<PlayerEpisodeSheet> {
  late int serverIndex;
  String? selectedServerType;
  final searchController = TextEditingController();
  int? selectedRangeStart;
  bool checkingServers = false;
  Map<int, ServerCheckResult> serverHealth = const {};

  @override
  void initState() {
    super.initState();
    final servers = widget.movie.episodes;
    final found = servers.indexOf(widget.currentServer);
    serverIndex = found < 0 ? 0 : found;

    // Một số phim bộ có nguồn dự phòng chỉ trả về một mục "Full", trong
    // khi nguồn chính chứa đầy đủ danh sách tập. Player có thể đang phát từ
    // nguồn dự phòng đó, nhưng bảng chọn tập vẫn phải ưu tiên nguồn đầy đủ.
    if (servers[serverIndex].items.length <= 1) {
      var richestIndex = serverIndex;
      for (var i = 0; i < servers.length; i++) {
        if (servers[i].items.length > servers[richestIndex].items.length) {
          richestIndex = i;
        }
      }
      if (servers[richestIndex].items.length > 1) serverIndex = richestIndex;
    }
    selectedServerType = servers[serverIndex].typeName;
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  bool _isCurrent(EpisodeServer server, EpisodeItem episode) =>
      server.name == widget.currentServer.name &&
      episode.name == widget.currentEpisode.name &&
      episode.linkM3u8 == widget.currentEpisode.linkM3u8 &&
      episode.linkEmbed == widget.currentEpisode.linkEmbed;

  EpisodeItem _checkEpisodeFor(EpisodeServer server) {
    final targetNumber = episodeNumber(widget.currentEpisode.displayName);
    final byNumber = server.items.where(
      (episode) => episodeNumber(episode.displayName) == targetNumber,
    );
    if (byNumber.isNotEmpty) return byNumber.first;
    return server.items.isNotEmpty ? server.items.first : widget.currentEpisode;
  }

  Future<void> _checkServers({bool autoSelect = false}) async {
    final sources = <Map<String, dynamic>>[];
    for (var i = 0; i < widget.movie.episodes.length; i++) {
      final episode = _checkEpisodeFor(widget.movie.episodes[i]);
      if (episode.playUrl.isEmpty) continue;
      sources.add({
        'id': '$i:${episode.playUrl}',
        'serverIndex': i,
        'label': widget.movie.episodes[i].displayName,
        'url': episode.linkM3u8,
        'embedUrl': episode.linkEmbed,
      });
    }
    if (sources.isEmpty) return;
    setState(() => checkingServers = true);
    try {
      final result = await widget.repo.checkServers(sources);
      if (!mounted) return;
      setState(() {
        serverHealth = result.results;
        if (autoSelect &&
            result.bestServerIndex != null &&
            result.bestServerIndex! >= 0 &&
            result.bestServerIndex! < widget.movie.episodes.length) {
          serverIndex = result.bestServerIndex!;
          selectedRangeStart = null;
          searchController.clear();
        }
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không kiểm tra được server lúc này')),
      );
    } finally {
      if (mounted) setState(() => checkingServers = false);
    }
  }

  List<int> _rangeStarts(List<EpisodeItem> episodes) {
    if (episodes.length <= 50) return const [];
    final maxEpisode = episodes.indexed.fold<int>(0, (max, entry) {
      final number = episodeNumber(entry.$2.displayName);
      return math.max(max, number <= 1 ? entry.$1 + 1 : number);
    });
    final maxValue = math.max(maxEpisode, episodes.length);
    return [for (var start = 1; start <= maxValue; start += 50) start];
  }

  bool _matchesQuery(EpisodeItem episode, String query) {
    final value = query.trim().toLowerCase();
    if (value.isEmpty) return true;
    final number = episodeNumber(episode.displayName).toString();
    return episode.displayName.toLowerCase().contains(value) ||
        episode.name.toLowerCase().contains(value) ||
        number == value ||
        'tap $number'.contains(value) ||
        'tập $number'.contains(value);
  }

  bool _matchesRange(EpisodeItem episode, int index) {
    final start = selectedRangeStart;
    if (start == null) return true;
    final number = episodeNumber(episode.displayName);
    final value = number <= 1 ? index + 1 : number;
    return value >= start && value < start + 50;
  }

  Future<void> _openTvSearchDialog() async {
    final next = await showTvEpisodeSearchDialog(
      context,
      searchController.text,
    );
    if (!mounted || next == null) return;
    setState(() {
      searchController.text = next;
      if (next.trim().isNotEmpty) selectedRangeStart = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final servers = widget.movie.episodes;
    final server = servers[serverIndex.clamp(0, servers.length - 1)];
    final serverTypes = servers.map((e) => e.typeName).toSet().toList();
    final visibleServerIndexes = servers.indexed
        .where((e) => e.$2.typeName == selectedServerType)
        .map((e) => e.$1);
    final ranges = _rangeStarts(server.items);
    final query = searchController.text;
    final visibleEntries = server.items.indexed
        .where(
          (entry) =>
              _matchesRange(entry.$2, entry.$1) &&
              _matchesQuery(entry.$2, query),
        )
        .toList();
    final width = MediaQuery.sizeOf(context).width;
    final columns = isTvBuild
        ? 5
        : width >= 900
        ? 6
        : width >= 600
        ? 5
        : 3;
    final maxHeight = (MediaQuery.sizeOf(context).height * .86).clamp(
      260.0,
      620.0,
    );
    return SafeArea(
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(child: SectionTitle('Chọn tập')),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Đang xem: ${widget.currentEpisode.displayName} • ${widget.currentServer.displayName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: CvColors.muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: checkingServers
                          ? null
                          : () => _checkServers(autoSelect: true),
                      icon: checkingServers
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded),
                      label: Text(
                        checkingServers ? 'Đang kiểm tra' : 'Kiểm tra server',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final type in serverTypes)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(type),
                            selected: type == selectedServerType,
                            showCheckmark: false,
                            onSelected: (_) {
                              final i = servers.indexWhere(
                                (e) => e.typeName == type,
                              );
                              if (i >= 0) {
                                setState(() {
                                  selectedServerType = type;
                                  serverIndex = i;
                                });
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final i in visibleServerIndexes)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: useLeanbackControls
                              ? TvFilterChip(
                                  label:
                                      '${servers[i].sourceName} • ${serverHealth[i]?.label ?? 'chưa kiểm tra'}',
                                  selected: i == serverIndex,
                                  onPressed: () => setState(() {
                                    serverIndex = i;
                                    selectedRangeStart = null;
                                    searchController.clear();
                                  }),
                                )
                              : ChoiceChip(
                                  label: Text(
                                    '${servers[i].sourceName} • ${serverHealth[i]?.label ?? 'chưa kiểm tra'}',
                                  ),
                                  selected: i == serverIndex,
                                  showCheckmark: false,
                                  onSelected: (_) => setState(() {
                                    serverIndex = i;
                                    selectedRangeStart = null;
                                    searchController.clear();
                                  }),
                                ),
                        ),
                    ],
                  ),
                ),
                if (server.items.length > 12) ...[
                  const SizedBox(height: 12),
                  if (isTvBuild)
                    tvEpisodeSearchButton(
                      query: query,
                      onPressed: _openTvSearchDialog,
                    )
                  else
                    TextField(
                      controller: searchController,
                      onChanged: (_) => setState(() {}),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Tìm tập, ví dụ: 120',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: query.trim().isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Xóa tìm kiếm',
                                onPressed: () {
                                  searchController.clear();
                                  setState(() {});
                                },
                                icon: const Icon(Icons.close_rounded),
                              ),
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: .06),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                ],
                if (ranges.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: useLeanbackControls
                              ? TvFilterChip(
                                  label: 'Tất cả',
                                  selected: selectedRangeStart == null,
                                  onPressed: () =>
                                      setState(() => selectedRangeStart = null),
                                )
                              : ChoiceChip(
                                  label: const Text('Tất cả'),
                                  selected: selectedRangeStart == null,
                                  showCheckmark: false,
                                  onSelected: (_) =>
                                      setState(() => selectedRangeStart = null),
                                ),
                        ),
                        for (final start in ranges)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: useLeanbackControls
                                ? TvFilterChip(
                                    label:
                                        '$start-${math.min(start + 49, server.items.length)}',
                                    selected: selectedRangeStart == start,
                                    onPressed: () => setState(
                                      () => selectedRangeStart = start,
                                    ),
                                  )
                                : ChoiceChip(
                                    label: Text(
                                      '$start-${math.min(start + 49, server.items.length)}',
                                    ),
                                    selected: selectedRangeStart == start,
                                    showCheckmark: false,
                                    onSelected: (_) => setState(
                                      () => selectedRangeStart = start,
                                    ),
                                  ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Expanded(
                  child: visibleEntries.isEmpty
                      ? const EmptyState('Không tìm thấy tập phù hợp')
                      : GridView.builder(
                          itemCount: visibleEntries.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                                childAspectRatio: isTvBuild ? 2.8 : 2.35,
                              ),
                          itemBuilder: (context, index) {
                            final episode = visibleEntries[index].$2;
                            final selected = _isCurrent(server, episode);
                            return FocusButton(
                              selected: selected,
                              autofocus: selected && isTvBuild,
                              onPressed: () => widget.onSelect(server, episode),
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        episode.displayName,
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: selected ? Colors.white : null,
                                        ),
                                      ),
                                      if (selected) ...[
                                        const SizedBox(height: 2),
                                        const Text(
                                          'Đang xem',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: CvColors.accent,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MoviePosterCard extends StatelessWidget {
  const MoviePosterCard({
    super.key,
    required this.movie,
    required this.width,
    required this.onTap,
    this.onRemove,
    this.removeTooltip,
    this.heroTag,
  });
  final Movie movie;
  final double width;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final String? removeTooltip;
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final useLandscapeArt = isTvBuild;
    final cardMetaLine = movie.metaLineFor(
      compactLanguage: !useLandscapeArt,
      includeQuality: useLandscapeArt,
    );
    final artUrl = useLandscapeArt
        ? (movie.backdropUrl.isNotEmpty ? movie.backdropUrl : movie.posterUrl)
        : movie.posterUrl;
    final artFallbackUrl = useLandscapeArt
        ? (movie.backdropFallbackUrl.isNotEmpty
              ? movie.backdropFallbackUrl
              : movie.posterFallbackUrl)
        : movie.posterFallbackUrl;
    if (useLandscapeArt) {
      return SizedBox(
        width: width,
        child: FocusButton(
          onPressed: onTap,
          borderRadius: 14,
          child: SizedBox(
            height: moviePosterCardHeight(width),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NetworkBackdrop(
                    url: artUrl,
                    fallbackUrl: artFallbackUrl,
                    fit: BoxFit.cover,
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: .18),
                          Colors.black.withValues(alpha: .88),
                        ],
                        stops: const [.42, .68, 1],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    top: 10,
                    child: MetaPill(movie.availabilityBadgeLabel),
                  ),
                  if (movie.hasBilingualServer)
                    const Positioned(
                      left: 10,
                      top: 44,
                      child: _BilingualBadge(),
                    ),
                  if (movie.qualityBadgeLabel.isNotEmpty && onRemove == null)
                    Positioned(
                      top: 10,
                      right: 10,
                      child: MetaPill(movie.qualityBadgeLabel),
                    ),
                  if (onRemove != null)
                    Positioned(
                      top: 10,
                      right: 10,
                      child: _PosterRemoveButton(
                        tooltip: removeTooltip ?? 'Xoá',
                        onPressed: onRemove!,
                      ),
                    ),
                  Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .36),
                        shape: BoxShape.circle,
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 38,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 14,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          movie.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textScaler: TextScaler.noScaling,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            height: 1.12,
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 8),
                            ],
                          ),
                        ),
                        if (cardMetaLine.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(
                            cardMetaLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textScaler: TextScaler.noScaling,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: .82),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              shadows: const [
                                Shadow(color: Colors.black, blurRadius: 6),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: width,
      child: FocusButton(
        onPressed: onTap,
        borderRadius: 12,
        child: SizedBox(
          height: moviePosterCardHeight(width),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: useLandscapeArt ? 16 / 9 : 2 / 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      useLandscapeArt
                          ? NetworkBackdrop(
                              url: artUrl,
                              fallbackUrl: artFallbackUrl,
                              fit: BoxFit.cover,
                            )
                          : (heroTag != null
                                ? Hero(
                                    tag: heroTag!,
                                    child: NetworkPoster(
                                      url: artUrl,
                                      fallbackUrl: artFallbackUrl,
                                    ),
                                  )
                                : NetworkPoster(
                                    url: artUrl,
                                    fallbackUrl: artFallbackUrl,
                                  )),
                      Positioned(
                        left: 7,
                        top: useLandscapeArt ? 7 : null,
                        bottom: useLandscapeArt ? null : 7,
                        child: MetaPill(movie.availabilityBadgeLabel),
                      ),
                      if (movie.hasBilingualServer)
                        const Positioned(
                          left: 7,
                          top: 7,
                          child: _BilingualBadge(),
                        ),
                      if (movie.qualityBadgeLabel.isNotEmpty &&
                          onRemove == null)
                        Positioned(
                          top: 7,
                          right: 7,
                          child: MetaPill(movie.qualityBadgeLabel),
                        ),
                      if (onRemove != null)
                        Positioned(
                          top: 7,
                          right: 7,
                          child: _PosterRemoveButton(
                            tooltip: removeTooltip ?? 'Xoá',
                            onPressed: onRemove!,
                          ),
                        ),
                      if (useLandscapeArt) ...[
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: .12),
                                  Colors.black.withValues(alpha: .82),
                                ],
                                stops: const [.45, .7, 1],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 12,
                          right: 12,
                          bottom: 10,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                movie.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textScaler: TextScaler.noScaling,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  height: 1.15,
                                  shadows: [
                                    Shadow(color: Colors.black, blurRadius: 8),
                                  ],
                                ),
                              ),
                              if (cardMetaLine.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  cardMetaLine,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textScaler: TextScaler.noScaling,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: .82),
                                    fontSize: 12,
                                    shadows: const [
                                      Shadow(
                                        color: Colors.black,
                                        blurRadius: 6,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (!useLandscapeArt) ...[
                const SizedBox(height: 8),
                SizedBox(
                  height: 42,
                  child: Text(
                    movie.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textScaler: TextScaler.noScaling,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1.18,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 18,
                  child: Text(
                    cardMetaLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textScaler: TextScaler.noScaling,
                    style: const TextStyle(color: CvColors.muted, fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PosterRemoveButton extends StatelessWidget {
  const _PosterRemoveButton({required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: .58),
    shape: CircleBorder(
      side: BorderSide(color: Colors.white.withValues(alpha: .2)),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onPressed,
      customBorder: const CircleBorder(),
      child: Tooltip(
        message: tooltip,
        child: SizedBox.square(
          dimension: 34,
          child: Icon(
            Icons.close_rounded,
            size: 22,
            color: Colors.white.withValues(alpha: .94),
          ),
        ),
      ),
    ),
  );
}

class ContinueCard extends StatelessWidget {
  const ContinueCard({
    super.key,
    required this.item,
    required this.width,
    required this.onTap,
    this.onRemove,
  });
  final WatchItem item;
  final double width;
  final VoidCallback onTap;
  final Future<void> Function()? onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            FocusTraversalOrder(
              order: const NumericFocusOrder(0),
              child: FocusButton(
                onPressed: () async {
                  if (!isTvBuild || onRemove == null) {
                    onTap();
                    return;
                  }
                  final choice = await showDialog<String>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: Text(item.title),
                      content: const Text('Bạn muốn làm gì với phim này?'),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.pop(dialogContext, 'remove'),
                          child: const Text('Xoá khỏi Xem tiếp'),
                        ),
                        FilledButton(
                          onPressed: () =>
                              Navigator.pop(dialogContext, 'resume'),
                          child: const Text('Xem tiếp'),
                        ),
                      ],
                    ),
                  );
                  if (!context.mounted) return;
                  if (choice == 'remove') {
                    await onRemove!();
                  } else if (choice == 'resume') {
                    onTap();
                  }
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NetworkBackdrop(
                        url: item.backdrop.isNotEmpty
                            ? item.backdrop
                            : item.poster,
                        fit: BoxFit.cover,
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: .84),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 14,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                MiniBadge(item.episodeName),
                                if (item.serverName.isNotEmpty)
                                  MiniBadge(item.serverName),
                                MiniBadge('${item.progressPercent}%'),
                              ],
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: item.progress,
                              minHeight: 4,
                              backgroundColor: Colors.white24,
                              color: CvColors.accent,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${fmtDuration(Duration(milliseconds: item.positionMs))}'
                              ' / ${fmtDuration(Duration(milliseconds: item.durationMs))}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: CvColors.muted,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Center(
                        child: Icon(
                          Icons.play_circle_fill_rounded,
                          size: 48,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!isTvBuild && onRemove != null)
              Positioned(
                top: 8,
                right: 8,
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(1),
                  child: FocusButton(
                    autofocus: false,
                    onPressed: () => onRemove!(),
                    child: Tooltip(
                      message: 'Xoá khỏi Xem tiếp',
                      child: Material(
                        color: Colors.black.withValues(alpha: .58),
                        shape: const CircleBorder(),
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class MiniBadge extends StatelessWidget {
  const MiniBadge(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .52),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: Colors.white.withValues(alpha: .12)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
      ),
    ),
  );
}

class NetworkPoster extends StatelessWidget {
  const NetworkPoster({super.key, required this.url, this.fallbackUrl = ''});
  final String url;
  final String fallbackUrl;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const PosterFallback();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : cardExtent(context);
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : width * 1.5;
        final fallback = fallbackUrl.trim();
        Widget image(String imageUrl, {required bool allowFallback}) =>
            CachedNetworkImage(
              imageUrl: imageUrl,
              fit: BoxFit.cover,
              memCacheWidth: cachePixels(context, width, max: 900),
              memCacheHeight: cachePixels(context, height, max: 1400),
              maxWidthDiskCache: cachePixels(context, width, max: 900),
              maxHeightDiskCache: cachePixels(context, height, max: 1400),
              fadeInDuration: const Duration(milliseconds: 120),
              useOldImageOnUrlChange: true,
              placeholder: (_, _) => const PosterFallback(),
              errorWidget: (_, _, _) =>
                  allowFallback && fallback.isNotEmpty && fallback != imageUrl
                  ? image(fallback, allowFallback: false)
                  : const PosterFallback(),
            );
        return RepaintBoundary(child: image(url, allowFallback: true));
      },
    );
  }
}

class NetworkBackdrop extends StatelessWidget {
  const NetworkBackdrop({
    super.key,
    required this.url,
    this.fallbackUrl = '',
    required this.fit,
  });
  final String url;
  final String fallbackUrl;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const PosterFallback();
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = MediaQuery.sizeOf(context);
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : size.width;
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : math.max(width * 9 / 16, 180.0);
        final fallback = fallbackUrl.trim();
        Widget image(String imageUrl, {required bool allowFallback}) =>
            CachedNetworkImage(
              imageUrl: imageUrl,
              fit: fit,
              memCacheWidth: cachePixels(context, width, max: 1800),
              memCacheHeight: cachePixels(context, height, max: 1100),
              maxWidthDiskCache: cachePixels(context, width, max: 1800),
              maxHeightDiskCache: cachePixels(context, height, max: 1100),
              fadeInDuration: const Duration(milliseconds: 120),
              useOldImageOnUrlChange: true,
              placeholder: (_, _) => const PosterFallback(),
              errorWidget: (_, _, _) =>
                  allowFallback && fallback.isNotEmpty && fallback != imageUrl
                  ? image(fallback, allowFallback: false)
                  : const PosterFallback(),
            );
        return RepaintBoundary(child: image(url, allowFallback: true));
      },
    );
  }
}

class TvActionButton extends StatelessWidget {
  const TvActionButton({
    super.key,
    this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.primary = false,
    this.danger = false,
    this.width,
    this.onFocus,
  });

  final IconData? icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final bool primary;
  final bool danger;
  final double? width;
  final VoidCallback? onFocus;

  @override
  Widget build(BuildContext context) {
    final background = primary
        ? Colors.white
        : selected
        ? CvColors.accent.withValues(alpha: .22)
        : Colors.white.withValues(alpha: .09);
    final foreground = primary ? Colors.black : Colors.white;
    final border = danger
        ? CvColors.danger.withValues(alpha: .62)
        : selected
        ? CvColors.accent.withValues(alpha: .78)
        : Colors.white.withValues(alpha: .14);
    final content = Container(
      width: width,
      constraints: const BoxConstraints(minHeight: 58, minWidth: 138),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: onPressed == null
            ? CvColors.panel.withValues(alpha: .42)
            : background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, color: danger ? CvColors.danger : foreground, size: 25),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: foreground,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
    if (onPressed == null) return Opacity(opacity: .48, child: content);
    return FocusButton(
      selected: selected,
      onPressed: onPressed!,
      onFocus: onFocus,
      child: content,
    );
  }
}

class TvFilterChip extends StatelessWidget {
  const TvFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => TvActionButton(
    icon: icon,
    label: label,
    selected: selected,
    onPressed: onPressed,
    width: 166,
  );
}

class FocusButton extends StatefulWidget {
  const FocusButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.selected = false,
    this.autofocus = false,
    this.focusNode,
    this.onFocus,
    this.borderRadius = 8,
  });
  final Widget child;
  final VoidCallback onPressed;
  final bool selected;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback? onFocus;
  final double borderRadius;

  @override
  State<FocusButton> createState() => _FocusButtonState();
}

class _FocusButtonState extends State<FocusButton> {
  bool focused = false;

  void _handleFocusChange(bool value) {
    setState(() => focused = value);
    if (!value || !isTvBuild) return;
    if (widget.onFocus != null) {
      widget.onFocus!();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: _handleFocusChange,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onPressed();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedScale(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        scale: focused && isTvBuild ? 1.025 : 1,
        child: Material(
          color: widget.selected
              ? CvColors.accent.withValues(alpha: .14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(widget.borderRadius),
          clipBehavior: Clip.none,
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                border: Border.all(
                  color: focused
                      ? (isTvBuild ? CvColors.accent : Colors.white)
                      : Colors.transparent,
                  width: focused ? 2 : 1,
                ),
                boxShadow: focused && isTvBuild
                    ? [
                        BoxShadow(
                          color: CvColors.accent.withValues(alpha: .55),
                          blurRadius: 26,
                          spreadRadius: 1,
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .5),
                          blurRadius: 18,
                          offset: const Offset(0, 10),
                        ),
                      ]
                    : null,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: CvColors.panel,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: CvColors.border),
    ),
    clipBehavior: Clip.antiAlias,
    child: Material(
      color: Colors.transparent,
      child: Padding(padding: const EdgeInsets.all(18), child: child),
    ),
  );
}

class ProfileTile extends StatelessWidget {
  const ProfileTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: FocusButton(
      onPressed: onTap,
      child: ListTile(
        tileColor: CvColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        leading: Icon(icon, color: CvColors.accent),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    ),
  );
}

class CineLogo extends StatelessWidget {
  const CineLogo({super.key, required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/branding/cineviet-icon.png',
    width: size,
    height: size,
    errorBuilder: (_, _, _) =>
        Icon(Icons.movie_filter_rounded, size: size, color: CvColors.accent),
  );
}

class SidebarLogo extends StatelessWidget {
  const SidebarLogo({super.key});

  @override
  Widget build(BuildContext context) {
    final width = isTvBuild ? 88.0 : 76.0;
    final height = isTvBuild ? 88.0 : 76.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.asset(
        'assets/branding/cineviet-sidebar-logo.jpg',
        width: width,
        height: height,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const CineLogo(size: 48),
      ),
    );
  }
}

class CineWordmark extends StatelessWidget {
  const CineWordmark({super.key});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const CineLogo(size: 36),
      const SizedBox(width: 10),
      Text(
        'CINEVIET',
        style: TextStyle(
          color: CvColors.accent,
          fontSize: isTvBuild ? 28 : 24,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    ],
  );
}

class FeaturedBadge extends StatelessWidget {
  const FeaturedBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: CvColors.accent.withValues(alpha: .92),
      borderRadius: BorderRadius.circular(6),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: .35),
          blurRadius: 16,
          offset: const Offset(0, 8),
        ),
      ],
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.local_fire_department_rounded, size: 18),
        SizedBox(width: 6),
        Text(
          'Phim nổi bật',
          style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0),
        ),
      ],
    ),
  );
}

class PosterFallback extends StatelessWidget {
  const PosterFallback({super.key});

  @override
  Widget build(BuildContext context) => Container(
    color: CvColors.panel2,
    alignment: Alignment.center,
    child: const Icon(Icons.movie_creation_rounded, color: CvColors.muted),
  );
}

class MetaPill extends StatelessWidget {
  const MetaPill(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .7),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
    ),
  );
}

class _BilingualBadge extends StatelessWidget {
  const _BilingualBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xFF7C3AED),
      borderRadius: BorderRadius.circular(6),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFF7C3AED).withValues(alpha: .36),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ],
    ),
    child: const Text(
      'SN',
      style: TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

class InfoPill extends StatelessWidget {
  const InfoPill(this.label, {super.key, this.prominent = false});
  final String label;
  final bool prominent;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: prominent
          ? CvColors.accent.withValues(alpha: .92)
          : Colors.black.withValues(alpha: .62),
      borderRadius: BorderRadius.circular(6),
      border: prominent
          ? null
          : Border.all(color: Colors.white.withValues(alpha: .12)),
    ),
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: prominent ? CvColors.black : CvColors.text,
        fontSize: 12,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

class GenreChip extends StatelessWidget {
  const GenreChip({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Chip(
    label: Text(label),
    backgroundColor: CvColors.panel,
    side: BorderSide(color: Colors.white.withValues(alpha: .08)),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: TextStyle(
      fontSize: isTvBuild ? 26 : 22,
      fontWeight: FontWeight.w900,
    ),
  );
}

class PageHeading extends StatelessWidget {
  const PageHeading(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: TextStyle(
      fontSize: isTvBuild ? 34 : 30,
      fontWeight: FontWeight.w900,
    ),
  );
}

class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final cardW = cardExtent(context);
    final cardH = moviePosterCardHeight(cardW);
    Widget row(String _) => Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: pagePadding(context).copyWith(top: 0, bottom: 12),
            child: SkeletonBox(width: 160, height: 20, borderRadius: 6),
          ),
          SizedBox(
            height: cardH,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: pagePadding(context).copyWith(top: 0, bottom: 0),
              physics: const NeverScrollableScrollPhysics(),
              itemCount: 5,
              separatorBuilder: (_, i) => const SizedBox(width: 14),
              itemBuilder: (_, i) =>
                  SkeletonBox(width: cardW, height: cardH, borderRadius: 8),
            ),
          ),
        ],
      ),
    );
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: SkeletonBox(
              width: double.infinity,
              height: heroBannerHeight(context),
              borderRadius: 0,
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildListDelegate([
            for (final t in const ['a', 'b', 'c', 'd', 'e']) row(t),
            const SizedBox(height: 48),
          ]),
        ),
      ],
    );
  }
}

class LoadingPage extends StatelessWidget {
  const LoadingPage({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SingleChildScrollView(
      padding: pagePadding(context).copyWith(top: 72, bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: CvColors.muted)),
          const SizedBox(height: 18),
          SkeletonBox(
            width: double.infinity,
            height: isTvBuild ? 280 : 220,
            borderRadius: 18,
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 14,
            runSpacing: 18,
            children: [
              for (var i = 0; i < 8; i++)
                SkeletonBox(
                  width: cardExtent(context),
                  height: moviePosterCardHeight(cardExtent(context)),
                  borderRadius: 8,
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = 12,
  });
  final double width;
  final double height;
  final double borderRadius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, child) {
      final value = controller.value;
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          gradient: LinearGradient(
            begin: Alignment(-1 + value * 2, -1),
            end: Alignment(value * 2, 1),
            colors: const [CvColors.panel, CvColors.panel2, CvColors.panel],
          ),
        ),
      );
    },
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(color: CvColors.muted),
      ),
    ),
  );
}

class EmptyActionState extends StatelessWidget {
  const EmptyActionState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_rounded,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: CvColors.muted),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: CvColors.muted,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    ),
  );
}

class InlineErrorState extends StatelessWidget {
  const InlineErrorState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off_rounded, size: 44, color: CvColors.amber),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: CvColors.muted,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Thử lại'),
          ),
        ],
      ),
    ),
  );
}

EdgeInsets pagePadding(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  final horizontal = isTvBuild
      ? 44.0
      : width >= 1300
      ? 52.0
      : width >= 800
      ? 32.0
      : 16.0;
  return EdgeInsets.symmetric(horizontal: horizontal);
}

double cardExtent(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (isTvBuild) return 176;
  if (width >= 1200) return 172;
  if (width >= 800) return 150;
  return 132;
}

double movieCardExtent(BuildContext context) =>
    isTvBuild ? landscapeExtent(context) : cardExtent(context);

double moviePosterCardHeight(double width) =>
    isTvBuild ? (width * .68) : (width * 1.5 + 72);

double moviePosterRowHeight(double width) =>
    moviePosterCardHeight(width) + (isTvBuild ? 34 : 0);

double landscapeExtent(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (isTvBuild) return 360;
  if (width >= 1100) return 330;
  if (width >= 700) return 300;
  return 250;
}

String fmtDuration(Duration d) {
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '$m:${s.toString().padLeft(2, '0')}';
}

int cachePixels(
  BuildContext context,
  double logicalPixels, {
  required int max,
}) {
  if (!logicalPixels.isFinite || logicalPixels <= 0) return max;
  final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 3.0);
  return (logicalPixels * dpr).round().clamp(64, max).toInt();
}

int episodeNumber(String value) {
  final match = RegExp(r'\d+').firstMatch(value);
  if (match == null) return 1;
  return int.tryParse(match.group(0) ?? '') ?? 1;
}

void openDetail(
  BuildContext context,
  MovieRepository repo,
  Movie movie, {
  bool autoplay = false,
  String? heroTag,
}) {
  final page = MovieDetailScreen(
    repo: repo,
    initial: movie,
    autoplay: autoplay,
    heroTag: heroTag,
  );
  if (isTvBuild) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    return;
  }
  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 340),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, _, _) => page,
      transitionsBuilder: (_, animation, secondaryAnimation, child) {
        // Slide-up modal kiểu Crunchyroll: trang chi tiết trượt từ dưới lên
        // đè lên home, kèm fade nhẹ.
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    ),
  );
}

void openPlayer(
  BuildContext context,
  MovieRepository repo,
  Movie movie,
  EpisodeServer server,
  EpisodeItem episode,
  int serverIndex,
) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PlayerScreen(
        repo: repo,
        movie: movie,
        server: server,
        episode: episode,
        serverIndex: serverIndex,
      ),
    ),
  );
}

void showSnack(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 6),
      margin: EdgeInsets.fromLTRB(
        isTvBuild ? 48 : 16,
        0,
        isTvBuild ? 48 : 16,
        isTvBuild ? 42 : 92,
      ),
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.info_rounded, color: CvColors.accent, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: CvColors.text,
                fontSize: 15,
                fontWeight: FontWeight.w900,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<bool> isLoggedIn() async {
  return (await Api.instance.currentUser()) != null;
}

Map<String, dynamic>? userMapFromAuthResponse(dynamic data) {
  if (data is! Map) return null;
  final raw = data['user'] is Map ? data['user'] : data;
  if (raw is! Map || raw.isEmpty) return null;
  final user = Map<String, dynamic>.from(raw);
  final id = cleanText(user['id'] ?? user['_id'] ?? user['email']);
  return id.isEmpty ? null : user;
}

Future<bool> requireOfflineVip(BuildContext context) async {
  final user =
      await Api.instance.currentUser() ?? await Api.instance.cachedUser();
  if (user != null && (isVipUser(user) || isAdminUser(user))) return true;
  if (!context.mounted) return false;
  showSnack(context, 'Tải xuống cần tài khoản VIP hoặc Administrator');
  return false;
}

Future<bool> requireOfflineLogin(BuildContext context) async {
  // Không gọi /auth/me ở đây: thư viện tải xuống phải mở được khi mất mạng.
  // Phiên lưu cục bộ chỉ tồn tại sau khi đăng nhập thành công và bị xóa khi
  // đăng xuất, nên đủ để khóa tính năng này mà không phụ thuộc kết nối mạng.
  if (await Api.instance.hasStoredSession()) return true;
  if (!context.mounted) return false;
  return requireLogin(context, 'Tải xuống');
}

Future<bool> requireLogin(BuildContext context, String feature) async {
  if (await isLoggedIn()) return true;
  if (!context.mounted) return false;
  final openLogin = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('$feature cần đăng nhập'),
      content: const Text(
        'Đăng nhập tài khoản CineViet để đồng bộ yêu thích, lịch sử xem và dùng tính năng này trên mọi thiết bị.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Để sau'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Đăng nhập'),
        ),
      ],
    ),
  );
  if (openLogin == true && context.mounted) {
    final shell = context.findAncestorStateOfType<_AppShellState>();
    if (shell != null) {
      shell.openProfileTab();
    } else {
      showSnack(context, 'Mở tab Tài khoản để đăng nhập CineViet');
    }
  }
  return false;
}

String offlineDownloadId(
  Movie movie,
  EpisodeServer server,
  EpisodeItem episode,
) {
  final raw = '${movie.id}|${movie.slug}|${server.name}|${episode.name}';
  return base64Url.encode(utf8.encode(raw)).replaceAll('=', '');
}

String formatOfflineBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class OfflineEpisodePicker extends StatefulWidget {
  const OfflineEpisodePicker({
    super.key,
    required this.movie,
    required this.servers,
    required this.initialServerIndex,
  });
  final Movie movie;
  final List<EpisodeServer> servers;
  final int initialServerIndex;

  @override
  State<OfflineEpisodePicker> createState() => _OfflineEpisodePickerState();
}

class _OfflineEpisodePickerState extends State<OfflineEpisodePicker> {
  late int serverIndex = widget.initialServerIndex.clamp(
    0,
    widget.servers.length - 1,
  );
  final manager = OfflineDownloadManager.instance;

  @override
  void initState() {
    super.initState();
    manager.addListener(_refresh);
    unawaited(manager.load());
  }

  @override
  void dispose() {
    manager.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _download(EpisodeServer server, EpisodeItem episode) async {
    final source = episode.linkM3u8.trim();
    if (source.isEmpty) {
      showSnack(context, 'Nguồn embed này không hỗ trợ tải offline');
      return;
    }
    var selectedAudio = episode.audioSources;
    var selectedSubtitles = episode.subtitles;
    if (episode.audioSources.length > 1 || episode.subtitles.isNotEmpty) {
      final selection = await showDialog<_OfflineTrackSelection>(
        context: context,
        builder: (_) => _OfflineTrackPicker(
          audioSources: episode.audioSources,
          subtitles: episode.subtitles,
        ),
      );
      if (selection == null || !mounted) return;
      selectedAudio = selection.audioSources;
      selectedSubtitles = selection.subtitles;
    }
    try {
      await manager.enqueue(
        id: offlineDownloadId(widget.movie, server, episode),
        movieId: widget.movie.id,
        movieSlug: widget.movie.slug,
        movieTitle: widget.movie.title,
        episodeName: episode.name,
        serverName: server.name,
        sourceUrl: source,
        posterUrl: widget.movie.posterUrl,
        audioSources: selectedAudio
            .map(
              (source) => {
                'key': source.key,
                'label': source.label,
                'url': source.url,
              },
            )
            .toList(),
        subtitles: selectedSubtitles
            .map(
              (subtitle) => {
                'lang': subtitle.lang,
                'label': subtitle.label,
                'url': subtitle.url,
                'format': subtitle.format,
              },
            )
            .toList(),
      );
      if (mounted) {
        showSnack(context, 'Đã thêm ${episode.displayName} vào tải xuống');
      }
    } catch (error) {
      if (mounted) {
        showSnack(
          context,
          error.toString().replaceFirst('FormatException: ', ''),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final availableServers = widget.servers
        .where((server) => server.supportsOfflineDownload)
        .toList();
    if (availableServers.isEmpty) {
      return const SafeArea(child: EmptyState('Không có nguồn tải khả dụng'));
    }
    if (serverIndex >= availableServers.length) serverIndex = 0;
    final server = availableServers[serverIndex];
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .78,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                children: [
                  const Icon(Icons.download_rounded, color: CvColors.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Tải ${widget.movie.title}',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final entry in availableServers.indexed)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(entry.$2.displayName),
                        selected: entry.$1 == serverIndex,
                        onSelected: (_) =>
                            setState(() => serverIndex = entry.$1),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                itemCount: server.items
                    .where((episode) => episode.linkM3u8.trim().isNotEmpty)
                    .length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final episodes = server.items
                      .where((episode) => episode.linkM3u8.trim().isNotEmpty)
                      .toList();
                  final episode = episodes[index];
                  final item = manager.find(
                    offlineDownloadId(widget.movie, server, episode),
                  );
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      episode.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: item == null
                        ? Text(server.sourceName)
                        : Text(_offlineStateLabel(item)),
                    trailing: item?.isActive == true
                        ? SizedBox(
                            width: 42,
                            height: 42,
                            child: IconButton(
                              tooltip: 'Hủy tải',
                              onPressed: () => manager.cancel(item!.id),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          )
                        : item?.state == OfflineDownloadState.completed
                        ? const Icon(
                            Icons.download_done_rounded,
                            color: CvColors.accent,
                          )
                        : IconButton(
                            tooltip: item == null ? 'Tải xuống' : 'Tải lại',
                            onPressed: () => _download(server, episode),
                            icon: Icon(
                              item == null
                                  ? Icons.download_rounded
                                  : Icons.refresh_rounded,
                            ),
                          ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OfflineTrackSelection {
  const _OfflineTrackSelection(this.audioSources, this.subtitles);
  final List<EpisodeAudioSource> audioSources;
  final List<EpisodeSubtitleTrack> subtitles;
}

class _OfflineTrackPicker extends StatefulWidget {
  const _OfflineTrackPicker({
    required this.audioSources,
    required this.subtitles,
  });
  final List<EpisodeAudioSource> audioSources;
  final List<EpisodeSubtitleTrack> subtitles;

  @override
  State<_OfflineTrackPicker> createState() => _OfflineTrackPickerState();
}

class _OfflineTrackPickerState extends State<_OfflineTrackPicker> {
  late final selectedAudio = widget.audioSources.map((e) => e.key).toSet();
  late final selectedSubtitles = widget.subtitles.map((e) => e.url).toSet();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Chọn nội dung tải'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440, maxHeight: 520),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.audioSources.isNotEmpty) ...[
              const Text(
                'Audio',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              for (final track in widget.audioSources)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: selectedAudio.contains(track.key),
                  title: Text(track.label),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      selectedAudio.add(track.key);
                    } else {
                      selectedAudio.remove(track.key);
                    }
                  }),
                ),
              const SizedBox(height: 10),
            ],
            if (widget.subtitles.isNotEmpty) ...[
              const Text(
                'Phụ đề',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              for (final track in widget.subtitles)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: selectedSubtitles.contains(track.url),
                  title: Text(track.label),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      selectedSubtitles.add(track.url);
                    } else {
                      selectedSubtitles.remove(track.url);
                    }
                  }),
                ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      FilledButton.icon(
        onPressed: selectedAudio.isEmpty && widget.audioSources.isNotEmpty
            ? null
            : () => Navigator.pop(
                context,
                _OfflineTrackSelection(
                  widget.audioSources
                      .where((track) => selectedAudio.contains(track.key))
                      .toList(),
                  widget.subtitles
                      .where((track) => selectedSubtitles.contains(track.url))
                      .toList(),
                ),
              ),
        icon: const Icon(Icons.download_rounded),
        label: const Text('Tải xuống'),
      ),
    ],
  );
}

String _offlineStateLabel(OfflineDownloadItem item) {
  switch (item.state) {
    case OfflineDownloadState.queued:
      return 'Đang chờ tải';
    case OfflineDownloadState.downloading:
      final progress = item.progress;
      final percent = progress == null ? '' : ' ${(progress * 100).round()}%';
      return 'Đang tải$percent • ${formatOfflineBytes(item.receivedBytes)}';
    case OfflineDownloadState.completed:
      return 'Đã tải • ${formatOfflineBytes(item.receivedBytes)}';
    case OfflineDownloadState.cancelled:
      return 'Đã hủy • chạm tải lại';
    case OfflineDownloadState.failed:
      return item.error.isEmpty ? 'Tải thất bại' : item.error;
  }
}

class OfflineDownloadsScreen extends StatefulWidget {
  const OfflineDownloadsScreen({super.key, required this.repo});
  final MovieRepository repo;

  @override
  State<OfflineDownloadsScreen> createState() => _OfflineDownloadsScreenState();
}

class _OfflineDownloadsScreenState extends State<OfflineDownloadsScreen> {
  final manager = OfflineDownloadManager.instance;

  @override
  void initState() {
    super.initState();
    manager.addListener(_refresh);
    unawaited(manager.load());
  }

  @override
  void dispose() {
    manager.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _play(OfflineDownloadItem item) async {
    final file = File(item.localManifestPath);
    if (!await file.exists()) {
      if (mounted) showSnack(context, 'Bản tải xuống không còn trên thiết bị');
      return;
    }
    final movie = Movie(
      id: item.movieId,
      title: item.movieTitle,
      slug: item.movieSlug,
      poster: item.posterUrl,
    );
    final episode = EpisodeItem(
      name: item.episodeName,
      linkM3u8: item.sourceUrl,
      audioSources: item.audioSources
          .map((value) => EpisodeAudioSource.fromJson(value))
          .toList(),
      subtitles: item.subtitles
          .map((value) => EpisodeSubtitleTrack.fromJson(value))
          .toList(),
    );
    final server = EpisodeServer(name: item.serverName, items: [episode]);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          repo: widget.repo,
          movie: movie,
          server: server,
          episode: episode,
          serverIndex: 0,
          offlineManifestPath: item.localManifestPath,
        ),
      ),
    );
  }

  Future<void> _confirmDeleteMovie(List<OfflineDownloadItem> items) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xóa folder phim?'),
        content: Text(
          '${items.first.movieTitle} và toàn bộ ${items.length} tập sẽ bị xóa.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Giữ lại'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await manager.deleteMovie(items.map((item) => item.id));
    }
  }

  Future<void> _confirmDelete(OfflineDownloadItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xóa bản tải xuống?'),
        content: Text(
          '${item.movieTitle} • ${EpisodeItem(name: item.episodeName).displayName} sẽ bị xóa khỏi thiết bị.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Giữ lại'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (confirmed == true) await manager.delete(item.id);
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<OfflineDownloadItem>>{};
    for (final item in manager.items) {
      final key = item.movieId > 0
          ? 'id:${item.movieId}'
          : 'slug:${item.movieSlug}';
      groups.putIfAbsent(key, () => []).add(item);
    }
    final movies = groups.values.toList()
      ..sort((a, b) => b.first.createdAt.compareTo(a.first.createdAt));
    return Scaffold(
      appBar: AppBar(title: const Text('Tải xuống')),
      body: movies.isEmpty
          ? const EmptyState('Chưa có nội dung tải xuống')
          : ListView.separated(
              padding: pagePadding(context).copyWith(top: 18, bottom: 32),
              itemCount: movies.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final episodes = movies[index]
                  ..sort(
                    (a, b) => episodeNumber(
                      a.episodeName,
                    ).compareTo(episodeNumber(b.episodeName)),
                  );
                final movie = episodes.first;
                final completed = episodes
                    .where(
                      (item) => item.state == OfflineDownloadState.completed,
                    )
                    .length;
                final totalBytes = episodes.fold<int>(
                  0,
                  (total, item) => total + item.receivedBytes,
                );
                return Dismissible(
                  key: ValueKey(
                    'download-movie-${movie.movieId}-${movie.movieSlug}',
                  ),
                  direction: isTvBuild
                      ? DismissDirection.none
                      : DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    decoration: BoxDecoration(
                      color: CvColors.danger.withValues(alpha: .85),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(
                      Icons.delete_forever_rounded,
                      color: Colors.white,
                    ),
                  ),
                  confirmDismiss: (_) async {
                    await _confirmDeleteMovie(episodes);
                    return false;
                  },
                  child: Panel(
                    child: ExpansionTile(
                      tilePadding: const EdgeInsets.all(12),
                      childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 56,
                          height: 76,
                          child: movie.posterUrl.isEmpty
                              ? const ColoredBox(
                                  color: CvColors.panel2,
                                  child: Icon(Icons.movie_rounded),
                                )
                              : CachedNetworkImage(
                                  imageUrl: movie.posterUrl,
                                  fit: BoxFit.cover,
                                ),
                        ),
                      ),
                      title: Text(
                        movie.movieTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      subtitle: Text(
                        '$completed/${episodes.length} tập đã tải • ${formatOfflineBytes(totalBytes)}',
                        style: const TextStyle(color: CvColors.muted),
                      ),
                      trailing: isTvBuild
                          ? IconButton(
                              tooltip: 'Xóa toàn bộ phim',
                              onPressed: () => _confirmDeleteMovie(episodes),
                              icon: const Icon(Icons.delete_forever_rounded),
                            )
                          : null,
                      children: [
                        for (final item in episodes) _downloadEpisodeTile(item),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _downloadEpisodeTile(OfflineDownloadItem item) => Column(
    children: [
      const Divider(height: 1),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          EpisodeItem(name: item.episodeName).displayName,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _offlineStateLabel(item),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: item.state == OfflineDownloadState.failed
                    ? CvColors.danger
                    : CvColors.soft,
                fontSize: 12,
              ),
            ),
            if (item.isActive) ...[
              const SizedBox(height: 7),
              LinearProgressIndicator(
                value: item.progress,
                color: CvColors.accent,
              ),
            ],
          ],
        ),
        trailing: Wrap(
          spacing: 2,
          children: [
            if (item.state == OfflineDownloadState.completed)
              IconButton(
                tooltip: 'Phát offline',
                onPressed: () => _play(item),
                icon: const Icon(
                  Icons.play_circle_fill_rounded,
                  color: CvColors.accent,
                ),
              )
            else if (item.isActive)
              IconButton(
                tooltip: 'Hủy',
                onPressed: () => manager.cancel(item.id),
                icon: const Icon(Icons.close_rounded),
              )
            else
              IconButton(
                tooltip: 'Tải lại',
                onPressed: () => manager.retry(item.id),
                icon: const Icon(Icons.refresh_rounded),
              ),
            IconButton(
              tooltip: 'Xóa',
              onPressed: () => _confirmDelete(item),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
      ),
    ],
  );
}
