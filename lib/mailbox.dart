// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'exceptions.dart';
import 'primitives.dart';
import 'sendable.dart';
import 'src/count_down.dart';

final class _MailboxRepr extends Struct {
  external Pointer<Uint8> buffer;

  @Int32()
  external int bufferLength;

  /// Whether the mailbox is open or closed (0 = closed, 1 = open)
  @Int32()
  external int open;

  /// the number of items in the mailbox (0 or 1)
  @Int32()
  external int count;

  /// used to assert for memory corruption.
  @Uint32()
  external int magic; // init to 0xC0FFEE01
}

class _SendableMailbox {
  final int address;
  final Sendable<Mutex> mutex;
  final Sendable<ConditionVariable> condVar;

  _SendableMailbox(
      {required this.address, required this.mutex, required this.condVar});
}

/// Mailbox communication primitive.
///
/// This synchronization primitive allows a single producer to send messages
/// to one or more consumers. Producer uses [put] to place a message into
/// a mailbox which consumers can then [take] out.
///
/// [Mailbox] object can not be directly sent to other isolates via a
/// `SendPort`, but it can be converted to a `Sendable<Mailbox>` via
/// `asSendable` getter.
///
/// !!! WARNING !!!
/// The [Mailbox] object is owned by the isolate that created it.
/// You need to be certain that all producers and consumers have stopped before
/// dereferencing the mailbox in the owning isolate, otherwise
/// you may corrupt memory.
class Mailbox {
  // magic number to detect memory corruption.
  static const _magic = 0xC0FFEE01;

  final Pointer<_MailboxRepr> _mailbox;
  final Mutex _mutex;
  final ConditionVariable _condVar;

  static const _stateOpen = 1;
  static const _stateClosed = 0;

  static final finalizer = Finalizer((mailbox) {
    final p = mailbox! as Pointer<_MailboxRepr>;

    if (p.ref.buffer != nullptr) {
      calloc.free(p.ref.buffer);
    }
    calloc.free(p);
  });

  Mailbox()
      : _mailbox = calloc<_MailboxRepr>(),
        _mutex = Mutex(),
        _condVar = ConditionVariable() {
    _mailbox.ref
      ..open = _stateOpen
      ..count = 0
      ..buffer = nullptr
      ..bufferLength = 0
      ..magic = _magic; // canary for memory corruption detection
    finalizer.attach(this, _mailbox);
  }

  Mailbox._fromSendable(_SendableMailbox sendable)
      : _mailbox = Pointer.fromAddress(sendable.address),
        _mutex = sendable.mutex.materialize(),
        _condVar = sendable.condVar.materialize() {
    assert(_mailbox.ref.magic == _magic, 'Mailbox memory corrupted/UAF');
  }

  /// Place a message into the mailbox if has space for it.

  /// If mailbox already contains a message the [put] will
  /// throw a [MailBoxFullException] exception.
  ///  If  mailbox is closed then [put] will
  /// throw [MailBoxClosedException].
  void put(Uint8List message) {
    _mutex.runLocked(() {
      assert(_mailbox.ref.magic == _magic, 'Mailbox memory corrupted/UAF');
      if (_isClosed) {
        throw MailBoxClosedException();
      }

      if (_isFull) {
        throw MailBoxFullException();
      }
      final buffer = message.isEmpty ? nullptr : _toBuffer(message);
      _mailbox.ref.count = 1;
      _mailbox.ref.buffer = buffer;
      _mailbox.ref.bufferLength = message.length;
      _condVar.notify();
    });
  }

  /// Internal getters for use within locked sections.
  bool get _isOpen => _mailbox.ref.open == _stateOpen;

  bool get _isClosed => !_isOpen;

  /// The number of messages currently in the mailbox (0 or 1).
  int get _count => _mailbox.ref.count;

  bool get _isFull => _count == 1;
  bool get _isEmpty => _count == 0;

  /// Returns true if the mailbox is open.
  bool isOpen() => _mutex.runLocked(() => _isOpen);

  bool isClosed() => !isOpen();

  /// The number of messages currently in the mailbox (0 or 1).
  int get count => _mutex.runLocked(() => _count);

  bool isFull() => count == 1;
  bool isEmpty() => count == 0;

  /// Close a mailbox.
  ///
  /// If the mailbox has a message we leave the message intact
  /// so that it can be read by the consumer.
  void close() => _mutex.runLocked(() {
        assert(_mailbox.ref.magic == _magic, 'Mailbox memory corrupted/UAF');

        _mailbox.ref.open = _stateClosed;

        _condVar.notify();
      });

  /// Take a message from the mailbox.
  ///
  /// If the mailbox is empty this will synchronously block until message
  /// is available or a timeout occurs.
  /// If the mailbox is closed then [take] will throw [MailBoxClosedException].
  ///
  /// If not [timeout] is provided then this method will block
  /// indefinitely.
  ///
  /// If [timeout] is provided then this will block for at most [timeout].
  /// If the timeout expires before a message is available then this will
  /// throw a [TimeoutException].
  /// The [timeout] supports a resolution of microseconds.
  Uint8List take({Duration? timeout}) {
    if (timeout != null) {
      return _takeTimed(timeout);
    } else {
      return _take();
    }
  }

  Uint8List _takeTimed(Duration timeout) {
    final countDown = CountDown(timeout);

    return _mutex.runLocked(
      timeout: timeout,
      () {
        assert(_mailbox.ref.magic == _magic, 'Mailbox memory corrupted/UAF');

        /// Wait for an item to be posted into the mailbox.
        while (_isOpen && _isEmpty) {
          _condVar.wait(_mutex, timeout: countDown.remainingTime);
        }
        // we allow take to complete if there is a message even if
        // the mailbox is closed.
        // The next attempt to take on a closed and empty mailbox will throw.
        if (_isClosed && _isEmpty) {
          throw MailBoxClosedException();
        }
        return _takeAndFree();
      },
    );
  }

  Uint8List _take() => _mutex.runLocked(() {
        assert(_mailbox.ref.magic == _magic, 'Mailbox memory corrupted/UAF');
        while (_isOpen && _isEmpty) {
          _condVar.wait(_mutex);
        }

        // we allow take to complete if there is a message even if
        // the mailbox is closed.
        // The next attempt to take on a closed and empty mailbox will throw.
        if (_isClosed && _isEmpty) {
          throw MailBoxClosedException();
        }

        return _takeAndFree();
      });

  /// Takes the message from the mailbox, copies it into
  /// Dart GC memory and frees the native memory that was holding
  /// the message.
  Uint8List _takeAndFree() {
    final result = _toDartList(_mailbox.ref.buffer, _mailbox.ref.bufferLength);

    if (_mailbox.ref.buffer != nullptr) {
      malloc.free(_mailbox.ref.buffer);
    }
    _mailbox.ref.count = 0;
    _mailbox.ref.buffer = nullptr;
    _mailbox.ref.bufferLength = 0;

    return result;
  }

  static final _emptyResponse = Uint8List(0);

  /// Always return a Dart-owned Uint8List (never native-backed).
  static Uint8List _toDartList(Pointer<Uint8> buffer, int length) {
    // Fast path: empty payload → return a shared empty list.
    if (length == 0) {
      return _emptyResponse;
    }

    // Defensive checks.
    assert(buffer != nullptr, 'Non-zero length with nullptr buffer');
    assert(length >= 0, 'Negative length');

    // Copy native bytes into a Dart-heap Uint8List.
    final out = Uint8List(length)
      ..setRange(0, length, buffer.asTypedList(length));

    return out;
  }

  static Pointer<Uint8> _toBuffer(Uint8List list) {
    final buffer = malloc.allocate<Uint8>(list.length);
    buffer.asTypedList(list.length).setRange(0, list.length, list);
    return buffer;
  }

  Sendable<Mailbox> get asSendable => Sendable.wrap(
      Mailbox._fromSendable,
      _SendableMailbox(
          address: _mailbox.address,
          mutex: _mutex.asSendable,
          condVar: _condVar.asSendable));
}
