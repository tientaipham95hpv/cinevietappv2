import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform, Process, ProcessStartMode;
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

const apiBase = 'https://cineviet.live/api';
const siteBase = 'https://cineviet.live';
const isTvBuild = bool.fromEnvironment('APP_IS_TV');
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
      fontFamily: 'Inter',
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
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('cineviet_v2_access_token') ??
        prefs.getString('cineviet_access_token');
  }

  Future<String?> _readRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('cineviet_v2_refresh_token') ??
        prefs.getString('cineviet_refresh_token');
  }

  Future<void> restoreToken() async {
    final token = await _readAccessToken();
    if (token != null && token.isNotEmpty) {
      dio.options.headers['Authorization'] = 'Bearer $token';
    }
  }

  Future<void> saveSession(String token, String refreshToken) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cineviet_v2_access_token', token);
    await prefs.setString('cineviet_access_token', token);
    if (refreshToken.isNotEmpty) {
      await prefs.setString('cineviet_v2_refresh_token', refreshToken);
      await prefs.setString('cineviet_refresh_token', refreshToken);
    }
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
    dio.options.headers.remove('Authorization');
  }

  Future<Map<String, dynamic>?> currentUser({bool allowRefresh = true}) async {
    if (!hasAuthToken) await restoreToken();
    if (!hasAuthToken && allowRefresh) await refreshToken();
    if (!hasAuthToken) return null;
    try {
      final res = await dio.get('/auth/me');
      final user = userMapFromAuthResponse(res.data);
      if (user != null || !allowRefresh) return user;
      if (!await refreshToken()) return null;
      final retry = await dio.get('/auth/me');
      return userMapFromAuthResponse(retry.data);
    } catch (_) {
      if (!allowRefresh || !await refreshToken()) return null;
      try {
        final retry = await dio.get('/auth/me');
        return userMapFromAuthResponse(retry.data);
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
    this.genres = const [],
    this.cast = const [],
    this.directors = const [],
    this.episodes = const [],
    this.related = const [],
  });

  final int id;
  final String title;
  final String slug;
  final String titleEn;
  final String description;
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
  final List<String> genres;
  final List<MoviePerson> cast;
  final List<MoviePerson> directors;
  final List<EpisodeServer> episodes;
  final List<Movie> related;

  String get posterUrl => imageUrl(poster.isNotEmpty ? poster : thumbnail);
  String get backdropUrl => imageUrl(
    backdrop.isNotEmpty
        ? backdrop
        : (thumbnail.isNotEmpty ? thumbnail : poster),
  );
  String get routeKey => slug.isNotEmpty ? slug : '$id';
  bool get hasPlayableVideo => episodes.any(
    (server) => server.items.any((episode) => episode.playUrl.isNotEmpty),
  );
  bool get isTrailerOnly => !hasPlayableVideo && trailerUrl.isNotEmpty;
  String get posterBadgeLabel =>
      isTrailerOnly ? 'Trailer' : (quality.isEmpty ? 'HD' : quality);
  String get metaLine {
    final parts = [
      if (releaseYear != null) '$releaseYear',
      if (quality.isNotEmpty) quality,
      if (language.isNotEmpty) language,
      if (episodeCurrent.isNotEmpty) episodeCurrent,
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
      // Thứ tự ưu tiên nguồn phát: OPhim → KKPhim/PhimAPI → NguồnC.
      // NguồnC/StreamC chỉ là dự phòng embed/WebView, không đứng trước m3u8 sạch.
      if (name.contains('ophim')) return 0;
      if (name.contains('kkphim') || name.contains('phimapi')) return 1;
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
      genres: csv(json['genres']),
      cast: parsePeople(json['cast'] ?? json['actors']),
      directors: parsePeople(json['director'] ?? json['directors']),
      episodes: episodes,
      related: parseRelated(json['related']),
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
    'genres': genres,
  };
}

class EpisodeServer {
  const EpisodeServer({required this.name, required this.items});
  final String name;
  final List<EpisodeItem> items;

  String get displayName {
    final base = name
        .replaceAll(
          RegExp(
            r'\s*\[(ophim|kkphim|phimapi|nguồn\s*c|nguonc)\]\s*',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\s*(ophim|kkphim|phimapi|nguồn\s*c|nguonc)\s*[-–]\s*',
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
  });

  final String name;
  final String filename;
  final String linkM3u8;
  final String linkEmbed;

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
  );
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
  });

  final int id;
  final String content;
  final String userName;
  final String userAvatar;
  final String createdAt;
  final int likes;
  final bool isSpoiler;

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

class MovieRepository {
  MovieRepository(this.api);
  final Api api;
  final Map<String, Movie> _cache = {};
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
  }) async {
    final res = await api.dio.get(
      '/movies',
      queryParameters: {
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
      },
    );
    final movies = ((res.data['movies'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Movie.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    for (final movie in movies) {
      _cache[movie.routeKey] = movie;
      _cache['${movie.id}'] = movie;
    }
    return movies;
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
      return const {};
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
      if (token.isNotEmpty) await api.saveSession(token, refreshToken);
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
    final current = await items();
    final next = [
      item,
      ...current.where((e) => e.key != item.key),
    ].take(120).toList();
    await prefs.setString(
      key,
      jsonEncode(next.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> removeMovie(int movieId) async {
    final prefs = await SharedPreferences.getInstance();
    final next = (await items()).where((e) => e.movieId != movieId).toList();
    if (next.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(
      key,
      jsonEncode(next.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
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
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) return const SplashScreen();
    final destinations = [
      AppDestination(
        icon: Icons.home_rounded,
        label: 'Trang chủ',
        screen: HomeScreen(repo: repo),
      ),
      AppDestination(
        icon: Icons.search_rounded,
        label: isTvBuild ? 'Tìm kiếm' : 'Tìm',
        screen: BrowseScreen(repo: repo, embedded: true),
      ),
      if (!isTvBuild)
        AppDestination(
          icon: Icons.groups_rounded,
          label: 'Xem chung',
          screen: WatchTogetherScreen(repo: repo),
          requiresLogin: true,
        ),
      AppDestination(
        icon: Icons.person_rounded,
        label: 'Của tôi',
        screen: ProfileScreen(repo: repo),
      ),
    ];
    if (index >= destinations.length) index = destinations.length - 1;
    final wide = MediaQuery.sizeOf(context).width >= 900 || isTvBuild;
    return Scaffold(
      body: Row(
        children: [
          if (wide)
            RailNav(
              index: index,
              items: destinations,
              onChanged: (value) => setTab(value, destinations),
            ),
          Expanded(child: destinations[index].screen),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: index,
              backgroundColor: CvColors.ink,
              indicatorColor: CvColors.accent.withValues(alpha: .22),
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
      if (!updateAvailable || !forceUpdate || url.isEmpty) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Cần cập nhật ứng dụng'),
          content: const Text(
            'Phiên bản hiện tại đã cũ. Vui lòng cập nhật để tiếp tục sử dụng CineViet.',
          ),
          actions: [
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const UpdateInfoScreen()),
              ),
              icon: const Icon(Icons.system_update_alt_rounded),
              label: const Text('Cập nhật'),
            ),
          ],
        ),
      );
    } catch (_) {}
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
            const CineLogo(size: 48),
            const SizedBox(height: 22),
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

  @override
  void initState() {
    super.initState();
    data = _loadWithCache();
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
    final showContinue = await isLoggedIn();
    final sectionLimit = isTvBuild ? 8 : 18;
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
    ]);
    final home = HomeData(
      featured: results[0],
      latest: results[1],
      cinema: results[2],
      series: results[3],
      single: results[4],
      anime: results[5],
      tvShows: results[6],
      history: showContinue ? await _safeHistory() : const [],
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
    final local = await LocalHistory.items();
    final cloud = await widget.repo.cloudHistory();
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
      return Column(
        children: [
          SizedBox(
            height: heroBannerHeight(context),
            child: featured.isEmpty
                ? const HomeEmptyHero()
                : FeaturedHeroCarousel(movies: featured, repo: widget.repo),
          ),
          Expanded(
            child: CustomScrollView(
              key: const PageStorageKey('home-tv-scroll'),
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: pagePadding(context).copyWith(top: 22, bottom: 72),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      if (home.history.isNotEmpty)
                        WatchRow(
                          title: 'Xem tiếp',
                          items: home.history,
                          repo: widget.repo,
                          onRemove: _removeHistory,
                        ),
                      MovieRow(
                        title: 'Top CineViet',
                        movies: featured.length > 1
                            ? featured.skip(1).toList()
                            : featured,
                        repo: widget.repo,
                        padded: false,
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
  });
  final String title;
  final List<Movie>? movies; // null = tab "Đề xuất"; ngược lại = seed trang 1
  final String type; // type gọi API cho tab danh mục
  final bool cinema; // chieu_rap=1
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
    required this.repo,
  });
  final List<Movie> seed;
  final String title;
  final String type;
  final bool cinema;
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
    required this.history,
  });
  final List<Movie> featured;
  final List<Movie> latest;
  final List<Movie> cinema;
  final List<Movie> series;
  final List<Movie> single;
  final List<Movie> anime;
  final List<Movie> tvShows;
  final List<WatchItem> history;

  Map<String, dynamic> toCacheJson() => {
    'featured': featured.map((m) => m.toCacheJson()).toList(),
    'latest': latest.map((m) => m.toCacheJson()).toList(),
    'cinema': cinema.map((m) => m.toCacheJson()).toList(),
    'series': series.map((m) => m.toCacheJson()).toList(),
    'single': single.map((m) => m.toCacheJson()).toList(),
    'anime': anime.map((m) => m.toCacheJson()).toList(),
    'tvShows': tvShows.map((m) => m.toCacheJson()).toList(),
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
      tvShows.isEmpty;
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
    if (widget.movies.length < 2) return;
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

  @override
  Widget build(BuildContext context) {
    final height = heroBannerHeight(context);
    return SizedBox(
      height: height,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          PageView.builder(
            controller: controller,
            itemCount: widget.movies.length,
            onPageChanged: (value) => setState(() => page = value),
            itemBuilder: (context, index) =>
                HeroBanner(movie: widget.movies[index], repo: widget.repo),
          ),
          if (widget.movies.length > 1)
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
      : (size.height * (isTvBuild ? .72 : .56)).clamp(390.0, 690.0);
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
          NetworkBackdrop(url: artwork, fit: BoxFit.cover),
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
            padding: pagePadding(
              context,
            ).copyWith(top: compact ? 64 : 86, bottom: compact ? 34 : 56),
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
                              fontSize: compact
                                  ? 34
                                  : (isTvBuild ? 54 : (tablet ? 32 : 38)),
                              height: 1.02,
                              fontWeight: FontWeight.w900,
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
                                  : (isTvBuild ? 4 : 3),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15.5,
                                height: 1.42,
                              ),
                            ),
                          ],
                          SizedBox(height: tablet ? 16 : 22),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              if (useLeanbackControls) ...[
                                TvActionButton(
                                  icon: Icons.play_arrow_rounded,
                                  label: 'Xem ngay',
                                  primary: true,
                                  onPressed: () => openDetail(
                                    context,
                                    repo,
                                    movie,
                                    autoplay: true,
                                  ),
                                ),
                                TvActionButton(
                                  icon: Icons.info_outline_rounded,
                                  label: 'Chi tiết',
                                  onPressed: () =>
                                      openDetail(context, repo, movie),
                                ),
                              ] else ...[
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
                            ],
                          ),
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
            height: moviePosterRowHeight(cardWidth),
            child: ListView.separated(
              key: PageStorageKey('movie-row-$title'),
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
    this.onRemove,
  });
  final String title;
  final List<WatchItem> items;
  final MovieRepository repo;
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
      padding: pagePadding(context).copyWith(top: 30),
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
  String genre = '';
  String country = '';
  String year = '';
  String sort = 'created_at';
  late Future<List<Movie>> results;
  late Future<BrowseMeta> meta;

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

  void runSearch() {
    setState(() {
      results = widget.repo.list(
        limit: 48,
        search: search.text,
        type: type,
        genre: genre,
        country: country,
        year: year,
        sort: sort,
      );
    });
  }

  @override
  void dispose() {
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
                    return FilterBar(
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
          onRetry: runSearch,
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
      onSelected: (_) => select(),
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
    this.onRetry,
  });
  final Future<List<Movie>> future;
  final double cardWidth;
  final MovieRepository repo;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
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
            padding: pagePadding(context).copyWith(top: 20, bottom: 36),
            sliver: SliverGrid.builder(
              itemCount: 12,
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: cardWidth + 28,
                mainAxisSpacing: 18,
                crossAxisSpacing: 14,
                childAspectRatio: cardWidth / moviePosterCardHeight(cardWidth),
              ),
              itemBuilder: (context, index) => SkeletonBox(
                borderRadius: 8,
                width: cardWidth,
                height: moviePosterCardHeight(cardWidth),
              ),
            ),
          );
        }
        final movies = snapshot.data!;
        if (movies.isEmpty) {
          return const SliverFillRemaining(
            child: EmptyState('Không tìm thấy phim phù hợp'),
          );
        }
        return SliverPadding(
          padding: pagePadding(context).copyWith(bottom: 36),
          sliver: SliverGrid.builder(
            itemCount: movies.length,
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: cardWidth + 28,
              mainAxisSpacing: 18,
              crossAxisSpacing: 14,
              childAspectRatio: cardWidth / moviePosterCardHeight(cardWidth),
            ),
            itemBuilder: (context, index) => MoviePosterCard(
              movie: movies[index],
              width: cardWidth,
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
    final local = await LocalHistory.items();
    final cloud = Api.instance.hasAuthToken
        ? await widget.repo.cloudHistory()
        : const <WatchItem>[];
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
                child: EmptyState('Chưa có phim đang xem dở'),
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
    return Api.instance.currentUser();
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
      setState(() => meFuture = _me());
      if (mounted) showSnack(context, 'Đăng nhập thành công');
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
      setState(() => meFuture = _me());
      if (mounted) showSnack(context, 'Đăng nhập Google thành công');
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
      if (!mounted) return;
      setState(() => meFuture = _me());
      showSnack(context, 'Đăng nhập Google thành công');
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
        return ListView(
          key: const PageStorageKey('profile-scroll'),
          padding: pagePadding(context).copyWith(top: 36, bottom: 36),
          children: [
            const PageHeading('Của tôi'),
            const SizedBox(height: 22),
            if (!snapshot.hasData &&
                snapshot.connectionState == ConnectionState.waiting)
              const LinearProgressIndicator(color: CvColors.accent),
            if (user == null)
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
            if (user != null) AccountPanel(user: user, onLogout: logout),
            const SizedBox(height: 22),
            if (useLeanbackControls)
              TvProfileHub(repo: widget.repo, onRequireLogin: requireLogin),
            if (!useLeanbackControls) ...[
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

class TvProfileHub extends StatelessWidget {
  const TvProfileHub({
    super.key,
    required this.repo,
    required this.onRequireLogin,
  });

  final MovieRepository repo;
  final Future<bool> Function(BuildContext context, String feature)
  onRequireLogin;

  @override
  Widget build(BuildContext context) {
    final actions = <TvHubAction>[
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
  const AccountPanel({super.key, required this.user, required this.onLogout});
  final Map<String, dynamic> user;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final name = cleanText(user['name'] ?? user['email']);
    final avatar = userAvatarUrlFrom(user);
    return Panel(
      child: Row(
        children: [
          UserAvatar(name: name, avatarUrl: avatar, radius: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? 'CineViet user' : name,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  cleanText(user['email']),
                  style: const TextStyle(color: CvColors.muted),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onLogout,
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Thoát'),
          ),
        ],
      ),
    );
  }
}

class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.name,
    required this.avatarUrl,
    this.radius = 22,
  });

  final String name;
  final String avatarUrl;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final initial = name.characters.isEmpty
        ? ''
        : name.characters.first.toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: CvColors.panel2,
      backgroundImage: avatarUrl.isNotEmpty
          ? CachedNetworkImageProvider(avatarUrl)
          : null,
      child: avatarUrl.isEmpty
          ? Text(
              initial.isEmpty ? 'C' : initial,
              style: TextStyle(
                color: Colors.white,
                fontSize: radius * .78,
                fontWeight: FontWeight.w900,
              ),
            )
          : null,
    );
  }
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
          if (!snapshot.hasData) {
            return CustomScrollView(
              slivers: [
                FutureGrid(future: future, cardWidth: width, repo: widget.repo),
              ],
            );
          }
          final movies = snapshot.data!;
          if (movies.isEmpty) return const EmptyState('Chưa có phim yêu thích');
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
              if (!snapshot.hasData)
                const LinearProgressIndicator(color: CvColors.accent)
              else if (playlists.isEmpty)
                const EmptyState('Chưa có playlist hoặc chưa đăng nhập')
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
                      EmptyState('Playlist này chưa có phim'),
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
                if (!snapshot.hasData)
                  const LinearProgressIndicator(color: CvColors.accent)
                else if (playlists.isEmpty)
                  const EmptyState(
                    'Chưa có playlist. Tạo playlist trong mục Của tôi.',
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

  Future<void> _downloadAndInstall(String url) async {
    if (downloading) return;
    setState(() {
      downloading = true;
      progress = 0;
      statusMessage = 'Đang tải bản mới...';
    });
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/cineviet-update.apk');
        if (await file.exists()) await file.delete();
        await Dio().download(
          url,
          file.path,
          onReceiveProgress: (received, total) {
            if (!mounted || total <= 0) return;
            setState(() => progress = received / total);
          },
        );
        setState(() => statusMessage = 'Đã tải xong, đang mở trình cài đặt...');
        await _installerChannel.invokeMethod('installApk', {'path': file.path});
      } else if (!kIsWeb &&
          Platform.isWindows &&
          url.toLowerCase().endsWith('.exe')) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}\\cineviet-update-setup.exe');
        if (await file.exists()) await file.delete();
        await Dio().download(
          url,
          file.path,
          onReceiveProgress: (received, total) {
            if (!mounted || total <= 0) return;
            setState(() => progress = received / total);
          },
        );
        setState(() => statusMessage = 'Đã tải xong, đang mở trình cài đặt...');
        await Process.start(
          file.path,
          const [],
          mode: ProcessStartMode.detached,
        );
      } else {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (!mounted) return;
      setState(
        () => statusMessage = 'Không cài được tự động. Đang mở link tải...',
      );
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } finally {
      if (mounted) setState(() => downloading = false);
    }
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
                          downloading ? 'Đang tải...' : 'Tải bản mới',
                        ),
                      ),
                      if (statusMessage != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          statusMessage!,
                          style: const TextStyle(color: CvColors.muted),
                        ),
                      ],
                      if (downloading && progress > 0) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: progress.clamp(0, 1),
                          color: CvColors.accent,
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

class MovieDetailScreen extends StatefulWidget {
  const MovieDetailScreen({
    super.key,
    required this.repo,
    required this.initial,
    this.autoplay = false,
    this.heroTag,
  });
  final MovieRepository repo;
  final Movie initial;
  final bool autoplay;
  final String? heroTag;

  @override
  State<MovieDetailScreen> createState() => _MovieDetailScreenState();
}

class _MovieDetailScreenState extends State<MovieDetailScreen> {
  late Future<Movie> future;
  int serverIndex = 0;
  int? favoriteMovieId;
  bool isFavorite = false;
  bool favoriteBusy = false;

  @override
  void initState() {
    super.initState();
    future = widget.repo.detail(widget.initial.routeKey);
    favoriteMovieId = widget.initial.id;
    refreshFavoriteState(widget.initial);
    future.then(refreshFavoriteState).catchError((_) {});
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

  Future<void> refreshFavoriteState(Movie movie, {bool force = false}) async {
    if (movie.id <= 0) return;
    favoriteMovieId = movie.id;
    if (!Api.instance.hasAuthToken) {
      if (mounted) {
        setState(() {
          isFavorite = false;
          favoriteBusy = false;
        });
      }
      return;
    }
    final expectedMovieId = movie.id;
    final favorited = await widget.repo.isFavorite(movie, force: force);
    if (!mounted || favoriteMovieId != expectedMovieId) return;
    setState(() {
      isFavorite = favorited;
      favoriteBusy = false;
    });
  }

  Future<void> toggleFavorite(Movie movie) async {
    if (favoriteBusy) return;
    if (!await requireLogin(context, 'Yêu thích')) return;
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
                                url: usePortraitHero
                                    ? movie.posterUrl
                                    : movie.backdropUrl,
                                fit: BoxFit.cover,
                              ),
                            )
                          : NetworkBackdrop(
                              url: usePortraitHero
                                  ? movie.posterUrl
                                  : movie.backdropUrl,
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
                                    detailAction(
                                      icon: Icons.play_arrow_rounded,
                                      label: 'Phát',
                                      primary: true,
                                      onPressed:
                                          selectedServer == null ||
                                              selectedServer.items.isEmpty
                                          ? null
                                          : () => openPlayer(
                                              context,
                                              widget.repo,
                                              movie,
                                              selectedServer,
                                              selectedServer.items.first,
                                              serverIndex,
                                            ),
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
                        Text(
                          movie.description,
                          style: const TextStyle(fontSize: 16, height: 1.48),
                        ),
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
                      const SizedBox(height: 28),
                      if (!snapshot.hasData)
                        const LinearProgressIndicator(color: CvColors.accent),
                      if (servers.isNotEmpty) ...[
                        EpisodeSection(
                          movie: movie,
                          repo: widget.repo,
                          servers: servers,
                          serverIndex: serverIndex,
                          onServerChanged: (value) =>
                              setState(() => serverIndex = value),
                        ),
                      ] else if (snapshot.hasData)
                        const EmptyState(
                          'Phim này chưa có nguồn phát trong API',
                        ),
                      if (directors.isNotEmpty || cast.isNotEmpty) ...[
                        const SizedBox(height: 30),
                        CrewSection(
                          repo: widget.repo,
                          directors: directors,
                          cast: cast.take(30).toList(),
                        ),
                      ],
                      if (snapshot.hasData && !isTvBuild) ...[
                        const SizedBox(height: 30),
                        SocialSection(repo: widget.repo, movie: movie),
                      ],
                    ],
                  ),
                ),
              ),
              if (movie.related.isNotEmpty)
                SliverToBoxAdapter(
                  child: MovieRow(
                    title: 'Có thể bạn thích',
                    movies: movie.related,
                    repo: widget.repo,
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

class EpisodeSection extends StatelessWidget {
  const EpisodeSection({
    super.key,
    required this.movie,
    required this.repo,
    required this.servers,
    required this.serverIndex,
    required this.onServerChanged,
  });
  final Movie movie;
  final MovieRepository repo;
  final List<EpisodeServer> servers;
  final int serverIndex;
  final ValueChanged<int> onServerChanged;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = serverIndex.clamp(0, servers.length - 1);
    final server = servers[selectedIndex];
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
          const SectionTitle('Tập phim'),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < servers.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      right: useLeanbackControls ? 12 : 8,
                    ),
                    child: useLeanbackControls
                        ? TvFilterChip(
                            label: servers[i].displayName,
                            icon: Icons.storage_rounded,
                            selected: i == selectedIndex,
                            onPressed: () => onServerChanged(i),
                          )
                        : ChoiceChip(
                            label: Text(servers[i].displayName),
                            selected: i == selectedIndex,
                            onSelected: (_) => onServerChanged(i),
                          ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: server.items.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: isTvBuild ? 2.8 : 2.35,
            ),
            itemBuilder: (context, index) {
              final episode = server.items[index];
              return FocusButton(
                onPressed: () => openPlayer(
                  context,
                  repo,
                  movie,
                  server,
                  episode,
                  selectedIndex,
                ),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      episode.displayName,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: isTvBuild ? 16 : 14,
                      ),
                    ),
                  ),
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
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: UserAvatar(
                            name: item.userName,
                            avatarUrl: item.userAvatar,
                            radius: 21,
                          ),
                          title: Text(
                            item.userName,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          subtitle: Text(
                            item.isSpoiler
                                ? '[Spoiler] ${item.content}'
                                : item.content,
                          ),
                          trailing: item.likes > 0
                              ? Text(
                                  '${item.likes} thích',
                                  style: const TextStyle(color: CvColors.muted),
                                )
                              : null,
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

class ResumeLoaderScreen extends StatelessWidget {
  const ResumeLoaderScreen({super.key, required this.repo, required this.item});
  final MovieRepository repo;
  final WatchItem item;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Movie>(
      future: repo.detail(item.slug.isNotEmpty ? item.slug : '${item.movieId}'),
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
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => PlayerScreen(
                repo: repo,
                movie: movie,
                server: server,
                episode: episode,
                serverIndex: item.serverIndex,
                resume: Duration(milliseconds: item.positionMs),
              ),
            ),
          );
        });
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
  });

  final MovieRepository repo;
  final Movie movie;
  final EpisodeServer server;
  final EpisodeItem episode;
  final int serverIndex;
  final Duration? resume;
  final WatchTogetherState? watchTogetherState;
  final String? watchTogetherCode;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? controller;
  Timer? saveTimer;
  Timer? controlsTimer;
  Timer? levelApplyTimer;
  Timer? deviceLevelSyncTimer;
  Timer? gestureHintTimer;
  final focusNode = FocusNode();
  late EpisodeServer currentServer;
  late EpisodeItem currentEpisode;
  late int currentServerIndex;
  PlayerFitMode fitMode = PlayerFitMode.contain;
  bool controls = true;
  bool controlsLocked = false;
  bool autoNextEpisode = true;
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
  String? lastWatchRoomFrom;
  int lastWatchSyncSentAt = 0;
  List<PlaybackUrlCandidate> activePlayableUrls = const [];
  int activePlayableUrlIndex = 0;
  WebViewController? webViewController;
  windows_webview.WebviewController? windowsWebViewController;
  String? activeWebViewUrl;
  bool recoveringPlayback = false;
  bool reportingPlaybackIssue = false;
  bool androidBrightnessSettingsPrompted = false;
  bool introSkipped = false;
  int runtimeRecoveryAttempts = 0;
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
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => focusNode.requestFocus(),
    );
    _bindWatchTogetherSocket();
    _init();
  }

  bool _isStreamCEmbedUrl(String raw) {
    final parsed = Uri.tryParse(raw.trim());
    if (parsed == null) return false;
    final host = parsed.host.toLowerCase();
    final path = parsed.path.toLowerCase();
    return host.contains('streamc.xyz') && path.contains('/embed');
  }

  String? _webViewFallbackUrl(EpisodeItem episode) {
    // Thử nghiệm có kiểm soát cho StreamC/NguồnC: nguồn này chỉ có embed,
    // không có m3u8/direct nên native player không dùng được. Chỉ bật WebView
    // cho chính link embed StreamC của tập hiện tại; không tự nhảy server khác.
    final embed = episode.linkEmbed.trim();
    if (_isStreamCEmbedUrl(embed)) return embed;
    final play = episode.playUrl.trim();
    if (_isStreamCEmbedUrl(play)) return play;
    return null;
  }

  List<String> _playableUrls(String raw) {
    final urls = <String>[];

    void add(String value) {
      final text = value.trim();
      if (text.isEmpty || urls.contains(text)) return;
      urls.add(text);
    }

    final parsed = Uri.tryParse(raw);
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
    if (rawLooksPlayable && !rawIsKnownEmbedOnly) add(raw);

    final nested = parsed?.queryParameters['url'];
    if (nested != null && nested.isNotEmpty) add(Uri.decodeFull(nested));

    final m3u8 = urls.firstWhere(
      (e) => Uri.tryParse(e)?.path.toLowerCase().contains('.m3u8') ?? false,
      orElse: () => '',
    );
    if (m3u8.isNotEmpty && !m3u8.contains('/api/stream')) {
      add('$apiBase/stream?url=${Uri.encodeComponent(m3u8)}');
    }

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

  List<PlaybackSourceCandidate> _currentPlaybackSources() {
    final sources = <PlaybackSourceCandidate>[];
    // Chỉ phát nằng server đang chọn. Phim chỉ có 1 nguồn (kkphim),
    // các server vẫn phát bình thường nên không tự nhảy sang server
    // ngôn ngữ khác. Fallback chỉ xảy ra giữa các URL của cùng một tập
    // (link trực tiếp → link qua proxy) khi link server đó bị chết.
    final urls = _playableUrls(currentEpisode.playUrl);
    final webViewUrl = _webViewFallbackUrl(currentEpisode);
    if (urls.isNotEmpty || webViewUrl != null) {
      final quality = _qualityLabelFor(currentServer, currentEpisode);
      sources.add(
        PlaybackSourceCandidate(
          server: currentServer,
          episode: currentEpisode,
          serverIndex: currentServerIndex,
          qualityLabel: quality,
          qualityRank: _qualityRank(quality),
          sourceLabel: currentServer.displayName,
          urls: urls,
          webViewUrl: webViewUrl,
        ),
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
      activePlayableUrls = const [];
      activePlayableUrlIndex = 0;
      webViewController = null;
      await windowsWebViewController?.dispose();
      windowsWebViewController = controller;
      activeWebViewUrl = url;
      playbackNotice = null;
      error = null;
      saveTimer?.cancel();
      saveTimer = Timer.periodic(const Duration(seconds: 8), (_) => _save());
      _trackPlaybackEvent('webview_windows_start');
      if (mounted) setState(() {});
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
            final isStreamCFrame =
                host == initialHost || host.endsWith('.streamc.xyz');
            if (request.isMainFrame && !isStreamCFrame) {
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
            final resumeSec =
                (lastGoodPosition ?? widget.resume)?.inSeconds ?? 0;
            unawaited(
              webViewController?.runJavaScript('''
                (function () {
                  try {
                    var resumeAt = $resumeSec;
                    document.querySelectorAll('video').forEach(function (v) {
                      v.setAttribute('playsinline', '');
                      v.setAttribute('webkit-playsinline', '');
                      try { v.webkitEnterFullscreen = function () {}; } catch (_) {}
                      try { v.webkitEnterFullScreen = function () {}; } catch (_) {}
                      if (resumeAt > 3 && !v.dataset.cvResumed) {
                        v.dataset.cvResumed = '1';
                        var doSeek = function () {
                          try {
                            if (isFinite(v.duration) && v.duration > 0 && resumeAt < v.duration - 5) {
                              v.currentTime = resumeAt;
                            }
                          } catch (_) {}
                        };
                        if (isFinite(v.duration) && v.duration > 0) { doSeek(); }
                        else { v.addEventListener('loadedmetadata', doSeek, { once: true }); }
                      }
                    });
                    ['requestFullscreen','webkitRequestFullscreen','webkitEnterFullscreen','webkitEnterFullScreen','mozRequestFullScreen','msRequestFullscreen'].forEach(function (name) {
                      try {
                        if (Element.prototype[name]) Element.prototype[name] = function () { return Promise.resolve && Promise.resolve(); };
                      } catch (_) {}
                    });
                  } catch (_) {}
                })();
              '''),
            );
          },
          onWebResourceError: (error) {
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
    activePlayableUrls = const [];
    activePlayableUrlIndex = 0;
    webViewController = controller;
    activeWebViewUrl = url;
    playbackNotice = null;
    error = null;
    // WebView không có controller native nên cần timer riêng để lưu "Xem tiếp".
    saveTimer?.cancel();
    saveTimer = Timer.periodic(const Duration(seconds: 8), (_) => _save());
    _trackPlaybackEvent('webview_start');
    if (mounted) setState(() {});
  }

  Future<void> _init({int startUrlIndex = 0, Duration? startAt}) async {
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
        final next = VideoPlayerController.networkUrl(parsed);
        controller = next;
        await next.initialize().timeout(const Duration(seconds: 18));
        await next.setPlaybackSpeed(playbackSpeed);
        await next.setVolume(usesPlayerVolume ? appVolume : 1.0);
        if (isWatchTogether && !isWatchHost && watchRoomState != null) {
          final target = Duration(
            milliseconds: (watchRoomState!.currentTime * 1000).round(),
          );
          if (target > Duration.zero) await next.seekTo(target);
        }
        final resume = widget.resume;
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
        recoveringPlayback = false;
        next.addListener(_handlePlayerTick);
        saveTimer = Timer.periodic(const Duration(seconds: 8), (_) => _save());
        _scheduleControlsHide();
        _trackPlaybackEvent('playback_start');
        playbackNotice = null;
        if (mounted) setState(() {});
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
    if (c.value.hasError) {
      unawaited(_recoverPlayback(c.value.errorDescription));
      return;
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
      if (controller != null) return;
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
    final c = controller;
    if (c == null || !c.value.isInitialized) {
      // Nguồn WebView (NguồnC/StreamC) không có controller native -> đọc tiến độ
      // trực tiếp từ thẻ <video> trong trang qua JS để vẫn lưu "Xem tiếp".
      if (activeWebViewUrl != null) await _saveWebView();
      return;
    }
    _emitWatchSync();
    if (!await isLoggedIn()) return;
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
    await widget.repo.syncWatch(item);
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
            var v = document.querySelector('video');
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
    if (!await isLoggedIn()) return;
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
    await widget.repo.syncWatch(item);
  }

  void _scheduleControlsHide() {
    controlsTimer?.cancel();
    controlsTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && controller?.value.isPlaying == true && !controlsLocked) {
        setState(() => controls = false);
      }
    });
  }

  void _showControls() {
    if (controlsLocked) return;
    setState(() => controls = true);
    _scheduleControlsHide();
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
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    await c.seekTo(_clampPosition(c.value.position + offset, c.value.duration));
    _emitWatchSync(force: true);
    if (showControls) _showControls();
  }

  bool _shouldShowIntroSkip(VideoPlayerController? c) {
    if (introSkipped || c == null || !c.value.isInitialized) return false;
    if (c.value.duration.inSeconds <= introSkipSeconds) return false;
    final seconds = c.value.position.inSeconds;
    return seconds >= 1 && seconds < introSkipSeconds;
  }

  Future<void> _skipIntro() async {
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    introSkipped = true;
    final target = Duration(seconds: introSkipSeconds);
    await c.seekTo(_clampPosition(target, c.value.duration));
    _emitWatchSync(force: true);
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

  void _maybeAutoNext() {
    final c = controller;
    if (!autoNextEpisode ||
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
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    c.value.isPlaying ? c.pause() : c.play();
    _emitWatchSync(force: true);
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

  Future<void> _exitPlayer() async {
    if (leavingPlayer) return;
    leavingPlayer = true;
    _stopPlaybackNow();
    if (mounted) setState(() {});
    try {
      await _save().timeout(const Duration(seconds: 2));
    } catch (_) {}
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
      return source.qualityLabel;
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
      controls = true;
      error = null;
      introSkipped = false;
    });
    runtimeRecoveryAttempts = 0;
    lastGoodPosition = null;
    await _init();
  }

  void _playSibling(int offset) {
    final index = _currentEpisodeIndex;
    final next = index + offset;
    if (index < 0 || next < 0 || next >= currentServer.items.length) return;
    _switchTo(currentServer, currentServer.items[next]);
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

  @override
  void dispose() {
    _stopPlaybackNow();
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
    watchChatController.dispose();
    controller?.removeListener(_handlePlayerTick);
    controller?.dispose();
    windowsWebViewController?.dispose();
    WakelockPlus.disable();
    if (supportsTouchLevels) {
      brightnessChannel.invokeMethod<double>('reset').catchError((_) => null);
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return PopScope(
      // WebView (StreamC/NguồnC) có thể giữ history/popup riêng và nuốt nút back.
      // Chặn pop mặc định để mọi nút back luôn đi qua _exitPlayer() của app.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _stopPlaybackNow();
        unawaited(_save());
        unawaited(_exitPlayer());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: KeyboardListener(
          focusNode: focusNode,
          onKeyEvent: (event) {
            if (event is! KeyDownEvent) return;
            final key = event.logicalKey;
            // Back phải hoạt động trên WebView StreamC cả khi không có native
            // VideoPlayer controller (Android TV remote, Windows Esc/back, keyboard).
            if (key == LogicalKeyboardKey.escape ||
                key == LogicalKeyboardKey.goBack ||
                key == LogicalKeyboardKey.browserBack) {
              _exitPlayer();
              return;
            }
            if (c == null) return;
            final primaryFocus = FocusManager.instance.primaryFocus;
            final playerHasPrimaryFocus =
                primaryFocus == null || primaryFocus == focusNode;
            if (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.space ||
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
              _showControls();
              if (isTvBuild && playerHasPrimaryFocus) {
                FocusScope.of(context).previousFocus();
              }
            }
            if (key == LogicalKeyboardKey.arrowDown) {
              _showControls();
              if (isTvBuild && playerHasPrimaryFocus) {
                FocusScope.of(context).nextFocus();
              }
            }
            if (key == LogicalKeyboardKey.keyN) {
              _playSibling(1);
            }
            if (key == LogicalKeyboardKey.keyP) {
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
                      reporting: reportingPlaybackIssue,
                      onRetry: _retryPlayback,
                      onChangeSource: _showEpisodeSheet,
                      onReport: _reportPlaybackIssue,
                    )
                  else if (activeWebViewUrl != null &&
                      windowsWebViewController != null)
                    windows_webview.Webview(windowsWebViewController!)
                  else if (activeWebViewUrl != null &&
                      webViewController != null)
                    WebViewWidget(controller: webViewController!)
                  else if (c == null || !c.value.isInitialized)
                    const Center(
                      child: CircularProgressIndicator(color: CvColors.accent),
                    )
                  else
                    Center(
                      child: _FittedVideo(controller: c, fitMode: fitMode),
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
                  if (usesWindowsBrightnessOverlay && screenBrightness < .99)
                    IgnorePointer(
                      child: ColoredBox(
                        color: Colors.black.withValues(
                          alpha: ((1 - screenBrightness) * .58).clamp(.0, .58),
                        ),
                      ),
                    ),
                  if (_shouldShowIntroSkip(c) && !controlsLocked)
                    IntroSkipButton(onPressed: _skipIntro),
                  if (controls && !controlsLocked)
                    FocusTraversalGroup(
                      policy: OrderedTraversalPolicy(),
                      child: PlayerOverlay(
                        controller: c,
                        title: widget.movie.title,
                        episode:
                            '${currentServer.displayName} • ${currentEpisode.displayName}',
                        sourceLabel: _activeSourceLabel,
                        fitLabel: fitMode.label,
                        canPrevious: _currentEpisodeIndex > 0,
                        canNext:
                            _currentEpisodeIndex >= 0 &&
                            _currentEpisodeIndex <
                                currentServer.items.length - 1,
                        onPlayPause: _togglePlay,
                        onReplay: () => _seekBy(const Duration(seconds: -10)),
                        onForward: () => _seekBy(const Duration(seconds: 10)),
                        onPrevious: () => _playSibling(-1),
                        onNext: () => _playSibling(1),
                        onEpisodes: _showEpisodeSheet,
                        onSettings: _showSettingsSheet,
                        onFit: _cycleFitMode,
                        onBack: _exitPlayer,
                      ),
                    ),
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
                onSend: _sendWatchMessage,
                onHide: () => setState(() => watchChatVisible = false),
              )
            : Align(
                key: const ValueKey('watch-chat-toggle'),
                alignment: Alignment.topRight,
                child: WatchChatToggleButton(
                  code: watchRoomCode,
                  count: watchMessages.length,
                  onTap: () => setState(() => watchChatVisible = true),
                ),
              ),
      ),
    );
  }

  Widget _buildLockButton({required bool locked}) => Positioned(
    top: 14,
    right: 16,
    child: SafeArea(
      child: IconButton.filledTonal(
        tooltip: locked ? 'Mở khóa cử chỉ' : 'Khóa cử chỉ',
        onPressed: _toggleControlsLock,
        icon: Icon(locked ? Icons.lock_open_rounded : Icons.lock_rounded),
      ),
    ),
  );
}

class IntroSkipButton extends StatelessWidget {
  const IntroSkipButton({super.key, required this.onPressed});

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
        label: const Text(
          'Bỏ qua intro',
          style: TextStyle(fontWeight: FontWeight.w900),
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
    required this.reporting,
    required this.onRetry,
    required this.onChangeSource,
    required this.onReport,
  });

  final String message;
  final bool reporting;
  final VoidCallback onRetry;
  final VoidCallback onChangeSource;
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
        onPressed: onChangeSource,
        icon: const Icon(Icons.video_library_rounded),
        label: Text(compact ? 'Tập' : 'Chọn tập'),
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
    required this.fitLabel,
    required this.canPrevious,
    required this.canNext,
    required this.onPlayPause,
    required this.onReplay,
    required this.onForward,
    required this.onPrevious,
    required this.onNext,
    required this.onEpisodes,
    required this.onSettings,
    required this.onFit,
    this.onBack,
  });
  final VideoPlayerController? controller;
  final String title;
  final String episode;
  final String sourceLabel;
  final String fitLabel;
  final bool canPrevious;
  final bool canNext;
  final VoidCallback onPlayPause;
  final VoidCallback onReplay;
  final VoidCallback onForward;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onEpisodes;
  final VoidCallback onSettings;
  final VoidCallback onFit;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: .72),
            Colors.transparent,
            Colors.black.withValues(alpha: .82),
          ],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton.filledTonal(
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
                ],
              ),
              const Spacer(),
              if (c != null && c.value.isInitialized)
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: c,
                  builder: (context, value, _) => Column(
                    children: [
                      VideoProgressIndicator(
                        c,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: CvColors.accent,
                        ),
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
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(children: visibleButtons),
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
    required this.movie,
    required this.currentServer,
    required this.currentEpisode,
    required this.onSelect,
  });

  final Movie movie;
  final EpisodeServer currentServer;
  final EpisodeItem currentEpisode;
  final void Function(EpisodeServer server, EpisodeItem episode) onSelect;

  @override
  State<PlayerEpisodeSheet> createState() => _PlayerEpisodeSheetState();
}

class _PlayerEpisodeSheetState extends State<PlayerEpisodeSheet> {
  late int serverIndex;

  @override
  void initState() {
    super.initState();
    final found = widget.movie.episodes.indexOf(widget.currentServer);
    serverIndex = found < 0 ? 0 : found;
  }

  bool _isCurrent(EpisodeServer server, EpisodeItem episode) =>
      server.name == widget.currentServer.name &&
      episode.name == widget.currentEpisode.name &&
      episode.linkM3u8 == widget.currentEpisode.linkM3u8 &&
      episode.linkEmbed == widget.currentEpisode.linkEmbed;

  @override
  Widget build(BuildContext context) {
    final servers = widget.movie.episodes;
    final server = servers[serverIndex.clamp(0, servers.length - 1)];
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
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < servers.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(servers[i].displayName),
                          selected: i == serverIndex,
                          onSelected: (_) => setState(() => serverIndex = i),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: GridView.builder(
                  itemCount: server.items.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: isTvBuild ? 2.8 : 2.35,
                  ),
                  itemBuilder: (context, index) {
                    final episode = server.items[index];
                    final selected = _isCurrent(server, episode);
                    return FocusButton(
                      selected: selected,
                      onPressed: () => widget.onSelect(server, episode),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            episode.displayName,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: selected ? Colors.white : null,
                            ),
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
    final artUrl = useLandscapeArt
        ? (movie.backdropUrl.isNotEmpty ? movie.backdropUrl : movie.posterUrl)
        : movie.posterUrl;
    return SizedBox(
      width: width,
      child: FocusButton(
        onPressed: onTap,
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
                          ? NetworkBackdrop(url: artUrl, fit: BoxFit.cover)
                          : (heroTag != null
                                ? Hero(
                                    tag: heroTag!,
                                    child: NetworkPoster(url: artUrl),
                                  )
                                : NetworkPoster(url: artUrl)),
                      Positioned(
                        left: 7,
                        top: 7,
                        child: MetaPill(movie.posterBadgeLabel),
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
                              if (movie.metaLine.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  movie.metaLine,
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
                    movie.metaLine,
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
      child: FocusButton(
        onPressed: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              NetworkBackdrop(
                url: item.backdrop.isNotEmpty ? item.backdrop : item.poster,
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
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.episodeName,
                      style: const TextStyle(
                        color: CvColors.muted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: item.progress,
                      minHeight: 4,
                      backgroundColor: Colors.white24,
                      color: CvColors.accent,
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
              if (onRemove != null)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Material(
                    color: Colors.black.withValues(alpha: .58),
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: 'Xoá khỏi Xem tiếp',
                      onPressed: onRemove,
                      icon: const Icon(Icons.close_rounded),
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class NetworkPoster extends StatelessWidget {
  const NetworkPoster({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context) => url.isEmpty
      ? const PosterFallback()
      : CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          placeholder: (_, _) => const PosterFallback(),
          errorWidget: (_, _, _) => const PosterFallback(),
        );
}

class NetworkBackdrop extends StatelessWidget {
  const NetworkBackdrop({super.key, required this.url, required this.fit});
  final String url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => url.isEmpty
      ? const PosterFallback()
      : CachedNetworkImage(
          imageUrl: url,
          fit: fit,
          placeholder: (_, _) => const PosterFallback(),
          errorWidget: (_, _, _) => const PosterFallback(),
        );
}

class TvActionButton extends StatelessWidget {
  const TvActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.primary = false,
    this.danger = false,
    this.width,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final bool primary;
  final bool danger;
  final double? width;

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
          Icon(icon, color: danger ? CvColors.danger : foreground, size: 25),
          const SizedBox(width: 10),
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
    icon: icon ?? Icons.check_rounded,
    label: label,
    selected: selected,
    primary: selected,
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
  });
  final Widget child;
  final VoidCallback onPressed;
  final bool selected;

  @override
  State<FocusButton> createState() => _FocusButtonState();
}

class _FocusButtonState extends State<FocusButton> {
  bool focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (value) => setState(() => focused = value),
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
        duration: const Duration(milliseconds: 120),
        scale: focused && isTvBuild ? 1.06 : 1,
        child: Material(
          color: widget.selected
              ? CvColors.accent.withValues(alpha: .14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
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
    isTvBuild ? (width * 9 / 16 + 12) : (width * 1.5 + 72);

double moviePosterRowHeight(double width) =>
    moviePosterCardHeight(width) + (isTvBuild ? 28 : 0);

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
      duration: const Duration(seconds: 4),
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
      action: SnackBarAction(
        label: 'Đóng',
        textColor: CvColors.accent,
        onPressed: messenger.hideCurrentSnackBar,
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

Future<bool> requireLogin(BuildContext context, String feature) async {
  if (await isLoggedIn()) return true;
  if (context.mounted) {
    showSnack(context, '$feature cần đăng nhập tài khoản CineViet');
  }
  return false;
}
