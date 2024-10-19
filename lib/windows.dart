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
  final ConditionVariable _conditionVariable;

  static final _finalizer = Finalizer<Pointer<SRWLOCK>>((ptr) {
    malloc.free(ptr);
  });

  _WindowsMutex()
      : _impl = malloc.allocate(_WindowsMutex._sizeInBytes),
        _conditionVariable = _WindowsConditionVariable(),
        super._() {
    _initGetLastError();
    InitializeSRWLock(_impl);
    _finalizer.attach(this, _impl);
  }

  _WindowsMutex.fromAddress(int mutexAddress, this._conditionVariable)
      : _impl = Pointer.fromAddress(mutexAddress),
        super._();

  @override
  void _lock({Duration? timeout}) {
    log(() => 'taking lock ${_impl.address}');

    if (timeout != null) {
      if (!TryAcquireSRWLockExclusive(_impl)) {
        log(() => 'Failed to acquire lock, will wait ${_impl.address}');

        // Didn't get the lock immediately, so wait on the condition variable
        _conditionVariable.wait(this, timeout: timeout);
        log(() => 'wait returned ${_impl.address}');
      }
    } else {
      AcquireSRWLockExclusive(_impl);
    }
    log(() => 'lock acquired ${_impl.address}');
  }

  @override
  void _unlock() {
    log(() => 'releasing lock  ${_impl.address}');

    // Signal the condition variable to wake up any waiting threads
    _conditionVariable.notify();

    // Release the SRW lock
    ReleaseSRWLockExclusive(_impl);
    log(() => 'lock released ${_impl.address}');
  }

  @override
  Sendable<Mutex> get asSendable =>
      _SendableWindowsMutex(_impl.address, _conditionVariable);
}

class _SendableWindowsMutex implements Sendable<Mutex> {
  _SendableWindowsMutex(this.mutexAddress, ConditionVariable conditionVariable)
      : conditionVariableAddress = conditionVariable.asSendable;
  int mutexAddress;
  Sendable<ConditionVariable> conditionVariableAddress;

  @override
  Mutex materialize() {
    final conditionalVariable = conditionVariableAddress.materialize();
    return _WindowsMutex.fromAddress(mutexAddress, conditionalVariable);
  }
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
    log(() => 'Notifying condition variable ${_impl.address}');
    WakeConditionVariable(_impl);
  }

  static const ERROR_TIMEOUT = 0x5b4;
  @override
  void wait(covariant _WindowsMutex mutex, {Duration? timeout}) {
    const infinite = 0xFFFFFFFF;
    const exclusive = 0;
    log(() => 'waiting for lock with timeout: $timeout  ${_impl.address}');

    var result = 0;
    final timeoutMs = timeout?.inMilliseconds ?? infinite;

    result =
        SleepConditionVariableSRW(_impl, mutex._impl, timeoutMs, exclusive);

    log(() => 'wait returned with result: $result  ${_impl.address}');
    if (result == 0) {
      final error = GetLastError();
      if (error == ERROR_TIMEOUT) {
        log(() => 'throwing timeout from wait ${_impl.address}');
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
