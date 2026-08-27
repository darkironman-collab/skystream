import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'extension_plugin.dart';

class ExtensionRepository {
  final String name;
  final String url;
  final String? description;
  final String? iconUrl;
  final int manifestVersion;
  final List<String> pluginLists;
  final List<String> includedRepos;
  final List<ExtensionPlugin> plugins; // NEW: Direct plugin list
  final String? _explicitId;

  ExtensionRepository({
    required this.name,
    required this.url,
    required this.pluginLists,
    this.includedRepos = const [],
    this.plugins = const [],
    this.description,
    this.iconUrl,
    this.manifestVersion = 1,
    String? explicitId,
  }) : _explicitId = explicitId;

  /// The Package Namespace.
  /// Returns explicit package/id or falls back to Hash(Url).
  ///
  /// The hash fallback is important for the official CloudStream repository
  /// shape, which intentionally does not require an `id` or `packageName`.
  String get packageName =>
      _explicitId ??
      sha256.convert(utf8.encode(url)).toString().substring(0, 10);

  /// Factory constructor to parse from JSON
  factory ExtensionRepository.fromJson(Map<String, dynamic> json, String url) {
    final explicitId =
        json['packageName']?.toString().trim().isNotEmpty == true
        ? json['packageName'].toString().trim()
        : json['id']?.toString().trim().isNotEmpty == true
        ? json['id'].toString().trim()
        : null;
    final repoId = explicitId ??
        sha256.convert(utf8.encode(url)).toString().substring(0, 10);

    return ExtensionRepository(
      name: json['name'] as String? ?? 'Unknown Repository',
      url: url,
      pluginLists:
          (json['pluginLists'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      includedRepos:
          (json['repos'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      plugins:
          (json['plugins'] as List<dynamic>?)
              ?.whereType<Map<dynamic, dynamic>>()
              .map(
                (e) => ExtensionPlugin.fromJson(
                  Map<String, dynamic>.from(e),
                  repoId,
                ),
              )
              .toList() ??
          [],
      description: json['description'] as String?,
      iconUrl: json['iconUrl'] as String?,
      manifestVersion: json['manifestVersion'] as int? ?? 1,
      explicitId: explicitId,
    );
  }
}
