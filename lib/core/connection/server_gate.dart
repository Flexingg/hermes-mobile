import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../features/connection/connect_server_page.dart';

/// Gates the whole app behind a real server connection. Until [AppState] has
/// successfully reached a server, the connect screen is shown and no data is
/// displayed.
///
/// Losing a bridge the app was already using is not "no server": the shell
/// stays, with the data it has and the offline strip's Retry, rather than
/// ejecting the user to onboarding every time the Wi-Fi blinks.
class ServerGate extends StatelessWidget {
  final Widget child;
  const ServerGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.connected && !(state.offline && state.config.hasServer)) {
      return const ConnectServerPage();
    }
    return child;
  }
}
