import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/services/external_player_service.dart';

void main() {
  group('Energy Media Player integration', () {
    final player = ExternalPlayerService.allPlayers.singleWhere(
      (candidate) => candidate.id == 'energy_media_player',
    );

    test('is available on Windows with both Store execution aliases', () {
      expect(player.displayName, 'Energy Media Player');
      expect(player.supportedPlatforms, contains(TargetPlatform.windows));
      expect(player.supportedPlatforms, hasLength(1));
      expect(player.desktopCommand, 'EnergyPlayerForWindows.exe');
      expect(player.desktopCommandAliases, contains('EnergyPlayer.exe'));
    });

    test('passes network URLs using the EMP --path argument', () {
      const url = 'https://example.com/video.m3u8?token=a&quality=4k';

      expect(
        ExternalPlayerService.instance.buildDesktopLaunchArguments(
          player,
          url,
        ),
        ['--path=$url'],
      );
    });
  });
}
