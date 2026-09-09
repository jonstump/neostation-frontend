import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/screens/search_screen/remote_search_source.dart';

/// The search screen's RomM rows come from the persisted catalog while the
/// server is known to be unreachable, and from the server otherwise — a cold
/// start with nothing asked yet included, since a request is how it finds
/// out.
///
/// Governing: ADR-0020 (unified library), SPEC-0019 REQ "Secondary Display
/// And Search"
void main() {
  test('offline reads the catalog', () {
    expect(
      remoteSearchSourceFor(RommReachability.offline),
      RemoteSearchSource.catalog,
    );
  });

  test('online and unknown ask the server', () {
    expect(
      remoteSearchSourceFor(RommReachability.online),
      RemoteSearchSource.server,
    );
    expect(
      remoteSearchSourceFor(RommReachability.unknown),
      RemoteSearchSource.server,
    );
  });
}
