/// A Dart client for herdr-core (`hc`): its framed connection and codec, a
/// gateway that keeps a live mirror of its terminals, and their records.
library;

export 'src/connection.dart' show HcConnection, HcSubscription;
export 'src/errors.dart';
export 'src/frame.dart';
export 'src/gateway.dart';
export 'src/mirror.dart';
export 'src/notification.dart';
export 'src/socket_path.dart';
export 'src/terminal.dart';
