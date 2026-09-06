import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_locale.dart';
import '../../models/romm_pairing.dart';
import '../../providers/romm_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../services/game_service.dart' show GamepadNavigationManager;
import '../../services/neosync/auth_service.dart';
import '../../sync/providers/neo_sync_adapter.dart';
import '../../sync/providers/romm_provider.dart';
import '../../sync/sync_manager.dart';
import '../../utils/gamepad_nav.dart';
import '../../utils/login_form_selection.dart';
import '../../utils/romm_pair_code_input_formatter.dart';
import '../../utils/romm_pair_error_message.dart';
import '../../utils/romm_qr_platform.dart';
import '../../widgets/custom_notification.dart';
import '../app_screen.dart';
import 'romm_auth_mode.dart';
import 'romm_qr_scan_screen.dart';

/// Self-contained RomM connect / account panel for the top-level RomM tab.
///
/// When disconnected it shows the server credential form: the server URL, an
/// authentication mode switch (username + password, a RomM Client API Token,
/// or a pairing code from RomM's Client API Tokens screen), the fields that
/// mode needs, and connect. The URL leads because every mode needs it — the
/// switch only changes how you prove who you are, not which server you are
/// proving it to. When connected it shows the server status plus
/// the save-sync toggle, a disconnect action, and — when [onBrowse] is provided
/// — a shortcut back to the library browser. Unlike the old settings panel this
/// widget owns its own gamepad navigation layer so it works as a standalone tab.
class RommConnectContent extends StatefulWidget {
  /// Invoked by the "back to library" action while connected. Null when the
  /// panel is shown as the disconnected landing view (nothing to go back to).
  final VoidCallback? onBrowse;

  const RommConnectContent({super.key, this.onBrowse});

  @override
  State<RommConnectContent> createState() => _RommConnectContentState();
}

class _RommConnectContentState extends State<RommConnectContent>
    with LoginFormSelection<RommConnectContent> {
  final ScrollController _scrollController = ScrollController();
  // One per slot of the longest order: pairing mode with the scan action.
  final List<GlobalKey> _itemKeys = List.generate(6, (_) => GlobalKey());

  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _pairCodeController = TextEditingController();
  final FocusNode _urlFocus = FocusNode();
  final FocusNode _userFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();
  final FocusNode _apiKeyFocus = FocusNode();
  final FocusNode _pairCodeFocus = FocusNode();

  late final GamepadNavigation _gamepadNav;
  bool _busy = false;

  /// How the form is collecting credentials: a username and password, a
  /// Client API Token, or a pairing code. Purely a property of the login form
  /// — a connection remembers its own mode in the database.
  // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On The Connect Screen"
  RommAuthMode _authMode = RommAuthMode.password;

  /// Whether pairing mode draws the "Scan QR code" row: only on Android and
  /// macOS, where the scanner plugin is wired in and a camera is plausible.
  /// Windows and Linux never get the row, nor a slot for it.
  // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A Camera Exists"
  bool get _canScanQr => showsQrScanAction(defaultTargetPlatform);

  /// The current mode's cursor order, with the scan action when this
  /// platform has it.
  List<RommConnectSlot> get _focusOrder =>
      focusOrderFor(_authMode, includeScanQr: _canScanQr);

  /// The slots the D-pad walks, which change with both the connection state and
  /// the authentication mode: connected it is three action rows and no field at
  /// all, disconnected it is [focusOrderFor] the current mode — the server URL,
  /// the mode switch, that mode's secret(s), and connect — mapped onto focus
  /// nodes. Read live, so the cursor is clamped into range the moment any of
  /// that changes — including by something other than this panel's own
  /// buttons.
  @override
  List<FocusNode?> get selectionSlots {
    if (context.read<RommProvider>().isConnected) {
      return const [null, null, null];
    }
    return _focusOrder.map(_focusNodeFor).toList(growable: false);
  }

  /// Every node the panel owns, not just the ones the current state shows, so
  /// focus tracking survives the switch to the connected view or between the
  /// authentication modes.
  @override
  List<FocusNode> get ownedFocusNodes => [
    _urlFocus,
    _userFocus,
    _passwordFocus,
    _apiKeyFocus,
    _pairCodeFocus,
  ];

  /// The text field behind [slot], or null for a control the D-pad activates
  /// rather than focuses. A new action slot only needs a null here and a case
  /// in [_selectCurrent].
  FocusNode? _focusNodeFor(RommConnectSlot slot) => switch (slot) {
    RommConnectSlot.url => _urlFocus,
    RommConnectSlot.username => _userFocus,
    RommConnectSlot.password => _passwordFocus,
    RommConnectSlot.apiKey => _apiKeyFocus,
    RommConnectSlot.pairCode => _pairCodeFocus,
    RommConnectSlot.authMode ||
    RommConnectSlot.scanQr ||
    RommConnectSlot.connect => null,
  };

  /// Where [slot] sits in the current mode's cursor order, for the rows that
  /// draw their own selection glow.
  int _slotIndex(RommConnectSlot slot) => _focusOrder.indexOf(slot);

  /// Slot the mode switch sits on: under the server URL, which every mode
  /// needs, and above the fields it actually decides. Left/Right step along
  /// its segments (see [_setAuthMode]); A advances it, for anyone who reaches
  /// it that way.
  int get _authModeSlot => _slotIndex(RommConnectSlot.authMode);

  @override
  void initState() {
    super.initState();
    attachFocusSelectionListeners();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: () => _setAuthMode(_authMode.toLeft),
      onNavigateRight: () => _setAuthMode(_authMode.toRight),
      onSelectItem: _selectCurrent,
      onBack: _handleBack,
      onPreviousTab: AppNavigation.previousTab,
      onNextTab: AppNavigation.nextTab,
      onLeftBumper: AppNavigation.previousTab,
      onRightBumper: AppNavigation.nextTab,
      allowRepeat: false,
      isTextFieldFocused: isAnyFieldFocused,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<RommProvider>();
      _urlController.text = provider.serverUrl;
      _userController.text = provider.username;
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'romm_connect',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('romm_connect');
    _gamepadNav.dispose();
    detachFocusSelectionListeners();
    _scrollController.dispose();
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _apiKeyController.dispose();
    _pairCodeController.dispose();
    _urlFocus.dispose();
    _userFocus.dispose();
    _passwordFocus.dispose();
    _apiKeyFocus.dispose();
    _pairCodeFocus.dispose();
    super.dispose();
  }

  // ── Gamepad navigation ──────────────────────────────────────────────────────

  /// Returns whether the cursor actually moved, so the gamepad handler can
  /// suppress the nav sound when the move was refused.
  bool _navigateUp() => _moveAndScroll(-1);

  bool _navigateDown() => _moveAndScroll(1);

  bool _moveAndScroll(int delta) {
    if (!moveSelection(delta)) return false;
    _scrollToIndex(selectedSlot);
    return true;
  }

  void _selectCurrent() {
    if (context.read<RommProvider>().isConnected) {
      if (isSelected(0)) {
        widget.onBrowse?.call();
      } else if (isSelected(1)) {
        _toggleSaveSync();
      } else if (isSelected(2)) {
        _disconnect();
      }
      return;
    }
    // Dispatch on the slot rather than its index so a mode that inserts a
    // row (the scanner story adds a scan action to pairing mode) only needs a
    // case here.
    switch (_focusOrder[selectedSlot]) {
      case RommConnectSlot.authMode:
        _toggleAuthMode();
      // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A Camera Exists"
      case RommConnectSlot.scanQr:
        _scanQr();
      case RommConnectSlot.connect:
        _connect();
      case RommConnectSlot.url:
      case RommConnectSlot.username:
      case RommConnectSlot.password:
      case RommConnectSlot.apiKey:
      case RommConnectSlot.pairCode:
        focusSelectedField();
    }
  }

  /// Advances to the next login mode, wrapping from pairing code back to
  /// password. Nothing at or above the switch moves, so the cursor is left
  /// where it is; only the rows below are replaced, and the mixin clamps a
  /// cursor that was parked on one of them.
  void _toggleAuthMode() => _applyAuthMode(_authMode.next);

  /// Steps to a neighbouring segment, which is what Left and Right do while
  /// the cursor is on the switch: Left moves one segment left and stops at
  /// password, Right moves one right and stops at pairing code. A segmented
  /// control reads as positions, not a ring, so the ends don't wrap.
  ///
  /// Returns whether anything changed, so the gamepad handler stays silent when
  /// the mode asked for is already the current one — the same "refused moves
  /// make no sound" contract [moveSelection] follows.
  // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On The Connect Screen"
  bool _setAuthMode(RommAuthMode mode) {
    if (context.read<RommProvider>().isConnected) return false;
    if (!isSelected(_authModeSlot)) return false;
    if (isAnyFieldFocused()) return false;
    if (_authMode == mode) return false;
    _applyAuthMode(mode);
    return true;
  }

  void _applyAuthMode(RommAuthMode mode) {
    if (_authMode == mode) return;
    setState(() => _authMode = mode);
  }

  /// B leaves a focused field first — that is what it does everywhere else in
  /// the app — and only steps back to the library once nothing is focused.
  void _handleBack() {
    if (isAnyFieldFocused()) {
      exitTextEntry();
      return;
    }
    widget.onBrowse?.call();
  }

  void _scrollToIndex(int index) {
    if (index < 0 || index >= _itemKeys.length) return;
    final ctx = _itemKeys[index].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      alignment: 0.5,
    );
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  bool _validateInputs() {
    final urlMissing = _urlController.text.trim().isEmpty;
    final secretMissing = switch (_authMode) {
      RommAuthMode.password =>
        _userController.text.trim().isEmpty || _passwordController.text.isEmpty,
      RommAuthMode.apiKey => _apiKeyController.text.trim().isEmpty,
      // The formatter only lets code characters through, so what is left to
      // check is that all 8 of them are there.
      RommAuthMode.pairCode => !RommPairCode.isValid(
        RommPairCode.normalize(_pairCodeController.text),
      ),
    };
    if (urlMissing || secretMissing) {
      final key = switch (_authMode) {
        RommAuthMode.password => AppLocale.rommCredentialsRequired,
        RommAuthMode.apiKey => AppLocale.rommApiKeyRequired,
        RommAuthMode.pairCode => AppLocale.rommPairCodeInvalidLength,
      };
      AppNotification.showNotification(
        context,
        key.getString(context),
        type: NotificationType.error,
      );
      return false;
    }
    return true;
  }

  Future<void> _connect() async {
    if (_busy || !_validateInputs()) return;
    setState(() => _busy = true);
    final provider = context.read<RommProvider>();
    // Both captured before the await: the context can't be read across the gap.
    final neoSyncLoggedIn = context.read<AuthService>().isLoggedIn;
    final persist = context
        .read<SqliteConfigProvider>()
        .updateActiveSyncProvider;
    final serverUrl = _urlController.text.trim();
    // Captured too: the D-pad can move the switch while the request is out,
    // and the error text must describe the mode that made the request.
    final mode = _authMode;
    final useApiKey = mode == RommAuthMode.apiKey;
    // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On The Connect Screen"
    final error = mode == RommAuthMode.pairCode
        // The code is good for about a minute and one use, so it goes to the
        // server the moment Connect is pressed; the provider exchanges it
        // and then connects through the API-key path with the token.
        ? await provider.connectWithPairCode(
            serverUrl: serverUrl,
            code: _pairCodeController.text,
          )
        : await provider.connect(
            serverUrl: serverUrl,
            username: useApiKey ? '' : _userController.text.trim(),
            password: useApiKey ? '' : _passwordController.text,
            apiKey: useApiKey ? _apiKeyController.text.trim() : '',
          );
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      // A pairing failure the provider could classify gets its own sentence;
      // anything else (network, TLS, verification) reads as it does for the
      // other modes.
      final pairKey = mode == RommAuthMode.pairCode
          ? rommPairErrorKey(provider.lastErrorKind)
          : null;
      AppNotification.showNotification(
        context,
        pairKey?.getString(context) ?? error,
        type: NotificationType.error,
      );
    } else {
      // Adopt save sync only when NeoSync isn't signed in. Save sync is one
      // provider at a time, so switching unconditionally would quietly move it
      // off a NeoSync account the user is still using — the same silent stop
      // _disconnect() guards against in the other direction. With NeoSync
      // logged out there is nothing to take away, and leaving it pointed there
      // means a freshly connected server syncs nowhere at all.
      if (!neoSyncLoggedIn && !_isSaveSyncActive) {
        await SyncManager.instance.setActive(
          RomMSyncProvider.kProviderId,
          persist: persist,
        );
      }
      if (!mounted) return;
      _clearSecretFields();
      // Reset selection so the connected view starts on the first row.
      resetSelection();
      AppNotification.showNotification(
        context,
        AppLocale.rommConnectionSuccess.getString(context),
        type: NotificationType.success,
      );
    }
  }

  /// Opens the camera scanner and acts on what it returns: a pairing link
  /// fills the URL and code fields and connects at once (the code has about
  /// a minute to live), a camera refusal is reported and the typed path is
  /// left exactly as it was, and backing out changes nothing.
  // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A Camera Exists"
  Future<void> _scanQr() async {
    if (_busy) return;
    // The scanner is a route of its own; leave text entry so the keyboard
    // isn't still up when the form comes back.
    exitTextEntry();
    final result = await RommQrScanScreen.show(context);
    if (!mounted) return;
    switch (result) {
      case null:
        return;
      case RommQrScanLink(:final link):
        _urlController.text = link.serverUrl;
        // Shown dashed, as RomM prints it and as the formatter would have
        // laid it out had the user typed it.
        _pairCodeController.text = RommPairCode.display(link.code);
        await _connect();
      case RommQrScanDenied():
        AppNotification.showNotification(
          context,
          AppLocale.rommScanQrCameraDenied.getString(context),
          type: NotificationType.error,
        );
      case RommQrScanUnavailable():
        AppNotification.showNotification(
          context,
          AppLocale.rommScanQrCameraUnavailable.getString(context),
          type: NotificationType.error,
        );
    }
  }

  Future<void> _disconnect() async {
    final provider = context.read<RommProvider>();
    // Capture before the await: the context can't be read across the gap.
    final persist = context
        .read<SqliteConfigProvider>()
        .updateActiveSyncProvider;
    await provider.disconnect();
    // If RomM was the active save-sync provider, hand save sync back to
    // NeoSync. Leaving "romm" active against a server we just forgot would
    // silently stop ALL save sync — RomM errors out, NeoSync sits idle —
    // until the user thought to re-toggle it.
    await SyncManager.instance.releaseIfActive(
      RomMSyncProvider.kProviderId,
      persist: persist,
    );
    if (!mounted) return;
    _clearSecretFields();
    resetSelection();
  }

  /// Wipes every mode's secret out of the form once it has been handed to
  /// the provider (or thrown away by a disconnect), so none lingers on
  /// screen — nor in memory — while the panel stays mounted. A pairing code
  /// is single use, so it is as spent as a password after the attempt.
  void _clearSecretFields() {
    _passwordController.clear();
    _apiKeyController.clear();
    _pairCodeController.clear();
  }

  bool get _isSaveSyncActive =>
      SyncManager.instance.activeProviderId == RomMSyncProvider.kProviderId;

  /// Toggles whether RomM is the active save-sync provider (vs NeoSync).
  Future<void> _toggleSaveSync() async {
    final persist = context
        .read<SqliteConfigProvider>()
        .updateActiveSyncProvider;
    final target = _isSaveSyncActive
        ? NeoSyncAdapter.kProviderId
        : RomMSyncProvider.kProviderId;
    await SyncManager.instance.setActive(target, persist: persist);
    if (!mounted) return;
    setState(() {});
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<RommProvider>();

    // Match the ScreenScraper / RetroAchievements login layout: a top-anchored,
    // horizontally-scrollable row with the credential card on the left and an
    // explanatory info box on the right (info box shown only when disconnected).
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 64.r), // Space for the top navigation dock.
          Center(
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.r),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      constraints: BoxConstraints(maxWidth: 260.r),
                      child: _buildFormCard(theme, provider),
                    ),
                    if (!provider.isConnected) ...[
                      SizedBox(width: 16.r),
                      SizedBox(width: 300.r, child: _buildInfoBox(theme)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormCard(ThemeData theme, RommProvider provider) {
    final connected = provider.isConnected;
    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (connected ? AppLocale.rommLibrary : AppLocale.rommLogin)
                      .getString(context),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                    fontSize: 14.r,
                  ),
                ),
              ),
            ],
          ),
          // The status line is redundant on the login form (you are visibly
          // disconnected); show it only once connected, mirroring the peers.
          if (connected) ...[
            SizedBox(height: 8.r),
            _buildStatusLine(theme, provider),
            ..._buildPairedTokenLines(theme, provider),
          ],
          SizedBox(height: 12.r),
          if (connected)
            ..._buildConnectedRows(theme)
          else
            ..._buildCredentialRows(theme),
        ],
      ),
    );
  }

  Widget _buildInfoBox(ThemeData theme) {
    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SvgPicture.asset(
                'assets/images/icons/romm-light.svg',
                width: 24.r,
                height: 24.r,
                colorFilter: ColorFilter.mode(
                  theme.colorScheme.primary,
                  BlendMode.srcIn,
                ),
                fit: BoxFit.contain,
              ),
              SizedBox(width: 12.r),
              Expanded(
                child: Text(
                  AppLocale.rommWhatIs.getString(context),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                    fontSize: 14.r,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 6.r),
          Text(
            AppLocale.rommDescription.getString(context),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              fontSize: 8.r,
            ),
            softWrap: true,
          ),
          SizedBox(height: 6.r),
          _buildInfoItem(
            theme,
            Symbols.grid_view_rounded,
            AppLocale.rommInfoBrowse.getString(context),
          ),
          _buildInfoItem(
            theme,
            Symbols.cloud_sync_rounded,
            AppLocale.rommInfoSaveSync.getString(context),
          ),
          _buildInfoItem(
            theme,
            Symbols.dns_rounded,
            AppLocale.rommInfoSelfHosted.getString(context),
          ),
          SizedBox(height: 6.r),
          RichText(
            softWrap: true,
            text: TextSpan(
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontSize: 8.r,
              ),
              children: [
                TextSpan(text: AppLocale.rommLearnMoreAt.getString(context)),
                TextSpan(
                  text: 'romm.app',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () async {
                      final url = Uri.parse('https://romm.app');
                      if (await canLaunchUrl(url)) {
                        await launchUrl(
                          url,
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoItem(ThemeData theme, IconData icon, String text) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8.r),
      child: Row(
        children: [
          Icon(
            icon,
            size: 12.r,
            color: theme.colorScheme.primary.withValues(alpha: 0.7),
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                fontSize: 8.r,
              ),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusLine(ThemeData theme, RommProvider provider) {
    final connected = provider.isConnected;
    final String text;
    if (connected) {
      text = AppLocale.rommConnectedAs
          .getString(context)
          .replaceAll('{user}', provider.username);
    } else if (provider.status == RommConnectionStatus.connecting) {
      text = AppLocale.rommConnecting.getString(context);
    } else {
      text = AppLocale.rommStatusDisconnected.getString(context);
    }
    return Row(
      children: [
        Icon(
          connected ? Symbols.cloud_done_rounded : Symbols.cloud_off_rounded,
          size: 16.r,
          color: connected
              ? Colors.greenAccent
              : theme.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
        SizedBox(width: 8.r),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
        ),
      ],
    );
  }

  /// The name and expiry of a token obtained by pairing, under the status
  /// line, so the user knows which RomM token this is and when it will stop
  /// working. Nothing for a pasted key or a password connection. Not
  /// focusable — captions for the status above them.
  List<Widget> _buildPairedTokenLines(ThemeData theme, RommProvider provider) {
    final name = provider.pairedTokenName;
    final expiresAt = provider.pairedTokenExpiresAt;
    final lines = <String>[
      if (name != null && name.isNotEmpty)
        AppLocale.rommPairedTokenName
            .getString(context)
            .replaceFirst('{name}', name),
      if (expiresAt != null)
        AppLocale.rommPairedTokenExpires
            .getString(context)
            .replaceFirst('{date}', rommTokenExpiryDate(expiresAt)),
    ];
    return [
      for (final line in lines)
        Padding(
          padding: EdgeInsets.only(top: 4.r, left: 24.r),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              line,
              style: TextStyle(
                fontSize: 9.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
    ];
  }

  List<Widget> _buildCredentialRows(ThemeData theme) {
    return [
      _buildFieldRow(
        theme,
        index: _slotIndex(RommConnectSlot.url),
        label: AppLocale.rommServerUrl.getString(context),
        hint: AppLocale.rommServerUrlHint.getString(context),
        controller: _urlController,
        focusNode: _urlFocus,
      ),
      SizedBox(height: 10.r),
      _buildAuthModeRow(theme),
      SizedBox(height: 10.r),
      ...switch (_authMode) {
        RommAuthMode.password => [
          _buildFieldRow(
            theme,
            index: _slotIndex(RommConnectSlot.username),
            label: AppLocale.username.getString(context),
            hint: AppLocale.enterUsername.getString(context),
            controller: _userController,
            focusNode: _userFocus,
          ),
          SizedBox(height: 8.r),
          _buildFieldRow(
            theme,
            index: _slotIndex(RommConnectSlot.password),
            label: AppLocale.password.getString(context),
            hint: AppLocale.enterPassword.getString(context),
            controller: _passwordController,
            focusNode: _passwordFocus,
            obscure: true,
          ),
        ],
        RommAuthMode.apiKey => [
          _buildFieldRow(
            theme,
            index: _slotIndex(RommConnectSlot.apiKey),
            label: AppLocale.rommApiKey.getString(context),
            hint: AppLocale.rommApiKeyHint.getString(context),
            controller: _apiKeyController,
            focusNode: _apiKeyFocus,
            obscure: true,
          ),
        ],
        RommAuthMode.pairCode => [
          // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On The Connect Screen"
          _buildFieldRow(
            theme,
            index: _slotIndex(RommConnectSlot.pairCode),
            label: AppLocale.rommPairCodeLabel.getString(context),
            hint: AppLocale.rommPairCodePlaceholder.getString(context),
            controller: _pairCodeController,
            focusNode: _pairCodeFocus,
            // Not a secret worth hiding: it is single use, dies in a minute,
            // and the user needs to see the 8 characters to check them.
            inputFormatters: const [RommPairCodeInputFormatter()],
            capitalization: TextCapitalization.characters,
            // Autocorrect and suggestions only ever fight a code.
            suggestions: false,
          ),
          SizedBox(height: 4.r),
          _buildPairCodeHint(theme),
          // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "QR Scan Where A Camera Exists"
          if (_canScanQr) ...[
            SizedBox(height: 8.r),
            _buildActionRow(
              theme,
              index: _slotIndex(RommConnectSlot.scanQr),
              icon: Symbols.qr_code_scanner_rounded,
              label: AppLocale.rommScanQrAction.getString(context),
              onTap: _scanQr,
            ),
          ],
        ],
      },
      SizedBox(height: 12.r),
      _buildConnectButton(theme),
    ];
  }

  /// Where the code comes from and how long it lives, under the code field.
  /// Not focusable — a caption for the field above it.
  Widget _buildPairCodeHint(ThemeData theme) {
    return Container(
      constraints: BoxConstraints(maxWidth: 220.r),
      padding: EdgeInsets.symmetric(horizontal: 4.r),
      child: Text(
        AppLocale.rommPairCodeHint.getString(context),
        style: TextStyle(
          fontSize: 8.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
        softWrap: true,
      ),
    );
  }

  /// Three-segment switch choosing how to authenticate. A advances it and a
  /// tap picks the segment tapped, so the gamepad needs one slot rather than
  /// three.
  // Governing: ADR-0007 (RomM pairing login), SPEC-0007 REQ "Pairing Mode On The Connect Screen"
  Widget _buildAuthModeRow(ThemeData theme) {
    final selected = isSelected(_authModeSlot);
    final scheme = theme.colorScheme;
    // A border participates in layout, so thickening it on selection would grow
    // this row and shove every field below it down — 6px on an AYN Thor, which
    // reads as the form twitching as the cursor passes through. The fields
    // opposite don't do that because their border sits inside a fixed-height
    // box; here the padding gives back exactly what the border takes, so the
    // row occupies the same space selected or not.
    final borderWidth = selected ? 2.r : 1.r;
    return Container(
      key: _itemKeys[_authModeSlot],
      constraints: BoxConstraints(maxWidth: 220.r),
      padding: EdgeInsets.all(4.r - borderWidth),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(
          color: selected
              ? scheme.primary
              : scheme.primary.withValues(alpha: 0.1),
          width: borderWidth,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.35),
                  blurRadius: 6.r,
                  spreadRadius: 1.r,
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          _buildAuthModeOption(
            theme,
            label: AppLocale.rommAuthPassword.getString(context),
            mode: RommAuthMode.password,
          ),
          _buildAuthModeOption(
            theme,
            label: AppLocale.rommAuthApiKey.getString(context),
            mode: RommAuthMode.apiKey,
          ),
          _buildAuthModeOption(
            theme,
            label: AppLocale.rommAuthModePairCode.getString(context),
            mode: RommAuthMode.pairCode,
          ),
        ],
      ),
    );
  }

  Widget _buildAuthModeOption(
    ThemeData theme, {
    required String label,
    required RommAuthMode mode,
  }) {
    final scheme = theme.colorScheme;
    final active = _authMode == mode;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          // A tap has a target, so it picks that segment; tapping the one
          // already active is a no-op the user never notices.
          onTap: _busy ? null : () => _applyAuthMode(mode),
          borderRadius: BorderRadius.circular(6.r),
          child: Container(
            padding: EdgeInsets.symmetric(vertical: 6.r),
            decoration: BoxDecoration(
              color: active ? scheme.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(6.r),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9.r,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
                color: active
                    ? scheme.onPrimary
                    : scheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildConnectedRows(ThemeData theme) {
    return [
      _buildActionRow(
        theme,
        index: 0,
        icon: Symbols.grid_view_rounded,
        label: AppLocale.rommBrowseLibrary.getString(context),
        primary: true,
        onTap: () => widget.onBrowse?.call(),
      ),
      SizedBox(height: 10.r),
      _buildActionRow(
        theme,
        index: 1,
        icon: Symbols.cloud_sync_rounded,
        label: AppLocale.rommUseForSaveSync.getString(context),
        primary: _isSaveSyncActive,
        toggleValue: _isSaveSyncActive,
        onTap: _toggleSaveSync,
      ),
      _buildSaveSyncCaption(theme),
      SizedBox(height: 10.r),
      _buildActionRow(
        theme,
        index: 2,
        icon: Symbols.logout_rounded,
        label: AppLocale.rommDisconnect.getString(context),
        onTap: _disconnect,
      ),
    ];
  }

  /// Caption under the save-sync toggle naming who currently owns save sync.
  ///
  /// Connecting a RomM server does not take save sync off a NeoSync account
  /// that is still signed in (see [_connect]), so a connected server plus
  /// downloads plus playtime can all look healthy while saves go elsewhere.
  /// Not focusable — it is a label for the row above it.
  Widget _buildSaveSyncCaption(ThemeData theme) {
    final scheme = theme.colorScheme;
    final owner = SyncManager.instance.active;
    // Same rule as the library header: a provider that owns save sync while
    // signed out is not handling it, so report that nothing is rather than
    // name it.
    final ownerSignedIn = owner != null && owner.isAuthenticated;
    final String text;
    if (_isSaveSyncActive) {
      text = AppLocale.rommSaveSyncActive.getString(context);
    } else if (!ownerSignedIn) {
      text = AppLocale.saveSyncNoneActive.getString(context);
    } else {
      text =
          '${AppLocale.saveSyncHandledBy.getString(context).replaceFirst('{provider}', owner.meta.name)} · '
          '${AppLocale.saveSyncSingleProvider.getString(context)}';
    }
    return Padding(
      padding: EdgeInsets.only(top: 4.r, left: 12.r, right: 12.r),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9.r,
          color: scheme.onSurface.withValues(alpha: 0.7),
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildFieldRow(
    ThemeData theme, {
    required int index,
    required String label,
    required String hint,
    required TextEditingController controller,
    required FocusNode focusNode,
    bool obscure = false,
    List<TextInputFormatter>? inputFormatters,
    TextCapitalization capitalization = TextCapitalization.none,
    bool suggestions = true,
  }) {
    final selected = isSelected(index);
    // Mirror the ScreenScraper / RetroAchievements field: a filled input with
    // the label floating inside it, constrained to 220.r, plus a soft primary
    // glow when the gamepad cursor is on this row.
    return Container(
      key: _itemKeys[index],
      constraints: BoxConstraints(maxWidth: 220.r),
      decoration: selected
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(8.r),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.35),
                  blurRadius: 6.r,
                  spreadRadius: 1.r,
                ),
              ],
            )
          : null,
      child: SizedBox(
        height: 32.r,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: obscure,
          enabled: !_busy,
          inputFormatters: inputFormatters,
          textCapitalization: capitalization,
          autocorrect: suggestions,
          enableSuggestions: suggestions,
          style: TextStyle(fontSize: 11.r),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              fontSize: 10.r,
            ),
            floatingLabelStyle: TextStyle(
              color: theme.colorScheme.primary,
              fontSize: 10.r,
              fontWeight: FontWeight.bold,
            ),
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 10.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            filled: true,
            fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8.r),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8.r),
              borderSide: BorderSide(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.primary.withValues(alpha: 0.1),
                width: selected ? 2.r : 1.r,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8.r),
              borderSide: BorderSide(
                color: theme.colorScheme.primary,
                width: 1.r,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Primary "Save & Connect" button, matching the RetroAchievements connect
  /// button (full-width elevated button with a gamepad-selection glow).
  Widget _buildConnectButton(ThemeData theme) {
    // Last slot either way, and which number that is depends on the mode.
    final index = submitSlot;
    final selected = isSelected(index);
    return Container(
      key: _itemKeys[index],
      constraints: BoxConstraints(maxWidth: 320.r),
      decoration: selected
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(8.r),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.5),
                  blurRadius: 8.r,
                  spreadRadius: 2.r,
                ),
              ],
            )
          : null,
      child: SizedBox(
        width: double.infinity,
        height: 32.r,
        child: ElevatedButton(
          onPressed: _busy ? null : _connect,
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.r),
            ),
            elevation: 0,
            padding: EdgeInsets.zero,
          ),
          child: _busy
              ? SizedBox(
                  width: 16.r,
                  height: 16.r,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.colorScheme.onPrimary,
                    ),
                  ),
                )
              : Text(
                  // Same label the RetroAchievements and ScreenScraper login
                  // buttons use, so the three forms read as one family.
                  AppLocale.login.getString(context),
                  style: TextStyle(fontSize: 14.r, fontWeight: FontWeight.bold),
                ),
        ),
      ),
    );
  }

  Widget _buildActionRow(
    ThemeData theme, {
    required int index,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
    bool? toggleValue,
  }) {
    final selected = isSelected(index);
    final scheme = theme.colorScheme;
    final borderColor = selected ? scheme.primary : scheme.outline;
    final bgColor = primary
        ? scheme.primary.withValues(alpha: selected ? 0.22 : 0.12)
        : scheme.onSurface.withValues(alpha: selected ? 0.10 : 0.04);
    return Container(
      key: _itemKeys[index],
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _busy ? null : onTap,
          borderRadius: BorderRadius.circular(8.r),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 12.r),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(
                color: borderColor,
                width: selected ? 2.r : 1.r,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 18.r, color: scheme.primary),
                SizedBox(width: 10.r),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.r,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                if (_busy) ...[
                  SizedBox(width: 10.r),
                  SizedBox(
                    width: 12.r,
                    height: 12.r,
                    child: CircularProgressIndicator(strokeWidth: 2.r),
                  ),
                ],
                if (toggleValue != null) ...[
                  const Spacer(),
                  Switch(
                    value: toggleValue,
                    onChanged: _busy ? null : (_) => onTap(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
