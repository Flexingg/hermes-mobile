/// Cadence for one background poll: normal, then 30 s, then a 60 s cap; the
/// first success puts it back to normal. Pure so it is tested without a clock.
///
/// A bridge that is down answers nothing for the full 15 s request timeout, so
/// polling it every 5-15 s only stacks up failures. Slowing down while it is
/// unreachable costs one late refresh when it comes back; not slowing down cost
/// a banner every few seconds.
class PollSchedule {
  static const Duration slow = Duration(seconds: 30);
  static const Duration cap = Duration(seconds: 60);

  final Duration normal;
  Duration _interval;

  PollSchedule(this.normal) : _interval = normal;

  /// The cadence the page should reschedule with right now.
  Duration get interval => _interval;

  /// True while failures have pushed the cadence past [normal].
  bool get backedOff => _interval > normal;

  /// normal -> [slow] -> [cap], and it stays at [cap].
  void onFailure() {
    _interval = _interval < slow ? slow : cap;
    // Backing off must never poll faster than the normal cadence.
    if (_interval < normal) _interval = normal;
  }

  /// The bridge answered: back to the normal cadence.
  void onSuccess() => _interval = normal;

  /// The user asked (Retry, pull-to-refresh): back to the normal cadence.
  void reset() => _interval = normal;
}
