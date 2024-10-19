// Import the ffi and `ffi` library from Dart
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart' as ffi;

import 'bindings/pthread.dart';

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
    Pointer<pthread_mutex_t> mutex, Pointer<pthread_timespec_t> absTimespec) {
  // Allocate and initialize remaining time struct
  final remaining = ffi.calloc<pthread_timespec_t>();
  remaining.ref.tv_sec = absTimespec.ref.tv_sec;
  remaining.ref.tv_nsec = absTimespec.ref.tv_nsec;

  int result;
  final ts = ffi.calloc<pthread_timespec_t>();
  final slept = ffi.calloc<pthread_timespec_t>();

  while ((result = pthread_mutex_trylock(mutex)) == 16) {
    // EBUSY is usually 16 on macOS
    ts.ref.tv_sec = 0;
    ts.ref.tv_nsec = (remaining.ref.tv_sec > 0
        ? 10000000
        : (remaining.ref.tv_nsec < 10000000
            ? remaining.ref.tv_nsec
            : 10000000));

    // Sleep for the specified time
    sleepTimespec(ts, slept);

    // Update remaining time
    ts.ref.tv_nsec -= slept.ref.tv_nsec;
    if (ts.ref.tv_nsec <= remaining.ref.tv_nsec) {
      remaining.ref.tv_nsec -= ts.ref.tv_nsec;
    } else {
      remaining.ref.tv_sec--;
      remaining.ref.tv_nsec =
          1000000 - (ts.ref.tv_nsec - remaining.ref.tv_nsec);
    }

    if (remaining.ref.tv_sec < 0 ||
        (remaining.ref.tv_sec == 0 && remaining.ref.tv_nsec <= 0)) {
      ffi.calloc.free(remaining);
      ffi.calloc.free(ts);
      ffi.calloc.free(slept);
      return 60; // ETIMEDOUT is usually 60 on macOS
    }
  }

  // Free allocated memory
  ffi.calloc.free(remaining);
  ffi.calloc.free(ts);
  ffi.calloc.free(slept);

  return result;
}

void sleepTimespec(
    Pointer<pthread_timespec_t> ts, Pointer<pthread_timespec_t> slept) {
  sleep(Duration(seconds: ts.ref.tv_sec, microseconds: ts.ref.tv_nsec ~/ 1000));
  slept.ref.tv_sec = ts.ref.tv_sec;
  slept.ref.tv_nsec = ts.ref.tv_nsec;
}
