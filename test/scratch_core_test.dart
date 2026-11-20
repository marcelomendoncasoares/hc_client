@Tags(['hc'])
@Timeout(Duration(minutes: 2))
library;

import 'package:hc_client/hc_client.dart';
import 'package:test/test.dart';

import 'package:hc_client/testing.dart';
import 'support/waits.dart';

/// Runs against a real hc core of the test's own: `dart test -P hc`.
void main() {
  group('Given a gateway following a scratch core,', () {
    late ScratchCore core;
    late HcGateway gateway;

    setUpAll(() async {
      core = await ScratchCore.start();
      addTearDown(core.stop);
      gateway = await followingGateway(core);
    });

    group(
      'when terminals are run, labelled into and out of app=demo, killed and removed,',
      () {
        late HcTerminal killed;
        late HcTerminal labelledOut;
        late HcTerminal removed;
        late HcTerminal labelledIn;
        late Map<String, HcTerminal> snapshot;

        setUpAll(() async {
          killed = await gateway.run(
            argv: sleeper,
            cwd: core.home,
            labels: demo,
          );
          labelledOut = await gateway.run(
            argv: sleeper,
            cwd: core.home,
            labels: demo,
          );
          labelledIn = await gateway.run(argv: sleeper, cwd: core.home);
          removed = await gateway.run(
            argv: sleeper,
            cwd: core.home,
            labels: demo,
          );
          await gateway.label(labelledIn.address, {'app': 'demo'});
          await gateway.label(labelledOut.address, {'app': 'other'});
          await gateway.kill(killed.address);
          await gateway.kill(removed.address);
          await untilFinished(gateway, removed.address);
          await gateway.rm(removed.address);
          await mark(gateway, killed.address);
          snapshot = await snapshotOf(core);
        });

        test('then the mirror equals a fresh snapshot of the core.', () {
          expect(comparable(gateway.terminals), comparable(snapshot));
        });

        test('then it holds the terminal labelled into app=demo.', () {
          expect(gateway.terminals, contains(labelledIn.address));
        });

        test('then it no longer holds the one labelled out.', () {
          expect(gateway.terminals, isNot(contains(labelledOut.address)));
        });

        test('then it no longer holds the removed one.', () {
          expect(gateway.terminals, isNot(contains(removed.address)));
        });

        test('then it holds the killed one as finished.', () {
          expect(gateway.terminals[killed.address]!.state, 'finished');
        });
      },
    );
  });

  group('Given a gateway following a fresh scratch core,', () {
    late ScratchCore core;
    late HcGateway gateway;

    setUpAll(() async {
      core = await ScratchCore.start();
      addTearDown(core.stop);
      gateway = await followingGateway(core);
    });

    group('when 300 labels of 4 KB each are set on one terminal,', () {
      late HcTerminal terminal;

      setUpAll(() async {
        terminal = await gateway.run(
          argv: sleeper,
          cwd: core.home,
          labels: demo,
        );
        final value = 'x' * 4096;
        final last = next<HcChanged>(
          gateway,
          (change) => change.terminal.labels['demo.big'] == '300$value',
        );
        for (var i = 1; i <= 300; i++) {
          await gateway.label(terminal.address, {'demo.big': '$i$value'});
        }
        await last;
      });

      test(
        'then the mirror holds the last label, past the 256 KiB of initial credit.',
        () {
          expect(
            gateway.terminals[terminal.address]!.labels['demo.big'],
            '300${'x' * 4096}',
          );
        },
      );
    });
  });

  group(
    'Given a gateway following a scratch core with two demo terminals and a pending approval,',
    () {
      late ScratchCore core;
      late HcGateway gateway;
      late String awaitingAddress;

      setUpAll(() async {
        core = await ScratchCore.start();
        addTearDown(core.stop);
        gateway = await followingGateway(core);
        final awaiting = await gateway.run(
          argv: sleeper,
          cwd: core.home,
          labels: {
            ...demo,
            'demo.ask.a1': '{"tool":"Bash","what":"printf hello"}',
          },
        );
        awaitingAddress = awaiting.address;
        await gateway.run(argv: sleeper, cwd: core.home, labels: demo);
        await until(() => gateway.terminals.length == 2);
      });

      group('when the core restarts and a third terminal is run after it,', () {
        late HcResync resync;
        late HcTerminal third;
        late Map<String, HcTerminal> snapshot;

        setUpAll(() async {
          final resynced = next<HcResync>(gateway);
          await core.restart();
          resync = await resynced;
          third = await gateway.run(
            argv: sleeper,
            cwd: core.home,
            labels: demo,
          );
          await mark(gateway, third.address);
          snapshot = await snapshotOf(core);
        });

        test('then the gateway resynced with both terminals.', () {
          expect(resync.terminals, hasLength(2));
        });

        test('then the mirror equals a fresh snapshot of the core.', () {
          expect(comparable(gateway.terminals), comparable(snapshot));
        });

        test('then it holds the third terminal.', () {
          expect(gateway.terminals, contains(third.address));
        });

        test('then the pending approval survives the core restart.', () {
          expect(
            gateway.terminals[awaitingAddress]!.labels['demo.ask.a1'],
            '{"tool":"Bash","what":"printf hello"}',
          );
        });
      });
    },
  );

  group('Given a gateway connected to a scratch core,', () {
    late ScratchCore core;
    late HcGateway gateway;

    setUpAll(() async {
      core = await ScratchCore.start();
      addTearDown(core.stop);
      gateway = await followingGateway(core);
    });

    group(
      'when a cat terminal is run, sent a line, read, given keys, labelled and interrupted,',
      () {
        late HcTerminal run;
        late HcSendResult sent;
        late HcScreen screen;
        late HcKeysResult keys;
        late HcTerminal labelled;
        late HcTerminal got;
        late HcInterruptResult interrupted;

        setUpAll(() async {
          run = await gateway.run(
            argv: ['cat'],
            cwd: core.home,
            labels: {...demo, 'demo.chat': '1'},
          );
          sent = await gateway.send(run.address, 'hello from the gateway');
          screen = await untilScreenHas(
            gateway,
            run.address,
            'hello from the gateway',
          );
          keys = await gateway.keys(run.address, ['enter']);
          labelled = await gateway.label(run.address, {'demo.x': '1'});
          got = await gateway.get(run.address);
          interrupted = await gateway.interrupt(run.address);
        });

        test('then run returns the live record with its labels.', () {
          expect(run.live, isTrue);
          expect(run.labels, {'app': 'demo', 'demo.chat': '1'});
        });

        test('then send returns the turn it went in at.', () {
          expect(sent.turn, 0);
        });

        test('then read returns the screen with the line.', () {
          expect(screen.text, contains('hello from the gateway'));
        });

        test('then keys returns the turn.', () {
          expect(keys.turn, 0);
        });

        test('then label returns the record with the new label.', () {
          expect(labelled.labels['demo.x'], '1');
        });

        test('then get returns the same terminal.', () {
          expect(got.address, run.address);
        });

        test('then interrupt pressed ctrl+c, as cat reports no status.', () {
          expect(interrupted.key, 'ctrl+c');
        });
      },
    );
  });

  group('Given a gateway following a fresh scratch core,', () {
    late ScratchCore core;
    late HcGateway gateway;

    setUpAll(() async {
      core = await ScratchCore.start();
      addTearDown(core.stop);
      gateway = await followingGateway(core);
    });

    group('when a terminal is killed and removed,', () {
      late HcTerminal killed;
      Object? afterRemoval;

      setUpAll(() async {
        final terminal = await gateway.run(
          argv: sleeper,
          cwd: core.home,
          labels: demo,
        );
        killed = await gateway.kill(terminal.address);
        await gateway.rm(terminal.address);
        try {
          await gateway.get(terminal.address);
        } on HcException catch (error) {
          afterRemoval = error;
        }
      });

      test('then kill returns the finished record.', () {
        expect(killed.state, 'finished');
      });

      test('then get finds it no more.', () {
        expect(
          afterRemoval,
          isA<HcException>().having((error) => error.kind, 'kind', 'not_found'),
        );
      });
    });
  });
}

const demo = {'app': 'demo'};

const sleeper = ['sh', '-c', 'sleep 300'];

/// A gateway on [core], started and through its first resync.
Future<HcGateway> followingGateway(ScratchCore core) async {
  final gateway = HcGateway(
    socketPath: core.socketPath,
    filter: demo,
    minBackoff: const Duration(milliseconds: 50),
    maxBackoff: const Duration(milliseconds: 500),
  );
  addTearDown(gateway.stop);
  final resync = next<HcResync>(gateway);
  gateway.start();
  await resync;
  return gateway;
}

/// Labels [address] and waits for the gateway to see it: every event before
/// the label's has then reached the mirror too.
Future<void> mark(HcGateway gateway, String address) async {
  final marked = next<HcChanged>(
    gateway,
    (change) => change.terminal.labels['demo.mark'] == 'yes',
  );
  await gateway.label(address, {'demo.mark': 'yes'});
  await marked;
}

Future<void> untilFinished(HcGateway gateway, String address) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while ((await gateway.get(address)).live) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('$address did not finish');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<HcScreen> untilScreenHas(
  HcGateway gateway,
  String address,
  String text,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    final screen = await gateway.read(address, lines: 0);
    if (screen.text.contains(text) || DateTime.now().isAfter(deadline)) {
      return screen;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// The core's terminals in the scope now, from a subscription of its own.
Future<Map<String, HcTerminal>> snapshotOf(ScratchCore core) async {
  final connection = await HcConnection.open(core.socketPath);
  try {
    final subscription = await connection.subscribe(demo);
    return {
      for (final terminal in subscription.terminals) terminal.address: terminal,
    };
  } finally {
    connection.close();
  }
}

/// The terminals as JSON, without `status_ms`: the mirror stamps a status
/// change when it sees it, hc when it happened.
Map<String, Object?> comparable(Map<String, HcTerminal> terminals) => {
  for (final entry in terminals.entries)
    entry.key: entry.value.toJson()..remove('status_ms'),
};
