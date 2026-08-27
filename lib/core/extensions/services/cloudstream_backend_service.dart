import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

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
///
/// CloudStream repositories publish two plugin shapes in practice:
///  * cross-platform JVM JARs via `jarUrl` (for example several Phisher builds)
///  * Android `.cs3` ZIPs containing `classes.dex` (for example CNCVerse)
///
/// JVM JARs are handed directly to the local backend. DEX-only CS3 packages are
/// converted locally with the bundled Apache-2.0 dex2jar tool and then loaded by
/// exactly the same JVM backend. No remote bridge is involved.
class CloudStreamBackendService {
  final Dio _dio;
  Process? _process;
  Future<bool>? _startFuture;
  int? _port;
  Directory? _dataDir;
  late final String _token;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  CloudStreamBackendService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 6),
                receiveTimeout: const Duration(seconds: 95),
                sendTimeout: const Duration(seconds: 30),
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
          ? p.join(appData, 'SkyStream', 'cloudstream-backend')
          : p.join(executableDir.path, 'cloudstream-data'),
    )..createSync(recursive: true);
    _dataDir = dataDir;

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

    final jarUrl = plugin.manifest['jarUrl']?.toString().trim() ?? '';
    if (jarUrl.isNotEmpty) {
      final payload = <String, dynamic>{
        'name': plugin.name,
        'internalName': plugin.manifest['internalName'],
        'url': plugin.sourceUrl,
        'jarUrl': jarUrl,
        'jarHash': plugin.manifest['jarHash'],
      };
      return _post('/plugins/install', payload);
    }

    if (plugin.sourceUrl.toLowerCase().endsWith('.cs3')) {
      return _installDexCs3(plugin);
    }

    return {
      'ok': false,
      'status': 'no_runtime_artifact',
      'message': 'This CloudStream provider has neither jarUrl nor a CS3 package.',
    };
  }

  Future<Map<String, dynamic>> _installDexCs3(ExtensionPlugin plugin) async {
    final executableDir = File(Platform.resolvedExecutable).parent;
    final dex2jar = _findDex2Jar(executableDir);
    if (dex2jar == null) {
      return {
        'ok': false,
        'status': 'dex_converter_unavailable',
        'message': 'Bundled dex2jar runtime is missing.',
      };
    }

    final dataDir = _dataDir;
    if (dataDir == null) {
      return {
        'ok': false,
        'status': 'backend_unavailable',
        'message': 'CloudStream data directory is unavailable.',
      };
    }

    final safeName = _safeFileName(
      plugin.manifest['internalName']?.toString().trim().isNotEmpty == true
          ? plugin.manifest['internalName'].toString().trim()
          : plugin.name,
    );

    final conversionDir = Directory(p.join(dataDir.path, 'conversion'))
      ..createSync(recursive: true);
    final dexFile = File(p.join(conversionDir.path, '$safeName.dex'));
    final convertedJar = File(p.join(conversionDir.path, '$safeName-jvm.jar'));

    try {
      final response = await _dio.get<List<int>>(
        plugin.sourceUrl,
        options: Options(
          responseType: ResponseType.bytes,
          headers: const {
            'User-Agent': 'SkyStream-CloudStream-Backend/0.2',
          },
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.length < 200) {
        return {
          'ok': false,
          'status': 'cs3_download_failed',
          'message': 'The CS3 package download was empty or invalid.',
        };
      }

      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      final dexEntry = archive.findFile('classes.dex');
      if (dexEntry == null || !dexEntry.isFile) {
        return {
          'ok': false,
          'status': 'cs3_missing_dex',
          'message': 'The CS3 package does not contain classes.dex.',
        };
      }

      final dexBytes = dexEntry.content;
      if (dexBytes is List<int>) {
        await dexFile.writeAsBytes(dexBytes, flush: true);
      } else {
        return {
          'ok': false,
          'status': 'cs3_invalid_dex',
          'message': 'Unable to read classes.dex from the CS3 package.',
        };
      }

      if (await convertedJar.exists()) await convertedJar.delete();

      final java = _findJava(executableDir);
      final classPath = p.join(dex2jar.path, 'lib', '*');
      final process = await Process.run(
        java,
        [
          '-cp',
          classPath,
          'com.googlecode.dex2jar.tools.Dex2jarCmd',
          '-f',
          '-o',
          convertedJar.path,
          dexFile.path,
        ],
        workingDirectory: conversionDir.path,
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 75));

      if (process.exitCode != 0 ||
          !await convertedJar.exists() ||
          await convertedJar.length() < 200) {
        final detail = '${process.stderr}\n${process.stdout}'.trim();
        return {
          'ok': false,
          'status': 'dex_conversion_failed',
          'message': detail.isEmpty
              ? 'DEX to JVM conversion failed.'
              : 'DEX to JVM conversion failed: ${_short(detail)}',
        };
      }

      final pluginsDir = Directory(p.join(dataDir.path, 'plugins'))
        ..createSync(recursive: true);
      final target = File(p.join(pluginsDir.path, '$safeName.jar'));
      await convertedJar.copy(target.path);

      final restarted = await restart();
      if (!restarted) {
        return {
          'ok': false,
          'status': 'backend_restart_failed',
          'message': 'Converted the CS3 package but could not restart the local runtime.',
        };
      }

      final active = await providers();
      final targetName = p.basename(target.path).toLowerCase();
      final loaded = active.where((entry) {
        final source = entry['sourcePlugin']?.toString().toLowerCase() ?? '';
        return source.endsWith(targetName);
      }).toList(growable: false);

      if (loaded.isEmpty) {
        return {
          'ok': false,
          'status': 'dex_no_provider',
          'message':
              'The CS3 package converted to JVM bytecode, but its provider could not be loaded locally. It may depend on Android-only APIs.',
          'providers': active,
        };
      }

      return {
        'ok': true,
        'status': 'installed_dex',
        'message': 'Converted and loaded ${loaded.length} CloudStream provider(s) locally.',
        'providers': loaded,
      };
    } on TimeoutException {
      return {
        'ok': false,
        'status': 'dex_conversion_timeout',
        'message': 'DEX conversion timed out.',
      };
    } catch (error) {
      if (kDebugMode) debugPrint('[CloudStreamBackend] DEX install failed: $error');
      return {
        'ok': false,
        'status': 'dex_error',
        'message': error.toString(),
      };
    }
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
        p.join(
          executableDir.path,
          'cloudstream-backend',
          'skystream-cloudstream-backend-all.jar',
        ),
      ),
      File(p.join(executableDir.path, 'cloudstream-backend', 'backend.jar')),
      File(
        p.join(
          Directory.current.path,
          'cloudstream_backend',
          'build',
          'libs',
          'skystream-cloudstream-backend-0.1.0-all.jar',
        ),
      ),
    ];
    for (final candidate in candidates) {
      if (candidate.existsSync()) return candidate;
    }
    return null;
  }

  Directory? _findDex2Jar(Directory executableDir) {
    final direct = Directory(
      p.join(executableDir.path, 'cloudstream-backend', 'dex2jar'),
    );
    if (Directory(p.join(direct.path, 'lib')).existsSync()) return direct;

    if (direct.existsSync()) {
      for (final entity in direct.listSync(followLinks: false)) {
        if (entity is Directory &&
            Directory(p.join(entity.path, 'lib')).existsSync()) {
          return entity;
        }
      }
    }
    return null;
  }

  String _findJava(Directory executableDir) {
    final candidates = [
      File(
        p.join(
          executableDir.path,
          'cloudstream-backend',
          'runtime',
          'bin',
          'java.exe',
        ),
      ),
      File(p.join(executableDir.path, 'runtime', 'bin', 'java.exe')),
    ];
    for (final candidate in candidates) {
      if (candidate.existsSync()) return candidate.path;
    }
    return 'java';
  }

  String _safeFileName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'^[._-]+|[._-]+$'), '');
    return cleaned.isEmpty ? 'plugin' : cleaned;
  }

  String _short(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length <= 500 ? normalized : '${normalized.substring(0, 500)}…';
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
