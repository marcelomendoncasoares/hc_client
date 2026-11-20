import 'package:hc_client/hc_client.dart';
import 'package:hc_client/testing.dart';
import 'package:test/test.dart';

import 'support/records.dart';
import 'support/waits.dart';

void main() {
  late FakeHcCore core;

  setUp(() async {
    core = await FakeHcCore.start();
    addTearDown(core.stop);
  });

  HcGateway gateway({
    Map<String, String>? filter,
    Set<String>? requiredFeatures,
  }) {
    final gateway = HcGateway(
      socketPath: core.socketPath,
      filter: filter ?? const {},
      requiredFeatures:
          requiredFeatures ?? HcConnection.defaultRequiredFeatures,
      minBackoff: const Duration(milliseconds: 10),
      maxBackoff: const Duration(milliseconds: 40),
    );
    addTearDown(gateway.stop);
    return gateway;
  }

  group('Given a core holding terminals of two apps and one unlabelled,', () {
    setUp(() {
      core.terminals = [
        demoRecord('t1'),
        demoRecord('t2', labels: {'app': 'other'}),
        demoRecord('t3', labels: const {}),
      ];
    });

    group('when a gateway with no filter connects,', () {
      late HcResync resync;

      setUp(() async {
        final first = gateway();
        final resynced = next<HcResync>(first);
        first.start();
        resync = await resynced;
      });

      test('then it subscribed with no labels.', () {
        expect(
          [
            for (final (method, params) in core.calls)
              if (method == 'events.subscribe') params,
          ],
          [
            {'labels': <String, String>{}},
          ],
        );
      });

      test('then its mirror holds every terminal.', () {
        expect(resync.terminals.keys, unorderedEquals(['t1', 't2', 't3']));
      });
    });

    group('when a gateway filtered to app=demo connects,', () {
      late HcResync resync;

      setUp(() async {
        final filtered = gateway(filter: demo);
        final resynced = next<HcResync>(filtered);
        filtered.start();
        resync = await resynced;
      });

      test('then its mirror holds only the demo terminal.', () {
        expect(resync.terminals.keys, ['t1']);
      });
    });
  });

  group('Given a core without the status feature,', () {
    setUp(() {
      core.features = ['framed', 'events'];
    });

    test(
      'when a gateway with the default features connects, '
      'then it subscribes.',
      () async {
        final plain = gateway();
        final resynced = next<HcResync>(plain);
        plain.start();
        await resynced;

        expect(plain.connected, isTrue);
      },
    );

    test(
      'when a gateway that requires status has tried it twice, '
      'then it never subscribed and is disconnected.',
      () async {
        final strict = gateway(
          requiredFeatures: {...HcConnection.defaultRequiredFeatures, 'status'},
        )..start();

        await until(() => core.connections >= 2);

        expect(core.calls, isEmpty);
        expect(strict.connected, isFalse);
      },
    );
  });

  group('Given a gateway connected to a core holding two terminals,', () {
    late HcGateway connected;

    setUp(() async {
      core.terminals = [
        demoRecord('t1'),
        demoRecord('t2', labels: {'app': 'other'}, state: 'finished'),
      ];
      connected = gateway(filter: demo);
      final resynced = next<HcResync>(connected);
      connected.start();
      await resynced;
    });

    group('when it lists with no arguments,', () {
      late List<HcTerminal> listed;

      setUp(() async {
        listed = await connected.list();
      });

      test('then the core got terminal.list with no params.', () {
        final (method, params) = core.calls.last;
        expect(method, 'terminal.list');
        expect(params, isEmpty);
      });

      test('then it returns the live terminal, whatever the filter.', () {
        expect([for (final terminal in listed) terminal.address], ['t1']);
      });
    });

    group('when it lists app=other with finished ones,', () {
      late List<HcTerminal> listed;

      setUp(() async {
        listed = await connected.list(labels: {'app': 'other'}, all: true);
      });

      test('then the core got terminal.list with the labels and all.', () {
        final (method, params) = core.calls.last;
        expect(method, 'terminal.list');
        expect(params, {
          'labels': {'app': 'other'},
          'all': true,
        });
      });

      test('then it returns the finished terminal of that app.', () {
        expect([for (final terminal in listed) terminal.address], ['t2']);
      });
    });
  });
}
