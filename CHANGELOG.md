# 0.7.1
- reduced logging.
- updated the random log functions to use the dev logging package.

# 0.7.0
- added windodws support to take with a timeout.
- fixed macos support for take with a timeout.

# 0.6.0
- Added method to the public API to determine the mailboxes state. 
- removed the test in _takeTimed for a closed mailbox as a work around for https://github.com/dart-lang/sdk/issues/56412

# 0.4.0
- Added a timeout to the Mailbox.take, Mutex.runLocked and ConditionVariable.wait methods.
 Note: the Mutex timeout is ignored on Windows.


## 0.3.0
- Add a closed state to `Mailbox`.

## 0.2.0

- Lower SDK lower bound to 3.0.0.

## 0.1.0

- Initial version.
- Expose `Mutex` and `ConditionVariable`
- Implement `Mailbox`.
