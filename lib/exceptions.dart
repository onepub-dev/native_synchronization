class MailBoxException implements Exception {
  MailBoxException(this.message);
  String message;

  @override
  String toString() => 'MailBoxException: $message';
}

class MailBoxFullException extends MailBoxException {
  MailBoxFullException() : super('Mailbox is full');
}

class MailBoxClosedException extends MailBoxException {
  MailBoxClosedException() : super('Mailbox is closed');
}
