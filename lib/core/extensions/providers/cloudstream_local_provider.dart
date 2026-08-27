import 'dart:convert';

import 'package:dio/dio.dart';

import '../../domain/entity/multimedia_item.dart';
import '../base_provider.dart';
import '../services/cloudstream_backend_service.dart';

/// SkyStream adapter for the bundled, localhost-only CloudStream JVM runtime.
///
/// Search/detail/stream URLs are opaque local tokens. They never leave the
/// machine and preserve the CloudStream provider name plus the provider's own
/// URL/data payload between normal SkyStream navigation calls.
class CloudStreamLocalProvider extends SkyStreamProvider {
  static const String runtimePackageName = 'cloudstream.local.runtime';

  final CloudStreamBackendService backend;

  CloudStreamLocalProvider(this.backend);

  @override
  String get packageName => runtimePackageName;

  @override
  String get name => 'CloudStream Local';

  @override
  String get mainUrl => 'cloudstream-local://runtime';

  @override
  String get version => '0.1.0';

  @override
  List<String> get languages => const ['all'];

  @override
  Set<ProviderType> get supportedTypes => const {
    ProviderType.movie,
    ProviderType.series,
    ProviderType.anime,
    ProviderType.livestream,
    ProviderType.other,
  };

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) return const [];
    final results = await backend.search(query);
    if (cancelToken?.isCancelled ?? false) return const [];

    return results
        .map(_searchItem)
        .where((item) => item.title.isNotEmpty && item.url.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    // CloudStream home-page pagination is wired in the backend separately from
    // search. Returning an empty map keeps the provider lightweight until at
    // least one repo plugin is installed, while Explore/search works fully.
    return const {};
  }

  @override
  Future<MultimediaItem> getDetails(String url) async {
    final token = _decode(url, expectedKind: 'details');
    if (token == null) {
      throw StateError('Invalid CloudStream detail token');
    }

    final result = await backend.details(
      provider: token.provider,
      url: token.value,
    );
    if (result == null) {
      throw StateError('CloudStream provider failed to load details');
    }

    final provider = (result['provider'] as String?) ?? token.provider;
    final streamData = result['streamData']?.toString();
    final episodes = <Episode>[];
    final rawEpisodes = result['episodes'];
    if (rawEpisodes is List) {
      for (final raw in rawEpisodes.whereType<Map<dynamic, dynamic>>()) {
        final episode = Map<String, dynamic>.from(raw);
        final data = episode['data']?.toString() ?? '';
        if (data.isEmpty) continue;
        episodes.add(
          Episode(
            name: episode['name']?.toString() ?? 'Episode',
            url: _encode('stream', provider, data),
            season: _asInt(episode['season']) ?? 0,
            episode: _asInt(episode['episode']) ?? 0,
            description: episode['description']?.toString(),
            posterUrl: episode['posterUrl']?.toString(),
            rating: _asDouble(episode['rating']),
            runtime: _asInt(episode['runtime']),
            airDate: episode['airDate']?.toString(),
            dubStatus: _dubStatus(episode['dubStatus']),
          ),
        );
      }
    }

    final originalPage = result['url']?.toString() ?? token.value;
    final playableUrl = streamData != null && streamData.isNotEmpty
        ? _encode('stream', provider, streamData)
        : _encode('details', provider, originalPage);

    return MultimediaItem(
      title: result['title']?.toString() ?? 'CloudStream',
      url: playableUrl,
      posterUrl: result['posterUrl']?.toString() ?? '',
      bannerUrl: result['bannerUrl']?.toString(),
      logoUrl: result['logoUrl']?.toString(),
      description: result['description']?.toString(),
      contentType: MultimediaItem.parseContentType(result['type']?.toString()),
      episodes: episodes.isEmpty ? null : episodes,
      provider: provider,
      headers: _stringMap(result['headers']),
      year: _asInt(result['year']),
      score: _asDouble(result['score']),
      duration: _asInt(result['duration']),
      tags: _stringList(result['tags']),
      contentRating: result['contentRating']?.toString(),
      syncData: _stringMap(result['syncData']),
      source: 'CloudStream Local',
    );
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    final token = _decode(url, expectedKind: 'stream');
    if (token == null) return const [];

    final response = await backend.streams(
      provider: token.provider,
      data: token.value,
    );
    final subtitles = _subtitleList(response['subtitles']);
    final rawStreams = response['streams'];
    if (rawStreams is! List) return const [];

    final streams = <StreamResult>[];
    for (final raw in rawStreams.whereType<Map<dynamic, dynamic>>()) {
      final item = Map<String, dynamic>.from(raw);
      final streamUrl = item['url']?.toString() ?? '';
      if (streamUrl.isEmpty) continue;
      final baseSource = item['source']?.toString() ?? 'CloudStream';
      final quality = _asInt(item['quality']);
      streams.add(
        StreamResult(
          url: streamUrl,
          source: quality != null && quality > 0
              ? '$baseSource · ${quality}p'
              : baseSource,
          providerName: item['providerName']?.toString() ?? token.provider,
          headers: _stringMap(item['headers']),
          subtitles: subtitles.isEmpty ? null : subtitles,
        ),
      );
    }
    return streams;
  }

  MultimediaItem _searchItem(Map<String, dynamic> result) {
    final provider = result['provider']?.toString() ?? '';
    final sourceUrl = result['url']?.toString() ?? '';
    return MultimediaItem(
      title: result['title']?.toString() ?? '',
      url: provider.isEmpty || sourceUrl.isEmpty
          ? ''
          : _encode('details', provider, sourceUrl),
      posterUrl: result['posterUrl']?.toString() ?? '',
      contentType: MultimediaItem.parseContentType(result['type']?.toString()),
      provider: provider,
      headers: _stringMap(result['headers']),
      year: _asInt(result['year']),
      score: _asDouble(result['score']),
      source: 'CloudStream Local',
    );
  }

  String _encode(String kind, String provider, String value) {
    final body = jsonEncode({'provider': provider, 'value': value});
    final encoded = base64Url.encode(utf8.encode(body)).replaceAll('=', '');
    return 'cloudstream-local://$kind/$encoded';
  }

  _LocalToken? _decode(String url, {required String expectedKind}) {
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != 'cloudstream-local' || uri.host != expectedKind) {
        return null;
      }
      final encoded = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
      if (encoded.isEmpty) return null;
      final normalized = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
      final decoded = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final provider = map['provider']?.toString() ?? '';
      final value = map['value']?.toString() ?? '';
      if (provider.isEmpty || value.isEmpty) return null;
      return _LocalToken(provider, value);
    } catch (_) {
      return null;
    }
  }

  List<SubtitleFile> _subtitleList(dynamic raw) {
    if (raw is! List) return const [];
    final out = <SubtitleFile>[];
    for (final value in raw.whereType<Map<dynamic, dynamic>>()) {
      final item = Map<String, dynamic>.from(value);
      final url = item['url']?.toString() ?? '';
      if (url.isEmpty) continue;
      out.add(
        SubtitleFile(
          url: url,
          label: item['label']?.toString() ?? item['lang']?.toString() ?? 'Subtitle',
          lang: item['lang']?.toString(),
        ),
      );
    }
    return out;
  }

  Map<String, String>? _stringMap(dynamic raw) {
    if (raw is! Map) return null;
    final out = <String, String>{};
    raw.forEach((key, value) {
      if (key != null && value != null) out[key.toString()] = value.toString();
    });
    return out.isEmpty ? null : out;
  }

  List<String>? _stringList(dynamic raw) {
    if (raw is! List) return null;
    final out = raw.map((value) => value.toString()).toList(growable: false);
    return out.isEmpty ? null : out;
  }

  int? _asInt(dynamic raw) => raw is num ? raw.toInt() : int.tryParse('$raw');

  double? _asDouble(dynamic raw) =>
      raw is num ? raw.toDouble() : double.tryParse('$raw');

  DubStatus _dubStatus(dynamic raw) {
    switch (raw?.toString().toLowerCase()) {
      case 'dubbed':
      case 'dub':
        return DubStatus.dubbed;
      case 'subbed':
      case 'sub':
        return DubStatus.subbed;
      default:
        return DubStatus.none;
    }
  }
}

class _LocalToken {
  final String provider;
  final String value;

  const _LocalToken(this.provider, this.value);
}
