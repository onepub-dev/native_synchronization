import 'dart:developer' as developer;

bool _isLoggingEnabled = false; // Toggle this to enable/disable logging

/// The logger callback function.
/// It takes a closure [messageCallback] that
/// returns the log message if logging is enabled.
void log(String Function() messageCallback,
    {int level = 0, Object? error, StackTrace? stackTrace}) {
  if (_isLoggingEnabled) {
    developer.log(
      messageCallback(),
      level: level,
      error: error,
      stackTrace: stackTrace,
    );
  }
}
