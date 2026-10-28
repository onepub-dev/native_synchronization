# native_synchronization_temp

[![Dart](https://github.com/onepub-dev/native_synchronization/actions/workflows/dart.yaml/badge.svg)](https://github.com/onepub-dev/native_synchronization/actions/workflows/dart.yaml)
[![pub package](https://img.shields.io/pub/v/native_synchronization_temp.svg)](https://pub.dev/packages/native_synchronization_temp)

This experimental package provides native `Mutex`, `ConditionVariable`, and
`Mailbox` primitives for Dart isolates. It is maintained in the
[onepub-dev/native_synchronization](https://github.com/onepub-dev/native_synchronization)
fork and published as `native_synchronization_temp`.

The package derives from the Dart team's
[`native_synchronization`](https://pub.dev/packages/native_synchronization)
project. The two packages have separate releases. Check this fork's changelog
for fixes to its timeout and mailbox APIs.

Keep the owning objects alive until all isolates using their `Sendable` handles
have finished. A sendable handle borrows the underlying native allocation.
