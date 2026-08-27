import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/services/repository_service.dart';

/// Adding an extension repository by URL or by shortcode.
///
/// The old resolver understood exactly two things: a full `https://…` URL, or
/// a bare code looked up at `cutt.ly/sky-CODE` that answered with a redirect
/// header. Everything else — a host without a scheme, a code that lives at
/// `cutt.ly/CODE`, a shortener that answers 200 with a meta refresh — failed
/// with "Invalid URL format" or silently resolved to nothing.
void main() {
  late HttpServer server;
  late String base;
  late RepositoryService service;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    service = RepositoryService(Dio());
    server.listen((request) async {
      switch (request.uri.path) {
        case '/redirect':
          request.response
            ..statusCode = 302
            ..headers.set('location', 'https://example.com/repo.json');
        case '/meta':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
              '<html><head><meta http-equiv="refresh" '
              'content="0;url=https://example.com/meta.json"></head></html>',
            );
        case '/js':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
              "<html><script>window.location = "
              "'https://example.com/js.json';</script></html>",
            );
        case '/dead':
          request.response
            ..statusCode = 302
            ..headers.set('location', 'https://cutt.ly/404');
        case '/missing':
          request.response.statusCode = 404;
        case '/phisher-repo':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'name': 'Phisher Repo',
                'description': 'Phisher Repository',
                'manifestVersion': 1,
                'pluginLists': ['$base/phisher-plugins'],
              }),
            );
        case '/cnc-repo':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'name': 'CNC Repo(All Language)',
                'description': 'All Language Contents',
                'manifestVersion': 1,
                'pluginLists': ['$base/cnc-plugins'],
              }),
            );
        case '/phisher-plugins':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode([
                {
                  'url': 'https://example.com/AllWish.cs3',
                  'jarUrl': 'https://example.com/AllWish.jar',
                  'status': 1,
                  'version': 15,
                  'name': 'AllWish',
                  'internalName': 'AllWish',
                  'authors': ['Phisher98'],
                  'description': 'Anime provider',
                  'language': 'en',
                  'tvTypes': ['Anime'],
                },
              ]),
            );
        case '/cnc-plugins':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode([
                {
                  'url': 'https://example.com/CNCProvider.cs3',
                  'jarUrl': 'https://example.com/CNCProvider.jar',
                  'status': 1,
                  'version': 7,
                  'name': 'CNC Provider',
                  'internalName': 'CNCProvider',
                  'authors': ['CNCVerse'],
                  'description': 'Multi-language provider',
                  'language': 'hi',
                  'tvTypes': ['Movie', 'TvSeries'],
                },
              ]),
            );
        default:
          request.response.statusCode = 404;
      }
      await request.response.close();
    });
  });

  tearDown(() async => server.close(force: true));

  group('repository url parsing', () {
    test('keeps a full url as-is', () async {
      expect(
        await service.parseRepoUrl(' https://example.com/repo.json '),
        'https://example.com/repo.json',
      );
    });

    test('adds the scheme to a bare host or path', () async {
      expect(
        await service.parseRepoUrl('raw.githubusercontent.com/u/r/main/x.json'),
        'https://raw.githubusercontent.com/u/r/main/x.json',
      );
      expect(
        await service.parseRepoUrl('example.com'),
        'https://example.com',
      );
    });

    test('accepts a custom scheme share link', () async {
      expect(
        await service.parseRepoUrl('skystream://example.com/repo.json'),
        'https://example.com/repo.json',
      );
    });

    test('an empty value asks for input instead of crashing', () {
      expect(() => service.parseRepoUrl('   '), throwsA(isA<Exception>()));
    });
  });

  group('shortcode resolution', () {
    test('follows a redirect header', () async {
      expect(
        await service.resolveShortLink('$base/redirect'),
        'https://example.com/repo.json',
      );
    });

    test('follows a meta refresh page', () async {
      expect(
        await service.resolveShortLink('$base/meta'),
        'https://example.com/meta.json',
      );
    });

    test('follows a javascript redirect page', () async {
      expect(
        await service.resolveShortLink('$base/js'),
        'https://example.com/js.json',
      );
    });

    test('treats the shortener 404 page as "no such code"', () async {
      expect(await service.resolveShortLink('$base/dead'), isNull);
      expect(await service.resolveShortLink('$base/missing'), isNull);
    });

    test('recognises the shortener dead ends', () {
      expect(service.isDeadEnd('https://cutt.ly/404'), isTrue);
      expect(service.isDeadEnd('https://cutt.ly/'), isTrue);
      expect(service.isDeadEnd(''), isTrue);
      expect(service.isDeadEnd('https://example.com/x.json'), isFalse);
    });

    test('unescapes html entities in a redirect target', () {
      expect(
        service.unescapeHtml('https://e.com/a.json?x=1&amp;y=2'),
        'https://e.com/a.json?x=1&y=2',
      );
    });
  });

  group('CloudStream repository compatibility', () {
    test('accepts Phisher standard repo without id/packageName', () async {
      final repo = await service.fetchRepository('$base/phisher-repo');
      expect(repo, isNotNull);
      expect(repo!.name, 'Phisher Repo');
      expect(repo.packageName, isNotEmpty);
      expect(repo.pluginLists, ['$base/phisher-plugins']);

      final plugins = await service.getRepoPlugins(repo);
      expect(plugins, hasLength(1));
      expect(plugins.single.name, 'AllWish');
      expect(plugins.single.packageName, startsWith('cloudstream.'));
      expect(plugins.single.sourceUrl, endsWith('.cs3'));
      expect(plugins.single.languages, ['en']);
      expect(plugins.single.categories, ['Anime']);
      expect(plugins.single.manifest['cloudstream'], isTrue);
      expect(plugins.single.manifest['sourceFormat'], 'cloudstream-cs3');
      expect(plugins.single.manifest['jarUrl'], endsWith('.jar'));
    });

    test('accepts CNCVerse standard repo and normalizes plugin metadata', () async {
      final repo = await service.fetchRepository('$base/cnc-repo');
      expect(repo, isNotNull);
      expect(repo!.name, 'CNC Repo(All Language)');
      expect(repo.packageName, isNotEmpty);

      final plugins = await service.getRepoPlugins(repo);
      expect(plugins, hasLength(1));
      expect(plugins.single.name, 'CNC Provider');
      expect(plugins.single.packageName, contains('CNCProvider'));
      expect(plugins.single.sourceUrl, endsWith('.cs3'));
      expect(plugins.single.languages, ['hi']);
      expect(plugins.single.categories, ['Movie', 'TvSeries']);
      expect(plugins.single.manifest['cloudstream'], isTrue);
      expect(plugins.single.manifest['repositoryUrl'], '$base/cnc-repo');
    });
  });
}
