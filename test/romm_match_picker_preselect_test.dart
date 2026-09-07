import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/romm_rom.dart';
import 'package:neostation/models/romm_rom_filters.dart';
import 'package:neostation/models/romm_rom_page.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/providers/file_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/screens/game_screen/game_settings_dialog/romm_match_picker_dialog.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/services/sfx_service.dart';

import 'database_test_helper.dart';

/// Which row the link picker highlights when the caller pinned a RomM entry,
/// with the "Fix match on RomM" / "Change cover" rows present between the
/// search field and the results.
///
/// The preselect is an index into the *results*, and the fix-up actions sit
/// above them, so it has to be rebased onto the row layout
/// ([RommMatchPickerSlots]). It was not: the dialog highlighted `pinned + 1`,
/// which lands on an action row when the pinned entry is first and on the
/// wrong RomM entry once two rows precede it. `_confirm` has no confirmation
/// of its own, so A on that wrong row writes the manual link to an entry the
/// user never chose.
///
/// The existing picker tests cannot catch this: they drive the controller
/// directly, where the action rows do not exist. This one links the game (the
/// actions only appear for a linked ROM) so the layout under test is the one
/// the user meets.
///
/// Governing: ADR-0019 (expose RomM library filters, search and maintenance),
/// SPEC-0018 REQ "Fix Match In The Picker"
/// Governing: ADR-0004 (manual link provenance), SPEC-0004 REQ "Link Picker Dialog"

RommRom _rom(int id) => RommRom(
  id: id,
  name: 'Rom $id',
  platformId: 1,
  platformSlug: 'snes',
  fsName: 'rom$id.sfc',
  fsNameNoExt: 'rom$id',
  fsExtension: 'sfc',
);

/// A service that answers the picker's search without a server. Everything the
/// fix-up rows are gated on is left at its default: no heartbeat means no
/// `METADATA_SOURCES`, which reads as "a source may exist", and an unasked
/// scope reads as [RommScopeState.unknown] — the state every API-key
/// connection sits in (ADR-0013).
class _FakeRommService extends RommService {
  List<RommRom> page = const [];

  @override
  Future<RommRomPage> getRomsPage({
    List<int> platformIds = const [],
    int? collectionId,
    String? virtualCollectionId,
    String? search,
    List<String> genres = const [],
    List<String> companies = const [],
    RommRomFilters filters = RommRomFilters.none,
    int limit = 50,
    int offset = 0,
  }) async => RommRomPage(items: page, total: page.length);
}

class _FakeRommProvider extends RommProvider {
  _FakeRommProvider(this.fake);

  final _FakeRommService fake;

  @override
  bool get isConnected => true;

  @override
  RommService get service => fake;

  @override
  Future<List<int>> platformIdsForSystemName(String realName) async => const [
    1,
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  late _FakeRommService service;

  final game = GameModel(
    romname: 'Chrono Trigger.sfc',
    realname: 'Chrono Trigger',
    name: 'Chrono Trigger',
    year: '1995',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0,
    romPath: '/roms/snes/Chrono Trigger.sfc',
    systemFolderName: 'snes',
  );

  final system = SystemModel(
    id: 'sys-snes',
    folderName: 'snes',
    realName: 'Super Nintendo',
    iconImage: '/images/systems/snes-icon.png',
    color: '#5b4b8a',
  );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // SFX go through SoLoud's FFI bindings, which a test process cannot load.
    SfxService().setEnabled(false);
    // No gamepads: GamepadNavigation.initialize() must find a channel that
    // answers rather than a missing one that throws.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('xyz.luan/gamepads'),
          (call) async => <dynamic>[],
        );
    await FlutterLocalization.instance.ensureInitialized();
    FlutterLocalization.instance.init(
      mapLocales: [MapLocale('en', AppLocale.en)],
      initLanguageCode: 'en',
    );
  });

  tearDownAll(() => SfxService().setEnabled(true));

  setUp(() async {
    final db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    service = _FakeRommService();
  });

  tearDown(() async => helper.tearDown());

  /// Links the game to [rommRomId], which is what makes the fix-up rows
  /// appear: they rewrite the entry the link points at.
  Future<void> link(int rommRomId) async {
    final written = await RommSaveMapRepository.putManualMapping(
      romname: game.romname,
      systemFolder: system.folderName,
      rommRomId: rommRomId,
    );
    expect(written, isTrue);
  }

  late BuildContext host;

  Future<void> settle(WidgetTester tester, {int ms = 120}) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpApp(WidgetTester tester, RommProvider romm) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RommProvider>.value(value: romm),
          ChangeNotifierProvider<FileProvider>(create: (_) => FileProvider()),
        ],
        child: MediaQuery(
          data: const MediaQueryData(size: Size(1280, 720)),
          child: ScreenUtilInit(
            designSize: const Size(1280, 720),
            builder: (context, child) => MaterialApp(
              localizationsDelegates:
                  FlutterLocalization.instance.localizationsDelegates,
              supportedLocales: FlutterLocalization.instance.supportedLocales,
              shortcuts: const <ShortcutActivator, Intent>{},
              home: Scaffold(
                body: Builder(
                  builder: (ctx) {
                    host = ctx;
                    return const SizedBox.expand();
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// True when the row for [name] is the highlighted one — `_RommMatchRow`
  /// draws the selected row's title in w600 and every other in normal.
  ///
  /// Only real [Text] widgets count: `find.text` also matches the search
  /// field's [EditableText], which is prefilled with the pinned entry's name.
  bool highlighted(WidgetTester tester, String name) {
    final rows = find
        .text(name)
        .evaluate()
        .map((e) => e.widget)
        .whereType<Text>()
        .toList();
    expect(rows, hasLength(1), reason: 'one row should carry "$name"');
    return rows.single.style?.fontWeight == FontWeight.w600;
  }

  Future<void> openPicker(
    WidgetTester tester, {
    required RommRom preselected,
  }) async {
    unawaited(
      RommMatchPickerDialog.show(
        host,
        game,
        system,
        preselectedRom: preselected,
      ),
    );
    await settle(tester);
  }

  testWidgets('the fix-up rows are present for a linked game', (tester) async {
    await link(42);
    service.page = [_rom(42)];

    await pumpApp(tester, _FakeRommProvider(service));
    await openPicker(tester, preselected: _rom(42));

    // The premise of every case below: without these rows the preselect has
    // nothing to be shifted by, which is why the controller-level tests pass
    // either way.
    expect(find.text('Fix match on RomM'), findsOneWidget);
    expect(find.text('Change cover'), findsOneWidget);
  });

  testWidgets('a pinned entry the server did not return is highlighted', (
    tester,
  ) async {
    // `_withPreselected` prepends it, so preselectedIndex == 0 — the common
    // case, and the one where the old `pinned + 1` highlighted the
    // "Fix match on RomM" row instead of a result.
    await link(42);
    service.page = [_rom(10), _rom(11)];

    await pumpApp(tester, _FakeRommProvider(service));
    await openPicker(tester, preselected: _rom(42));

    expect(highlighted(tester, 'Rom 42'), isTrue);
    expect(highlighted(tester, 'Rom 10'), isFalse);
    expect(highlighted(tester, 'Rom 11'), isFalse);
  });

  testWidgets('a pinned entry two rows down is the one highlighted', (
    tester,
  ) async {
    // preselectedIndex == 2, where the old offset highlighted result 0 —
    // a different RomM entry, which A would then have written as the link.
    await link(42);
    service.page = [_rom(10), _rom(11), _rom(42), _rom(13)];

    await pumpApp(tester, _FakeRommProvider(service));
    await openPicker(tester, preselected: _rom(42));

    expect(highlighted(tester, 'Rom 42'), isTrue);
    expect(highlighted(tester, 'Rom 10'), isFalse);
    expect(highlighted(tester, 'Rom 11'), isFalse);
    expect(highlighted(tester, 'Rom 13'), isFalse);
  });

  testWidgets('a pinned entry further down is still the one highlighted', (
    tester,
  ) async {
    await link(42);
    service.page = [_rom(10), _rom(11), _rom(12), _rom(13), _rom(42)];

    await pumpApp(tester, _FakeRommProvider(service));
    await openPicker(tester, preselected: _rom(42));

    expect(highlighted(tester, 'Rom 42'), isTrue);
    expect(highlighted(tester, 'Rom 12'), isFalse);
  });

  group('RommMatchPickerSlots', () {
    // The invariant the dialog now computes every index through, pinned
    // directly so the next row inserted above the results (issue #81 plans
    // one) cannot reintroduce an ad-hoc offset.
    test('results never collide with the field or the action rows', () {
      for (final actionCount in [0, 1, 2, 3]) {
        final slots = RommMatchPickerSlots(actionCount: actionCount);
        for (var i = 0; i < 6; i++) {
          final slot = slots.slotForResult(i);
          expect(slot, greaterThan(actionCount));
          expect(slots.resultForSlot(slot), i);
          expect(slots.actionForSlot(slot), isNull);
        }
        for (var i = 0; i < actionCount; i++) {
          final slot = slots.slotForAction(i);
          expect(slots.actionForSlot(slot), i);
          expect(slots.resultForSlot(slot), isNull);
        }
        expect(slots.actionForSlot(0), isNull, reason: 'slot 0 is the field');
        expect(slots.resultForSlot(0), isNull, reason: 'slot 0 is the field');
        expect(slots.itemCount(4), actionCount + 5);
      }
    });
  });
}
