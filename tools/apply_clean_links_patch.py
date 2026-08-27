from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected exactly one match, found {count}")
    file.write_text(text.replace(old, new, 1), encoding="utf-8")


# Remove Energy Media Player from the external-player registry.
replace_once(
    "lib/core/services/external_player_service.dart",
    """    // Both Microsoft Store variants expose an execution alias. The Windows
    // edition is preferred, while the Xbox-compatible edition remains a
    // transparent fallback. EMP requires the stream URL as --path=<url>.
    ExternalPlayer(
      id: 'energy_media_player',
      displayName: 'Energy Media Player',
      icon: Icons.bolt_rounded,
      supportedPlatforms: {TargetPlatform.windows},
      desktopCommand: 'EnergyPlayerForWindows.exe',
      desktopCommandAliases: ['EnergyPlayer.exe'],
      desktopUrlArgumentPrefix: '--path=',
    ),
""",
    "",
)

sheet = "lib/features/sources/presentation/plugin_sources_sheet.dart"
replace_once(
    sheet,
    """import 'dart:async';

import 'package:flutter/material.dart';
""",
    """import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
""",
)
replace_once(
    sheet,
    """import '../../../core/network/link_probe_service.dart';
import '../../../core/utils/source_text.dart';
""",
    """import '../../../core/network/link_probe_service.dart';
import '../../../core/utils/m3u_export.dart';
import '../../../core/utils/source_text.dart';
""",
)
replace_once(
    sheet,
    """  List<_Row> get _visible => _allRows.where((row) {
    if (_providerFilter.isNotEmpty &&
""",
    """  bool _isDefinitelyDead(_Row row) {
    final status = _probes[row.url]?.statusCode;
    return status == 404 || status == 410;
  }

  int get _hiddenDeadCount => _allRows.where(_isDefinitelyDead).length;

  List<_Row> get _visible => _allRows.where((row) {
    // Only suppress links that are conclusively gone. Auth-protected links
    // (401/403), timeouts and transient server failures stay visible so a
    // provider that needs headers is not falsely removed.
    if (_isDefinitelyDead(row)) return false;
    if (_providerFilter.isNotEmpty &&
""",
)

export_method = r'''  Future<void> _exportWorkingM3u() async {
    final messenger = ScaffoldMessenger.of(context);
    final candidates = _allRows
        .where((row) => row.url.startsWith('http') && !row.isTorrent)
        .toList();
    if (candidates.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No direct stream links to export.')),
      );
      return;
    }

    final service = ref.read(linkProbeServiceProvider);
    for (var offset = 0;
        offset < candidates.length;
        offset += _maxParallelProbes) {
      final batch = candidates
          .skip(offset)
          .take(_maxParallelProbes)
          .toList(growable: false);
      final results = await Future.wait([
        for (final row in batch) service.probe(row.url, headers: row.headers),
      ]);
      if (_disposed) return;
      setState(() {
        for (var i = 0; i < batch.length; i++) {
          _probes[batch[i].url] = results[i];
          _probing.remove(batch[i].url);
        }
      });
    }

    final working = candidates
        .where((row) => _probes[row.url]?.reachable ?? false)
        .toList(growable: false);
    if (working.isEmpty) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('No verified working links found.')),
      );
      return;
    }

    final playlist = buildM3uPlaylist([
      for (final row in working)
        M3uEntry(
          title:
              '${row.providerName} · ${_probes[row.url]?.resolutionLabel ?? row.qualityLabel}',
          url: row.url,
          headers: row.headers,
        ),
    ]);
    final safeTitle = widget.target.title
        .replaceAll(RegExp(r'[<>:"/\\|?*\r\n]+'), '')
        .trim();
    final episode = widget.episode;
    final suffix = episode == null
        ? ''
        : '-S${episode.season.toString().padLeft(2, '0')}'
            'E${episode.episode.toString().padLeft(2, '0')}';
    final fileName =
        '${safeTitle.isEmpty ? 'SkyStream' : safeTitle}$suffix-working.m3u';

    final saved = await FilePicker.saveFile(
      dialogTitle: 'Save verified working links as M3U',
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(playlist)),
    );
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved == null
              ? 'M3U export cancelled.'
              : 'Saved ${working.length} verified working links.',
        ),
      ),
    );
  }

'''
replace_once(sheet, "  void _play(_Row row) {\n", export_method + "  void _play(_Row row) {\n")
replace_once(
    sheet,
    """                            : '${_allRows.length} links · '
                                  '${_pluginResult.streams.length} SkyStream · '
                                  '$nuvioCount Nuvio',
""",
    """                            : '${visible.length} links · '
                                  '${_hiddenDeadCount > 0 ? '$_hiddenDeadCount dead hidden · ' : ''}'
                                  '${_pluginResult.streams.length} SkyStream · '
                                  '$nuvioCount Nuvio',
""",
)
replace_once(
    sheet,
    """                    if (_isLoading)
                      SizedBox(
""",
    """                    if (!_isLoading && _allRows.isNotEmpty)
                      IconButton(
                        tooltip: 'Download verified working links as M3U',
                        onPressed: () => unawaited(_exportWorkingM3u()),
                        icon: const Icon(Icons.playlist_add_check_rounded),
                      ),
                    if (_isLoading)
                      SizedBox(
""",
)

# Update the true-local Windows build so it no longer expects Energy-specific
# tests or advertises an Energy handoff in release notes.
workflow = ".github/workflows/cloudstream-local-windows.yml"
replace_once(
    workflow,
    "      - name: Test CloudStream extensions and Energy Media Player handoff\n",
    "      - name: Test CloudStream extensions and smart link export\n",
)
replace_once(
    workflow,
    "run: flutter test test/core/extensions test/features/extensions test/core/services/external_player_service_test.dart test/compile_smoke_test.dart",
    "run: flutter test test/core/extensions test/features/extensions test/core/utils/m3u_export_test.dart test/compile_smoke_test.dart",
)
replace_once(
    workflow,
    "Phisher local provider validation, Energy Media Player handoff, and Stream X fallback",
    "Phisher local provider validation, dead-link suppression, working-link M3U export, and Stream X fallback",
)

# Pure playlist builder keeps file-format logic unit-testable without network or
# platform channels.
Path("lib/core/utils/m3u_export.dart").write_text(r'''class M3uEntry {
  final String title;
  final String url;
  final Map<String, String>? headers;

  const M3uEntry({required this.title, required this.url, this.headers});
}

String buildM3uPlaylist(Iterable<M3uEntry> entries) {
  final buffer = StringBuffer('#EXTM3U\n');
  for (final entry in entries) {
    final title = _singleLine(entry.title).trim();
    final userAgent = _header(entry.headers, 'user-agent');
    final referer = _header(entry.headers, 'referer') ??
        _header(entry.headers, 'referrer');

    buffer.writeln('#EXTINF:-1,${title.isEmpty ? 'Stream' : title}');
    if (userAgent != null && userAgent.isNotEmpty) {
      buffer.writeln('#EXTVLCOPT:http-user-agent=${_singleLine(userAgent)}');
    }
    if (referer != null && referer.isNotEmpty) {
      buffer.writeln('#EXTVLCOPT:http-referrer=${_singleLine(referer)}');
    }
    buffer.writeln(entry.url.trim());
  }
  return buffer.toString();
}

String _singleLine(String value) =>
    value.replaceAll(RegExp(r'[\r\n]+'), ' ');

String? _header(Map<String, String>? headers, String name) {
  if (headers == null) return null;
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}
''', encoding="utf-8")

Path("test/core/utils").mkdir(parents=True, exist_ok=True)
Path("test/core/utils/m3u_export_test.dart").write_text(r'''import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/utils/m3u_export.dart';

void main() {
  test('builds an M3U with stream metadata and common HTTP headers', () {
    final playlist = buildM3uPlaylist(const [
      M3uEntry(
        title: 'Provider\n1080p',
        url: 'https://example.com/video.m3u8?token=abc',
        headers: {
          'User-Agent': 'SkyStream Test',
          'Referer': 'https://example.com/',
        },
      ),
    ]);

    expect(playlist, startsWith('#EXTM3U\n'));
    expect(playlist, contains('#EXTINF:-1,Provider 1080p'));
    expect(playlist, contains('#EXTVLCOPT:http-user-agent=SkyStream Test'));
    expect(
      playlist,
      contains('#EXTVLCOPT:http-referrer=https://example.com/'),
    );
    expect(playlist, contains('https://example.com/video.m3u8?token=abc'));
  });

  test('uses a safe fallback title', () {
    final playlist = buildM3uPlaylist(const [
      M3uEntry(title: '', url: 'https://example.com/video.mp4'),
    ]);
    expect(playlist, contains('#EXTINF:-1,Stream'));
  });
}
''', encoding="utf-8")

print("clean-links patch applied")
