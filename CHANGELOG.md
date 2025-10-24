# 0.8.0
- Added asserts to check for memory corruption.
- Split the state of the mailbox to track open/closed full/empty separately.
This allows a consumer to read a final message from the mailbox even after the producer has closed the box.
The close method no longer empties the mailbox.
- Change take to return a full dart object rather than a dart object backed by a native buffer.  The old method was a problem if you subsequently tried to move the message to another isolate as the native buffer would be finalised the message buffer no longer valid.
- Changed from throwing a StateError to a MailBoxException. The close and full errors are both recoverable so arguably should never have been an Error.  We now throw MailBoxFullException and MailBoxCloseException which both derive from MailBoxException make the exceptions easier to manage.
- fixed possible erroronous free where the finalizer would always free the _mailbox.ref.buffer even if it was empty and hence null.
- created a standard export file native_synchronization.dart. We should all other files in lib to lib/src as is best practice.
- added additional unit tests.

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
