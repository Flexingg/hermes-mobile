import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import '../config/app_config.dart';

/// Wraps the app in a biometric lock screen when the vault is enabled.
/// On launch it shows a themed lock; unlocking requires fingerprint / face /
/// device credentials via [LocalAuthentication].
class VaultGate extends StatefulWidget {
  final Widget child;
  VaultGate({super.key, required this.child});

  @override
  State<VaultGate> createState() => _VaultGateState();
}

class _VaultGateState extends State<VaultGate> {
  final _auth = LocalAuthentication();
  bool _unlocked = false;
  bool _supported = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final cfg = context.read<AppConfig>();
    var supported = false;
    try {
      supported = await _auth.isDeviceSupported();
      await _auth.canCheckBiometrics;
    } catch (_) {
      supported = false;
    }
    if (mounted) {
      setState(() {
        _supported = supported;
        // Vault disabled -> skip the lock entirely.
        _unlocked = !cfg.vaultEnabled;
      });
    }
  }

  Future<void> _unlock() async {
    setState(() => _error = null);
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock Hermes to access your chats and controller',
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
      if (mounted) setState(() => _unlocked = ok);
      if (!ok && mounted) {
        setState(() => _error = 'Authentication failed — try again.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Biometrics unavailable: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = context.watch<AppConfig>();
    // If vault got disabled, reflect immediately.
    if (!cfg.vaultEnabled) return widget.child;
    if (_unlocked) return widget.child;
    return _LockScreen(
      supported: _supported,
      error: _error,
      onUnlock: _unlock,
    );
  }
}

class _LockScreen extends StatelessWidget {
  final bool supported;
  final String? error;
  final VoidCallback onUnlock;
  const _LockScreen({
    required this.supported,
    required this.error,
    required this.onUnlock,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.lock_outline,
                    size: 48, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(height: 24),
              Text('Hermes is locked',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                supported
                    ? 'Unlock with your fingerprint, face, or device PIN.'
                    : 'Biometric auth isn\'t available on this device.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.error)),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: supported ? onUnlock : null,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Unlock'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
