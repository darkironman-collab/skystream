import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/extension_plugin.dart';

final cloudStreamBackendServiceProvider = Provider<CloudStreamBackendService>((ref) {
  final service = CloudStreamBackendService();
  ref.onDispose(service.dispose);
  return service;
});

/// Manages the bundled CloudStream JVM runtime on Windows.
///
/// The backend is a child process bound to 127.0.0.1 only. A random per-process
/// token is required on every request, so other local applications cannot
/// silently drive the plugin runtime.
class CloudStreamBackendService {
  final Dio _dio;
  Process? _process;
  Future<bool>? _startFuture;
  int? _port;
  late final String _token;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  CloudStreamBackendService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 4),
                receiveTimeout: const Duration(seconds: 95),
                sendTimeout: const Duration(seconds: 20),
                validateStatus: (status) => status != null && status < 500,
              ),
            ) {
    final random = Random.secure();
    _token = base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
  }

  bool get isSupported => Platform.isWindows;
  bool get isRunning => _process != null && _port != null;

  Future<bool> ensureStarted() {
    if (!isSupported) return Future.value(false);
    return _startFuture ??= _start();
  }

  Future<bool> restart() async {
    await dispose();
    return ensureStarted();
  }

  Future<bool> _start() async {
    if (_process != null && _port != null) {
      if (await _health()) return true;
      await dispose();
    }

    final executableDir = File(Platform.resolvedExecutable).parent;
    final jar = _findBackendJar(executableDir);
    if (jar == null) {
      if (kDebugMode) {
        debugPrint('[CloudStreamBackend] backend JAR was not found next to the app');
      }
      return false;
    }

    final java = _findJava(executableDir);
    final appData = Platform.environment['APPDATA'];
    final dataDir = Directory(
      appData != null && appData.isNotEmpty
          ? '$appData${Platform.pathSeparator}SkyStream${Platform.pathSeparator}cloudstream-backend'
          : '${executableDir.path}${Platform.pathSeparator}cloudstream-data',
    )..createSync(recursive: true);

    final ready = Completer<int>();
    final process = await Process.start(
      java,
      [
        '--add-modules',
        'jdk.httpserver',
        '-jar',
        jar.path,
        '--port',
        '0',
        '--token',
        _token,
        '--data-dir',
        dataDir.path,
      ],
      workingDirectory: executableDir.path,
      runInShell: java == 'java',
    );
    _process = process;

    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      const prefix = 'SKYSTREAM_CLOUDSTREAM_BACKEND_READY:';
      if (line.startsWith(prefix) && !ready.isCompleted) {
        final port = int.tryParse(line.substring(prefix.length).trim());
        if (port != null) ready.complete(port);
      }
      if (kDebugMode) debugPrint('[CloudStreamBackend] $line');
    });
    _stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (kDebugMode) debugPrint('[CloudStreamBackend:stderr] $line');
    });

    unawaited(process.exitCode.then((_) {
      _process = null;
      _port = null;
      _startFuture = null;
      if (!ready.isCompleted) {
        ready.completeError(StateError('CloudStream backend exited before startup'));
      }
    }));

    try {
      _port = await ready.future.timeout(const Duration(seconds: 35));
      return await _health();
    } catch (error) {
      if (kDebugMode) debugPrint('[CloudStreamBackend] startup failed: $error');
      process.kill();
      _process = null;
      _port = null;
      return false;
    }
  }

  Future<Map<String, dynamic>> installPlugin(ExtensionPlugin plugin) async {
    if (!await ensureStarted()) {
      return {
        'ok': false,
        'status': 'backend_unavailable',
        'message': 'Local CloudStream runtime is unavailable.',
      };
    }
    final payload = <String, dynamic>{
      'name': plugin.name,
      'internalName': plugin.manifest['internalName'],
      'url': plugin.sourceUrl,
      'jarUrl': plugin.manifest['jarUrl'],
      'jarHash': plugin.manifest['jarHash'],
    };
    return _post('/plugins/install', payload);
  }

  Future<List<Map<String, dynamic>>> providers() async {
    if (!await ensureStarted()) return const [];
    final result = await _get('/providers');
    return _mapList(result['providers']);
  }

  Future<List<Map<String, dynamic>>> search(
    String query, {
    String? provider,
  }) async {
    if (!await ensureStarted()) return const [];
    final result = await _post('/search', {
      'query': query,
      if (provider != null && provider.isNotEmpty) 'provider': provider,
    });
    return _mapList(result['results']);
  }

  Future<Map<String, dynamic>?> details({
    required String provider,
    required String url,
  }) async {
    if (!await ensureStarted()) return null;
    final response = await _post('/details', {'provider': provider, 'url': url});
    return response.containsKey('error') ? null : response;
  }

  Future<Map<String, dynamic>> streams({
    required String provider,
    required String data,
  }) async {
    if (!await ensureStarted()) {
      return {'ok': false, 'streams': const <dynamic>[]};
    }
    return _post('/streams', {'provider': provider, 'data': data});
  }

  Future<bool> _health() async {
    try {
      final response = await _get('/health');
      return response['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final port = _port;
    if (port == null) return const {};
    final response = await _dio.get<dynamic>(
      'http://127.0.0.1:$port$path',
      options: Options(headers: {'X-SkyStream-Token': _token}),
    );
    return _toMap(response.data);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> data,
  ) async {
    final port = _port;
    if (port == null) return const {};
    final response = await _dio.post<dynamic>(
      'http://127.0.0.1:$port$path',
      data: data,
      options: Options(
        contentType: Headers.jsonContentType,
        headers: {'X-SkyStream-Token': _token},
      ),
    );
    return _toMap(response.data);
  }

  Map<String, dynamic> _toMap(dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return const {};
  }

  List<Map<String, dynamic>> _mapList(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList(growable: false);
  }

  File? _findBackendJar(Directory executableDir) {
    final candidates = [
      File(
        '${executableDir.path}${Platform.pathSeparator}cloudstream-backend${Platform.pathSeparator}skystream-cloudstream-backend-all.jar',
      ),
      File(
        '${executableDir.path}${Platform.pathSeparator}cloudstream-backend${Platform.pathSeparator}backend.jar',
      ),
      // Developer convenience when running from the repository root.
      File(
        '${Directory.current.path}${Platform.pathSeparator}cloudstream_backend${Platform.pathSeparator}build${Platform.pathSeparator}libs${Platform.pathSeparator}skystream-cloudstream-backend-0.1.0-all.jar',
      ),
    ];
    for (final candidate in candidates) {
      if (candidate.existsSync()) return candidate;
    }
    return null;
  }

  String _findJava(Directory executableDir) {
    final candidates = [
      File(
        '${executableDir.path}${Platform.pathSeparator}cloudstream-backend${Platform.pathSeparator}runtime${Platform.pathSeparator}bin${Platform.pathSeparator}java.exe',
      ),
      File(
        '${executableDir.path}${Platform.pathSeparator}runtime${Platform.pathSeparator}bin${Platform.pathSeparator}java.exe',
      ),
    ];
    for (final candidate in candidates) {
      if (candidate.existsSync()) return candidate.path;
    }
    return 'java';
  }

  Future<void> dispose() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    final process = _process;
    _process = null;
    _port = null;
    _startFuture = null;
    process?.kill();
  }
}
