import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
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

  static const _taskGroup = 'cineviet-offline-hls';
  static const _downloadHeaders = <String, String>{
    'Referer': 'https://cineviet.live/',
    'Origin': 'https://cineviet.live',
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13; CineViet) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
  };

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 2),
      followRedirects: true,
      headers: _downloadHeaders,
    ),
  );
  final Map<String, _DownloadPlan> _plans = {};
  StreamSubscription<TaskUpdate>? _updatesSubscription;
  List<OfflineDownloadItem> _items = const [];
  bool _loaded = false;

  List<OfflineDownloadItem> get items => List.unmodifiable(_items);

  Future<void> load() async {
    if (_loaded || !supportsOfflineDownloads) return;
    _loaded = true;
    if (Platform.isAndroid || Platform.isIOS) {
      _updatesSubscription = FileDownloader().updates.listen(_handleTaskUpdate);
      await FileDownloader().configure(
        globalConfig: (Config.holdingQueue, (6, 3, 6)),
      );
      await FileDownloader().start();
    }
    final file = await _indexFile();
    if (await file.exists()) {
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
        }
      } catch (_) {
        _items = const [];
      }
    }
    for (final item in _items.where((value) => value.isActive)) {
      final plan = await _readPlan(item.id);
      if (plan != null) _plans[item.id] = plan;
    }
    await _reconcileAll();
    notifyListeners();
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
    final old = find(id);
    if (old?.state == OfflineDownloadState.completed &&
        await File(old!.localManifestPath).exists()) {
      return;
    }
    if (old?.isActive == true) return;

    _replace(
      OfflineDownloadItem(
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
      ),
    );
    await _persist();
    notifyListeners();
    await _prepareAndEnqueue(id);
    final prepared = find(id);
    if (prepared?.state == OfflineDownloadState.failed) {
      throw FormatException(
        prepared!.error.isEmpty
            ? 'Không thể bắt đầu tải xuống'
            : prepared.error,
      );
    }
  }

  Future<void> retry(String id) async {
    final item = find(id);
    if (item == null) return;
    _update(
      id,
      (value) => value.copyWith(state: OfflineDownloadState.queued, error: ''),
    );
    await _persist();
    unawaited(_prepareAndEnqueue(id, preserveExisting: true));
  }

  Future<void> cancel(String id) async {
    final plan = _plans[id] ?? await _readPlan(id);
    if (plan != null && (Platform.isAndroid || Platform.isIOS)) {
      await FileDownloader().cancelTasksWithIds(
        plan.resources.map((e) => e.taskId),
      );
    }
    _update(
      id,
      (item) =>
          item.copyWith(state: OfflineDownloadState.cancelled, error: 'Đã hủy'),
    );
    await _persist();
  }

  Future<void> deleteMovie(Iterable<String> ids) async {
    for (final id in ids.toList()) {
      await _cancelNativeTasks(id);
      _plans.remove(id);
      final directory = await _downloadDirectory(id);
      if (await directory.exists()) await directory.delete(recursive: true);
    }
    final deleting = ids.toSet();
    _items = _items.where((item) => !deleting.contains(item.id)).toList();
    await _persist();
    notifyListeners();
  }

  Future<void> delete(String id) => deleteMovie([id]);

  Future<void> _prepareAndEnqueue(
    String id, {
    bool preserveExisting = false,
  }) async {
    final initial = find(id);
    if (initial == null) return;
    try {
      final directory = await _downloadDirectory(id);
      if (!preserveExisting && await directory.exists()) {
        await _cancelNativeTasks(id);
        await directory.delete(recursive: true);
      }
      await directory.create(recursive: true);
      _update(
        id,
        (item) =>
            item.copyWith(state: OfflineDownloadState.downloading, error: ''),
      );

      var manifestUri = Uri.parse(initial.sourceUrl);
      var manifest = await _getText(manifestUri);
      if (!manifest.startsWith('#EXTM3U')) {
        throw const FormatException('Nguồn trả về không phải HLS');
      }
      if (_isMasterPlaylist(manifest)) {
        final variant = _bestVariant(manifest, manifestUri);
        if (variant == null) {
          throw const FormatException('Không tìm thấy luồng HLS phù hợp');
        }
        manifestUri = variant;
        manifest = await _getText(manifestUri);
      }
      if (manifest.contains('METHOD=SAMPLE-AES') ||
          manifest.contains('KEYFORMAT=')) {
        throw const FormatException('Nguồn DRM không hỗ trợ tải offline');
      }
      final found = _manifestResources(manifest, manifestUri);
      if (found.isEmpty) {
        throw const FormatException('Danh sách HLS không có phân đoạn video');
      }

      var rewritten = manifest;
      final resources = <_PlannedResource>[];
      for (var index = 0; index < found.length; index++) {
        final resource = found[index];
        final extension = _extensionFor(resource.uri, resource.kind);
        final localName =
            '${resource.kind}_${index.toString().padLeft(5, '0')}.$extension';
        final taskId = _stableTaskId(id, 'video', index);
        resources.add(
          _PlannedResource(taskId, resource.uri.toString(), localName),
        );
        rewritten = rewriteHlsResourceReference(
          rewritten,
          resource.rawReference,
          localName,
        );
      }
      final manifestFile = File('${directory.path}/index.m3u8');
      await manifestFile.writeAsString(rewritten, flush: true);
      final plan = _DownloadPlan(id, manifestFile.path, resources);
      _plans[id] = plan;
      await _writePlan(plan);
      _update(
        id,
        (item) => item.copyWith(
          state: OfflineDownloadState.downloading,
          localManifestPath: manifestFile.path,
          totalFiles: resources.length,
          completedFiles: 0,
          receivedBytes: 0,
          totalBytes: 0,
          error: '',
        ),
      );
      await _persist();
      notifyListeners();
      await _enqueueMissing(plan);
    } catch (error) {
      _update(
        id,
        (item) => item.copyWith(
          state: OfflineDownloadState.failed,
          error: error.toString().replaceFirst('FormatException: ', ''),
        ),
      );
      await _persist();
      notifyListeners();
    }
  }

  Future<void> _enqueueMissing(_DownloadPlan plan) async {
    final directory = await _downloadDirectory(plan.itemId);
    final tasks = <DownloadTask>[];
    for (final resource in plan.resources) {
      final file = File('${directory.path}/${resource.localName}');
      if (await file.exists() && await file.length() > 0) continue;
      tasks.add(
        DownloadTask(
          taskId: resource.taskId,
          group: _taskGroup,
          url: resource.url,
          headers: _downloadHeaders,
          filename: resource.localName,
          directory: 'offline_hls/${plan.itemId}',
          baseDirectory: BaseDirectory.applicationSupport,
          updates: Updates.statusAndProgress,
          retries: 4,
          allowPause: false,
          displayName: find(plan.itemId)?.movieTitle ?? 'CineViet',
          metaData: jsonEncode({'itemId': plan.itemId}),
        ),
      );
    }
    if (tasks.isNotEmpty) {
      if (!(Platform.isAndroid || Platform.isIOS)) {
        throw UnsupportedError('Tải nền native chỉ khả dụng trên Android/iOS');
      }
      final accepted = await FileDownloader().enqueueAll(tasks);
      if (accepted.length != tasks.length || accepted.any((value) => !value)) {
        throw const FormatException(
          'Thiết bị từ chối tác vụ tải nền. Vui lòng thử lại.',
        );
      }
    }
    if (tasks.isEmpty) await _reconcile(plan.itemId);
  }

  void _handleTaskUpdate(TaskUpdate update) {
    if (update.task.group != _taskGroup) return;
    try {
      final metadata = jsonDecode(update.task.metaData);
      final id = metadata is Map ? metadata['itemId']?.toString() : null;
      if (id == null || id.isEmpty) return;
      if (update case TaskStatusUpdate(:final status)) {
        if (status == TaskStatus.failed || status == TaskStatus.notFound) {
          final detail = update.exception?.description.trim() ?? '';
          _update(
            id,
            (item) => item.copyWith(
              state: OfflineDownloadState.failed,
              error: detail.isEmpty
                  ? 'Không thể tiếp tục tải tài nguyên nền'
                  : 'Tải thất bại: $detail',
            ),
          );
          unawaited(_persist());
          notifyListeners();
          return;
        }
      }
      unawaited(_reconcile(id));
    } catch (_) {}
  }

  Future<void> _reconcileAll() async {
    for (final item in _items.where((value) => value.isActive).toList()) {
      await _reconcile(item.id);
      final plan = _plans[item.id];
      if (plan != null &&
          find(item.id)?.state == OfflineDownloadState.downloading) {
        await _enqueueMissing(plan);
      }
    }
  }

  Future<void> _reconcile(String id) async {
    final plan = _plans[id] ?? await _readPlan(id);
    final item = find(id);
    if (plan == null || item == null || !item.isActive) {
      if (item?.state == OfflineDownloadState.queued) {
        unawaited(_prepareAndEnqueue(id, preserveExisting: true));
      }
      return;
    }
    _plans[id] = plan;
    final directory = await _downloadDirectory(id);
    var complete = 0;
    var bytes = 0;
    for (final resource in plan.resources) {
      final file = File('${directory.path}/${resource.localName}');
      if (await file.exists()) {
        final length = await file.length();
        if (length > 0) {
          complete++;
          bytes += length;
        }
      }
    }
    final done = complete == plan.resources.length && plan.resources.isNotEmpty;
    _update(
      id,
      (value) => value.copyWith(
        state: done
            ? OfflineDownloadState.completed
            : OfflineDownloadState.downloading,
        localManifestPath: plan.manifestPath,
        completedFiles: complete,
        totalFiles: plan.resources.length,
        receivedBytes: bytes,
        totalBytes: done ? bytes : value.totalBytes,
        error: '',
      ),
    );
    await _persist();
    notifyListeners();
  }

  Future<void> _cancelNativeTasks(String id) async {
    final plan = _plans[id] ?? await _readPlan(id);
    if (plan != null && (Platform.isAndroid || Platform.isIOS)) {
      await FileDownloader().cancelTasksWithIds(
        plan.resources.map((e) => e.taskId),
      );
    }
  }

  String _stableTaskId(String itemId, String kind, int index) {
    final safe = itemId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'cv_${safe}_${kind}_$index';
  }

  Future<String> _getText(Uri uri) async {
    final response = await _dio.get<String>(
      uri.toString(),
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
        final reference = RegExp(r'URI="([^"]+)"').firstMatch(line)?.group(1);
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

  void _update(
    String id,
    OfflineDownloadItem Function(OfflineDownloadItem) transform,
  ) {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final values = [..._items];
    values[index] = transform(values[index]);
    _items = values;
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

  Future<Directory> _rootDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/offline_hls');
  }

  Future<Directory> _downloadDirectory(String id) async =>
      Directory('${(await _rootDirectory()).path}/$id');
  Future<File> _indexFile() async =>
      File('${(await _rootDirectory()).path}/$_indexFileName');
  Future<File> _planFile(String id) async =>
      File('${(await _downloadDirectory(id)).path}/download-plan.json');

  Future<_DownloadPlan?> _readPlan(String id) async {
    try {
      final file = await _planFile(id);
      if (!await file.exists()) return null;
      return _DownloadPlan.fromJson(
        Map<String, dynamic>.from(jsonDecode(await file.readAsString())),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writePlan(_DownloadPlan plan) async {
    final file = await _planFile(plan.itemId);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(plan.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<void> _persist() async {
    if (!supportsOfflineDownloads) return;
    final file = await _indexFile();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(_items.map((item) => item.toJson()).toList()),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  @override
  void dispose() {
    unawaited(_updatesSubscription?.cancel());
    super.dispose();
  }
}

class _DownloadPlan {
  const _DownloadPlan(this.itemId, this.manifestPath, this.resources);
  final String itemId;
  final String manifestPath;
  final List<_PlannedResource> resources;
  Map<String, dynamic> toJson() => {
    'itemId': itemId,
    'manifestPath': manifestPath,
    'resources': resources.map((e) => e.toJson()).toList(),
  };
  factory _DownloadPlan.fromJson(Map<String, dynamic> json) => _DownloadPlan(
    json['itemId']?.toString() ?? '',
    json['manifestPath']?.toString() ?? '',
    (json['resources'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => _PlannedResource.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
  );
}

class _PlannedResource {
  const _PlannedResource(this.taskId, this.url, this.localName);
  final String taskId;
  final String url;
  final String localName;
  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'url': url,
    'localName': localName,
  };
  factory _PlannedResource.fromJson(Map<String, dynamic> json) =>
      _PlannedResource(
        json['taskId']?.toString() ?? '',
        json['url']?.toString() ?? '',
        json['localName']?.toString() ?? '',
      );
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

class _ManifestResource {
  const _ManifestResource(this.rawReference, this.uri, this.kind);
  final String rawReference;
  final Uri uri;
  final String kind;
}
