import 'dart:async';

import 'package:hc_client/hc_client.dart';
import 'package:test/test.dart';

import 'package:hc_client/testing.dart';
import 'support/waits.dart';

void main() {
  group('Given a gateway waiting for its subscription snapshot,', () {
    late FakeHcCore core;
    late HcGateway gateway;
    late FakeHcClient client;

    setUpAll(() async {
      core = await FakeHcCore.start();
      addTearDown(core.stop);
      core.holdSubscribeReply = true;
      gateway = HcGateway(socketPath: core.socketPath);
      addTearDown(gateway.stop);
      final subscribed = core.nextSubscriber();
      gateway.start();
      client = await subscribed;
    });

    group('when it is stopped before the core replies,', () {
      late bool completedWithoutCore;
      late bool connectionClosed;

      setUpAll(() async {
        final stopped = gateway.stop();
        completedWithoutCore = await stopped
            .then((_) => true)
            .timeout(
              const Duration(milliseconds: 200),
              onTimeout: () => false,
            );
        connectionClosed = await client.done
            .then((_) => true)
            .timeout(
              const Duration(milliseconds: 200),
              onTimeout: () => false,
            );
        await core.down();
        await stopped;
      });

      test('then its connection closes without waiting for the core.', () {
        expect(completedWithoutCore, isTrue);
        expect(connectionClosed, isTrue);
      });
    });
  });

  group('Given a gateway waiting to retry an absent scratch socket,', () {
    late HcGateway gateway;
    late List<Timer> timers;

    setUpAll(() async {
      final core = await FakeHcCore.start();
      addTearDown(core.stop);
      await core.down();
      timers = [];
      gateway = HcGateway(
        socketPath: core.socketPath,
        connectTimeout: const Duration(milliseconds: 100),
        minBackoff: const Duration(seconds: 20),
        maxBackoff: const Duration(seconds: 20),
      );
      addTearDown(gateway.stop);
      addTearDown(() {
        for (final timer in timers) {
          timer.cancel();
        }
      });
      runZoned(
        gateway.start,
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createTimer(zone, duration, callback);
            if (duration >= const Duration(seconds: 1)) {
              timers.add(timer);
            }
            return timer;
          },
        ),
      );
      await until(() => timers.any((timer) => timer.isActive));
    });

    test(
      'when the gateway stops, '
      'then it leaves no active reconnect timer.',
      () async {
        await gateway.stop();
        final active = timers.where((timer) => timer.isActive).length;

        expect(active, 0);
      },
    );
  });
}
