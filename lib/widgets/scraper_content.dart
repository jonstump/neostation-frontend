import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/romm_provider.dart';
import '../screens/scraper_screen/new_scraper_options_screen.dart';
import '../screens/scraper_screen/scraper_login_screen.dart';
import '../services/screenscraper_service.dart';
import '../utils/scraper_entry_gate.dart';

class ScraperContent extends StatefulWidget {
  const ScraperContent({super.key});

  @override
  State<ScraperContent> createState() => _ScraperContentState();
}

class _ScraperContentState extends State<ScraperContent> {
  bool _hasCredentials = false;
  bool _isLoading = true;

  /// Set when a RomM-only user asks for the ScreenScraper login from the
  /// Account pane; cleared on success or when they back out.
  bool _loginRequested = false;

  @override
  void initState() {
    super.initState();
    _checkCredentials();
  }

  Future<void> _checkCredentials() async {
    final hasCredentials = await ScreenScraperService.hasSavedCredentials();
    if (mounted) {
      setState(() {
        _hasCredentials = hasCredentials;
        _isLoading = false;
      });
    }
  }

  void _onLoginSuccess() {
    setState(() {
      _hasCredentials = true;
      _loginRequested = false;
    });
  }

  void _onLogout() {
    setState(() {
      _hasCredentials = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // A connected RomM server is a scrape source on its own, so the options
    // (and the bulk scrape) must be reachable without ScreenScraper.
    // Governing: ADR-0006 (RomM-first scrape), SPEC-0006 REQ "Entry Point Consistency"
    final rommConnected = context.watch<RommProvider>().isConnected;
    final entry = scraperEntryFor(
      hasScreenscraperCredentials: _hasCredentials,
      rommConnected: rommConnected,
      loginRequested: _loginRequested,
    );

    switch (entry) {
      case ScraperEntry.options:
        return NewScraperOptionsScreen(
          onLogout: _onLogout,
          screenScraperLoggedIn: _hasCredentials,
          onLoginRequested: () => setState(() => _loginRequested = true),
        );
      case ScraperEntry.login:
        return ScraperLoginScreen(
          onLoginSuccess: _onLoginSuccess,
          onCancel: rommConnected
              ? () => setState(() => _loginRequested = false)
              : null,
        );
    }
  }
}
