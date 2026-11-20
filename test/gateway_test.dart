import 'dart:async';
import 'dart:convert';

import 'package:hc_client/hc_client.dart';
import 'package:test/test.dart';

import 'package:hc_client/testing.dart';
import 'support/records.dart';
import 'support/waits.dart';

void main() {
  late FakeHcCore core;

  setUp(() async {
    core = await FakeHcCore.start();
    addTearDown(core.stop);
  });

  group('Given a core holding two demo terminals at seq 7,', () {
    setUp(() {
      core
        ..seq = 7
        ..terminals = [demoRecord('t1'), demoRecord('t2')];
    });

    group('when the gateway connects,', () {
      late HcGateway gateway;
      late HcResync resync;

      setUp(() async {
        gateway = gatewayFor(core);
        final first = next<HcResync>(gateway);
        gateway.start();
        resync = await first;
      });

      test('then it is connected.', () {
        expect(gateway.connected, isTrue);
      });

      test('then its first change is a resync holding both terminals.', () {
        expect(resync.terminals.keys, ['t1', 't2']);
      });

      test('then its mirror holds both terminals.', () {
        expect(gateway.terminals, {
          't1': HcTerminal.fromJson(demoRecord('t1')),
          't2': HcTerminal.fromJson(demoRecord('t2')),
        });
      });

      test('then it shook hands with the hello line hc expects.', () {
        expect(core.helloLines, [
          '{"jsonrpc":"2.0","id":0,"method":"hello","params":{"framed":true,"generation":1}}',
        ]);
      });

      test('then it subscribed to the terminals labelled app=demo.', () {
        expect(
          [
            for (final (method, params) in core.calls)
              if (method == 'events.subscribe') params,
          ],
          [
            {
              'labels': {'app': 'demo'},
            },
          ],
        );
      });
    });
  });

  group('Given a gateway following a core holding t1 at seq 3,', () {
    late HcGateway gateway;

    setUp(() async {
      core
        ..seq = 3
        ..terminals = [demoRecord('t1')];
      gateway = await connectedGateway(core);
    });

    test(
      'when a status event says t1 is blocked on a permission, '
      'then the mirror shows t1 blocked with its kind and message.',
      () async {
        final changed = next<HcChanged>(gateway);

        core.push(
          event(4, 'status', 't1', {
            'status': {
              'state': 'blocked',
              'kind': 'permission',
              'msg': 'approve Bash: ls',
            },
            'records': {},
            'reported': true,
          }),
        );
        await changed;

        expect(
          gateway.terminals['t1']!.status,
          const HcStatus(
            'blocked',
            kind: 'permission',
            msg: 'approve Bash: ls',
          ),
        );
      },
    );

    test(
      'when a labels event takes app=demo off t1, '
      'then t1 leaves the mirror.',
      () async {
        final removed = next<HcRemoved>(gateway);

        core.push(
          event(4, 'labels', 't1', {
            'labels': {'app': 'other'},
          }),
        );
        await removed;

        expect(gateway.terminals, isEmpty);
      },
    );

    test(
      'when the core closes the event channel, '
      'then the gateway subscribes again and resyncs.',
      () async {
        final resync = next<HcResync>(gateway);

        core.subscribers.single.pushFrames([
          HcFrame(
            FakeHcCore.eventChannel,
            HcFrameKind.close,
            utf8.encode('{"reason":"closing"}'),
          ),
        ]);
        await resync;

        expect(core.connections, 2);
      },
    );

    test(
      'when the core sends a frame header announcing more than 16 MiB, '
      'then the gateway drops the connection and subscribes again.',
      () async {
        final resync = next<HcResync>(gateway);

        core.subscribers.single.pushBytes([
          1, 0, 0, 0, // channel 1
          0, // DATA
          1, 0, 0, 1, // 16 MiB and one byte
        ]);
        await resync;

        expect(core.connections, 2);
      },
    );

    test(
      'when events arrive, '
      'then the core is credited for every byte it sent on the event '
      'channel.',
      () async {
        final client = core.subscribers.single;
        final last = next<HcChanged>(
          gateway,
          (change) => change.type == 'turn',
        );

        core
          ..push(event(4, 'title', 't1', {'title': 'One'}))
          ..push(event(5, 'title', 't1', {'title': 'Two'}))
          ..push(event(6, 'turn', 't1', {'turn': 1, 'state': 'idle'}));
        await last;
        await until(() => client.credit == client.sent);

        expect(client.credit, client.sent);
      },
    );

    test(
      'when the gateway stops, '
      'then it is disconnected and never connects again.',
      () async {
        await gateway.stop();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(gateway.connected, isFalse);
        expect(core.connections, 1);
      },
    );
  });

  group(
    'Given a core at seq 10 holding t1 that sends, before its subscribe reply, a labels event at seq 10 and a status event at seq 11, and after it a turn event at seq 12,',
    () {
      setUp(() {
        core
          ..seq = 10
          ..terminals = [demoRecord('t1')]
          ..beforeSubscribeReply = [
            event(10, 'labels', 't1', {
              'labels': {'app': 'demo', 'demo.ask.a1': '{}'},
            }),
            event(11, 'status', 't1', {
              'status': {'state': 'working'},
              'records': {},
              'reported': true,
            }),
          ]
          ..afterSubscribeReply = [
            event(12, 'turn', 't1', {'turn': 1, 'state': 'idle'}),
          ];
      });

      group('when the gateway connects and takes the turn event,', () {
        late HcGateway gateway;

        setUp(() async {
          gateway = gatewayFor(core);
          final turn = next<HcChanged>(
            gateway,
            (change) => change.type == 'turn',
          );
          gateway.start();
          await turn;
        });

        test(
          'then the labels event, already in the snapshot, is not applied.',
          () {
            expect(gateway.terminals['t1']!.labels, {'app': 'demo'});
          },
        );

        test(
          'then the status event that came before the reply is applied.',
          () {
            expect(gateway.terminals['t1']!.status, const HcStatus('working'));
          },
        );

        test('then the turn event is applied.', () {
          expect(gateway.terminals['t1']!.turn, 1);
        });
      });
    },
  );

  test(
    'Given a core at seq 7 holding t1 that sends a turn event at seq 8 in the same write as its hello reply, '
    'when the gateway connects, '
    'then t1 is at turn 2.',
    () async {
      core
        ..seq = 7
        ..terminals = [demoRecord('t1')]
        ..afterHello = HcFrame(
          FakeHcCore.eventChannel,
          HcFrameKind.data,
          utf8.encode(
            '${jsonEncode(event(8, 'turn', 't1', {'turn': 2, 'state': 'idle'}))}\n',
          ),
        );
      final gateway = gatewayFor(core);
      final turn = next<HcChanged>(gateway, (change) => change.type == 'turn');

      gateway.start();
      await turn;

      expect(gateway.terminals['t1']!.turn, 2);
    },
  );

  group('Given a gateway following a core at seq 900 holding t1 and t2,', () {
    late HcGateway gateway;

    setUp(() async {
      core
        ..seq = 900
        ..terminals = [demoRecord('t1'), demoRecord('t2')];
      gateway = await connectedGateway(core);
    });

    group(
      'when the core restarts at seq 0 holding only t2, and sends a turn event at seq 1,',
      () {
        late HcResync resync;

        setUp(() async {
          core.afterSubscribeReply = [
            event(1, 'turn', 't2', {'turn': 3, 'state': 'idle'}),
          ];
          final resynced = next<HcResync>(gateway);
          final turn = next<HcChanged>(
            gateway,
            (change) => change.type == 'turn',
          );
          await core.restart(seq: 0, terminals: [demoRecord('t2')]);
          resync = await resynced;
          await turn;
        });

        test('then the gateway resyncs holding only t2.', () {
          expect(resync.terminals.keys, ['t2']);
        });

        test('then t1 is gone from the mirror.', () {
          expect(gateway.terminals.keys, ['t2']);
        });

        test('then the event at seq 1 is applied.', () {
          expect(gateway.terminals['t2']!.turn, 3);
        });
      },
    );
  });

  group('Given a gateway following a core at seq 20 holding t1 and t2,', () {
    late HcGateway gateway;

    setUp(() async {
      core
        ..seq = 20
        ..terminals = [demoRecord('t1'), demoRecord('t2')];
      gateway = await connectedGateway(core);
    });

    group(
      'when the core sends missed at seq 57 holding only t1, followed by a turn event at seq 57 and a title event at seq 58,',
      () {
        late HcResync resync;

        setUp(() async {
          final resynced = next<HcResync>(gateway);
          final title = next<HcChanged>(
            gateway,
            (change) => change.type == 'title',
          );
          core
            ..push({
              'jsonrpc': '2.0',
              'method': 'missed',
              'params': {
                'seq': 57,
                'terminals': [demoRecord('t1')],
              },
            })
            ..push(event(57, 'turn', 't1', {'turn': 9, 'state': 'idle'}))
            ..push(event(58, 'title', 't1', {'title': 'After'}));
          resync = await resynced;
          await title;
        });

        test('then the gateway resyncs holding only t1.', () {
          expect(resync.terminals.keys, ['t1']);
        });

        test('then t2 is gone from the mirror.', () {
          expect(gateway.terminals.keys, ['t1']);
        });

        test('then the event at seq 57 is not applied.', () {
          expect(gateway.terminals['t1']!.turn, 0);
        });

        test('then the event at seq 58 is applied.', () {
          expect(gateway.terminals['t1']!.title, 'After');
        });
      },
    );
  });

  test(
    'Given a gateway with a 200 ms heartbeat timeout following a core that sends nothing, '
    'when 200 ms pass, '
    'then it connects and subscribes again.',
    () async {
      final gateway = await connectedGateway(
        core,
        heartbeatTimeout: const Duration(milliseconds: 200),
      );
      final resync = next<HcResync>(gateway);

      await resync;

      expect(core.connections, 2);
    },
  );

  group('Given no core at the socket path,', () {
    setUp(() async {
      await core.down();
    });

    test(
      'when the gateway starts, '
      'then a call fails as unavailable.',
      () async {
        final gateway = gatewayFor(core)..start();

        await Future<void>.delayed(const Duration(milliseconds: 100));

        await expectLater(
          gateway.get('t1'),
          throwsA(isA<HcUnavailableException>()),
        );
      },
    );

    test(
      'when the gateway starts and a core comes up there later, '
      'then the gateway connects to it.',
      () async {
        final gateway = gatewayFor(core);
        final resync = next<HcResync>(gateway);
        gateway.start();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        await core.listen();
        await resync;

        expect(gateway.connected, isTrue);
      },
    );
  });

  test(
    'Given a core that speaks protocol generation 2, '
    'when the gateway has tried it twice, '
    'then it never subscribed and is disconnected.',
    () async {
      core.generation = 2;
      final gateway = gatewayFor(core)..start();

      await until(() => core.connections >= 2);

      expect(core.calls, isEmpty);
      expect(gateway.connected, isFalse);
    },
  );

  test(
    'Given a core without the events feature, '
    'when the gateway has tried it twice, '
    'then it never subscribed and is disconnected.',
    () async {
      core.features = ['framed', 'status'];
      final gateway = gatewayFor(core)..start();

      await until(() => core.connections >= 2);

      expect(core.calls, isEmpty);
      expect(gateway.connected, isFalse);
    },
  );

  group('Given a gateway connected to a core,', () {
    late HcGateway gateway;

    setUp(() async {
      gateway = await connectedGateway(core);
    });

    group('when a label call gets its record back,', () {
      late HcTerminal record;

      setUp(() async {
        core.onCall = (method, params) => demoRecord(
          't1',
          labels: {'app': 'demo', 'demo.reply.a1': 'allow'},
        );
        record = await gateway.label('t1', {'demo.reply.a1': 'allow'});
      });

      test(
        'then the core got terminal.label with the terminal and labels.',
        () {
          final (method, params) = core.calls.last;
          expect(method, 'terminal.label');
          expect(params, {
            'terminal': 't1',
            'labels': {'demo.reply.a1': 'allow'},
          });
        },
      );

      test('then the call returns the record.', () {
        expect(record.labels, {'app': 'demo', 'demo.reply.a1': 'allow'});
      });
    });

    test(
      'when hc answers a call with not_found, '
      'then the call fails with that kind.',
      () async {
        core.onCall = (method, params) =>
            throw FakeHcError('not_found', 'no terminal "t9"');

        await expectLater(
          gateway.get('t9'),
          throwsA(
            isA<HcException>().having(
              (error) => error.kind,
              'kind',
              'not_found',
            ),
          ),
        );
      },
    );

    test(
      'when the core goes away during a call, '
      'then the call fails as unavailable.',
      () async {
        core.onCall = (method, params) => FakeHcCore.noReply;
        final call = gateway.send('t1', 'hello');

        await Future<void>.delayed(const Duration(milliseconds: 50));
        await core.down();

        await expectLater(call, throwsA(isA<HcUnavailableException>()));
      },
    );
  });
}

/// A gateway on [core]'s socket, quick to retry, stopped after the test.
HcGateway gatewayFor(
  FakeHcCore core, {
  Duration heartbeatTimeout = const Duration(seconds: 45),
}) {
  final gateway = HcGateway(
    socketPath: core.socketPath,
    filter: demo,
    heartbeatTimeout: heartbeatTimeout,
    minBackoff: const Duration(milliseconds: 10),
    maxBackoff: const Duration(milliseconds: 40),
  );
  addTearDown(gateway.stop);
  return gateway;
}

/// [gatewayFor], started and through its first resync.
Future<HcGateway> connectedGateway(
  FakeHcCore core, {
  Duration heartbeatTimeout = const Duration(seconds: 45),
}) async {
  final gateway = gatewayFor(core, heartbeatTimeout: heartbeatTimeout);
  final resync = next<HcResync>(gateway);
  gateway.start();
  await resync;
  return gateway;
}
