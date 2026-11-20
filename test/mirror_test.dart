import 'package:hc_client/hc_client.dart';
import 'package:test/test.dart';

import 'support/records.dart';

HcTerminal terminal(
  String address, {
  Map<String, String> labels = const {'app': 'demo'},
  Map<String, Object?>? status,
  int turn = 0,
}) => HcTerminal.fromJson(
  demoRecord(address, labels: labels, status: status, turn: turn),
);

HcEvent hcEvent(int seq, String type, String terminal, [Object? data]) =>
    HcEvent(seq: seq, type: type, terminal: terminal, data: data ?? {});

void main() {
  test(
    'Given a snapshot with a demo terminal and one labelled otherwise, '
    'when the mirror takes it, '
    'then it holds only the demo terminal.',
    () {
      final mirror = HcMirror({'app': 'demo'});

      mirror.replace(5, [
        terminal('t1'),
        terminal('t2', labels: {'app': 'other'}),
      ]);

      expect(mirror.terminals.keys, ['t1']);
    },
  );

  group('Given a mirror taken from a snapshot at seq 10 with t1 idle,', () {
    late HcMirror mirror;

    setUp(() {
      mirror = HcMirror({'app': 'demo'}, nowMs: () => 99);
      mirror.replace(10, [
        terminal('t1', status: {'state': 'idle'}),
      ]);
    });

    test(
      'when a labels event at seq 10 arrives, '
      'then it is ignored as already in the snapshot.',
      () {
        final change = mirror.apply(
          hcEvent(10, 'labels', 't1', {
            'labels': {'app': 'demo', 'demo.ask.a1': '{}'},
          }),
        );

        expect(change, isNull);
        expect(mirror.terminals['t1']!.labels, {'app': 'demo'});
      },
    );

    test(
      'when a status event at seq 11 says working, '
      'then t1 is working since now, and the change says so.',
      () {
        final change = mirror.apply(
          hcEvent(11, 'status', 't1', {
            'status': {'state': 'working', 'app': 'claude-code'},
            'records': {},
            'reported': true,
          }),
        );

        expect(
          mirror.terminals['t1']!.status,
          const HcStatus('working', app: 'claude-code'),
        );
        expect(mirror.terminals['t1']!.statusMs, 99);
        expect(
          change,
          isA<HcChanged>().having((c) => c.type, 'type', 'status'),
        );
      },
    );

    test(
      'when a status event keeps the word idle with a new message, '
      'then the time of the word stays the snapshot\'s.',
      () {
        mirror.apply(
          hcEvent(11, 'status', 't1', {
            'status': {'state': 'idle', 'msg': 'ready'},
            'records': {},
            'reported': true,
          }),
        );

        expect(mirror.terminals['t1']!.statusMs, 1794031258000);
      },
    );

    test(
      'when a turn event at seq 11 says turn 3, '
      'then t1 is at turn 3.',
      () {
        mirror.apply(hcEvent(11, 'turn', 't1', {'turn': 3, 'state': 'idle'}));

        expect(mirror.terminals['t1']!.turn, 3);
      },
    );

    test(
      'when a labels event adds an ask label, '
      'then t1 carries exactly the event\'s labels.',
      () {
        mirror.apply(
          hcEvent(11, 'labels', 't1', {
            'labels': {
              'app': 'demo',
              'demo.ask.a1': '{"tool":"Bash","what":"ls"}',
            },
          }),
        );

        expect(mirror.terminals['t1']!.labels, {
          'app': 'demo',
          'demo.ask.a1': '{"tool":"Bash","what":"ls"}',
        });
      },
    );

    test(
      'when a labels event takes app=demo off t1, '
      'then t1 leaves the mirror as removed.',
      () {
        final change = mirror.apply(
          hcEvent(11, 'labels', 't1', {
            'labels': {'app': 'other'},
          }),
        );

        expect(mirror.terminals, isNot(contains('t1')));
        expect(change, isA<HcRemoved>());
      },
    );

    test(
      'when a labels event brings t2 in with its record, '
      'then t2 is added with the event\'s labels.',
      () {
        final change = mirror.apply(
          hcEvent(11, 'labels', 't2', {
            'labels': {'app': 'demo', 'demo.chat': '4'},
            'record': demoRecord('t2', labels: {'app': 'other'}),
          }),
        );

        expect(change, isA<HcAdded>());
        expect(mirror.terminals['t2']!.labels, {
          'app': 'demo',
          'demo.chat': '4',
        });
      },
    );

    test(
      'when a created event for t2 arrives, '
      'then t2 is added from its record.',
      () {
        final change = mirror.apply(
          hcEvent(11, 'created', 't2', demoRecord('t2')),
        );

        expect(change, isA<HcAdded>());
        expect(mirror.terminals['t2'], terminal('t2'));
      },
    );

    test(
      'when a finished event says t1 was killed, '
      'then t1 is finished with its reason, signal and time.',
      () {
        mirror.apply(
          hcEvent(11, 'finished', 't1', {
            'exit_code': null,
            'finished_ms': 1794031259153,
            'reason': 'killed',
            'signal': 1,
          }),
        );

        final t1 = mirror.terminals['t1']!;
        expect(
          (t1.state, t1.reason, t1.signal, t1.finishedMs),
          (
            'finished',
            'killed',
            1,
            1794031259153,
          ),
        );
      },
    );

    test(
      'when a lost event says its holder was lost, '
      'then t1 stays live with that reason.',
      () {
        mirror.apply(
          hcEvent(11, 'lost', 't1', {
            'exit_code': null,
            'finished_ms': null,
            'reason': 'holder_lost',
            'signal': null,
          }),
        );

        final t1 = mirror.terminals['t1']!;
        expect((t1.state, t1.reason), ('live', 'holder_lost'));
      },
    );

    test(
      'when a restarted event brings a new record, '
      'then t1 is that record.',
      () {
        mirror.apply(
          hcEvent(11, 'restarted', 't1', demoRecord('t1', turn: 4)),
        );

        expect(mirror.terminals['t1'], terminal('t1', turn: 4));
      },
    );

    test(
      'when a removed event arrives, '
      'then t1 leaves the mirror as removed.',
      () {
        final change = mirror.apply(hcEvent(11, 'removed', 't1'));

        expect(mirror.terminals, isEmpty);
        expect(change, isA<HcRemoved>());
      },
    );

    test(
      'when title and keep events arrive, '
      'then t1 has the new title and keeps.',
      () {
        mirror
          ..apply(hcEvent(11, 'title', 't1', {'title': 'Fix the bug'}))
          ..apply(hcEvent(12, 'keep', 't1', {'keep': true}));

        final t1 = mirror.terminals['t1']!;
        expect((t1.title, t1.keep), ('Fix the bug', true));
      },
    );

    test(
      'when foreground and unknown events arrive, '
      'then t1 is unchanged and no change is reported.',
      () {
        final before = mirror.terminals['t1'];

        final changes = [
          mirror.apply(hcEvent(11, 'foreground', 't1', null)),
          mirror.apply(hcEvent(12, 'telepathy', 't1', {'x': 1})),
        ];

        expect(changes, [null, null]);
        expect(mirror.terminals['t1'], before);
      },
    );

    test(
      'when an event for a terminal outside the mirror arrives, '
      'then nothing changes.',
      () {
        final change = mirror.apply(hcEvent(11, 'turn', 't9', {'turn': 1}));

        expect(change, isNull);
        expect(mirror.terminals.keys, ['t1']);
      },
    );
  });

  group('Given a mirror at seq 900 holding t1 and t2,', () {
    late HcMirror mirror;

    setUp(() {
      mirror = HcMirror({'app': 'demo'});
      mirror.replace(900, [terminal('t1'), terminal('t2')]);
    });

    test(
      'when a restarted core\'s snapshot at seq 0 holds only t2, '
      'then t1 is gone and t2 stays.',
      () {
        mirror.replace(0, [terminal('t2')]);

        expect(mirror.terminals.keys, ['t2']);
      },
    );

    test(
      'when a restarted core\'s snapshot at seq 0 is followed by an event at seq 1, '
      'then the event is applied.',
      () {
        mirror
          ..replace(0, [terminal('t2')])
          ..apply(hcEvent(1, 'turn', 't2', {'turn': 2}));

        expect(mirror.terminals['t2']!.turn, 2);
      },
    );
  });

  group('Given a mirror at seq 20 holding t1 and t2,', () {
    late HcMirror mirror;

    setUp(() {
      mirror = HcMirror({'app': 'demo'});
      mirror.replace(20, [terminal('t1'), terminal('t2')]);
    });

    test(
      'when a missed snapshot at seq 57 holds only t1 at turn 5, '
      'then the mirror and the resync hold only t1, at turn 5.',
      () {
        final resync = mirror.replace(57, [terminal('t1', turn: 5)]);

        expect(mirror.terminals, {'t1': terminal('t1', turn: 5)});
        expect(resync.terminals, {'t1': terminal('t1', turn: 5)});
      },
    );

    test(
      'when a missed snapshot at seq 57 is followed by an event at seq 57, '
      'then the event is ignored.',
      () {
        mirror.replace(57, [terminal('t1', turn: 5)]);

        final change = mirror.apply(hcEvent(57, 'turn', 't1', {'turn': 4}));

        expect(change, isNull);
        expect(mirror.terminals['t1']!.turn, 5);
      },
    );
  });
}
