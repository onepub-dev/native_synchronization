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

  _WindowsMutex.fromAddress(int mutexAddress)
      : _impl = Pointer.fromAddress(mutexAddress),
        super._();

  @override
  void _lock({Duration? timeout}) {
    log(() => 'taking lock ${_impl.address}');

    if (timeout != null) {
      final countDown = CountDown(timeout);
      // A condition-variable wait requires ownership of the SRW lock. Retry
      // acquisition instead, and only return after actually acquiring it.
      var acquired = TryAcquireSRWLockExclusive(_impl);
      while (!acquired) {
        if (countDown.expired) {
          throw TimeoutException('Timed out waiting for Mutex lock');
        }
        sleep(countDown.minOfRemaining(const Duration(milliseconds: 1)));
        if (countDown.expired) {
          throw TimeoutException('Timed out waiting for Mutex lock');
        }
        acquired = TryAcquireSRWLockExclusive(_impl);
      }
    } else {
      AcquireSRWLockExclusive(_impl);
    }
    log(() => 'lock acquired ${_impl.address}');
  }

  @override
  void _unlock() {
    log(() => 'releasing lock  ${_impl.address}');

    // Release the SRW lock
    ReleaseSRWLockExclusive(_impl);
    log(() => 'lock released ${_impl.address}');
  }

  @override
  Sendable<Mutex> get asSendable => _SendableWindowsMutex(_impl.address);
}

class _SendableWindowsMutex implements Sendable<Mutex> {
  _SendableWindowsMutex(this.mutexAddress);
  int mutexAddress;

  @override
  Mutex materialize() => _WindowsMutex.fromAddress(mutexAddress);
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
        super._() {
    _initGetLastError();
  }

  @override
  void notify() {
    log(() => 'Notifying condition variable ${_impl.address}');
    WakeConditionVariable(_impl);
  }

  @override
  void notifyAll() {
    WakeAllConditionVariable(_impl);
  }

  static const ERROR_TIMEOUT = 0x5b4;
  @override
  void wait(covariant _WindowsMutex mutex, {Duration? timeout}) {
    const infinite = 0xFFFFFFFF;
    const maxFinite = infinite - 1;
    const exclusive = 0;
    log(() => 'waiting for lock with timeout: $timeout  ${_impl.address}');

    final countDown = timeout == null ? null : CountDown(timeout);
    while (true) {
      final remaining = countDown?.remainingTime;
      // Round finite waits up to milliseconds and split very long waits so
      // they cannot wrap a DWORD or become the INFINITE sentinel.
      final int timeoutMs;
      if (remaining == null) {
        timeoutMs = infinite;
      } else if (remaining.inMilliseconds >= maxFinite) {
        timeoutMs = maxFinite;
      } else {
        timeoutMs = (remaining.inMicroseconds + 999) ~/ 1000;
      }
      final result =
          SleepConditionVariableSRW(_impl, mutex._impl, timeoutMs, exclusive);
      if (result != 0) {
        return;
      }
      // Capture before logging or another native call can replace last error.
      final error = GetLastError();
      if (error == ERROR_TIMEOUT) {
        if (countDown != null && !countDown.expired) {
          continue;
        }
        throw TimeoutException('Timeout waiting for condition variable');
      } else {
        throw StateError(
            'Failed to wait on a condition variable; Error $error');
      }
    }
  }

  @override
  Sendable<ConditionVariable> get asSendable =>
      _SendableWindowsConditionVariable(_impl.address);
}

class _SendableWindowsConditionVariable implements Sendable<ConditionVariable> {
  _SendableWindowsConditionVariable(this.conditionVariableAddress);
  int conditionVariableAddress;

  @override
  ConditionVariable materialize() =>
      _WindowsConditionVariable.fromAddress(conditionVariableAddress);
}
