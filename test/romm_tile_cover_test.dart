// Governing: ADR-0008 (faster RomM browsing), SPEC-0008 REQ "Tile Cover Source
// Order", REQ "Decode At Tile Size", REQ "Fixed Tile Ratio"
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/screens/romm_screen/romm_rom_grid.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/utils/cover_decode.dart';

RommService _service({String serverUrl = 'https://romm.local'}) {
  final s = RommService();
  s.configure(serverUrl: serverUrl, username: 'testuser', password: 's3cret');
  return s;
}

RommRom _rom({
  String? urlCover,
  String? pathCoverLarge,
  String? pathCoverSmall,
}) => RommRom(
  id: 1,
  name: 'Game',
  platformId: 1,
  platformSlug: 'snes',
  fsName: 'game.sfc',
  fsNameNoExt: 'game',
  fsExtension: 'sfc',
  urlCover: urlCover,
  pathCoverLarge: pathCoverLarge,
  pathCoverSmall: pathCoverSmall,
);

void main() {
  group('RommService.tileCoverUrlCandidates', () {
    test('orders cached small, then cached large, then the provider URL', () {
      final urls = _service().tileCoverUrlCandidates(
        _rom(
          urlCover: 'https://cdn.igdb/cover.png',
          pathCoverLarge: '/assets/big.png',
          pathCoverSmall: '/assets/small.png',
        ),
      );
      expect(urls, [
        'https://romm.local/assets/small.png',
        'https://romm.local/assets/big.png',
        'https://cdn.igdb/cover.png',
      ]);
    });

    test('is the reverse of the large-cover order', () {
      final rom = _rom(
        urlCover: 'https://cdn.igdb/cover.png',
        pathCoverLarge: '/assets/big.png',
        pathCoverSmall: '/assets/small.png',
      );
      final s = _service();
      expect(
        s.tileCoverUrlCandidates(rom),
        s.coverUrlCandidates(rom).reversed.toList(),
      );
    });

    test('requests only the provider URL when that is all the ROM has', () {
      final urls = _service().tileCoverUrlCandidates(
        _rom(urlCover: 'https://cdn.igdb/cover.png'),
      );
      expect(urls, ['https://cdn.igdb/cover.png']);
    });

    test('requests only the small file when that is all the ROM has', () {
      final urls = _service().tileCoverUrlCandidates(
        _rom(pathCoverSmall: '/assets/small.png'),
      );
      expect(urls, ['https://romm.local/assets/small.png']);
    });

    test('skips sources the server left empty', () {
      final urls = _service().tileCoverUrlCandidates(
        _rom(
          urlCover: '',
          pathCoverLarge: '/assets/big.png',
          pathCoverSmall: '',
        ),
      );
      expect(urls, ['https://romm.local/assets/big.png']);
    });

    test('is empty when the ROM has no cover at all', () {
      expect(_service().tileCoverUrlCandidates(_rom()), isEmpty);
    });

    test('joins server-relative paths with and without a leading slash', () {
      final s = _service(serverUrl: 'http://10.0.0.5:8080');
      expect(
        s.tileCoverUrlCandidates(_rom(pathCoverSmall: '/assets/small.png')),
        ['http://10.0.0.5:8080/assets/small.png'],
      );
      expect(
        s.tileCoverUrlCandidates(_rom(pathCoverSmall: 'assets/small.png')),
        ['http://10.0.0.5:8080/assets/small.png'],
      );
    });

    test('passes absolute http(s) URLs through untouched', () {
      final urls = _service().tileCoverUrlCandidates(
        _rom(
          pathCoverSmall: 'http://other.host/small.png',
          urlCover: 'https://cdn.igdb/cover.png',
        ),
      );
      expect(urls, [
        'http://other.host/small.png',
        'https://cdn.igdb/cover.png',
      ]);
    });

    test('keeps auth headers for server files and withholds them for CDNs', () {
      final s = RommService();
      s.configure(
        serverUrl: 'https://romm.local',
        username: 'u',
        password: 'p',
        accessToken: 'tok',
      );
      final urls = s.tileCoverUrlCandidates(
        _rom(
          pathCoverSmall: '/assets/small.png',
          urlCover: 'https://cdn.igdb/cover.png',
        ),
      );
      expect(s.imageHeadersFor(urls[0]), isNotEmpty);
      expect(s.imageHeadersFor(urls[1]), isEmpty);
    });
  });

  group('coverDecodeWidth', () {
    test('120 logical px at 2.0 decodes at 240', () {
      expect(coverDecodeWidth(logicalWidth: 120, devicePixelRatio: 2.0), 240);
    });

    test('the 72 px list thumbnail at 2.625 decodes at 189', () {
      expect(coverDecodeWidth(logicalWidth: 72, devicePixelRatio: 2.625), 189);
    });

    test('rounds a fractional result up, never down', () {
      expect(coverDecodeWidth(logicalWidth: 100.4, devicePixelRatio: 1.0), 101);
      expect(coverDecodeWidth(logicalWidth: 100.01, devicePixelRatio: 1), 101);
    });

    test('never returns less than 1', () {
      expect(coverDecodeWidth(logicalWidth: 0, devicePixelRatio: 2), 1);
      expect(coverDecodeWidth(logicalWidth: -50, devicePixelRatio: 2), 1);
    });

    test('guards NaN and infinity', () {
      expect(
        coverDecodeWidth(logicalWidth: double.nan, devicePixelRatio: 2),
        1,
      );
      expect(
        coverDecodeWidth(logicalWidth: double.infinity, devicePixelRatio: 2),
        1,
      );
    });
  });

  group('RommRomGrid fixed tile ratio', () {
    test('tileRatio is the IGDB cover ratio the grid used to fall back to', () {
      expect(RommRomGrid.tileRatio, 1.417);
    });

    test('row height is the cell width times the ratio, for any width', () {
      for (final w in [50.0, 120.0, 133.7, 240.0]) {
        expect(RommRomGrid.rowHeightFor(w), closeTo(w * 1.417, 1e-9));
      }
    });

    test('row height depends on width only, so rebuilding is a no-op', () {
      final first = RommRomGrid.rowHeightFor(120);
      final again = RommRomGrid.rowHeightFor(120);
      expect(again, first);
    });
  });
}
