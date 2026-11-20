import 'dart:convert';
import 'dart:typed_data';

import 'package:hc_client/hc_client.dart';
import 'package:test/test.dart';

import 'gateway_test.dart' show connectedGateway;
import 'package:hc_client/testing.dart';
import 'support/records.dart';
import 'support/waits.dart';

void main() {
  group(
    'Given a gateway holding t1 and a missed snapshot larger than the initial event credit,',
    () {
      late FakeHcCore core;
      late HcGateway gateway;
      late Uint8List payload;
      late List<Map<String, Object?>> records;

      setUpAll(() async {
        core = await FakeHcCore.start();
        addTearDown(core.stop);
        core
          ..seq = 3
          ..terminals = [demoRecord('t1')];
        gateway = await connectedGateway(core);
        records = [
          for (var index = 0; index < 600; index++)
            demoRecord(
              't${index + 2}',
              labels: {'app': 'demo', 'demo.note': 'é' * 256},
            ),
        ];
        payload = utf8.encode(
          '${jsonEncode({
            'jsonrpc': '2.0',
            'method': 'missed',
            'params': {'seq': 57, 'terminals': records},
          })}\n',
        );
      });

      group(
        'when the snapshot spans credit-sized DATA frames with credit returned before each next frame,',
        () {
          late List<String> beforeCompletion;
          late HcResync resync;
          late int credited;
          late Map<String, HcTerminal> mirrored;

          setUpAll(() async {
            final client = core.subscribers.single;
            final resynced = next<HcResync>(gateway);
            const window = 256 * 1024;
            var offset = 0;

            while (offset < payload.length) {
              final end = (offset + window).clamp(0, payload.length);
              client.pushFrames([
                HcFrame(
                  FakeHcCore.eventChannel,
                  HcFrameKind.data,
                  Uint8List.sublistView(payload, offset, end),
                ),
              ]);
              await until(() => client.credit == end);
              if (end < payload.length) {
                beforeCompletion = gateway.terminals.keys.toList();
              }
              offset = end;
            }

            resync = await resynced;
            credited = client.credit;
            mirrored = Map.of(gateway.terminals);
          });

          test(
            'then the incomplete line leaves the previous mirror intact.',
            () {
              expect(beforeCompletion, ['t1']);
            },
          );

          test('then every payload byte is credited exactly once.', () {
            expect(credited, payload.length);
          });

          test(
            'then the whole snapshot replaces the mirror without losing text.',
            () {
              final expected = {
                for (final record in records)
                  record['address'] as String: HcTerminal.fromJson(record),
              };
              expect(mirrored, expected);
              expect(resync.terminals, expected);
            },
          );
        },
      );
    },
  );
}
