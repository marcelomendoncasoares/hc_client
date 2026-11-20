import 'dart:async';

import 'package:hc_client/hc_client.dart';

/// The gateway's next change of type [T] that passes [where]. Call it before
/// the action that causes the change: the changes are not replayed.
Future<T> next<T extends HcChange>(
  HcGateway gateway, [
  bool Function(T change)? where,
]) => gateway.changes
    .where((change) => change is T && (where?.call(change) ?? true))
    .cast<T>()
    .first
    .timeout(const Duration(seconds: 5));

/// Waits until [condition] holds, checking every 10 ms, for up to
/// [within]; then fails naming [what] it waited for, when given.
Future<void> until(
  bool Function() condition, {
  Duration within = const Duration(seconds: 5),
  String? what,
}) async {
  final deadline = DateTime.now().add(within);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        what == null ? 'the condition never held' : 'waited for $what',
        within,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// [future]'s value, waited for up to [within]; then fails naming [what]
/// it waited for, so a wait that never ends says which it was in seconds.
Future<T> untilDone<T>(
  Future<T> future,
  String what, {
  Duration within = const Duration(seconds: 30),
}) => future.timeout(
  within,
  onTimeout: () => throw TimeoutException('waited for $what', within),
);
