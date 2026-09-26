import 'dart:convert';

/// A failed bridge call, carrying the server's own explanation.
///
/// Before this, every request threw `Exception('GET $path → 401')`: the bridge's
/// careful `{"detail": "..."}` bodies were thrown away, and the UI showed
/// nothing at all (`catch (_) {}`). A dead route (404), a bad token (401) and a
/// dead socket were indistinguishable.
class ApiFailure implements Exception {
  /// HTTP verb, or `WS` for a WebSocket that never opened.
  final String method;

  /// Path that failed, e.g. `/api/v1/cron`.
  final String path;

  /// HTTP status, or 0 when no response was received at all.
  final int status;

  /// The server's message (`detail`/`error`), or the raw body when it isn't JSON.
  final String? detail;

  ApiFailure(this.method, this.path, this.status, this.detail);

  /// The credential was refused — re-pair, don't retry.
  bool get isAuth => status == 401 || status == 403;

  /// The bridge has no such route/method — the app is calling something that
  /// does not exist (this is the class of bug that shipped 9 phantom calls).
  bool get isMissingRoute => status == 404 || status == 405 || status == 501;

  /// Nothing answered (timeout, DNS, refused, TLS) — retrying can help.
  bool get isOffline => status == 0;

  @override
  String toString() {
    final d = (detail ?? '').trim();
    final suffix = d.isEmpty ? '' : ' — $d';
    final statusText = status == 0 ? 'no response' : '$status';
    return '$method $path failed ($statusText)$suffix';
  }
}

/// Pull a human-readable message out of an error body.
///
/// Handles the bridge's `{"detail": "..."}`, its coach endpoints'
/// `{"error": "..."}`, and FastAPI's 422 `{"detail": [{"msg": ...}]}` list form.
/// Falls back to the raw body (truncated) so a non-JSON error is still visible.
String? parseApiDetail(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) {
      final v = decoded['detail'] ?? decoded['error'] ?? decoded['message'];
      if (v == null) return null;
      if (v is List) {
        if (v.isEmpty) return null;
        final first = v.first;
        if (first is Map) {
          return (first['msg'] ?? first['detail'] ?? first).toString();
        }
        return first.toString();
      }
      final s = v.toString();
      return s.isEmpty ? null : s;
    }
    if (decoded is String) return decoded;
  } catch (_) {
    // Not JSON — fall through to the raw body.
  }
  return trimmed.length > 300 ? '${trimmed.substring(0, 300)}…' : trimmed;
}
