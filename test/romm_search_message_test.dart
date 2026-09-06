import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/romm_search_message.dart';

/// The line under the RomM in-platform search field, as a pure function:
/// nothing while the field is empty or the first page is loading, the loaded
/// count (marked as a lower bound while the server has more), or that
/// nothing matched — and every key it can pick resolves, placeholders
/// intact, in all twelve languages.
///
/// Governing: ADR-0008 (faster RomM browsing), SPEC-0008 REQ "In-Platform
/// Search Field", REQ "Localized User-Facing Text"

const _allLanguages = {
  'en': AppLocale.en,
  'es': AppLocale.es,
  'ru': AppLocale.ru,
  'zh': AppLocale.zh,
  'zh_Hant': AppLocale.zhHant,
  'pt': AppLocale.pt,
  'fr': AppLocale.fr,
  'de': AppLocale.de,
  'it': AppLocale.it,
  'id': AppLocale.id,
  'ja': AppLocale.ja,
  'ko': AppLocale.ko,
};

/// Every key the search row can draw, with the placeholders each carries.
const _keys = {
  AppLocale.rommSearchHint: <String>[],
  AppLocale.rommSearchCollectionHint: <String>[],
  AppLocale.rommSearchResultCount: ['{count}'],
  AppLocale.rommSearchResultCountOne: <String>[],
  AppLocale.rommSearchResultCountMore: ['{count}'],
  AppLocale.rommSearchNoResults: ['{term}'],
};

RommSearchMessage? _message({
  String term = 'chrono',
  int count = 0,
  bool hasMore = false,
  bool loading = false,
}) => rommSearchMessageFor(
  term: term,
  count: count,
  hasMore: hasMore,
  loading: loading,
);

void main() {
  group('rommSearchMessageFor', () {
    test('says nothing while the field is empty', () {
      expect(_message(term: '', count: 50, hasMore: true), isNull);
      expect(_message(term: '   ', count: 12), isNull);
    });

    test('says nothing while the first page of a search is loading', () {
      expect(_message(loading: true), isNull);
    });

    test('reports the loaded count', () {
      final message = _message(count: 12)!;
      expect(message.key, AppLocale.rommSearchResultCount);
      expect(message.placeholders, {'count': '12'});
    });

    test('uses the singular for one result', () {
      final message = _message(count: 1)!;
      expect(message.key, AppLocale.rommSearchResultCountOne);
      expect(message.placeholders, isEmpty);
    });

    test('marks the count as a lower bound while more pages remain', () {
      final message = _message(count: 50, hasMore: true)!;
      expect(message.key, AppLocale.rommSearchResultCountMore);
      expect(message.placeholders, {'count': '50'});
    });

    test('a loaded page is reported even while the next one loads', () {
      final message = _message(count: 50, hasMore: true, loading: true)!;
      expect(message.key, AppLocale.rommSearchResultCountMore);
    });

    test('names the term when nothing matched', () {
      final message = _message(term: ' chrono ')!;
      expect(message.key, AppLocale.rommSearchNoResults);
      expect(message.placeholders, {'term': 'chrono'});
    });

    test('format resolves the key and substitutes placeholders', () {
      String en(String key) => AppLocale.en[key] as String;
      expect(_message(count: 12)!.format(en), '12 results');
      expect(_message(count: 1)!.format(en), '1 result');
      expect(_message(count: 50, hasMore: true)!.format(en), '50+ results');
      expect(_message(term: 'chrono')!.format(en), 'No results for chrono');
    });
  });

  group('localization', () {
    test('every search-row key has a value in every language', () {
      for (final entry in _allLanguages.entries) {
        for (final key in _keys.keys) {
          final value = entry.value[key];
          expect(
            value,
            isA<String>().having((s) => s.trim(), 'text', isNotEmpty),
            reason: '$key in ${entry.key}',
          );
        }
      }
    });

    test('placeholders survive translation', () {
      for (final entry in _allLanguages.entries) {
        for (final key in _keys.entries) {
          final value = entry.value[key.key] as String;
          for (final placeholder in key.value) {
            expect(
              value,
              contains(placeholder),
              reason: '${key.key} in ${entry.key} lost $placeholder',
            );
          }
        }
      }
    });

    test('the messages format without a leftover placeholder anywhere', () {
      for (final entry in _allLanguages.entries) {
        String t(String key) => entry.value[key] as String;
        for (final message in [
          _message(count: 12)!,
          _message(count: 1)!,
          _message(count: 50, hasMore: true)!,
          _message(term: 'chrono')!,
        ]) {
          final text = message.format(t);
          expect(text, isNot(contains('{')), reason: '${entry.key}: $text');
          for (final value in message.placeholders.values) {
            expect(text, contains(value), reason: '${entry.key}: $text');
          }
        }
      }
    });
  });
}
