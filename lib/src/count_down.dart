class CountDown {
  CountDown(this.timeout);
  Duration timeout;
  final Stopwatch _stopwatch = Stopwatch()..start();

  Duration get remainingTime {
    final elapsed = _stopwatch.elapsed;
    if (timeout <= Duration.zero || elapsed >= timeout) {
      return Duration.zero;
    }
    return timeout - elapsed;
  }

  bool get expired => remainingTime <= Duration.zero;

  /// Returns the minimum of [duration] and [remainingTime].
  /// Use this method to calculate how long to sleep
  /// so you don't overshoot the remaining time.
  Duration minOfRemaining(Duration duration) {
    /// ensure that remaingTime isn't recalculated
    /// during this call.
    final _remaining = remainingTime;
    return _remaining < duration ? _remaining : duration;
  }
}
