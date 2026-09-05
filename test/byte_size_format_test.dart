import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/byte_size_format.dart';

void main() {
  group('formatByteSize', () {
    test('bytes stay whole', () {
      expect(formatByteSize(0), '0 B');
      expect(formatByteSize(1), '1 B');
      expect(formatByteSize(1023), '1023 B');
    });

    test('scales by 1024 with one decimal', () {
      expect(formatByteSize(1024), '1 KB');
      expect(formatByteSize(1536), '1.5 KB');
      expect(formatByteSize(1234567), '1.2 MB');
      expect(formatByteSize(5 * 1024 * 1024 * 1024), '5 GB');
    });

    test('drops a trailing .0', () {
      expect(formatByteSize(2 * 1024 * 1024), '2 MB');
    });

    test('caps at TB', () {
      expect(formatByteSize(1 << 40), '1 TB');
      expect(formatByteSize(1 << 42), '4 TB');
      expect(formatByteSize(1 << 52), '4096 TB');
    });

    test('a negative count reads as zero', () {
      expect(formatByteSize(-5), '0 B');
    });
  });
}
