// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:native_synchronization_temp/native_synchronization.dart';
import 'package:test/test.dart';

void main() {
  Future<String> startHelperIsolate(Sendable<Mailbox> sendableMailbox) async =>
      Isolate.run(() {
        sleep(const Duration(milliseconds: 500));
        sendableMailbox.materialize().put(Uint8List(42)..[41] = 42);
        return 'success';
      });

  test('mailbox', () async {
    final mailbox = Mailbox();
    final helperResult = startHelperIsolate(mailbox.asSendable);
    final value = mailbox.take();
    expect(value, isA<Uint8List>());
    expect(value.length, equals(42));
    expect(value[41], equals(42));
    expect(await helperResult, equals('success'));
  });

  test('mailbox - timeout', () async {
    final mailbox = Mailbox();
    expect(() => mailbox.take(timeout: const Duration(seconds: 2)),
        throwsA(isA<TimeoutException>()));
    final helperResult = startHelperIsolate(mailbox.asSendable);
    final value = mailbox.take(timeout: const Duration(seconds: 2));
    expect(value, isA<Uint8List>());
    expect(value.length, equals(42));
    expect(value[41], equals(42));
    expect(await helperResult, equals('success'));
  });

  Future<String> startHelperIsolateClose(Sendable<Mailbox> sendableMailbox) =>
      // ignore: discarded_futures
      Isolate.run(() {
        sleep(const Duration(milliseconds: 500));
        final mailbox = sendableMailbox.materialize();
        try {
          // The first take should succeed as we can take
          // from a closed box if there is a message.
          // The second take will fail as we are trying
          // to get a message from a closed and empty box.
          mailbox
            ..take()
            ..take();
          // ignore: avoid_catches_without_on_clauses
        } catch (_) {
          return 'success';
        }
        return 'failed';
      });

  test('mailbox close', () async {
    final mailbox = Mailbox()
      ..put(Uint8List(42)..[41] = 42)
      ..close();
    final helperResult = startHelperIsolateClose(mailbox.asSendable);
    expect(await helperResult, equals('success'));
  });

  /// Helpers
  Future<void> putAfter(
          Sendable<Mailbox> sendableMailbox, Duration d, Uint8List data) =>
      Isolate.run(() async {
        await Future<void>.delayed(d);
        sendableMailbox.materialize().put(data);
      });

  Future<void> closeAfter(Sendable<Mailbox> sendableMailbox, Duration d) =>
      Isolate.run(() async {
        await Future<void>.delayed(d);
        sendableMailbox.materialize().close();
      });

  test('put then take zero-length payload', () {
    final m = Mailbox()..put(Uint8List(0));
    final v = m.take();
    expect(v, isA<Uint8List>());
    expect(v.length, 0);
  });

  test('second put when full throws MailBoxFullException', () {
    final m = Mailbox()..put(Uint8List.fromList([1, 2, 3]));
    expect(() => m.put(Uint8List.fromList([9])),
        throwsA(isA<MailBoxFullException>()));
  });

  test('put after close throws MailBoxClosedException', () {
    final m = Mailbox()..close();
    expect(() => m.put(Uint8List(1)), throwsA(isA<MailBoxClosedException>()));
  });

  test('close preserves pending message for one take, then closed thereafter',
      () {
    final m = Mailbox()
      ..put(Uint8List.fromList([7, 7, 7]))
      ..close();

    // First take succeeds because a message is pending.
    final first = m.take();
    expect(first, [7, 7, 7]);

    // Next take should see closed+empty immediately.
    expect(() => m.take(timeout: const Duration(milliseconds: 50)),
        throwsA(isA<MailBoxClosedException>()));
  });

  test('''
take(timeout) throws TimeoutException when open+empty and no producer arrives''',
      () {
    final m = Mailbox();
    expect(() => m.take(timeout: const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()));
  });

  test('take(timeout) succeeds if a producer arrives before deadline',
      () async {
    final m = Mailbox();
    unawaited(putAfter(m.asSendable, const Duration(milliseconds: 20),
        Uint8List.fromList([1])));
    final v = m.take(timeout: const Duration(milliseconds: 200));
    expect(v, [1]);
  });

  test('''
take on open mailbox returns promptly after close with no pending message (closed+empty)''',
      () async {
    final m = Mailbox();
    unawaited(closeAfter(m.asSendable, const Duration(milliseconds: 20)));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(() => m.take(timeout: const Duration(milliseconds: 50)),
        throwsA(isA<MailBoxClosedException>()));
  });

  test('multiple consumers: only one gets the payload', () async {
    final m = Mailbox();
    final sendable = m.asSendable;
    // Start two takers with timeouts; only one should succeed
    final c1 = Isolate.run(() async => sendable
        .materialize()
        .take(timeout: const Duration(milliseconds: 200)));
    final c2 = Isolate.run(() async => sendable
        .materialize()
        .take(timeout: const Duration(milliseconds: 200)));
    // Producer posts a single payload
    m.put(Uint8List.fromList([42]));
    final results = await Future.wait<List<int>>([
      c1.then((v) => v, onError: (e) => <int>[]),
      c2.then((v) => v, onError: (e) => <int>[]),
    ]);
    // Exactly one consumer received [42]
    final got = results.where((r) => r.isNotEmpty).toList();
    expect(got.length, 1);
    expect(got.single, [42]);
  });

  test('producer flood: repeated tryPut pattern retries until consumer drains',
      () async {
    final m = Mailbox();

    // Simulate a non-blocking producer loop (similar to your postMessage retry)
    Future<void> producer() async {
      var attempts = 0;
      while (attempts < 50) {
        try {
          m.put(Uint8List.fromList([attempts]));
          return;
        } on MailBoxFullException {
          attempts++;
          // short backoff
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }
      fail('Producer never succeeded after 50 attempts');
    }

    // Start producer then drain after a short delay
    final p = producer();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final v1 = m.take(timeout: const Duration(milliseconds: 100));
    expect(v1.length, 1);
    await p; // ensure producer finished
  });

  test('stress: many small round trips', () {
    final m = Mailbox();
    for (var i = 0; i < 500; i++) {
      final payload = Uint8List.fromList([i & 0xFF]);
      m.put(payload);
      final v = m.take();
      expect(v, payload);
    }
  });

  test('''
close while a taker is waiting: taker throws closed unless a message arrives''',
      () async {
    final m = Mailbox();
    final sendable = m.asSendable;

    // Start taker with timeout
    final t = Isolate.run(() async {
      try {
        return sendable
            .materialize()
            .take(timeout: const Duration(milliseconds: 150))
            .length;
        // ignore: avoid_catches_without_on_clauses
      } on MailBoxException catch (_) {
        return -1; // indicate closed/timeout
      }
    });

    // Close after 30ms without posting a message
    await Future<void>.delayed(const Duration(milliseconds: 30));
    m.close();

    final result = await t;
    expect(result, equals(-1)); // closed path hit
  });

  test('close after posting one message: taker should still receive it', () {
    final m = Mailbox()
      ..put(Uint8List.fromList([9, 9]))
      ..close();
    final v = m.take();
    expect(v, [9, 9]);
    // then closed+empty
    expect(() => m.take(timeout: const Duration(milliseconds: 10)),
        throwsA(isA<MailBoxClosedException>()));
  });

  test('large payload round-trip (1MB)', () {
    final m = Mailbox();
    const n = 1 << 20;
    final payload = Uint8List(n)
      ..[0] = 1
      ..[n - 1] = 2;
    m.put(payload);
    final v = m.take();
    expect(v.length, n);
    expect(v.first, 1);
    expect(v.last, 2);
  });

  test('binary data is preserved (random-ish bytes)', () {
    final m = Mailbox();
    final payload =
        Uint8List.fromList(List<int>.generate(256, (i) => (i * 37) & 0xFF));
    m.put(payload);
    final v = m.take();
    expect(v, payload);
  });

  test('toList returns Dart-owned memory (safe across isolates)', () async {
    final m = Mailbox();
    final s = m.asSendable;
    final payload = Uint8List.fromList([1, 2, 3, 42]);

    // Producer in helper isolate
    await Isolate.run(() => s.materialize().put(payload));

    final v = m.take(timeout: const Duration(seconds: 1));
    expect(v, payload); // content matches
    // Try to mutate v and ensure we don't crash or corrupt native memory
    v[0] = 9;
    expect(v[0], 9);
  });

  test('producer isolate: put then close; primary can take final message',
      () async {
    final m = Mailbox();
    final sendable = m.asSendable;
    final payload = Uint8List.fromList([5, 4, 3]);

    // Producer runs in a secondary isolate and owns the "put; close" sequence.
    await Isolate.run(() {
      sendable.materialize()
        ..put(payload)
        ..close();
    });

    // Primary (owner) should still be able to take the pending message.
    final v = m.take(timeout: const Duration(seconds: 1));
    expect(v, [5, 4, 3]);

    var takeFailed = false;
    try {
      m.take(timeout: const Duration(milliseconds: 50));
    } on MailBoxClosedException catch (_) {
      takeFailed = true;
    }

    expect(takeFailed, true);

    // // // After draining, mailbox is closed+empty.
    // expect(() => m.take(timeout: const Duration(milliseconds: 50)),
    //     throwsA(isA<MailBoxClosedException>()));
  });

  test('producer isolate: put then close (no await); primary can still take',
      () async {
    final m = Mailbox();
    final s = m.asSendable;

    // Fire-and-forget producer isolate; close right after put.
    unawaited(Isolate.run(() async {
      final mb = s.materialize()..put(Uint8List.fromList([9, 8, 7]));
      // tiny delay just to exercise timing
      await Future<void>.delayed(const Duration(milliseconds: 10));
      mb.close();
    }));

    // Primary must still receive the final message even if close happens quickly.
    final v = m.take(timeout: const Duration(seconds: 1));
    expect(v, [9, 8, 7]);

    var takeFailed = false;
    try {
      m.take(timeout: const Duration(milliseconds: 50));
    } on MailBoxClosedException catch (_) {
      takeFailed = true;
    }

    expect(takeFailed, true);
  });
}
