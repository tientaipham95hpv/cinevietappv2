import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const _indexFileName = 'downloads.json';

bool offlineDownloadsSupportedFor({
  required bool isWeb,
  required String platform,
}) => !isWeb && const {'android', 'ios', 'windows'}.contains(platform);

bool get supportsOfflineDownloads => offlineDownloadsSupportedFor(
  isWeb: kIsWeb,
  platform: kIsWeb
      ? 'web'
      : Platform.isAndroid
      ? 'android'
      : Platform.isIOS
      ? 'ios'
      : Platform.isWindows
      ? 'windows'
      : 'unsupported',
);

enum OfflineDownloadState { queued, downloading, completed, failed, cancelled }

class OfflineDownloadItem {
  const OfflineDownloadItem({
    required this.id,
    required this.movieId,
    required this.movieSlug,
    required this.movieTitle,
    required this.episodeName,
    required this.serverName,
    required this.sourceUrl,
    required this.posterUrl,
    this.audioSources = const [],
    this.subtitles = const [],
    required this.state,
    required this.createdAt,
    this.localManifestPath = '',
    this.localPosterPath = '',
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.completedFiles = 0,
    this.totalFiles = 0,
    this.error = '',
  });

  final String id;
  final int movieId;
  final String movieSlug;
  final String movieTitle;
  final String episodeName;
  final String serverName;
  final String sourceUrl;
  final String posterUrl;
  final List<Map<String, dynamic>> audioSources;
  final List<Map<String, dynamic>> subtitles;
  final OfflineDownloadState state;
  final DateTime createdAt;
  final String localManifestPath;
  final String localPosterPath;
  final int receivedBytes;
  final int totalBytes;
  final int completedFiles;
  final int totalFiles;
  final String error;

  double? get progress {
    if (state == OfflineDownloadState.completed) return 1;
    if (totalFiles <= 0) return null;
    return (completedFiles / totalFiles).clamp(0, .99);
  }

  bool get isActive =>
      state == OfflineDownloadState.queued ||
      state == OfflineDownloadState.downloading;

  OfflineDownloadItem copyWith({
    OfflineDownloadState? state,
    String? localManifestPath,
    String? localPosterPath,
    int? receivedBytes,
    int? totalBytes,
    int? completedFiles,
    int? totalFiles,
    String? error,
    List<Map<String, dynamic>>? audioSources,
    List<Map<String, dynamic>>? subtitles,
  }) => OfflineDownloadItem(
    id: id,
    movieId: movieId,
    movieSlug: movieSlug,
    movieTitle: movieTitle,
    episodeName: episodeName,
    serverName: serverName,
    sourceUrl: sourceUrl,
    posterUrl: posterUrl,
    audioSources: audioSources ?? this.audioSources,
    subtitles: subtitles ?? this.subtitles,
    state: state ?? this.state,
    createdAt: createdAt,
    localManifestPath: localManifestPath ?? this.localManifestPath,
    localPosterPath: localPosterPath ?? this.localPosterPath,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    completedFiles: completedFiles ?? this.completedFiles,
    totalFiles: totalFiles ?? this.totalFiles,
    error: error ?? this.error,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'movieId': movieId,
    'movieSlug': movieSlug,
    'movieTitle': movieTitle,
    'episodeName': episodeName,
    'serverName': serverName,
    'sourceUrl': sourceUrl,
    'posterUrl': posterUrl,
    'audioSources': audioSources,
    'subtitles': subtitles,
    'state': state.name,
    'createdAt': createdAt.toIso8601String(),
    'localManifestPath': localManifestPath,
    'localPosterPath': localPosterPath,
    'receivedBytes': receivedBytes,
    'totalBytes': totalBytes,
    'completedFiles': completedFiles,
    'totalFiles': totalFiles,
    'error': error,
  };

  factory OfflineDownloadItem.fromJson(Map<String, dynamic> json) {
    final stateName = json['state']?.toString() ?? '';
    var state = OfflineDownloadState.values.firstWhere(
      (value) => value.name == stateName,
      orElse: () => OfflineDownloadState.failed,
    );
    // A process death stops the in-memory task. Keep the item recoverable.
    if (state == OfflineDownloadState.downloading ||
        state == OfflineDownloadState.queued) {
      state = OfflineDownloadState.cancelled;
    }
    return OfflineDownloadItem(
      id: json['id']?.toString() ?? '',
      movieId: (json['movieId'] as num?)?.toInt() ?? 0,
      movieSlug: json['movieSlug']?.toString() ?? '',
      movieTitle: json['movieTitle']?.toString() ?? '',
      episodeName: json['episodeName']?.toString() ?? '',
      serverName: json['serverName']?.toString() ?? '',
      sourceUrl: json['sourceUrl']?.toString() ?? '',
      posterUrl: json['posterUrl']?.toString() ?? '',
      audioSources:
          (json['audioSources'] as List?)
              ?.whereType<Map>()
              .map((value) => Map<String, dynamic>.from(value))
              .toList() ??
          const [],
      subtitles:
          (json['subtitles'] as List?)
              ?.whereType<Map>()
              .map((value) => Map<String, dynamic>.from(value))
              .toList() ??
          const [],
      state: state,
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      localManifestPath: json['localManifestPath']?.toString() ?? '',
      localPosterPath: json['localPosterPath']?.toString() ?? '',
      receivedBytes: (json['receivedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      completedFiles: (json['completedFiles'] as num?)?.toInt() ?? 0,
      totalFiles: (json['totalFiles'] as num?)?.toInt() ?? 0,
      error: json['error']?.toString() ?? '',
    );
  }
}

class OfflineDownloadManager extends ChangeNotifier {
  OfflineDownloadManager._();
  static final instance = OfflineDownloadManager._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 2),
      followRedirects: true,
      headers: const {
        'Referer': 'https://cineviet.live/',
        'Origin': 'https://cineviet.live',
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
            'Mobile/15E148 Safari/604.1',
      },
    ),
  );
  final Map<String, CancelToken> _cancelTokens = {};
  List<OfflineDownloadItem> _items = const [];
  bool _loaded = false;

  List<OfflineDownloadItem> get items => List.unmodifiable(_items);

  Future<void> load() async {
    if (_loaded || !supportsOfflineDownloads) return;
    _loaded = true;
    final file = await _indexFile();
    if (!await file.exists()) return;
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is List) {
        _items = data
            .whereType<Map>()
            .map(
              (value) => OfflineDownloadItem.fromJson(
                Map<String, dynamic>.from(value),
              ),
            )
            .where((item) => item.id.isNotEmpty)
            .toList();
        await _persist();
        notifyListeners();
      }
    } catch (_) {
      _items = const [];
    }
  }

  OfflineDownloadItem? find(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<void> enqueue({
    required String id,
    required int movieId,
    required String movieSlug,
    required String movieTitle,
    required String episodeName,
    required String serverName,
    required String sourceUrl,
    required String posterUrl,
    List<Map<String, dynamic>> audioSources = const [],
    List<Map<String, dynamic>> subtitles = const [],
  }) async {
    await load();
    final uri = Uri.tryParse(sourceUrl.trim());
    if (uri == null || !uri.hasScheme || sourceUrl.contains('/embed')) {
      throw const FormatException('Nguồn này không hỗ trợ tải offline');
    }
    if (_cancelTokens.containsKey(id)) return;
    final old = find(id);
    if (old?.state == OfflineDownloadState.completed &&
        await File(old!.localManifestPath).exists()) {
      return;
    }
    final item = OfflineDownloadItem(
      id: id,
      movieId: movieId,
      movieSlug: movieSlug,
      movieTitle: movieTitle,
      episodeName: episodeName,
      serverName: serverName,
      sourceUrl: sourceUrl,
      posterUrl: posterUrl,
      audioSources: audioSources,
      subtitles: subtitles,
      state: OfflineDownloadState.queued,
      createdAt: old?.createdAt ?? DateTime.now(),
    );
    _replace(item);
    await _persist();
    notifyListeners();
    unawaited(_download(item));
  }

  Future<void> retry(String id) async {
    final item = find(id);
    if (item == null) return;
    await enqueue(
      id: item.id,
      movieId: item.movieId,
      movieSlug: item.movieSlug,
      movieTitle: item.movieTitle,
      episodeName: item.episodeName,
      serverName: item.serverName,
      sourceUrl: item.sourceUrl,
      posterUrl: item.posterUrl,
      audioSources: item.audioSources,
      subtitles: item.subtitles,
    );
  }

  Future<void> cancel(String id) async {
    _cancelTokens[id]?.cancel('Người dùng đã hủy');
  }

  Future<void> deleteMovie(Iterable<String> ids) async {
    for (final id in ids.toList()) {
      _cancelTokens[id]?.cancel('Đã xóa');
      _cancelTokens.remove(id);
      final directory = await _downloadDirectory(id);
      if (await directory.exists()) await directory.delete(recursive: true);
    }
    final deleting = ids.toSet();
    _items = _items.where((item) => !deleting.contains(item.id)).toList();
    await _persist();
    notifyListeners();
  }

  Future<void> delete(String id) async {
    _cancelTokens[id]?.cancel('Đã xóa');
    _cancelTokens.remove(id);
    _items = _items.where((item) => item.id != id).toList();
    final directory = await _downloadDirectory(id);
    if (await directory.exists()) await directory.delete(recursive: true);
    await _persist();
    notifyListeners();
  }

  Future<void> _download(OfflineDownloadItem initial) async {
    final token = CancelToken();
    _cancelTokens[initial.id] = token;
    _update(
      initial.id,
      (item) => item.copyWith(
        state: OfflineDownloadState.downloading,
        error: '',
        receivedBytes: 0,
        totalBytes: 0,
        completedFiles: 0,
        totalFiles: 0,
      ),
    );
    try {
      final directory = await _downloadDirectory(initial.id);
      if (await directory.exists()) await directory.delete(recursive: true);
      await directory.create(recursive: true);

      var localPosterPath = initial.localPosterPath;
      final posterUri = Uri.tryParse(initial.posterUrl.trim());
      if (posterUri != null && posterUri.hasScheme) {
        try {
          final extension = _imageExtensionFor(posterUri);
          final poster = File('${directory.path}/poster.$extension');
          await _dio.download(
            posterUri.toString(),
            poster.path,
            cancelToken: token,
          );
          localPosterPath = poster.path;
        } catch (_) {
          // Ảnh bìa chỉ làm đẹp thư viện; không được làm hỏng video tải về.
        }
      }

      var manifestUri = Uri.parse(initial.sourceUrl);
      var manifest = await _getText(manifestUri, token);
      if (!manifest.startsWith('#EXTM3U')) {
        throw const FormatException('Nguồn trả về không phải HLS');
      }
      if (_isMasterPlaylist(manifest)) {
        final variant = _bestVariant(manifest, manifestUri);
        if (variant == null) {
          throw const FormatException('Không tìm thấy luồng HLS phù hợp');
        }
        manifestUri = variant;
        manifest = await _getText(manifestUri, token);
      }
      if (manifest.contains('METHOD=SAMPLE-AES') ||
          manifest.contains('KEYFORMAT=')) {
        throw const FormatException('Nguồn DRM không hỗ trợ tải offline');
      }

      final resources = _manifestResources(manifest, manifestUri);
      if (resources.isEmpty) {
        throw const FormatException('Danh sách HLS không có phân đoạn video');
      }
      _update(
        initial.id,
        (item) => item.copyWith(totalFiles: resources.length),
      );
      var rewritten = manifest;
      var received = 0;
      for (var index = 0; index < resources.length; index++) {
        final resource = resources[index];
        final extension = _extensionFor(resource.uri, resource.kind);
        final localName =
            '${resource.kind}_${index.toString().padLeft(5, '0')}.$extension';
        final destination = File('${directory.path}/$localName');
        await _dio.download(
          resource.uri.toString(),
          destination.path,
          cancelToken: token,
          onReceiveProgress: (current, total) {
            final base = received;
            _updateThrottled(
              initial.id,
              (item) => item.copyWith(
                receivedBytes: base + current,
                totalBytes: total > 0
                    ? mathMax(item.totalBytes, base + total)
                    : item.totalBytes,
              ),
            );
          },
        );
        final length = await destination.length();
        received += length;
        rewritten = rewriteHlsResourceReference(
          rewritten,
          resource.rawReference,
          localName,
        );
        _update(
          initial.id,
          (item) => item.copyWith(
            receivedBytes: received,
            totalBytes: mathMax(item.totalBytes, received),
            completedFiles: index + 1,
          ),
        );
      }
      final localManifest = File('${directory.path}/index.m3u8');
      await localManifest.writeAsString(rewritten, flush: true);

      final localAudio = <Map<String, dynamic>>[];
      for (var index = 0; index < initial.audioSources.length; index++) {
        final source = initial.audioSources[index];
        final url = source['url']?.toString().trim() ?? '';
        if (url.isEmpty) continue;
        if (url == initial.sourceUrl) {
          localAudio.add({...source, 'url': localManifest.path});
          continue;
        }
        try {
          final audioDirectory = Directory('${directory.path}/audio_$index');
          final result = await _downloadHlsTrack(
            Uri.parse(url),
            audioDirectory,
            token,
            prefix: 'audio',
            onResources: (count) {
              _update(
                initial.id,
                (item) => item.copyWith(totalFiles: item.totalFiles + count),
              );
            },
            onResourceDownloaded: (bytes) {
              received += bytes;
              _update(
                initial.id,
                (item) => item.copyWith(
                  receivedBytes: received,
                  totalBytes: mathMax(item.totalBytes, received),
                  completedFiles: item.completedFiles + 1,
                ),
              );
            },
          );
          localAudio.add({...source, 'url': result.manifestPath});
        } catch (_) {
          // Một track phụ không được làm hỏng bản video chính.
        }
      }

      final localSubtitles = <Map<String, dynamic>>[];
      for (var index = 0; index < initial.subtitles.length; index++) {
        final subtitle = initial.subtitles[index];
        final url = subtitle['url']?.toString().trim() ?? '';
        if (url.isEmpty) continue;
        try {
          final uri = Uri.parse(url);
          final format =
              (subtitle['format']?.toString().trim().isNotEmpty == true)
              ? subtitle['format'].toString().toLowerCase()
              : (uri.path.toLowerCase().endsWith('.srt') ? 'srt' : 'vtt');
          final file = File('${directory.path}/subtitle_$index.$format');
          await _dio.download(uri.toString(), file.path, cancelToken: token);
          final length = await file.length();
          received += length;
          localSubtitles.add({...subtitle, 'url': file.path, 'format': format});
          _update(
            initial.id,
            (item) => item.copyWith(
              receivedBytes: received,
              totalBytes: received,
              completedFiles: item.completedFiles + 1,
              totalFiles: item.totalFiles + 1,
            ),
          );
        } catch (_) {
          // Giữ tải video thành công; UI chỉ hiện track thực sự đã tải.
        }
      }

      _update(
        initial.id,
        (item) => item.copyWith(
          state: OfflineDownloadState.completed,
          localManifestPath: localManifest.path,
          localPosterPath: localPosterPath,
          audioSources: localAudio,
          subtitles: localSubtitles,
          receivedBytes: received,
          totalBytes: received,
          completedFiles: item.totalFiles,
          error: '',
        ),
      );
    } on DioException catch (error) {
      final cancelled = CancelToken.isCancel(error);
      _update(
        initial.id,
        (item) => item.copyWith(
          state: cancelled
              ? OfflineDownloadState.cancelled
              : OfflineDownloadState.failed,
          error: cancelled ? 'Đã hủy' : 'Lỗi mạng khi tải video',
        ),
      );
    } catch (error) {
      _update(
        initial.id,
        (item) => item.copyWith(
          state: OfflineDownloadState.failed,
          error: error.toString().replaceFirst('FormatException: ', ''),
        ),
      );
    } finally {
      _cancelTokens.remove(initial.id);
      await _persist();
      notifyListeners();
    }
  }

  Future<_DownloadedHlsTrack> _downloadHlsTrack(
    Uri source,
    Directory directory,
    CancelToken token, {
    required String prefix,
    void Function(int count)? onResources,
    void Function(int bytes)? onResourceDownloaded,
  }) async {
    await directory.create(recursive: true);
    var manifestUri = source;
    var manifest = await _getText(manifestUri, token);
    if (!manifest.startsWith('#EXTM3U')) {
      throw const FormatException('Audio không phải HLS');
    }
    if (_isMasterPlaylist(manifest)) {
      final variant = _bestVariant(manifest, manifestUri);
      if (variant == null) {
        throw const FormatException('Audio HLS không hợp lệ');
      }
      manifestUri = variant;
      manifest = await _getText(manifestUri, token);
    }
    if (manifest.contains('METHOD=SAMPLE-AES') ||
        manifest.contains('KEYFORMAT=')) {
      throw const FormatException('Audio DRM không được hỗ trợ');
    }
    final resources = _manifestResources(manifest, manifestUri);
    if (resources.isEmpty) throw const FormatException('Audio HLS rỗng');
    onResources?.call(resources.length);
    var rewritten = manifest;
    var bytes = 0;
    for (var index = 0; index < resources.length; index++) {
      final resource = resources[index];
      final extension = _extensionFor(resource.uri, resource.kind);
      final name =
          '${prefix}_${resource.kind}_${index.toString().padLeft(5, '0')}.$extension';
      final file = File('${directory.path}/$name');
      await _dio.download(
        resource.uri.toString(),
        file.path,
        cancelToken: token,
      );
      final fileBytes = await file.length();
      bytes += fileBytes;
      onResourceDownloaded?.call(fileBytes);
      rewritten = rewriteHlsResourceReference(
        rewritten,
        resource.rawReference,
        name,
      );
    }
    final manifestFile = File('${directory.path}/index.m3u8');
    await manifestFile.writeAsString(rewritten, flush: true);
    return _DownloadedHlsTrack(manifestFile.path, bytes, resources.length);
  }

  int _lastProgressNotify = 0;
  void _updateThrottled(
    String id,
    OfflineDownloadItem Function(OfflineDownloadItem) transform,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _update(id, transform, notify: now - _lastProgressNotify >= 250);
    if (now - _lastProgressNotify >= 250) _lastProgressNotify = now;
  }

  void _update(
    String id,
    OfflineDownloadItem Function(OfflineDownloadItem) transform, {
    bool notify = true,
  }) {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final values = [..._items];
    values[index] = transform(values[index]);
    _items = values;
    if (notify) notifyListeners();
  }

  void _replace(OfflineDownloadItem item) {
    final index = _items.indexWhere((value) => value.id == item.id);
    final values = [..._items];
    if (index < 0) {
      values.insert(0, item);
    } else {
      values[index] = item;
    }
    _items = values;
  }

  Future<String> _getText(Uri uri, CancelToken token) async {
    final response = await _dio.get<String>(
      uri.toString(),
      cancelToken: token,
      options: Options(responseType: ResponseType.plain),
    );
    return response.data ?? '';
  }

  bool _isMasterPlaylist(String value) => value.contains('#EXT-X-STREAM-INF');

  Uri? _bestVariant(String manifest, Uri base) {
    final lines = const LineSplitter().convert(manifest);
    final variants = <({int bandwidth, Uri uri})>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      final bandwidth =
          int.tryParse(
            RegExp(r'BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ?? '',
          ) ??
          0;
      for (var j = i + 1; j < lines.length; j++) {
        final candidate = lines[j].trim();
        if (candidate.isEmpty) continue;
        if (!candidate.startsWith('#')) {
          variants.add((bandwidth: bandwidth, uri: base.resolve(candidate)));
        }
        break;
      }
    }
    variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    return variants.firstOrNull?.uri;
  }

  List<_ManifestResource> _manifestResources(String manifest, Uri base) {
    final result = <_ManifestResource>[];
    final seen = <String>{};
    for (final rawLine in const LineSplitter().convert(manifest)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (!line.startsWith('#')) {
        if (seen.add(line)) {
          result.add(_ManifestResource(line, base.resolve(line), 'segment'));
        }
        continue;
      }
      if (line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-MAP:')) {
        final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
        final reference = match?.group(1);
        if (reference != null && seen.add(reference)) {
          result.add(
            _ManifestResource(
              reference,
              base.resolve(reference),
              line.startsWith('#EXT-X-KEY:') ? 'key' : 'map',
            ),
          );
        }
      }
    }
    return result;
  }

  String _extensionFor(Uri uri, String kind) {
    if (kind == 'key') return 'key';
    final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    if (dot >= 0 && dot < name.length - 1) {
      final ext = name.substring(dot + 1).toLowerCase();
      if (RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext)) return ext;
    }
    return kind == 'map' ? 'mp4' : 'ts';
  }

  String _imageExtensionFor(Uri uri) {
    final path = uri.path.toLowerCase();
    for (final extension in const ['jpg', 'jpeg', 'png', 'webp']) {
      if (path.endsWith('.$extension')) return extension;
    }
    return 'jpg';
  }

  Future<Directory> _rootDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/offline_hls');
  }

  Future<Directory> _downloadDirectory(String id) async =>
      Directory('${(await _rootDirectory()).path}/$id');

  Future<File> _indexFile() async =>
      File('${(await _rootDirectory()).path}/$_indexFileName');

  Future<void> _persist() async {
    if (!supportsOfflineDownloads) return;
    final file = await _indexFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(_items.map((item) => item.toJson()).toList()),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}

int mathMax(int a, int b) => a > b ? a : b;

String rewriteHlsResourceReference(
  String manifest,
  String remoteReference,
  String localReference,
) {
  final lines = const LineSplitter().convert(manifest);
  return lines
      .map((line) {
        final trimmed = line.trim();
        if (trimmed == remoteReference) return localReference;
        if ((trimmed.startsWith('#EXT-X-KEY:') ||
                trimmed.startsWith('#EXT-X-MAP:')) &&
            trimmed.contains('URI="$remoteReference"')) {
          return line.replaceFirst(
            'URI="$remoteReference"',
            'URI="$localReference"',
          );
        }
        return line;
      })
      .join('\n');
}

class _DownloadedHlsTrack {
  const _DownloadedHlsTrack(this.manifestPath, this.bytes, this.files);
  final String manifestPath;
  final int bytes;
  final int files;
}

class _ManifestResource {
  const _ManifestResource(this.rawReference, this.uri, this.kind);
  final String rawReference;
  final Uri uri;
  final String kind;
}
