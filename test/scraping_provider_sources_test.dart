import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/scraping_provider.dart';

/// The per-source tally a bulk scrape reports while it runs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.'
          'WakelockPlusApi.toggle',
          (_) async =>
              const StandardMessageCodec().encodeMessage(<Object?>[null]),
        );
  });

  test('a new provider shows no sources', () {
    final provider = ScrapingProvider();
    expect(provider.rommInPlay, isFalse);
    expect(provider.rommGames, 0);
    expect(provider.screenscraperGames, 0);
    expect(provider.rommUnavailableGames, 0);
  });

  test('updateSources records the tally and tells listeners', () {
    final provider = ScrapingProvider()..startScraping(maxThreads: 4);
    var notified = 0;
    provider.addListener(() => notified++);

    provider.updateSources(
      rommInPlay: true,
      rommGames: 5,
      screenscraperGames: 7,
      rommUnavailableGames: 2,
    );

    expect(provider.rommInPlay, isTrue);
    expect(provider.rommGames, 5);
    expect(provider.screenscraperGames, 7);
    expect(provider.rommUnavailableGames, 2);
    expect(notified, 1);
  });

  test('a new run starts from zero and hides the sources again', () {
    final provider = ScrapingProvider()..startScraping(maxThreads: 4);
    provider.updateSources(
      rommInPlay: true,
      rommGames: 5,
      screenscraperGames: 7,
      rommUnavailableGames: 2,
    );
    provider.stopScraping();

    provider.startScraping(maxThreads: 4);

    expect(provider.rommInPlay, isFalse);
    expect(provider.rommGames, 0);
    expect(provider.screenscraperGames, 0);
    expect(provider.rommUnavailableGames, 0);
  });

  test('the tally survives the run ending, for the final panel', () {
    final provider = ScrapingProvider()..startScraping(maxThreads: 4);
    provider.updateSources(
      rommInPlay: true,
      rommGames: 5,
      screenscraperGames: 7,
      rommUnavailableGames: 0,
    );

    provider.stopScraping();

    expect(provider.rommGames, 5);
    expect(provider.screenscraperGames, 7);
  });
}
