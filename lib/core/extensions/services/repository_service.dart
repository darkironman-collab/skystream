import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'; // kDebugMode, visibleForTesting
import 'dart:io';
import 'dart:convert';
import '../models/extension_repository.dart';
import '../models/extension_plugin.dart';

class RepositoryService {
  final Dio _dio;
  final bool enableGithubProxy;

  RepositoryService(this._dio, {this.enableGithubProxy = false});

  /// Resolves the actual URL from shortcodes, bare hosts or custom schemes.
  ///
  /// Previously this accepted exactly two shapes — a full `https://…` URL, or
  /// a bare alphanumeric code looked up as `cutt.ly/sky-CODE`. Anything else
  /// (`raw.githubusercontent.com/…`, `github.com/user/repo`, a `cutt.ly/xyz`
  /// link that already carries the prefix) was rejected as "Invalid URL
  /// format", and a shortener answering 200 with a meta-refresh instead of a
  /// 302 resolved to nothing.
  Future<String?> parseRepoUrl(String url) async {
    final fixedUrl = url.trim();
    if (fixedUrl.isEmpty) throw Exception('Enter a repository URL or code');

    // Standard HTTP/HTTPS.
    if (RegExp(r'^https?://').hasMatch(fixedUrl)) {
      return fixedUrl;
    }

    // Custom scheme used by share links: skystream://host/path.
    final scheme = RegExp(
      r'^[a-zA-Z][a-zA-Z0-9+.-]*://(.+)$',
    ).firstMatch(fixedUrl);
    if (scheme != null) {
      return 'https://${scheme.group(1)}';
    }

    // Anything that looks like a host or a path is a URL missing its scheme.
    if (fixedUrl.contains('/') ||
        RegExp(r'^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+').hasMatch(fixedUrl)) {
      return 'https://$fixedUrl';
    }

    // Shortcode: try the SkyStream namespace first, then the bare code.
    if (RegExp(r'^[a-zA-Z0-9!_-]+$').hasMatch(fixedUrl)) {
      Object? lastError;
      for (final candidate in [
        'https://cutt.ly/sky-$fixedUrl',
        'https://cutt.ly/$fixedUrl',
      ]) {
        try {
          final resolved = await resolveShortLink(candidate);
          if (resolved != null) return resolved;
        } catch (error) {
          lastError = error;
        }
      }
      if (lastError is DioException) {
        throw Exception(
          'Could not reach the shortcode service: ${lastError.message}',
        );
      }
      throw Exception("That shortcode doesn't exist");
    }

    throw Exception('Invalid URL format');
  }

  /// Follows one short link. Handles a redirect header, and the increasingly
  /// common "200 + meta refresh / window.location" pages.
  @visibleForTesting
  Future<String?> resolveShortLink(String shortUrl) async {
    final response = await _dio.get<dynamic>(
      shortUrl,
      options: Options(
        followRedirects: false,
        responseType: ResponseType.plain,
        validateStatus: (status) => status != null && status < 500,
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        },
      ),
    );

    final status = response.statusCode ?? 0;
    if (status >= 300 && status < 400) {
      final location = response.headers.value('location');
      if (location != null && !isDeadEnd(location)) return location;
      return null;
    }
    if (status == 404 || status == 410) return null;

    final body = response.data is String ? response.data as String : '';
    if (body.isEmpty) return null;

    final meta = RegExp(
      r'<meta[^>]+http-equiv=["]?refresh["]?[^>]+content=["][^"]*url=([^">\s]+)',
      caseSensitive: false,
    ).firstMatch(body);
    if (meta != null) {
      final target = unescapeHtml(meta.group(1)!);
      if (!isDeadEnd(target)) return target;
    }

    final js = RegExp(
      r'(?:window\.)?location(?:\.href)?\s*=\s*["]([^"]+)["]',
      caseSensitive: false,
    ).firstMatch(body);
    if (js != null) {
      final target = unescapeHtml(js.group(1)!);
      if (!isDeadEnd(target)) return target;
    }

    final jsSingle = RegExp(
      r"(?:window\.)?location(?:\.href)?\s*=\s*'([^']+)'",
      caseSensitive: false,
    ).firstMatch(body);
    if (jsSingle != null) {
      final target = unescapeHtml(jsSingle.group(1)!);
      if (!isDeadEnd(target)) return target;
    }
    return null;
  }

  @visibleForTesting
  bool isDeadEnd(String location) {
    final trimmed = location.replaceAll(RegExp(r'/$'), '').trim();
    return trimmed.startsWith('https://cutt.ly/404') ||
        trimmed == 'https://cutt.ly' ||
        trimmed.isEmpty;
  }

  @visibleForTesting
  String unescapeHtml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .trim();

  /// Fetch and parse a Repository from a URL.
  ///
  /// SkyStream-native repositories may provide `packageName`/`id`. Standard
  /// CloudStream repositories intentionally do not: the official format is
  /// simply name + manifestVersion + pluginLists. The repository URL itself is
  /// already used as a stable hashed namespace, so requiring an extra ID here
  /// rejected valid Phisher/CNCVerse-style repositories for no safety benefit.
  Future<ExtensionRepository?> fetchRepository(String url) async {
    try {
      final resolvedUrl = await parseRepoUrl(url);
      if (resolvedUrl == null) {
        throw Exception('Failed to resolve URL');
      }

      final normalizedUrl = _normalizeUrl(resolvedUrl);
      final response = await _dio.request<String>(normalizedUrl);
      if (response.statusCode == 200 && response.data != null) {
        final decoded = response.data is String
            ? _jsonDecodeSafe(response.data!)
            : response.data;
        final Map<String, dynamic>? data = decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : null;

        if (data != null) {
          final hasName = (data['name']?.toString().trim().isNotEmpty ?? false);
          final pluginLists = (data['pluginLists'] as List?) ?? <dynamic>[];
          final repos = (data['repos'] as List?) ?? <dynamic>[];
          final directPlugins = (data['plugins'] as List?) ?? <dynamic>[];
          final hasPluginLists = pluginLists.isNotEmpty;
          final hasRepos = repos.isNotEmpty;
          final hasDirectPlugins = directPlugins.isNotEmpty;

          if (!hasName ||
              (!hasPluginLists && !hasRepos && !hasDirectPlugins)) {
            throw Exception(
              'Invalid repository format: Missing name or pluginLists/repos/plugins',
            );
          }

          if (hasPluginLists && hasRepos) {
            throw Exception(
              "Repository cannot contain both 'pluginLists' and 'repos'. Please separate them.",
            );
          }

          return ExtensionRepository.fromJson(data, url);
        }
      }
    } on DioException catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to fetch repository $url: $e');
      }
    } catch (e) {
      rethrow;
    }
    return null;
  }

  /// Fetch all plugins listed in a repository.
  ///
  /// CloudStream's SitePlugin schema uses `internalName` rather than
  /// `packageName`, and points at a `.cs3` plus optional `jarUrl`. We retain
  /// that metadata and synthesize a safe SkyStream-side package id so the
  /// repository can be browsed without pretending the binary is a native
  /// `.sky` JavaScript plugin. Runtime execution is supplied by the configured
  /// CloudStream bridge add-on.
  Future<List<ExtensionPlugin>> getRepoPlugins(ExtensionRepository repo) async {
    final List<ExtensionPlugin> allPlugins = <ExtensionPlugin>[];

    allPlugins.addAll(repo.plugins);

    for (final pluginListUrl in repo.pluginLists) {
      try {
        final normalizedUrl = _normalizeUrl(pluginListUrl);
        final response = await _dio.get<dynamic>(normalizedUrl);

        if (response.statusCode == 200 && response.data != null) {
          final decoded = response.data is String
              ? _jsonDecodeSafe(response.data as String)
              : response.data;
          final List<dynamic>? list = decoded is List ? decoded : null;

          if (list != null) {
            for (final raw in list) {
              if (raw is! Map) continue;
              final source = Map<String, dynamic>.from(raw);
              final normalized = _normalizePluginEntry(source, repo);
              try {
                allPlugins.add(
                  ExtensionPlugin.fromJson(normalized, repo.packageName),
                );
              } catch (error) {
                if (kDebugMode) {
                  debugPrint(
                    'Skipping invalid plugin entry from $pluginListUrl: $error',
                  );
                }
              }
            }
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Failed to fetch plugin list $pluginListUrl: $e');
        }
      }
    }

    return allPlugins;
  }

  @visibleForTesting
  Map<String, dynamic> normalizePluginEntryForTesting(
    Map<String, dynamic> source,
    ExtensionRepository repo,
  ) => _normalizePluginEntry(source, repo);

  Map<String, dynamic> _normalizePluginEntry(
    Map<String, dynamic> source,
    ExtensionRepository repo,
  ) {
    final result = Map<String, dynamic>.from(source);
    final rawUrl = result['url']?.toString() ?? '';
    final internalName = result['internalName']?.toString().trim() ?? '';
    final hasJar = (result['jarUrl']?.toString().trim().isNotEmpty ?? false);
    final isCloudStream =
        internalName.isNotEmpty ||
        rawUrl.toLowerCase().endsWith('.cs3') ||
        hasJar;

    if (isCloudStream) {
      final seed = internalName.isNotEmpty
          ? internalName
          : (result['name']?.toString().trim().isNotEmpty ?? false)
          ? result['name'].toString().trim()
          : 'provider';
      result['packageName'] ??=
          'cloudstream.${repo.packageName}.${_safePackageSegment(seed)}';
      result['cloudstream'] = true;
      result['sourceFormat'] = 'cloudstream-cs3';
      result['repositoryUrl'] ??= repo.url;
    }

    return result;
  }

  String _safePackageSegment(String value) {
    var safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    safe = safe.replaceAll(RegExp(r'^[._-]+'), '');
    if (safe.isEmpty) safe = 'provider';
    return safe;
  }

  /// Download a plugin file to a temporary location.
  Future<File?> downloadPlugin(String url) async {
    try {
      final normalizedUrl = _normalizeUrl(url);
      final tempDir = Directory.systemTemp;
      final tempFile = File(
        '${tempDir.path}/temp_${DateTime.now().millisecondsSinceEpoch}.sky',
      );

      await _dio.download(normalizedUrl, tempFile.path);

      if (await tempFile.exists()) {
        return tempFile;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to download plugin $url: $e');
      }
    }
    return null;
  }

  String _normalizeUrl(String url) {
    if (!enableGithubProxy) return url;

    // Convert raw.githubusercontent.com to jsdelivr for caching/performance
    if (url.contains('raw.githubusercontent.com')) {
      final regex = RegExp(
        r'^https://raw\.githubusercontent\.com/([A-Za-z0-9-]+)/([A-Za-z0-9_.-]+)/(.*)$',
      );
      final match = regex.firstMatch(url);
      if (match != null) {
        final user = match.group(1);
        final repo = match.group(2);
        final path = match.group(3);
        return 'https://cdn.jsdelivr.net/gh/$user/$repo@$path';
      }
    }
    return url;
  }

  dynamic _jsonDecodeSafe(String source) {
    try {
      return jsonDecode(source);
    } catch (_) {
      return null;
    }
  }
}
