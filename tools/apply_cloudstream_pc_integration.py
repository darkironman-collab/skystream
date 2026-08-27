from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text(encoding='utf-8')
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected one anchor, found {count}: {old[:80]!r}')
    p.write_text(text.replace(old, new, 1), encoding='utf-8')


# ---------------------------------------------------------------------------
# 1) Persist CloudStream metadata without treating .cs3 as a .sky ZIP.
# ---------------------------------------------------------------------------
storage = 'lib/core/extensions/services/plugin_storage_service.dart'
replace_once(
    storage,
    '''    return plugin;\n  }\n\n  /// Deletes a plugin directory (by Package Name).''',
    '''    return plugin;\n  }\n\n  /// Persists a CloudStream repository entry without extracting its Android\n  /// `.cs3` package as a SkyStream `.sky` archive. The executable provider\n  /// code is owned by either the localhost JVM runtime (`runtimeMode=jvm`) or\n  /// the configured Stream X/Stremio bridge (`runtimeMode=bridge`).\n  Future<ExtensionPlugin> installCloudStreamMetadata(\n    ExtensionPlugin plugin, {\n    required String runtimeMode,\n    String? bridgeManifestUrl,\n  }) async {\n    if (!isSafePluginPackageName(plugin.packageName)) {\n      throw Exception(\n        'Unsafe CloudStream package name: ${plugin.packageName}',\n      );\n    }\n\n    final rootDir = await _pluginsDir;\n    final targetPath = resolvePluginPathWithin(rootDir.path, plugin.packageName);\n    if (targetPath == null) {\n      throw Exception('CloudStream package path escapes the plugin directory');\n    }\n\n    final targetDir = Directory(targetPath);\n    final stagingDir = Directory(\n      p.join(\n        rootDir.path,\n        '.tmp-cloudstream-${plugin.packageName}-${DateTime.now().millisecondsSinceEpoch}',\n      ),\n    );\n    await stagingDir.create(recursive: true);\n\n    try {\n      final meta = Map<String, dynamic>.from(plugin.manifest);\n      meta['packageName'] = plugin.packageName;\n      meta['name'] = plugin.name;\n      meta['url'] = plugin.sourceUrl;\n      meta['version'] = plugin.version;\n      meta['status'] = plugin.status;\n      meta['repositoryId'] = plugin.repositoryId;\n      meta['cloudstream'] = true;\n      meta['sourceFormat'] = 'cloudstream-cs3';\n      meta['runtimeMode'] = runtimeMode;\n      if (bridgeManifestUrl != null && bridgeManifestUrl.isNotEmpty) {\n        meta['bridgeManifestUrl'] = bridgeManifestUrl;\n      } else {\n        meta.remove('bridgeManifestUrl');\n      }\n\n      await File(p.join(stagingDir.path, 'meta.json')).writeAsString(\n        jsonEncode(meta),\n      );\n\n      if (await targetDir.exists()) {\n        await targetDir.delete(recursive: true);\n      }\n      await stagingDir.rename(targetDir.path);\n      return ExtensionPlugin.fromJson(meta, plugin.repositoryId);\n    } catch (_) {\n      try {\n        if (await stagingDir.exists()) {\n          await stagingDir.delete(recursive: true);\n        }\n      } catch (_) {}\n      rethrow;\n    }\n  }\n\n  /// Deletes a plugin directory (by Package Name).''',
)


# ---------------------------------------------------------------------------
# 2) Route CloudStream installs to JVM or Stream X instead of .sky extraction.
# ---------------------------------------------------------------------------
controller = 'lib/features/extensions/providers/extensions_controller.dart'
replace_once(
    controller,
    "import '../../../../core/extensions/extension_manager.dart';\nimport '../../../../core/extensions/providers.dart';",
    "import '../../../../core/extensions/extension_manager.dart';\nimport '../../../../core/extensions/providers.dart';\nimport '../../../../core/extensions/services/cloudstream_backend_service.dart';\nimport '../../../../core/addons/data/addon_repository.dart';",
)
replace_once(
    controller,
    '''part 'extensions_controller.g.dart';\n\n// State for the Extensions Screen (Sealed Class Hierarchy)''',
    '''part 'extensions_controller.g.dart';\n\n@visibleForTesting\nbool isCloudStreamExtensionPlugin(ExtensionPlugin plugin) =>\n    plugin.manifest['cloudstream'] == true ||\n    plugin.manifest['sourceFormat'] == 'cloudstream-cs3' ||\n    plugin.sourceUrl.toLowerCase().endsWith('.cs3');\n\n// State for the Extensions Screen (Sealed Class Hierarchy)''',
)
replace_once(
    controller,
    '''  Future<void> ensureInitialized() async {\n    if (_initialized) return;\n    _initialized = true;\n    await _init();\n  }\n''',
    '''  Future<void> ensureInitialized() async {\n    if (_initialized) return;\n    _initialized = true;\n    await _init();\n  }\n\n  String? _streamXBridgeManifestUrl() {\n    final addons = ref.read(addonRepositoryProvider).enabled;\n    for (final addon in addons) {\n      final manifest = addon.manifest;\n      if (manifest == null) continue;\n      final fingerprint = [\n        manifest.id,\n        manifest.name,\n        manifest.description,\n        addon.manifestUrl,\n      ].join(' ').toLowerCase();\n      final hasStreams = manifest.resources.any((r) => r.name == 'stream');\n      final looksLikeStreamX =\n          fingerprint.contains('stream x') ||\n          fingerprint.contains('streamx') ||\n          fingerprint.contains('cloudstream bridge') ||\n          fingerprint.contains('extremeos') ||\n          fingerprint.contains('/provider/');\n      if (hasStreams && looksLikeStreamX) return addon.manifestUrl;\n    }\n    return null;\n  }\n''',
)
replace_once(
    controller,
    '''      for (final plugin in plugins) {\n        File? savedFile;\n\n        // Standard HTTP Download''',
    '''      for (final plugin in plugins) {\n        if (isCloudStreamExtensionPlugin(plugin)) {\n          final backend = ref.read(cloudStreamBackendServiceProvider);\n          final result = await backend.installPlugin(plugin);\n          final status = result['status']?.toString() ?? 'error';\n\n          String runtimeMode;\n          String? bridgeManifestUrl;\n          if (result['ok'] == true) {\n            runtimeMode = 'jvm';\n          } else if (status == 'android_only') {\n            bridgeManifestUrl = _streamXBridgeManifestUrl();\n            if (bridgeManifestUrl == null) {\n              throw Exception(\n                '${plugin.name} is an Android-only CloudStream provider. '\n                'Install/enable your Stream X Bridge manifest in Add-ons, then retry. '\n                'SkyStream will delegate this provider to the bridge instead of trying '\n                'to execute Android DEX on Windows.',\n              );\n            }\n            runtimeMode = 'bridge';\n          } else {\n            final message = result['message']?.toString();\n            throw Exception(\n              message == null || message.isEmpty\n                  ? 'CloudStream provider installation failed ($status).'\n                  : message,\n            );\n          }\n\n          final targetPlugin = await storageService.installCloudStreamMetadata(\n            plugin,\n            runtimeMode: runtimeMode,\n            bridgeManifestUrl: bridgeManifestUrl,\n          );\n\n          await ref\n              .read(extensionManagerProvider.notifier)\n              .reloadPlugin(targetPlugin);\n\n          final newUpdates = Map<String, ExtensionPlugin>.from(\n            state.availableUpdates,\n          )..remove(targetPlugin.packageName);\n          final currentInstalling = Set<String>.from(state.installingPlugins)\n            ..remove(targetPlugin.packageName);\n          final newInstalled = List<ExtensionPlugin>.from(\n            state.installedPlugins,\n          );\n          final existingIndex = newInstalled.indexWhere(\n            (p) => p.packageName == targetPlugin.packageName,\n          );\n          if (existingIndex >= 0) {\n            newInstalled[existingIndex] = targetPlugin;\n          } else {\n            newInstalled.add(targetPlugin);\n          }\n          state = ExtensionsSuccess(\n            installedPlugins: newInstalled,\n            repositories: state.repositories,\n            availablePlugins: state.availablePlugins,\n            availableUpdates: newUpdates,\n            installingPlugins: currentInstalling,\n          );\n          continue;\n        }\n\n        File? savedFile;\n\n        // Standard HTTP Download''',
)
replace_once(
    controller,
    '''  Future<void> uninstallPlugin(ExtensionPlugin plugin) async {\n    final storageService = ref.read(pluginStorageServiceProvider);\n    await storageService.deletePlugin(plugin);\n    await loadInstalledPlugins();\n  }''',
    '''  Future<void> uninstallPlugin(ExtensionPlugin plugin) async {\n    final storageService = ref.read(pluginStorageServiceProvider);\n    final isCloudStream = isCloudStreamExtensionPlugin(plugin);\n    await storageService.deletePlugin(plugin);\n    if (isCloudStream) {\n      // A JVM cannot unload arbitrary plugin classloaders safely. Restart the\n      // localhost sidecar, then the normal extension sync re-registers only\n      // the CloudStream plugins that are still installed.\n      await ref.read(cloudStreamBackendServiceProvider).restart();\n    }\n    await loadInstalledPlugins();\n    if (isCloudStream) {\n      await ref\n          .read(extensionManagerProvider.notifier)\n          .syncFromPlugins(state.installedPlugins);\n    }\n  }''',
)


# ---------------------------------------------------------------------------
# 3) Register exactly one SkyStream provider for the local JVM runtime.
# ---------------------------------------------------------------------------
manager = 'lib/core/extensions/extension_manager.dart'
replace_once(
    manager,
    "import 'providers/js_based_provider.dart';\nimport 'services/plugin_storage_service.dart';",
    "import 'providers/js_based_provider.dart';\nimport 'providers/cloudstream_local_provider.dart';\nimport 'services/plugin_storage_service.dart';\nimport 'services/cloudstream_backend_service.dart';",
)
replace_once(
    manager,
    '''part 'extension_manager.g.dart';\n\n@Riverpod(keepAlive: true)''',
    '''part 'extension_manager.g.dart';\n\nbool _isCloudStreamPlugin(ExtensionPlugin plugin) =>\n    plugin.manifest['cloudstream'] == true ||\n    plugin.manifest['sourceFormat'] == 'cloudstream-cs3' ||\n    plugin.sourceUrl.toLowerCase().endsWith('.cs3');\n\nbool _isLocalJvmCloudStreamPlugin(ExtensionPlugin plugin) {\n  if (!_isCloudStreamPlugin(plugin)) return false;\n  if (plugin.manifest['runtimeMode'] == 'bridge') return false;\n  final jarUrl = plugin.manifest['jarUrl']?.toString().trim() ?? '';\n  return jarUrl.isNotEmpty;\n}\n\n@Riverpod(keepAlive: true)''',
)
replace_once(
    manager,
    '''          final loadedInBatch = results.expand((l) => l).toList();\n          if (loadedInBatch.isNotEmpty) {\n            state = [...state, ...loadedInBatch];\n          }''',
    '''          final loadedInBatch = results.expand((l) => l).toList();\n          if (loadedInBatch.isNotEmpty) {\n            final next = List<SkyStreamProvider>.from(state);\n            for (final provider in loadedInBatch) {\n              if (!next.any((p) => p.packageName == provider.packageName)) {\n                next.add(provider);\n              }\n            }\n            state = next;\n          }''',
)
replace_once(
    manager,
    '''      final installedPackageNames = installed.map((e) => e.packageName).toSet();''',
    '''      final installedPackageNames = installed.map((e) => e.packageName).toSet();\n      if (installed.any(_isLocalJvmCloudStreamPlugin)) {\n        installedPackageNames.add(CloudStreamLocalProvider.runtimePackageName);\n      }''',
)
replace_once(
    manager,
    '''  /// Registers shell providers for a plugin. JS is NOT evaluated here — it is\n  /// loaded lazily on the first search/getHome/getDetails/loadStreams call.''',
    '''  Future<List<SkyStreamProvider>> _loadCloudStreamPlugin(\n    ExtensionPlugin plugin,\n  ) async {\n    // Android/Dex-only providers are consumed through the user's enabled\n    // Stream X Stremio add-on. They deliberately do not create a fake local\n    // provider or try to evaluate a .cs3 as JavaScript.\n    if (plugin.manifest['runtimeMode'] == 'bridge') return const [];\n\n    final backend = ref.read(cloudStreamBackendServiceProvider);\n    final result = await backend.installPlugin(plugin);\n    if (result['ok'] == true) {\n      if (state.any(\n        (p) => p.packageName == CloudStreamLocalProvider.runtimePackageName,\n      )) {\n        return const [];\n      }\n      return [CloudStreamLocalProvider(backend)];\n    }\n\n    // On application restart the backend preloads persisted JARs before the\n    // Dart extension manager syncs. Re-installing the same JAR may therefore\n    // report `no_provider` even though its provider is already active. Treat\n    // a non-empty backend provider list as a healthy, idempotent runtime.\n    final activeProviders = await backend.providers();\n    if (activeProviders.isNotEmpty) {\n      if (state.any(\n        (p) => p.packageName == CloudStreamLocalProvider.runtimePackageName,\n      )) {\n        return const [];\n      }\n      return [CloudStreamLocalProvider(backend)];\n    }\n\n    if (kDebugMode) {\n      debugPrint(\n        'CloudStream local load failed for ${plugin.name}: '\n        '${result['status']} ${result['message']}',\n      );\n    }\n    return const [];\n  }\n\n  /// Registers shell providers for a plugin. JS is NOT evaluated here — it is\n  /// loaded lazily on the first search/getHome/getDetails/loadStreams call.''',
)
replace_once(
    manager,
    '''  Future<List<SkyStreamProvider>> _loadPlugin(ExtensionPlugin plugin) async {\n    if (_engine == null || _storageService == null) return [];\n    try {''',
    '''  Future<List<SkyStreamProvider>> _loadPlugin(ExtensionPlugin plugin) async {\n    if (_engine == null || _storageService == null) return [];\n    if (_isCloudStreamPlugin(plugin)) {\n      return _loadCloudStreamPlugin(plugin);\n    }\n    try {''',
)


# ---------------------------------------------------------------------------
# 4) Allow safe runtime restart after CloudStream uninstall/update lifecycle.
# ---------------------------------------------------------------------------
backend = 'lib/core/extensions/services/cloudstream_backend_service.dart'
replace_once(
    backend,
    '''  Future<bool> ensureStarted() {\n    if (!isSupported) return Future.value(false);\n    return _startFuture ??= _start();\n  }\n''',
    '''  Future<bool> ensureStarted() {\n    if (!isSupported) return Future.value(false);\n    return _startFuture ??= _start();\n  }\n\n  Future<bool> restart() async {\n    await dispose();\n    return ensureStarted();\n  }\n''',
)

print('CloudStream PC integration patch applied successfully.')
