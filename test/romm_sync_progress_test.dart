import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/romm_sync_progress.dart';

void main() {
  group('rommFileFraction', () {
    test('is null without a usable total', () {
      expect(rommFileFraction(received: 10, total: null), isNull);
      expect(rommFileFraction(received: 10, total: 0), isNull);
    });

    test('is the received share, clamped', () {
      expect(rommFileFraction(received: 0, total: 100), 0.0);
      expect(rommFileFraction(received: 25, total: 100), 0.25);
      expect(rommFileFraction(received: 100, total: 100), 1.0);
      expect(rommFileFraction(received: 150, total: 100), 1.0);
    });
  });
}
