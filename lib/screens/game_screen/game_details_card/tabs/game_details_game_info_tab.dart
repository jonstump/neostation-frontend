import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import '../../../../models/system_model.dart';
import '../../../../models/game_model.dart';
import '../../../../models/romm_manual.dart';
import '../../../../models/romm_rom.dart';
import '../../../../providers/file_provider.dart';
import '../../../../repositories/romm_save_map_repository.dart';
import '../../../../services/logger_service.dart';
import '../../../../services/romm/romm_manual_cache.dart';
import '../../../../services/romm_service.dart';
import '../../../../services/screenscraper_service.dart';
import '../../../manual_viewer/manual_viewer_screen.dart';
import '../widgets/header_action_button.dart';
import '../../../../themes/chrome_surface.dart';
import '../../../../themes/corner_radii.dart';
import '../../../../utils/game_utils.dart';
import '../widgets/panel_gate_highlight.dart';
import '../widgets/scrolling_status_line.dart';
import 'package:neostation/providers/romm_provider.dart';

class GameDetailsGameInfoTab extends StatefulWidget {
  final SystemModel system;
  final GameModel game;
  final FileProvider fileProvider;
  final String description;

  /// Hides the metadata pills while the card's scrape panel covers this tab.
  final bool isScrapingGame;
  final VoidCallback onScrapeGame;

  /// How far above the card's bottom edge the panel stops, in the same
  /// unscaled units as the other offsets. The card works it out from what the
  /// footer under it will draw, so the panel takes back the room a missing
  /// achievements pill leaves behind.
  final double bottomOffset;

  const GameDetailsGameInfoTab({
    super.key,
    required this.system,
    required this.game,
    required this.fileProvider,
    required this.description,
    required this.isScrapingGame,
    required this.onScrapeGame,
    this.bottomOffset = 110.0,
  });

  @override
  State<GameDetailsGameInfoTab> createState() => GameDetailsGameInfoTabState();
}

class GameDetailsGameInfoTabState extends State<GameDetailsGameInfoTab> {
  /// App language code -> the key the scraper files that language under.
  ///
  /// Only the two that actually differ are listed. ScreenScraper writes
  /// Japanese as `jp` where the app calls it `ja`, and it has one Chinese
  /// bucket where the app offers simplified and traditional separately, so
  /// both app variants read the same text. Every other app language is its own
  /// key, and `id` has no bucket at all — it falls through to English like any
  /// other language a game was not scraped in.
  static const Map<String, String> _descriptionKeys = {
    'ja': 'jp',
    'zh': 'zh',
    'zh_Hant': 'zh',
  };

  /// Drives the description pane: the D-pad scrolls it while the panel is
  /// active, and a finger can drag it at any time.
  final ScrollController _descriptionController = ScrollController();

  /// Whether the panel owns the D-pad.
  ///
  /// Same gate as the achievements panel: arriving on this tab must not
  /// swallow the D-pad, so left/right keep walking the tabs and up/down keep
  /// moving the games list until A steps in. B steps back out.
  bool _isPanelActive = false;

  /// How far one D-pad press moves the description: about three lines, so a
  /// press is a readable step rather than a jump.
  double get _scrollStep => 56.r;

  /// Whether the panel currently owns the D-pad.
  bool get isPanelActive => _isPanelActive;

  static final _log = LoggerService.instance;

  /// Which header action holds focus, or -1 while the description does.
  ///
  /// Up from the top of the description lands here, down goes back to the
  /// text, and left/right walk the actions — the same shape the achievements
  /// panel uses, so MANUAL and REFRESH are reachable without a touchscreen.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Availability"
  int _headerFocusIndex = -1;

  /// What RomM knows about this game's manual, once resolved.
  ///
  /// Resolved per game, debounced, and memoized per rom id: the details card
  /// rebuilds for every game the cursor passes, and a detail fetch per row
  /// would put the library scroll on the network.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Availability"
  static final Map<int, RommManual?> _manualByRomId = {};

  Timer? _manualResolveTimer;

  /// RomM rom id this game is linked to, or null when it is not linked.
  int? _manualRomId;

  /// The manual RomM reports for [_manualRomId], or null when it has none
  /// (or the server has not been asked yet).
  RommManual? _manualMeta;

  /// Absolute path of the already-downloaded manual, or null when nothing is
  /// cached. A cached manual keeps the action available offline.
  String? _manualCachedPath;

  /// Set while a manual is downloading, so the action reports itself and a
  /// second press cannot start a second download.
  bool _manualBusy = false;

  /// Localized key of the line shown under the actions, or null for none.
  String? _manualStatusKey;

  /// Interpolation for [_manualStatusKey], when it takes one.
  String? _manualStatusArg;

  /// Whether this game has a manual to open: one cached on disk, or one the
  /// server reported.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Availability"
  bool get _hasManual => _manualCachedPath != null || _manualMeta != null;

  /// Whether "Refresh" can re-download: only with a server to ask.
  bool get _canRefreshManual =>
      _manualMeta != null && context.read<RommProvider>().isConnected;

  /// Whether the panel's edge is currently lit as enterable.
  ///
  /// It cannot be answered during a build: [_canScroll] reads a scroll metric
  /// that does not exist until the description has been laid out, so the
  /// panel's own first frame always says "nothing to drive". Held in state and
  /// refreshed once the frame is up, rather than read live in [build].
  bool _isDrivable = false;

  /// Re-reads whether there is anything in here to drive, one frame late.
  ///
  /// Without this the panel kept its first-frame answer until something else
  /// rebuilt the card — and the next thing that does is the tab slide
  /// finishing, so the highlight arrived exactly as the panel came to rest.
  void _refreshDrivability() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final drivable = _canScroll;
      if (drivable != _isDrivable) setState(() => _isDrivable = drivable);
    });
  }

  @override
  void initState() {
    super.initState();
    _refreshDrivability();
    _scheduleManualResolve();
  }

  /// Whether the description is longer than its pane.
  bool get _canScroll =>
      _descriptionController.hasClients &&
      _descriptionController.position.maxScrollExtent > 0;

  /// Hands the D-pad to the panel. Returns whether the input was consumed.
  ///
  /// Refuses when there is nothing to drive: a description that fits in its
  /// pane leaves the D-pad better spent on the tabs and the list. Scrolling is
  /// now the only thing in here to drive — the language strip that was the
  /// other half of this gate is gone.
  bool enterPanel() {
    if (_isPanelActive) return true; // Already inside — A stays consumed.
    // A manual to open is as good a reason to enter as text to scroll: a game
    // whose description fits its pane still has an action in here.
    final actions = _headerActions();
    if (!_canScroll && actions.isEmpty) return false;

    setState(() {
      _isPanelActive = true;
      // With nothing to scroll, the actions are the only place to be.
      _headerFocusIndex = _canScroll ? -1 : 0;
    });
    return true;
  }

  /// Gives the D-pad back to the details card. Returns whether it was held.
  bool exitPanel() {
    if (!_isPanelActive) return false;

    setState(() {
      _isPanelActive = false;
      _headerFocusIndex = -1;
    });
    return true;
  }

  /// Runs the focused header action (gamepad A).
  ///
  /// Always reports the button consumed while the panel is active: A must not
  /// fall through and launch the game from under a panel the user is reading.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Availability"
  bool activateFocused() {
    if (!_isPanelActive) return false;

    final actions = _headerActions();
    if (_headerFocusIndex >= 0 && _headerFocusIndex < actions.length) {
      SfxService().playNavSound();
      actions[_headerFocusIndex].onTap();
    }
    return true;
  }

  /// Gamepad navigation delegate: scrolls the description up one step, or
  /// steps onto the header actions once the text is already at the top.
  void moveUp() {
    if (_headerFocusIndex >= 0) return; // Already on the actions row.
    if (_headerActions().isNotEmpty && _isDescriptionAtTop) {
      setState(() => _headerFocusIndex = 0);
      return;
    }
    _scrollDescription(-_scrollStep);
  }

  /// Gamepad navigation delegate: scrolls the description down one step, or
  /// steps off the header actions back into the text.
  void moveDown() {
    if (_headerFocusIndex >= 0) {
      setState(() => _headerFocusIndex = -1);
      return;
    }
    _scrollDescription(_scrollStep);
  }

  /// Whether the description is at (or has no) scroll offset — the boundary
  /// that hands the D-pad up to the actions row instead of scrolling further.
  bool get _isDescriptionAtTop =>
      !_descriptionController.hasClients ||
      _descriptionController.position.pixels <= 0.5;

  /// Gamepad navigation delegate: nothing to the left or right in here.
  ///
  /// These used to walk the language strip. The panel shows one language now —
  /// the user's — so there is no horizontal axis left to drive. They stay as
  /// no-ops rather than being unregistered: the card dispatches left/right to
  /// whichever panel holds the D-pad, and a panel that is being read should
  /// swallow them rather than let a stray press slide the tab out from under
  /// the text. B is the way out, as everywhere else.
  void moveLeft() => _moveHeaderFocus(-1);

  /// Gamepad navigation delegate: see [moveLeft].
  void moveRight() => _moveHeaderFocus(1);

  /// Moves header focus by [delta], clamped to the ends so the run of actions
  /// has edges rather than wrapping under the user. A no-op while the
  /// description holds the D-pad, which is what keeps left/right swallowed.
  void _moveHeaderFocus(int delta) {
    if (_headerFocusIndex < 0) return;
    final actions = _headerActions();
    if (actions.isEmpty) return;
    final next = (_headerFocusIndex + delta).clamp(0, actions.length - 1);
    if (next == _headerFocusIndex) return;
    setState(() => _headerFocusIndex = next);
  }

  void _scrollDescription(double delta) {
    if (!_isPanelActive || !_descriptionController.hasClients) return;

    final position = _descriptionController.position;
    final target = (position.pixels + delta).clamp(
      0.0,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < 0.5) return;

    _descriptionController.animateTo(
      target,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  @override
  void didUpdateWidget(GameDetailsGameInfoTab oldWidget) {
    super.didUpdateWidget(oldWidget);

    // A new game, or a scrape landing on this one, is a new description: what
    // there is to drive has to be measured again.
    _refreshDrivability();

    // A new game is a new panel: drop the gate and start its text from the
    // top. There is no language to carry over or reset any more — the panel
    // resolves one from the app's own language on every build.
    if (oldWidget.game.romPath != widget.game.romPath) {
      _isPanelActive = false;
      _headerFocusIndex = -1;
      _scheduleManualResolve();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _descriptionController.hasClients) {
          _descriptionController.jumpTo(0);
        }
      });
    }
  }

  @override
  void dispose() {
    _manualResolveTimer?.cancel();
    _descriptionController.dispose();
    super.dispose();
  }

  /// The one language this panel reads the description in.
  ///
  /// The app's own display language, mapped onto the scraper's key for it. The
  /// panel used to show every language a game had been scraped in, as a strip
  /// of chips the D-pad walked — which put a language picker in front of a
  /// user who has already told the app which language they read, on a tab
  /// whose job is to be read.
  ///
  /// Falling back is [GameModel.getDescriptionForLanguage]'s job and it
  /// already does it: the requested language, then English, then the rest of
  /// its hierarchy, then anything the game has. A game scraped in one language
  /// still shows that text rather than an empty pane.
  String _descriptionLanguage(BuildContext context) {
    final appLanguage = context
        .watch<SqliteConfigProvider>()
        .config
        .appLanguage;
    return _descriptionKeys[appLanguage] ?? appLanguage;
  }

  // ── Manual (SPEC-0017) ───────────────────────────────────────────────────

  /// The ROM detail a manual download needs, kept per rom id so opening the
  /// same manual twice costs one detail fetch at most. Only written when a
  /// manual is actually opened, which is rare enough to keep it small.
  static final Map<int, RommRom> _rommRomById = {};

  /// How many rom ids [_manualByRomId] remembers before it starts forgetting
  /// the oldest. A scroll through a large library resolves one entry per game,
  /// and the answer is cheap to re-fetch.
  static const int _manualMemoLimit = 500;

  /// Memoizes the answer for [romId] — including "no manual" — dropping the
  /// oldest entry once the cap is reached.
  static void _rememberManual(int romId, RommManual? manual) {
    if (!_manualByRomId.containsKey(romId) &&
        _manualByRomId.length >= _manualMemoLimit) {
      _manualByRomId.remove(_manualByRomId.keys.first);
    }
    _manualByRomId[romId] = manual;
  }

  /// Identity of the game on screen. Every async manual step re-checks it, so
  /// an answer for the game the cursor just left cannot land on this one.
  String get _gameToken => '${widget.system.folderName}/${widget.game.romname}';

  /// Restarts manual resolution for the game now on screen.
  ///
  /// Debounced: the details card rebuilds for every game the cursor passes,
  /// and resolving each one would put a mapping query (and possibly a detail
  /// fetch) on the library scroll.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Availability"
  void _scheduleManualResolve() {
    _manualResolveTimer?.cancel();
    _manualRomId = null;
    _manualMeta = null;
    _manualCachedPath = null;
    _manualBusy = false;
    _manualStatusKey = null;
    _manualStatusArg = null;

    final token = _gameToken;
    _manualResolveTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || _gameToken != token) return;
      unawaited(_resolveManual(token));
    });
  }

  /// Works out whether this game has a manual, cheapest answer first: the link
  /// row, then the cache (which answers offline), then — only for a rom id
  /// nothing is memoized for — RomM's detail endpoint.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Availability"
  Future<void> _resolveManual(String token) async {
    try {
      final mapping = await RommSaveMapRepository.getMapping(
        widget.game.romname,
        widget.system.folderName,
      );
      if (!mounted || _gameToken != token || mapping == null) return;

      final romId = mapping.rommRomId;
      final cached = await RommManualCache.cachedPathFor(
        mediaRoot: widget.fileProvider.getMediaDirectoryPath(),
        romId: romId,
      );
      if (!mounted || _gameToken != token) return;

      final memoized = _manualByRomId[romId];
      setState(() {
        _manualRomId = romId;
        _manualCachedPath = cached;
        _manualMeta = memoized ?? RommManual.fromPath(cached);
      });

      // A memoized answer — including a memoized "no manual" — is final for
      // this run; nothing more to ask.
      if (_manualByRomId.containsKey(romId)) return;

      final romm = context.read<RommProvider>();
      if (!romm.isConnected) return;

      final rom = await romm.service.getRom(romId);
      // Only the manual is memoized here, not the whole ROM: this runs for
      // every game the cursor rests on, and holding a detail object per row
      // would grow with the library.
      _rememberManual(romId, rom.manual);
      if (!mounted || _gameToken != token) return;
      setState(() => _manualMeta = rom.manual ?? _manualMeta);
    } catch (e) {
      _log.w(
        'Manual availability lookup failed: '
        'game=${widget.game.romname} system=${widget.system.folderName} '
        'error=$e',
      );
    }
  }

  /// Opens the manual, downloading it first when it is not already cached.
  ///
  /// With [refresh] the cached copy is ignored and the file is fetched again;
  /// without it a cached manual opens with **no request at all**, which is
  /// what makes a manual readable with the server unreachable.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Download And Cache"
  Future<void> _openManual({bool refresh = false}) async {
    if (_manualBusy) return;
    final romId = _manualRomId;
    if (romId == null) return;

    final meta = _manualMeta;
    if (meta != null && !meta.isSupported) {
      setState(() {
        _manualStatusKey = AppLocale.manualUnsupportedType;
        _manualStatusArg = meta.extension;
      });
      return;
    }

    final mediaRoot = widget.fileProvider.getMediaDirectoryPath();
    if (!refresh) {
      final cached =
          _manualCachedPath ??
          await RommManualCache.cachedPathFor(
            mediaRoot: mediaRoot,
            romId: romId,
          );
      if (!mounted) return;
      if (cached != null) {
        setState(() => _manualCachedPath = cached);
        await _showManual(cached);
        return;
      }
    }

    final romm = context.read<RommProvider>();
    if (!romm.isConnected) {
      setState(() {
        _manualStatusKey = AppLocale.manualNotAvailable;
        _manualStatusArg = null;
      });
      return;
    }

    setState(() {
      _manualBusy = true;
      _manualStatusKey = AppLocale.manualDownloading;
      _manualStatusArg = null;
    });
    try {
      var rom = _rommRomById[romId];
      if (rom == null || refresh) {
        rom = await romm.service.getRom(romId);
        _rommRomById[romId] = rom;
        _rememberManual(romId, rom.manual);
      }
      final manual = rom.manual;
      if (manual == null) {
        throw RommException('No manual for rom $romId');
      }
      if (!manual.isSupported) {
        if (!mounted) return;
        setState(() {
          _manualBusy = false;
          _manualStatusKey = AppLocale.manualUnsupportedType;
          _manualStatusArg = manual.extension;
        });
        return;
      }

      final path = await RommManualCache.ensure(
        service: romm.service,
        rom: rom,
        mediaRoot: mediaRoot,
        refresh: refresh,
      );
      if (!mounted) return;
      setState(() {
        _manualBusy = false;
        _manualCachedPath = path;
        _manualMeta = manual;
        _manualStatusKey = null;
      });
      await _showManual(path);
    } catch (e) {
      _log.w('Manual open failed: rom=$romId refresh=$refresh error=$e');
      if (!mounted) return;
      setState(() {
        _manualBusy = false;
        _manualStatusKey = AppLocale.manualNotAvailable;
        _manualStatusArg = null;
      });
    }
  }

  /// Pushes the viewer for an on-disk manual. Returning from it (B) leaves the
  /// action that opened it focused, because nothing here moves the cursor.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Viewer"
  Future<void> _showManual(String filePath) async {
    final manual = RommManual.fromPath(filePath);
    if (manual == null || !manual.isSupported) {
      setState(() {
        _manualStatusKey = AppLocale.manualUnsupportedType;
        _manualStatusArg = manual?.extension ?? '';
      });
      return;
    }
    await ManualViewerScreen.show(
      context,
      filePath: filePath,
      kind: manual.kind,
      title: widget.game.romname,
    );
  }

  /// The header actions the D-pad can reach, in the order they are drawn.
  // Governing: ADR-0017 (view RomM manuals and notes on device), SPEC-0017 REQ "Manual Availability"
  List<_HeaderAction> _headerActions() {
    if (!_hasManual) return const [];
    return [
      _HeaderAction(label: AppLocale.manual, onTap: _openManual),
      if (_canRefreshManual)
        _HeaderAction(
          label: AppLocale.manualRefresh,
          onTap: () => _openManual(refresh: true),
        ),
    ];
  }

  /// The actions row, or nothing when this game has no manual.
  Widget _buildHeaderActions() {
    final actions = _headerActions();
    if (actions.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) SizedBox(width: 4.r),
          HeaderActionButton(
            label: actions[i].label.getString(context).toUpperCase(),
            onTap: actions[i].onTap,
            backgroundColor: scheme.surfaceContainerHighest,
            foregroundColor: scheme.onSurface,
            isFocused: _isPanelActive && _headerFocusIndex == i,
          ),
        ],
      ],
    );
  }

  /// The one-line manual status, or nothing when there is none to show.
  Widget _buildManualStatus() {
    final key = _manualStatusKey;
    if (key == null) return const SizedBox.shrink();
    var text = key.getString(context);
    final arg = _manualStatusArg;
    if (arg != null) text = text.replaceFirst('{extension}', arg);
    return Padding(
      padding: EdgeInsets.only(top: 4.r),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 9.r,
          color: key == AppLocale.manualDownloading
              ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)
              : Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final description = widget.description;

    final bool showScrapeView =
        description.isEmpty ||
        description == AppLocale.noDescription.getString(context) ||
        description.trim().isEmpty;

    final List<Widget> headerFacts = showScrapeView || widget.isScrapingGame
        ? const []
        : _buildHeaderFacts();

    return Positioned(
      left: 12.r,
      right: 12.r,
      top: 55.r,
      bottom: widget.bottomOffset.r,
      // The panel is its own affordance now: its edge lights up while there
      // is something in here to drive, and a tap anywhere on it is the touch
      // equivalent of the A gate. B is still the way back out.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (_isPanelActive || !_isDrivable) return;
          SfxService().playNavSound();
          enterPanel();
        },
        child: AnimatedContainer(
          duration: PanelGateHighlight.duration,
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: ChromeSurface.fill(context),
            borderRadius:
                Theme.of(context).extension<CornerRadii>()?.radiusExternal ??
                BorderRadius.circular(14.r),
            border: PanelGateHighlight.border(
              context,
              isDrivable: _isDrivable,
              isActive: _isPanelActive,
              restingColor: Theme.of(context).colorScheme.outline,
            ),
            boxShadow: PanelGateHighlight.shadows(
              context,
              isActive: _isPanelActive,
              resting: BoxShadow(
                color: Theme.of(
                  context,
                ).colorScheme.shadow.withValues(alpha: 0.25),
                blurRadius: 2.r,
                offset: Offset(2.0.r, 2.0.r),
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(8.r, 8.r, 8.r, 0.r),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Symbols.info_rounded,
                          color: Theme.of(context).colorScheme.onSurface,
                          size: 13.r,
                        ),
                        // No title: the selected tab in the card's header strip
                        // is already this icon, so naming the panel again only
                        // costs the row room. Everything packs to the left into
                        // the space it used to take.
                        SizedBox(width: 8.r),
                        // No gate chip: the panel's own edge carries that now, so
                        // the row neither spends a slot on it nor re-packs itself
                        // on the frame the drivability answer lands. The facts
                        // strip starts at the same x on every game.
                        // The facts take the rest of the row. A long publisher
                        // name (or a system whose scrape fills every field) can
                        // outrun it, so the strip marquees when it genuinely
                        // overflows and sits still when it does not — the same
                        // treatment the footer's metadata line gets, rather than
                        // an overflow stripe or a truncated name.
                        if (headerFacts.isNotEmpty)
                          Expanded(
                            child: SizedBox(
                              height: _headerFactsHeight,
                              child: ScrollingStatusLine(
                                resetKey: widget.game.romname,
                                children: headerFacts,
                              ),
                            ),
                          )
                        else
                          const Spacer(),
                        _buildHeaderActions(),
                      ],
                    ),
                    _buildManualStatus(),
                    Divider(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.1),
                      height: 10.r,
                    ),
                  ],
                ),
              ),

              Expanded(
                child: Padding(
                  padding: EdgeInsets.all(8.r),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // While scraping, the card lays ScrapingProgressPanel over
                      // this whole region — every tab gets the same feedback, so
                      // this tab no longer draws its own copy.
                      return showScrapeView
                          ? _buildNonScrapedView()
                          : _buildScrapedView();
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNonScrapedView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            AppLocale.incompleteMetadata.getString(context),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 20.r,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 12.r),
          SizedBox(
            width: 300.r,
            child: Text(
              AppLocale.scrapeToDownload.getString(context),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
                fontSize: 12.r,
                height: 1.5,
              ),
            ),
          ),
          SizedBox(height: 32.r),
          FutureBuilder<bool>(
            future: ScreenScraperService.hasSavedCredentials(),
            builder: (context, snapshot) {
              if (widget.system.folderName == 'android-apps') {
                return Text(
                  AppLocale.scrapingUnavailableAndroid.getString(context),
                  style: TextStyle(fontSize: 10.r, color: Colors.grey),
                );
              }
              final hasCredentials = snapshot.data ?? false;
              // A connected RomM server scrapes on its own (ADR-0006), so
              // the ScreenScraper prompt only applies when neither is set up.
              // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Entry Point Consistency"
              final rommConnected = context.read<RommProvider>().isConnected;
              if (!hasCredentials && !rommConnected) {
                return Text(
                  AppLocale.loginToScrape.getString(context),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 10.r,
                    fontStyle: FontStyle.italic,
                  ),
                );
              }

              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

  /// Height of the header's fact strip. Fixed, because the marquee inside it
  /// needs a bounded box to measure its overflow against.
  double get _headerFactsHeight => 16.r;

  /// The scraped facts, in the order they are read.
  ///
  /// Publisher and genre joined developer, players and year here when the
  /// details footer's metadata strip was removed: this panel already carried
  /// three of the five, and the strip was painting the other two onto the
  /// game's fanart on every view, one marquee'd line above the filename. All
  /// five in one place is the tab's whole job, and the strip's two are the
  /// ones a reader has to *look* for rather than glance at.
  ///
  /// Empty fields drop out entirely rather than rendering a placeholder, so an
  /// unscraped game leaves the strip empty and the row collapses.
  List<Widget> _buildHeaderFacts() {
    return [
      if (widget.game.developer.isNotEmpty)
        _InfoPill(icon: Symbols.business_rounded, text: widget.game.developer),
      if (widget.game.publisher.isNotEmpty)
        _InfoPill(
          icon: Symbols.storefront_rounded,
          text: widget.game.publisher,
        ),
      if (widget.game.players.isNotEmpty)
        _InfoPill(icon: Symbols.people_rounded, text: widget.game.players),
      if (widget.game.year.isNotEmpty)
        _InfoPill(
          icon: Symbols.calendar_today_rounded,
          text:
              RegExp(r'\d{4}').stringMatch(widget.game.year) ??
              widget.game.year,
        ),
      if (widget.game.genre.isNotEmpty)
        _InfoPill(icon: Symbols.category_rounded, text: widget.game.genre),
    ];
  }

  /// The description pane.
  ///
  /// It used to scroll itself on a timer, which meant the text was moving
  /// under the reader and there was no way to hold it still or go back a
  /// paragraph. It stays put now: a finger drags it, and the D-pad steps it
  /// once the panel has been activated.
  Widget _buildDescription(String text) {
    return SingleChildScrollView(
      controller: _descriptionController,
      physics: const BouncingScrollPhysics(),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
          fontSize: 11.r,
          height: 1.6,
        ),
      ),
    );
  }

  Widget _buildScrapedView() {
    final descriptions = widget.game.descriptions;

    if (descriptions == null || descriptions.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(12.r),
        child: _buildDescription(
          GameUtils.cleanupDescription(widget.description),
        ),
      );
    }

    // One language, resolved from the app's. The strip of chips that used to
    // sit under this text is gone with it: it offered a choice the user had
    // already made in Settings, and it cost the description a band of height
    // on every game that happened to be scraped more than once.
    final activeDesc = widget.game.getDescriptionForLanguage(
      _descriptionLanguage(context),
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      child: _buildDescription(
        GameUtils.cleanupDescription(
          activeDesc.isNotEmpty ? activeDesc : widget.description,
        ),
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoPill({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4.r),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 10.r,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
          SizedBox(width: 4.r),
          Text(
            text,
            style: TextStyle(
              fontSize: 9.r,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// One reachable action in the info panel's header row.
class _HeaderAction {
  /// [AppLocale] key, resolved at build time.
  final String label;
  final VoidCallback onTap;

  const _HeaderAction({required this.label, required this.onTap});
}
