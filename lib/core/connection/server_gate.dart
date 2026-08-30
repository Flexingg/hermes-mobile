import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../state/app_state.dart';
import '../../features/connection/connect_server_page.dart';

/// Gates the whole app behind a real server connection. Until [AppState] has
/// successfully reached a server, the connect screen is shown and no data is
/// displayed.
class ServerGate extends StatelessWidget {
  final Widget child;
  const ServerGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.connected) {
      return const ConnectServerPage();
    }
    return child;
  }
}
