@Tags(['hc'])
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';

import 'package:hc_client/hc_client.dart';
import 'package:hc_client/testing.dart';
import 'package:test/test.dart';

import 'support/records.dart';
import 'support/viewers.dart';
import 'support/waits.dart';

/// Watches terminals of a real hc core of the test's own: `dart test -P hc`.
void main() {
  late ScratchCore core;
  late HcGateway gateway;

  setUpAll(() async {
    core = await ScratchCore.start();
    addTearDown(core.stop);
    gateway = HcGateway(socketPath: core.socketPath, filter: demo);
    addTearDown(gateway.stop);
    gateway.start();
    await gateway.firstTry;
  });

  /// A terminal that prints a red word, then echoes what it is sent.
  Future<HcTerminal> colouredCat() => gateway.run(
    argv: ['sh', '-c', r'printf "\033[31mred\033[0m ready\n"; exec cat'],
    cwd: core.home,
    labels: demo,
  );

  Future<(int, int)> sizeOf(String address) async {
    final record = await core.hc(['get', address, '--json']);
    return (record['cols'] as int, record['rows'] as int);
  }

  group('Given a terminal that printed a red word,', () {
    late HcTerminal terminal;

    setUpAll(() async {
      terminal = await colouredCat();
      await untilRead(gateway, terminal.address, 'ready');
    });

    group('when a viewer attaches, and the terminal is sent a line,', () {
      late HcViewer viewer;
      late Watched watched;
      late (int, int) sizeAfter;

      setUpAll(() async {
        viewer = await gateway.attach(terminal.address);
        watched = Watched(viewer);
        await watched.untilOutputHas('ready');
        await gateway.send(terminal.address, 'hello viewer');
        await watched.untilOutputHas('hello viewer');
        sizeAfter = await sizeOf(terminal.address);
      });

      tearDownAll(() => viewer.close());

      test('then the viewer knows the terminal it watches.', () {
        expect(viewer.terminal.address, terminal.address);
      });

      test('then its first event is the terminal\'s size.', () {
        expect(watched.events.first, HcResize(viewer.cols, viewer.rows));
      });

      test('then its first output starts with a paint, CAN first.', () {
        expect(watched.outputs.first.bytes.first, 0x18);
      });

      test('then the paint keeps the red word\'s colour.', () {
        final paint = utf8.decode(
          watched.outputs.first.bytes,
          allowMalformed: true,
        );
        expect(paint, matches(RegExp(r'\x1b\[(31|38;5;1)mred')));
      });

      test('then the line sent after it comes live.', () {
        expect(watched.text, contains('hello viewer'));
      });

      test('then the terminal kept its size, as a watching viewer\'s never '
          'counts.', () {
        expect(sizeAfter, (viewer.cols, viewer.rows));
        expect(sizeAfter, isNot((80, 24)));
      });
    });

    group('when a viewer attaches and closes,', () {
      late Watched watched;
      late HcTerminal after;

      setUpAll(() async {
        final viewer = await gateway.attach(terminal.address);
        watched = Watched(viewer);
        await watched.untilOutputHas('ready');
        await untilDone(viewer.close(), 'hc to let the viewer go');
        await gateway.send(terminal.address, 'after the viewer');
        await untilRead(gateway, terminal.address, 'after the viewer');
        after = await gateway.get(terminal.address);
      });

      test('then its events end with no error.', () async {
        expect(await watched.ended, isNull);
      });

      test('then the connection still serves calls.', () {
        expect(after.address, terminal.address);
        expect(gateway.connected, isTrue);
      });
    });
  });

  group('Given a viewer of a terminal,', () {
    late HcTerminal terminal;
    late Watched watched;

    setUpAll(() async {
      terminal = await colouredCat();
      await untilRead(gateway, terminal.address, 'ready');
      watched = Watched(await gateway.attach(terminal.address));
      await watched.untilOutputHas('ready');
    });

    group('when the terminal is killed,', () {
      setUpAll(() async {
        await gateway.kill(terminal.address);
        await untilDone(watched.ended, 'the viewer to end');
      });

      test('then the last event says it was killed.', () {
        expect(
          watched.events.last,
          isA<HcEnd>().having((end) => end.reason, 'reason', 'killed'),
        );
      });

      test('then the events end with no error.', () async {
        expect(await watched.ended, isNull);
      });

      test('then attaching again is refused as finished.', () async {
        await expectLater(
          gateway.attach(terminal.address),
          throwsA(
            isA<HcException>().having(
              (error) => error.kind,
              'kind',
              'finished',
            ),
          ),
        );
      });
    });
  });
}

/// Waits until [address]'s screen shows [text].
Future<void> untilRead(HcGateway gateway, String address, String text) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!(await gateway.read(address, lines: 0)).text.contains(text)) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('waited for "$text" on $address');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
