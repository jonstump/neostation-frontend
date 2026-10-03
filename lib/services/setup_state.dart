/// SharedPreferences key of the "first-run setup finished" flag.
///
/// Lives in a service-level file so services (the in-app reset) and the
/// setup widgets share one constant without a service importing a widget.
const String kSetupCompletedKey = 'setup_completed_prefs';
