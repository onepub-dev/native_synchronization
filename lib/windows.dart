// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// ignore_for_file: constant_identifier_names

part of 'primitives.dart';

bool _lastErrorInitialised = false;

/// Calls to GetLastError via ffi are a little fraught as
/// there are a number of circumstances where the dart vm
/// can make a windows call between our call to an api
/// and our call to GetLastError.
/// Specifically:
/// 1) GetLastError can be lazily linked so the first call
/// results in a call to LoadLibrary.
/// 2) A GC can occur between a windows call and a call to
/// GetLastError.
/// So calling _initLastError resolves 1) but not 2),
void _initGetLastError() {
  if (!_lastErrorInitialised) {
    GetLastError();
    _lastErrorInitialised = true;
  }
}

class _WindowsMutex extends Mutex {
  static const _sizeInBytes = 8; // `sizeof(SRWLOCK)`

  final Pointer<SRWLOCK> _impl;

  static final _finalizer = Finalizer<Pointer<SRWLOCK>>((ptr) {
    malloc.free(ptr);
  });

  _WindowsMutex()
      : _impl = malloc.allocate(_WindowsMutex._sizeInBytes),
        super._() {
    _initGetLastError();
    InitializeSRWLock(_impl);
    _finalizer.attach(this, _impl);
  }

  _WindowsMutex.fromAddress(int address)
      : _impl = Pointer.fromAddress(address),
        super._();

  @override
  void _lock({Duration? timeout}) {
    _log('taking lock');

    if (timeout != null) {
      if (!TryAcquireSRWLockExclusive(_impl)) {
        _log('Failed to acquire lock will wait');
        // we didn't get the lock so sleep on it.
        _WindowsConditionVariable().wait(this, timeout: timeout);
        _log('wait returned');
      }
    } else {
      AcquireSRWLockExclusive(_impl);
    }
  }

  @override
  void _unlock() {
    _log('releasing lock');
    ReleaseSRWLockExclusive(_impl);
  }

  @override
  int get _address => _impl.address;
}

class _WindowsConditionVariable extends ConditionVariable {
  static const _sizeInBytes = 8; // `sizeof(CONDITION_VARIABLE)`

  final Pointer<CONDITION_VARIABLE> _impl;

  static final _finalizer = Finalizer<Pointer<CONDITION_VARIABLE>>((ptr) {
    malloc.free(ptr);
  });

  _WindowsConditionVariable()
      : _impl = malloc.allocate(_WindowsConditionVariable._sizeInBytes),
        super._() {
    _initGetLastError();
    InitializeConditionVariable(_impl);
    _finalizer.attach(this, _impl);
  }

  _WindowsConditionVariable.fromAddress(int address)
      : _impl = Pointer.fromAddress(address),
        super._();

  @override
  void notify() {
    WakeConditionVariable(_impl);
  }

  static const ERROR_TIMEOUT = 0x5b4;
  @override
  void wait(covariant _WindowsMutex mutex, {Duration? timeout}) {
    const infinite = 0xFFFFFFFF;
    const exclusive = 0;
    _log('waiting for lock $timeout');

    var result = 0;
    try {
      print('timeout ms ${timeout!.inMilliseconds}');
      result = SleepConditionVariableSRW(
          _impl,
          mutex._impl,
          timeout == null ? infinite : 9000,

          //  timeout.inMilliseconds,

          exclusive);
    } catch (e) {
      print(e);
    }

    _log('waiting returned with $result');
    if (result == 0) {
      final error = GetLastError();
      if (error == ERROR_TIMEOUT) {
        _log('throwing timeout from wait');
        throw TimeoutException('Timeout waiting for conditional variable');
      } else {
        throw StateError(
            'Failed to wait on a condition variable; Error $error');
      }
    }
  }

  @override
  int get _address => _impl.address;
}

void _log(dynamic args) {
  // Add line back into log lock progress.
  print('${DateTime.now()} $args');
}
