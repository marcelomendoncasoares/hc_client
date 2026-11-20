// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:hc_client/hc_client.dart';

/// Follows the terminals of the core `hc` would reach from here, printing
/// each one's status as it changes, until Ctrl+C. Pass `key=value` labels
/// to follow only the terminals that carry them.
Future<void> main(List<String> arguments) async {
  final filter = {
    for (final argument in arguments)
      if (argument.split('=') case [final key, final value]) key: value,
  };
  final gateway = HcGateway(
    socketPath: hcSocketPath(Platform.environment),
    filter: filter,
    log: (message) => stderr.writeln(message),
  );
  final changes = gateway.changes.listen((change) {
    switch (change) {
      case HcResync(:final terminals):
        print('${terminals.length} terminals');
        terminals.values.forEach(show);
      case HcAdded(:final terminal):
        show(terminal);
      case HcChanged(:final before, :final terminal)
          when before.status?.state != terminal.status?.state ||
              before.state != terminal.state:
        show(terminal);
      case HcChanged():
        break;
      case HcRemoved(:final terminal):
        print('${terminal.address} removed');
    }
  });
  gateway.start();
  if (!await gateway.firstTry) {
    stderr.writeln('no hc core answered at ${gateway.socketPath}');
  }

  await ProcessSignal.sigint.watch().first;
  await changes.cancel();
  await gateway.stop();
}

void show(HcTerminal terminal) {
  final name = terminal.name ?? terminal.argv.join(' ');
  final status = terminal.live
      ? terminal.status?.state ?? 'no status'
      : 'finished (${terminal.reason ?? 'ended'})';
  print('${terminal.address} $name: $status');
}
