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

  /// [address]'s size, asked on the viewers' own connection: after every
  /// RESIZE the gateway sent before, which hc reads in order.
  Future<(int, int)> sizeOf(String address) async {
    final record =
        await gateway.call('terminal.get', {'terminal': address}) as Map;
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

  group('Given a terminal with a watching viewer,', () {
    late HcTerminal terminal;
    late Watched watched;
    late (int, int) headless;

    setUpAll(() async {
      terminal = await colouredCat();
      await untilRead(gateway, terminal.address, 'ready');
      headless = await sizeOf(terminal.address);
      watched = Watched(await gateway.attach(terminal.address));
      await watched.untilOutputHas('ready');
    });

    group('when sizing viewers attach, resize and close,', () {
      late HcViewer first;
      final sizes = <String, (int, int)>{};

      setUpAll(() async {
        final address = terminal.address;
        first = await gateway.attach(address, size: (cols: 100, rows: 30));
        sizes['first attached'] = await sizeOf(address);
        first.resize(90, 25);
        sizes['first resized'] = await sizeOf(address);
        final second = await gateway.attach(
          address,
          size: (cols: 120, rows: 40),
        );
        sizes['second attached'] = await sizeOf(address);
        await untilDone(second.close(), 'hc to let the second go');
        sizes['second closed'] = await sizeOf(address);
        await untilDone(first.close(), 'hc to let the first go');
        sizes['first closed'] = await sizeOf(address);
        await until(
          () => watched.events.whereType<HcResize>().length == 6,
          what: 'the watching viewer to see six sizes',
        );
      });

      test('then the sizing viewer knows the size it attached with.', () {
        expect((first.cols, first.rows), (100, 30));
        expect(first.sizing, isTrue);
      });

      test('then the latest to attach or resize sized the terminal, and as '
          'each went, the one before took it back.', () {
        expect(sizes, {
          'first attached': (100, 30),
          'first resized': (90, 25),
          'second attached': (120, 40),
          'second closed': (90, 25),
          'first closed': headless,
        });
      });

      test('then the watching viewer saw each size, in order.', () {
        expect(watched.events.whereType<HcResize>(), [
          HcResize(headless.$1, headless.$2),
          const HcResize(100, 30),
          const HcResize(90, 25),
          const HcResize(120, 40),
          const HcResize(90, 25),
          HcResize(headless.$1, headless.$2),
        ]);
      });
    });
  });

  group('Given a terminal that reads a line, sized by two viewers, the '
      'second attached last,', () {
    late HcTerminal terminal;
    late HcViewer first;
    late HcViewer second;

    setUpAll(() async {
      terminal = await gateway.run(
        argv: ['sh', '-c', r'echo ready; read line; echo "got <$line>"'],
        cwd: core.home,
        labels: demo,
      );
      await untilRead(gateway, terminal.address, 'ready');
      first = await gateway.attach(
        terminal.address,
        size: (cols: 100, rows: 30),
      );
      second = await gateway.attach(
        terminal.address,
        size: (cols: 120, rows: 40),
      );
    });

    tearDownAll(() async {
      await first.close();
      await second.close();
    });

    group('when the first types "?€" and Enter,', () {
      late (int, int) sizeBefore;
      late (int, int) sizeAfter;

      setUpAll(() async {
        sizeBefore = await sizeOf(terminal.address);
        first.input(utf8.encode('?€\r'));
        await untilRead(gateway, terminal.address, 'got <');
        sizeAfter = await sizeOf(terminal.address);
      });

      test('then the program read the line as typed.', () async {
        final screen = await gateway.read(terminal.address, lines: 0);

        expect(screen.text, contains('got <?€>'));
      });

      test(
        'then the first sized the terminal again, as the latest to type.',
        () {
          expect(sizeBefore, (120, 40));
          expect(sizeAfter, (100, 30));
        },
      );
    });
  });

  group('Given a sizing viewer of a terminal that prints 1 MB on a line, '
      'then exits,', () {
    late Watched sized;

    setUpAll(() async {
      final terminal = await gateway.run(
        argv: ['sh', '-c', 'read line; yes | head -c 1000000; exit 3'],
        cwd: core.home,
        labels: demo,
      );
      sized = Watched(
        await gateway.attach(terminal.address, size: (cols: 100, rows: 30)),
      );
      await gateway.send(terminal.address, 'go');
      await untilDone(sized.ended, 'the sizing viewer to end');
    });

    test('then its events brought the end alone, after all that output.', () {
      expect(sized.events, [
        isA<HcEnd>()
            .having((end) => end.reason, 'reason', 'exited')
            .having((end) => end.exitCode, 'exitCode', 3),
      ]);
    });

    test('then they end with no error.', () async {
      expect(await sized.ended, isNull);
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
