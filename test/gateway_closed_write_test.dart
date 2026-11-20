import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hc_client/hc_client.dart';
import 'package:test/test.dart';

import 'package:hc_client/testing.dart';
import 'support/records.dart';
import 'support/waits.dart';

/// The gateway writes the credit for each event it reads; when the core has
/// closed the connection by then, that write fails, and must end the
/// connection, never escape as an error its caller doesn't handle.
void main() {
  group('Given a gateway subscribed to a core,', () {
    late FakeHcCore core;
    late HcGateway gateway;

    setUp(() async {
      core = await FakeHcCore.start();
      addTearDown(core.stop);
      gateway = HcGateway(
        socketPath: core.socketPath,
        minBackoff: const Duration(milliseconds: 10),
        maxBackoff: const Duration(milliseconds: 40),
      );
      addTearDown(gateway.stop);
      final subscribed = core.nextSubscriber();
      gateway.start();
      await subscribed;
      await until(() => gateway.connected);
    });

    test(
      'when the core sends events and closes the connection at once, '
      'then the gateway connects again, with no error escaping.',
      () async {
        final again = core.nextSubscriber();
        final client = core.subscribers.single;
        for (var seq = 1; seq <= 20; seq++) {
          client.pushLine(event(seq, 'labels', 't1'));
        }
        client.drop();
        await again.timeout(const Duration(seconds: 5));
        await until(() => gateway.connected);

        expect(core.connections, 2);
      },
    );
  });

  group(
    'Given a subscribed socket whose next credit write fails through its done future,',
    () {
      late FakeHcCore core;
      late HcGateway gateway;
      late _WriteFailureSocket socket;

      setUpAll(() async {
        core = await FakeHcCore.start();
        addTearDown(core.stop);
        gateway = HcGateway(
          socketPath: core.socketPath,
          minBackoff: const Duration(milliseconds: 10),
          maxBackoff: const Duration(milliseconds: 40),
        );
        addTearDown(gateway.stop);
        final outside = Zone.current;
        var first = true;
        IOOverrides.runZoned(
          gateway.start,
          socketConnect:
              (host, port, {sourceAddress, sourcePort = 0, timeout}) async {
                final delegate = await outside.run(
                  () => Socket.connect(
                    host,
                    port,
                    sourceAddress: sourceAddress,
                    sourcePort: sourcePort,
                    timeout: timeout,
                  ),
                );
                if (!first) return delegate;
                first = false;
                return socket = _WriteFailureSocket(delegate);
              },
        );
        await until(() => gateway.connected);
        socket.failNextCredit = true;
      });

      group('when an event makes the gateway write credit to that socket,', () {
        late bool writeFailed;
        late int connections;
        late Set<String> terminals;

        setUpAll(() async {
          final again = core.nextSubscriber();
          final record = demoRecord('t1');
          core.terminals = [record];
          core.seq = 1;
          core.push(event(1, 'created', 't1', record));
          await again.timeout(const Duration(seconds: 5));
          await until(
            () => gateway.connected && gateway.terminals.containsKey('t1'),
          );
          writeFailed = socket.writeFailed;
          connections = core.connections;
          terminals = gateway.terminals.keys.toSet();
        });

        test(
          'then the asynchronous write failure closes the connection and reconnects.',
          () {
            expect(writeFailed, isTrue);
            expect(connections, 2);
          },
        );

        test(
          'then the fresh snapshot retains the terminal without an unhandled error.',
          () {
            expect(terminals, {'t1'});
          },
        );
      });
    },
  );
}

/// Uses a real socket for the protocol, but delivers one sink failure before
/// the read side closes. This exercises Socket.done rather than hoping the
/// operating system delivers a reset in the necessary order.
final class _WriteFailureSocket implements Socket {
  _WriteFailureSocket(this.socket) {
    socket.done.then<void>(
      (_) {
        if (!_done.isCompleted) _done.complete();
      },
      onError: (Object error, StackTrace stack) {
        if (!_done.isCompleted) _done.completeError(error, stack);
      },
    );
  }

  final Socket socket;
  final _done = Completer<void>();
  var failNextCredit = false;
  var writeFailed = false;

  @override
  Future<void> get done => _done.future;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => socket.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void add(List<int> data) {
    final frames = HcFrameDecoder().add(data);
    if (failNextCredit &&
        frames.any((frame) => frame.kind == HcFrameKind.credit)) {
      failNextCredit = false;
      writeFailed = true;
      _done.completeError(const SocketException('scratch socket write failed'));
      return;
    }
    socket.add(data);
  }

  @override
  void write(Object? object) => socket.write(object);

  @override
  void destroy() => socket.destroy();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'unexpected socket operation: ${invocation.memberName}',
  );
}
