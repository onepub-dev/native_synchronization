// Import the ffi and `ffi` library from Dart
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';
import 'dart:io';

import 'bindings/pthread.dart';
import 'count_down.dart';

const int MACOS_ETIMEDOUT = 60;
const int MACOS_EBUSY = 16;

final DynamicLibrary pthreadLib =
    DynamicLibrary.open('/usr/lib/libSystem.B.dylib');

// Define the function signature for pthread_mutex_trylock
typedef PthreadMutexTrylockNative = Int32 Function(
    Pointer<pthread_mutex_t> mutex);
typedef PthreadMutexTrylock = int Function(Pointer<pthread_mutex_t> mutex);

// Get a reference to pthread_mutex_trylock
final PthreadMutexTrylock pthread_mutex_trylock = pthreadLib
    .lookup<NativeFunction<PthreadMutexTrylockNative>>('pthread_mutex_trylock')
    .asFunction();

// Dart implementation of macos_pthread_mutex_timedlock using FFI
int macos_pthread_mutex_timedlock(
    Pointer<pthread_mutex_t> mutex, Duration timeout) {
  final countDown = CountDown(timeout);
  _log('started lock, timeout: $timeout');

  int result;

  while ((result = pthread_mutex_trylock(mutex)) == MACOS_EBUSY) {
    final timeToSleep =
        countDown.minOfRemaining(const Duration(milliseconds: 100));
    _log(
        '''try failed, sleeping for: $timeToSleep remaining: ${countDown.remainingTime}''');
    sleep(timeToSleep);

    _log('remaining lock: ${countDown.remainingTime}');

    if (countDown.expired) {
      _log('returning timeoujt');
      return MACOS_ETIMEDOUT;
    }
  }

  _log('completed lock');

  return result;
}

void sleepTimespec(
    Pointer<pthread_timespec_t> ts, Pointer<pthread_timespec_t> slept) {
  sleep(Duration(seconds: ts.ref.tv_sec, microseconds: ts.ref.tv_nsec ~/ 1000));
  slept.ref.tv_sec = ts.ref.tv_sec;
  slept.ref.tv_nsec = ts.ref.tv_nsec;
}

void _log(dynamic args) {
  // Add line back into log lock progress.
  // print('${DateTime.now()} $args');
}
