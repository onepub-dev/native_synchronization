// Windows reserves DWORD's largest value for an infinite wait.
const windowsInfiniteTimeout = 0xFFFFFFFF;
const windowsMaxFiniteTimeout = windowsInfiniteTimeout - 1;

/// Converts a timeout without overflow or accidentally producing INFINITE.
int windowsTimeoutMilliseconds(Duration? timeout) {
  if (timeout == null) {
    return windowsInfiniteTimeout;
  }
  if (timeout <= Duration.zero) {
    return 0;
  }
  if (timeout.inMilliseconds >= windowsMaxFiniteTimeout) {
    return windowsMaxFiniteTimeout;
  }
  return (timeout.inMicroseconds + 999) ~/ 1000;
}
