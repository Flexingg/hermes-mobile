import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

/// A Mercury/Hermes bridge discovered on the local network via mDNS.
class DiscoveredBridge {
  final String name;
  final String baseUrl;
  final List<String> hostAddresses;
  final String? hostname;
  final int port;

  const DiscoveredBridge({
    required this.name,
    required this.baseUrl,
    required this.hostAddresses,
    required this.hostname,
    required this.port,
  });
}

/// Discovers Mercury bridges advertising `_mercury._tcp` on the local network.
///
/// Wraps bonsoir (Android NSD / Apple Bonjour) behind a simple one-shot API so
/// the connect screen can offer "Search your network" instead of only typing a
/// hardcoded IP. mDNS only sees devices on the *same LAN* — it does not cross
/// VPN/Tailscale boundaries, so manual entry remains the way to reach a remote
/// bridge.
class BridgeDiscovery {
  static const String _type = '_mercury._tcp';
  static const String _scheme = 'http';

  /// Browse for bridges for [timeout], returning everything resolved.
  ///
  /// Swallows bonsoir init errors (e.g. platform unsupported) and returns an
  /// empty list rather than throwing, so a failed scan is just "no bridges
  /// found" in the UI.
  static Future<List<DiscoveredBridge>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final found = <String, BonsoirService>{};

    BonsoirDiscovery? discovery;
    StreamSubscription<BonsoirDiscoveryEvent>? sub;
    try {
      final d = BonsoirDiscovery(type: _type);
      discovery = d;
      final resolver = d.serviceResolver;
      await d.initialize();

      sub = d.eventStream?.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent():
            // Ask NSD to resolve this service to an address/port.
            event.service.resolve(resolver);
            break;
          case BonsoirDiscoveryServiceResolvedEvent():
            found[event.service.name] = event.service;
            break;
          case BonsoirDiscoveryServiceUpdatedEvent():
            found[event.service.name] = event.service;
            break;
          case BonsoirDiscoveryServiceLostEvent():
            found.remove(event.service.name);
            break;
          default:
            break;
        }
      });

      await d.start();
      await Future<void>.delayed(timeout);
      await d.stop();
    } catch (_) {
      // Unsupported platform or transient failure — treat as "nothing found".
    } finally {
      await sub?.cancel();
      try {
        await discovery?.stop();
      } catch (_) {}
    }

    return found.values.map(_toDiscovered).toList();
  }

  static DiscoveredBridge _toDiscovered(BonsoirService s) {
    final address = _preferredAddress(s.hostAddresses);
    final port = s.port > 0 ? s.port : 9130;
    final baseUrl = Uri(
      scheme: _scheme,
      host: address ?? s.hostname ?? 'localhost',
      port: port,
    ).toString();
    return DiscoveredBridge(
      name: s.name,
      baseUrl: baseUrl,
      hostAddresses: s.hostAddresses,
      hostname: s.hostname,
      port: port,
    );
  }

  /// Pick an IPv4 address when available (the host's resolvable LAN IP); mDNS
  /// may otherwise surface IPv6 link-local (`fe80::…`) entries that a phone
  /// cannot open directly.
  static String? _preferredAddress(List<String> addresses) {
    if (addresses.isEmpty) return null;
    // IPv4: only dots and digits (no ':'), not loopback.
    for (final a in addresses) {
      if (a.contains('.') && !a.contains(':') && !a.startsWith('127.')) {
        return a;
      }
    }
    // Otherwise prefer a non-link-local entry (bracket for IPv6 safety later).
    for (final a in addresses) {
      if (!a.startsWith('fe80') && a != '::1') {
        return a.contains(':') ? '[$a]' : a;
      }
    }
    return addresses.first.contains(':') ? '[${addresses.first}]' : addresses.first;
  }
}
