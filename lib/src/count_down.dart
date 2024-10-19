class CountDown {
  CountDown(this.timeout);
  Duration timeout;
  DateTime start = DateTime.now();

  Duration get remainingTime {
    var remainingTime = timeout - (DateTime.now().difference(start));
    if (remainingTime < Duration.zero) {
      remainingTime = Duration.zero;
    }
    return remainingTime;
  }

  bool get expired => remainingTime <= Duration.zero;

  /// Returns the max of [duration] and [remainingTime].
  /// Use this method to calucate how long to sleep
  /// so you don't overshoot the remaining time.
  Duration minOfRemaining(Duration duration) {
    /// ensure that remaingTime isn't recalculated
    /// during this call.
    final _remaining = remainingTime;
    return _remaining < duration ? _remaining : duration;
  }
}
