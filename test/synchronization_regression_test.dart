import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:mirrors';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:native_synchronization_temp/native_synchronization.dart';
import 'package:native_synchronization_temp/src/count_down.dart';
import 'package:native_synchronization_temp/src/windows_timeout.dart';
import 'package:test/test.dart';

const _deadline = Duration(seconds: 10);

// Join without replacing the test's primary failure with a cleanup failure.
// The external watchdog handles a worker stuck inside synchronous native code.
Future<void> _joinForCleanup(Future<dynamic> worker) async {
  try {
    await worker;
  } on Object catch (_) {
    // The test body observes worker errors. Cleanup only joins the worker.
  }
}

Future<void> _holdMutex(Sendable<Mutex> lock, Sendable<Mailbox> release,
        SendPort ready, int address) =>
    Isolate.run(() {
      final occupied = Pointer<Uint8>.fromAddress(address);
      lock.materialize().runLocked(() {
        occupied.value = 1;
        ready.send(null);
        try {
          release.materialize().take(timeout: _deadline);
        } finally {
          occupied.value = 0;
        }
      });
    });

Future<List<int>> _acquireMutex(
        Sendable<Mutex> lock,
        SendPort ready,
        int address,
        Duration timeout,
        Sendable<Mailbox> probeStart,
        Sendable<Mailbox> probeResult) =>
    Isolate.run(() {
      final mutex = lock.materialize();
      final instance = reflect(mutex);
      final library = reflectClass(Mutex).owner! as LibraryMirror;
      var reported = false;
      instance.invoke(MirrorSystem.getSymbol('_lockWithTimeout', library), [
        timeout
      ], {
        #onFailedAttempt: () {
          if (!reported) {
            reported = true;
            ready.send(null);
          }
        }
      });
      try {
        final occupied = Pointer<Uint8>.fromAddress(address).value;
        // While this callback owns the mutex, an independent contender must
        // time out. Checking the old owner's marker alone cannot prove this.
        probeStart.materialize().put(Uint8List(0));
        final probe = probeResult.materialize().take(timeout: _deadline);
        return [occupied, probe.single];
      } finally {
        instance.invoke(MirrorSystem.getSymbol('_unlock', library), []);
      }
    });

Future<String> _waitForBroadcast(Sendable<Mutex> lock,
        Sendable<ConditionVariable> condition, SendPort ready, int address,
        {Duration timeout = _deadline}) =>
    Isolate.run(() {
      final mutex = lock.materialize();
      final condVar = condition.materialize();
      final released = Pointer<Uint8>.fromAddress(address);
      final countdown = CountDown(timeout);
      return mutex.runLocked(() {
        ready.send(null);
        while (released.value == 0) {
          condVar.wait(mutex, timeout: countdown.remainingTime);
        }
        return 'released';
      }, timeout: _deadline);
    });

Future<String> _waitForMailboxClose(
    Sendable<Mailbox> mailbox,
    Sendable<Mutex> lock,
    Sendable<ConditionVariable> condition,
    SendPort ready,
    int address) async {
  await _waitForBroadcast(lock, condition, ready, address);
  try {
    mailbox.materialize().take(timeout: _deadline);
    return 'unexpected message';
  } on MailBoxClosedException {
    return 'closed';
  }
}

Future<void> _probeMutex(Sendable<Mutex> lock, Sendable<Mailbox> start,
        Sendable<Mailbox> result) =>
    Isolate.run(() {
      start.materialize().take(timeout: _deadline);
      var acquired = false;
      try {
        lock.materialize().runLocked(() => acquired = true,
            timeout: const Duration(milliseconds: 20));
      } on TimeoutException {
        // Expected while the original caller still owns the mutex.
      }
      result.materialize().put(Uint8List.fromList([if (acquired) 1 else 0]));
    });

Future<String> _takeUntilClosed(Sendable<Mailbox> mailbox, SendPort ready) =>
    Isolate.run(() {
      final consumer = mailbox.materialize();
      ready.send(null);
      try {
        consumer.take(timeout: _deadline);
        return 'unexpected message';
      } on MailBoxClosedException {
        return 'closed';
      } on TimeoutException {
        return 'timeout';
      }
    });

void main() {
  // A timer in the same isolate cannot interrupt a synchronous FFI deadlock.
  // Run native scenarios in a disposable process and join it before finishing.
  if (Platform.environment['NATIVE_SYNC_REGRESSION_CHILD'] != '1') {
    test('native synchronization regressions (external watchdog)', () async {
      final process = await Process.start(Platform.resolvedExecutable, [
        'test',
        'test/synchronization_regression_test.dart',
        '--reporter=expanded',
      ], environment: {
        'NATIVE_SYNC_REGRESSION_CHILD': '1'
      });
      final output = process.stdout.transform(systemEncoding.decoder).join();
      final errors = process.stderr.transform(systemEncoding.decoder).join();
      try {
        final exitCode = await process.exitCode
            .timeout(const Duration(seconds: 90), onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          throw TimeoutException('Native regression process exceeded 90s');
        });
        expect(exitCode, 0, reason: '${await output}\n${await errors}');
      } finally {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    }, timeout: const Timeout(Duration(seconds: 100)));
    return;
  }

  test('Windows timeout conversion preserves finite boundaries', () {
    expect(windowsTimeoutMilliseconds(null), windowsInfiniteTimeout);
    for (final micros in [0, -1, -0x8000000000000000]) {
      expect(windowsTimeoutMilliseconds(Duration(microseconds: micros)), 0);
    }
    for (final micros in [1, 999, 1000]) {
      expect(windowsTimeoutMilliseconds(Duration(microseconds: micros)), 1);
    }
    expect(windowsTimeoutMilliseconds(const Duration(microseconds: 1001)), 2);
    for (final duration in [
      const Duration(milliseconds: 0xFFFFFFFE),
      const Duration(milliseconds: 0xFFFFFFFF),
      const Duration(days: 100000),
      const Duration(microseconds: 0x7FFFFFFFFFFFFFFF),
    ]) {
      expect(windowsTimeoutMilliseconds(duration), windowsMaxFiniteTimeout);
    }
  });
  test('countdown clamps nonpositive and very large durations', () {
    expect(CountDown(Duration.zero).remainingTime, Duration.zero);
    expect(CountDown(const Duration(microseconds: -1)).expired, isTrue);
    expect(CountDown(const Duration(microseconds: -0x8000000000000000)).expired,
        isTrue);
    final long = CountDown(const Duration(days: 100000));
    expect(long.expired, isFalse);
    expect(long.minOfRemaining(const Duration(milliseconds: 1)),
        const Duration(milliseconds: 1));
  });

  test('timed contention never enters callback and mutex remains usable',
      () async {
    final mutex = Mutex();
    final release = Mailbox();
    final ready = ReceivePort();
    final occupied = calloc<Uint8>();
    final holder = _holdMutex(
        mutex.asSendable, release.asSendable, ready.sendPort, occupied.address);
    try {
      await ready.first.timeout(_deadline);
      for (final timeout in [
        Duration.zero,
        const Duration(microseconds: -1),
        const Duration(microseconds: 1),
        const Duration(milliseconds: 20),
      ]) {
        var entered = false;
        expect(() => mutex.runLocked(() => entered = true, timeout: timeout),
            throwsA(isA<TimeoutException>()));
        expect(entered, isFalse);
      }
    } finally {
      release.put(Uint8List(0));
      await _joinForCleanup(holder);
      ready.close();
      calloc.free(occupied);
    }
    expect(mutex.runLocked(() => 42, timeout: Duration.zero), 42);
    expect(release.isEmpty(), isTrue);
  });

  for (final timeout in [
    const Duration(seconds: 5),
  ]) {
    test('timed contender acquires ownership after release ($timeout)',
        () async {
      final mutex = Mutex();
      final release = Mailbox();
      final held = ReceivePort();
      final started = ReceivePort();
      final occupied = calloc<Uint8>();
      final holder = _holdMutex(mutex.asSendable, release.asSendable,
          held.sendPort, occupied.address);
      final probeStart = Mailbox();
      final probeResult = Mailbox();
      final probe = _probeMutex(
          mutex.asSendable, probeStart.asSendable, probeResult.asSendable);
      Future<List<int>>? contender;
      List<int>? acquired;
      try {
        await held.first.timeout(_deadline);
        contender = _acquireMutex(
            mutex.asSendable,
            started.sendPort,
            occupied.address,
            timeout,
            probeStart.asSendable,
            probeResult.asSendable);
        await started.first.timeout(_deadline);
        release.put(Uint8List(0));
        await holder.timeout(_deadline);
        acquired = await contender.timeout(_deadline);
        await probe.timeout(_deadline);
      } finally {
        release.close();
        await _joinForCleanup(holder);
        if (contender != null) {
          await _joinForCleanup(contender);
        }
        probeStart.close();
        await _joinForCleanup(probe);
        held.close();
        started.close();
        calloc.free(occupied);
      }
      expect(acquired, [0, 0]);
      expect(mutex.runLocked(() => 42, timeout: Duration.zero), 42);
      expect(release.isEmpty(), isTrue);
      expect(probeResult.isEmpty(), isTrue);
    }, skip: !Platform.isWindows);
  }

  test('notifyAll releases every registered waiter', () async {
    final mutex = Mutex();
    final condition = ConditionVariable();
    final released = calloc<Uint8>();
    final ready = ReceivePort();
    final allReady = ready.take(4).toList().timeout(_deadline);
    final waiters = List.generate(
        4,
        (_) => _waitForBroadcast(mutex.asSendable, condition.asSendable,
            ready.sendPort, released.address));
    final completed = Future.wait(waiters);
    try {
      await allReady;
      // Each ready message is sent with this mutex held. Acquiring it after
      // all messages proves that every waiter has released it inside wait().
      mutex.runLocked(() {
        released.value = 1;
        condition.notifyAll();
      }, timeout: _deadline);
      expect(await completed.timeout(_deadline), everyElement('released'));
    } finally {
      // Every native wait has a deadline; join before freeing shared state.
      await _joinForCleanup(completed);
      ready.close();
      calloc.free(released);
    }
    expect(mutex.runLocked(() => true), isTrue);
    condition.notifyAll();
  });

  test('close releases all consumers of an empty mailbox', () async {
    final mailbox = Mailbox();
    final ready = ReceivePort();
    final allReady = ready.take(8).toList().timeout(_deadline);
    final consumers = List.generate(
        8, (_) => _takeUntilClosed(mailbox.asSendable, ready.sendPort));
    final completed = Future.wait(consumers);
    try {
      await allReady;
      mailbox.close();
      expect(await completed.timeout(_deadline), everyElement('closed'));
    } finally {
      mailbox.close();
      await _joinForCleanup(completed);
      ready.close();
    }
    expect(mailbox.isClosed(), isTrue);
  });

  test('close broadcasts to every registered mailbox condition waiter',
      () async {
    final mailbox = Mailbox();
    // Inspect the real mailbox primitives without adding production test
    // hooks. The public take() API has no waiter-registration callback.
    final library = reflectClass(Mailbox).owner! as LibraryMirror;
    final instance = reflect(mailbox);
    final mutex = instance
        .getField(MirrorSystem.getSymbol('_mutex', library))
        .reflectee as Mutex;
    final condition = instance
        .getField(MirrorSystem.getSymbol('_condVar', library))
        .reflectee as ConditionVariable;
    final released = calloc<Uint8>();
    final ready = ReceivePort();
    final allReady = ready.take(4).toList().timeout(_deadline);
    final waiters = List.generate(
        4,
        (_) => _waitForMailboxClose(mailbox.asSendable, mutex.asSendable,
            condition.asSendable, ready.sendPort, released.address));
    final completed = Future.wait(waiters);
    try {
      await allReady;
      mutex.runLocked(() => released.value = 1, timeout: _deadline);
      mailbox.close();
      expect(await completed.timeout(_deadline), everyElement('closed'));
    } finally {
      mailbox.close();
      await _joinForCleanup(completed);
      ready.close();
      calloc.free(released);
    }
    expect(mailbox.isClosed(), isTrue);
  });

  for (final timeout in [
    Duration.zero,
    const Duration(microseconds: -1),
    const Duration(microseconds: 1),
  ]) {
    test('condition timeout reacquires ownership ($timeout)', () async {
      final mutex = Mutex();
      final condition = ConditionVariable();
      final start = Mailbox();
      final result = Mailbox();
      final probe =
          _probeMutex(mutex.asSendable, start.asSendable, result.asSendable);
      try {
        mutex.runLocked(() {
          final budget = CountDown(timeout);
          final watchdog = Stopwatch()..start();
          var timedOut = false;
          while (!timedOut && watchdog.elapsed < _deadline) {
            try {
              condition.wait(mutex, timeout: budget.remainingTime);
            } on TimeoutException {
              timedOut = true;
            }
          }
          expect(timedOut, isTrue,
              reason: 'Spurious wakes must not prevent eventual timeout');
          start.put(Uint8List(0));
          expect(result.take(timeout: _deadline), [0]);
        });
      } finally {
        start.close();
        await _joinForCleanup(probe);
      }
      expect(mutex.runLocked(() => true, timeout: Duration.zero), isTrue);
      expect(result.isEmpty(), isTrue);
      condition.notifyAll();
    }, skip: !Platform.isWindows);
  }

  test('intermediate condition timeout returns to the predicate', () async {
    final mutex = Mutex();
    final condition = ConditionVariable();
    final released = calloc<Uint8>();
    final ready = ReceivePort();
    final probeStart = Mailbox();
    final probeResult = Mailbox();
    final probe = _probeMutex(
        mutex.asSendable, probeStart.asSendable, probeResult.asSendable);
    final waiter = _waitWithShortChunks(
        mutex.asSendable,
        condition.asSendable,
        ready.sendPort,
        released.address,
        probeStart.asSendable,
        probeResult.asSendable);
    try {
      await ready.first.timeout(_deadline);
      mutex.runLocked(() {
        // The worker released this mutex inside its native wait. Keep it
        // held beyond the short chunk, then change the predicate while the
        // worker must reacquire the mutex. This notification is not retained
        // for any subsequent wait.
        sleep(const Duration(milliseconds: 100));
        released.value = 1;
        condition.notifyAll();
      }, timeout: _deadline);
      expect(await waiter.timeout(_deadline), 'released');
      await probe.timeout(_deadline);
    } finally {
      await _joinForCleanup(waiter);
      probeStart.close();
      await _joinForCleanup(probe);
      ready.close();
      calloc.free(released);
    }
    expect(mutex.runLocked(() => true), isTrue);
    condition.notifyAll();
  }, skip: !Platform.isWindows);
}

Future<String> _waitWithShortChunks(
        Sendable<Mutex> lock,
        Sendable<ConditionVariable> condition,
        SendPort ready,
        int address,
        Sendable<Mailbox> probeStart,
        Sendable<Mailbox> probeResult) =>
    Isolate.run(() {
      final mutex = lock.materialize();
      final condVar = condition.materialize();
      final library = reflectClass(ConditionVariable).owner! as LibraryMirror;
      final instance = reflect(condVar);
      final released = Pointer<Uint8>.fromAddress(address);
      final budget = CountDown(const Duration(seconds: 2));
      return mutex.runLocked(() {
        ready.send(null);
        while (released.value == 0) {
          instance.invoke(MirrorSystem.getSymbol('_waitWithTimeout', library),
              [mutex, budget.remainingTime], {#maxWaitMilliseconds: 1});
        }
        probeStart.materialize().put(Uint8List(0));
        final acquired = probeResult.materialize().take(timeout: _deadline);
        return acquired.single == 0 ? 'released' : 'mutex was not held';
      }, timeout: _deadline);
    });
