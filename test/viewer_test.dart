import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hc_client/hc_client.dart';
import 'package:hc_client/testing.dart';
import 'package:test/test.dart';

import 'support/records.dart';
import 'support/viewers.dart';
import 'support/waits.dart';

void main() {
  late FakeHcCore core;
  late HcGateway gateway;
  late FakeHcClient client;
  var seq = 0;

  setUp(() async {
    core = await FakeHcCore.start();
    addTearDown(core.stop);
    core.terminals = [demoRecord('t1')];
    core.onCall = (method, params) => method == 'terminal.attach'
        ? attachResult(2, demoRecord('t1'))
        : throw FakeHcError('unknown_method', method);
    core.afterReply['terminal.attach'] = [
      resizeFrame(2, 200, 120),
      outputFrame(2, 'paint'),
    ];
    gateway = HcGateway(
      socketPath: core.socketPath,
      filter: demo,
      minBackoff: const Duration(milliseconds: 10),
      maxBackoff: const Duration(milliseconds: 40),
    );
    addTearDown(gateway.stop);
    final subscribed = core.nextSubscriber();
    final resynced = next<HcResync>(gateway);
    gateway.start();
    client = await subscribed;
    await resynced;
  });

  /// Pushes [frames], then a label on t1, and waits for the gateway to see
  /// the label: every frame before it was read by then. A call's round
  /// trip after it puts whatever the client wrote meanwhile before the core.
  Future<void> pushAndSettle(List<HcFrame> frames) async {
    seq++;
    final marked = next<HcChanged>(
      gateway,
      (change) => change.terminal.labels['demo.mark'] == '$seq',
    );
    client.pushFrames(frames);
    client.pushLine(
      event(seq, 'labels', 't1', {
        'labels': {...demo, 'demo.mark': '$seq'},
      }),
    );
    await marked;
    await gateway.list();
  }

  group('Given a gateway connected to a core that attaches on channel 2,', () {
    group('when it attaches to t1 with history and a caller,', () {
      late HcViewer viewer;
      late Watched watched;

      setUp(() async {
        viewer = await gateway.attach('t1', history: 50, caller: 't9');
        watched = Watched(viewer);
        await watched.untilOutputHas('paint');
        await gateway.list();
      });

      test('then the core got terminal.attach, watching only, with resize '
          'notifications.', () {
        final (method, params) = core.calls.firstWhere(
          (call) => call.$1 == 'terminal.attach',
        );
        expect(method, 'terminal.attach');
        expect(params, {
          'terminal': 't1',
          'observe': true,
          'resize_notifications': true,
          'history': 50,
          'cols': 80,
          'rows': 24,
          'caller': 't9',
        });
      });

      test('then the viewer holds the terminal and its size.', () {
        expect(viewer.terminal.address, 't1');
        expect((viewer.cols, viewer.rows), (200, 120));
        expect(viewer.resizeNotifications, isTrue);
      });

      test('then the frames in the reply\'s own write arrive, in order.', () {
        expect(watched.events, [
          const HcResize(200, 120),
          isA<HcOutput>().having(
            (output) => utf8.decode(output.bytes),
            'text',
            'paint',
          ),
        ]);
      });

      test('then it credited the output the listener took.', () {
        expect(client.credits[2], 'paint'.length);
      });
    });

    group('when hc sends output while the listener is paused,', () {
      late StreamSubscription<HcViewerEvent> subscription;
      final taken = <HcViewerEvent>[];

      setUp(() async {
        taken.clear();
        final viewer = await gateway.attach('t1');
        // The gateway stops before the tear-down cancels: its error is ours.
        subscription = viewer.events.listen(taken.add, onError: (_) {});
        await until(() => taken.length == 2, what: 'the first paint');
        subscription.pause();
        await pushAndSettle([outputFrame(2, 'abc'), outputFrame(2, 'def')]);
      });

      tearDown(() => subscription.cancel());

      test('then it credits none of it.', () {
        expect(client.credits[2], 'paint'.length);
      });

      test(
        'then on resuming, it credits it as the listener takes it.',
        () async {
          subscription.resume();
          await until(() => taken.length == 4, what: 'the held output');
          await gateway.list();

          expect(client.credits[2], 'paintabcdef'.length);
        },
      );
    });

    group('when the viewer closes while hc still sends,', () {
      late Watched watched;
      late Future<void> closed;
      late bool closedYet;

      setUp(() async {
        closedYet = false;
        core.echoClose = false;
        final viewer = await gateway.attach('t1');
        watched = Watched(viewer);
        await watched.untilOutputHas('paint');
        closed = viewer.close().then((_) => closedYet = true);
        await until(() => client.closes.isNotEmpty, what: 'the CLOSE');
        await pushAndSettle([
          outputFrame(2, 'late'),
          HcFrame(
            2,
            HcFrameKind.data,
            Uint8List.fromList([0xff, 0x0a, 0x7b, 0x0a]),
          ),
        ]);
      });

      test(
        'then the events ended with no error, before the late output.',
        () async {
          expect(await watched.ended, isNull);
          expect(watched.text, 'paint');
        },
      );

      test('then it sent CLOSE on the channel once.', () {
        expect(client.closes, [2]);
      });

      test('then it credited none of the late output.', () {
        expect(client.credits[2], 'paint'.length);
      });

      test('then the gateway is still connected, the late bytes not read as '
          'events.', () {
        expect(gateway.connected, isTrue);
        expect(core.connections, 1);
      });

      test('then close completes once hc says it let the viewer go.', () async {
        expect(closedYet, isFalse);
        client.pushFrames([closeFrame(2)]);
        await untilDone(closed, 'close');
      });
    });

    test('when the listener cancels, then the viewer sends CLOSE.', () async {
      final viewer = await gateway.attach('t1');
      final subscription = viewer.events.listen((_) {});
      await subscription.cancel();

      await until(() => client.closes.isNotEmpty, what: 'the CLOSE');
      expect(client.closes, [2]);
    });

    group('when hc ends the stream with the program\'s end,', () {
      late Watched watched;

      setUp(() async {
        watched = Watched(await gateway.attach('t1'));
        await watched.untilOutputHas('paint');
        client.pushFrames([
          outputFrame(2, ' bye'),
          closeFrame(2, {
            'reason': 'exited',
            'exit_code': 0,
            'signal': null,
            'finished_ms': 1794031259000,
          }),
        ]);
        await untilDone(watched.ended, 'the end');
      });

      test('then the last output, then the end, arrive.', () {
        expect(watched.text, 'paint bye');
        expect(
          watched.events.last,
          const HcEnd(
            reason: 'exited',
            exitCode: 0,
            finishedMs: 1794031259000,
          ),
        );
      });

      test('then the events end with no error.', () async {
        expect(await watched.ended, isNull);
      });

      test('then the viewer sent no CLOSE of its own.', () async {
        await gateway.list();
        expect(client.closes, isEmpty);
      });
    });

    test(
      'when hc ends the stream with no reason, '
      'then the events end with HcUnavailableException.',
      () async {
        final watched = Watched(await gateway.attach('t1'));
        client.pushFrames([closeFrame(2)]);

        expect(
          await untilDone(watched.ended, 'the end'),
          isA<HcUnavailableException>(),
        );
      },
    );

    test(
      'when the connection drops, '
      'then the events end with HcUnavailableException.',
      () async {
        final watched = Watched(await gateway.attach('t1'));
        await watched.untilOutputHas('paint');
        client.drop();

        expect(
          await untilDone(watched.ended, 'the end'),
          isA<HcUnavailableException>(),
        );
      },
    );
  });

  group('Given a core whose attach answer comes after the call gave up,', () {
    late Completer<Object?> answer;
    Object? failure;

    setUp(() async {
      answer = Completer<Object?>();
      core.onCall = (method, params) => answer.future;
      core.afterReply['terminal.attach'] = [outputFrame(3, 'not json {')];
      try {
        await gateway.attach('t1', timeout: const Duration(milliseconds: 50));
      } on Object catch (error) {
        failure = error;
      }
      answer.complete(attachResult(3, demoRecord('t1')));
      await until(() => client.closes.isNotEmpty, what: 'the CLOSE');
      await pushAndSettle([]);
    });

    test('then the attach failed with HcUnavailableException.', () {
      expect(failure, isA<HcUnavailableException>());
    });

    test('then the client let the late viewer go.', () {
      expect(client.closes, [3]);
    });

    test('then the gateway is still connected.', () {
      expect(gateway.connected, isTrue);
      expect(core.connections, 1);
    });
  });

  test(
    'Given a gateway not connected, when it attaches, '
    'then it fails with HcUnavailableException, never sent.',
    () async {
      final idle = HcGateway(socketPath: core.socketPath);

      await expectLater(
        idle.attach('t1'),
        throwsA(
          isA<HcUnavailableException>().having(
            (error) => error.sent,
            'sent',
            isFalse,
          ),
        ),
      );
    },
  );
}
