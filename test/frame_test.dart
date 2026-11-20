import 'dart:convert';
import 'dart:typed_data';

import 'package:hc_client/hc_client.dart';
import 'package:test/test.dart';

/// Bytes from a hex string; spaces are for reading only.
String heartbeatHex() => [
  for (final byte in utf8.encode('{"method":"heartbeat"}\n'))
    byte.toRadixString(16).padLeft(2, '0'),
].join();

Uint8List hex(String text) {
  final digits = text.replaceAll(' ', '');
  return Uint8List.fromList([
    for (var i = 0; i < digits.length; i += 2)
      int.parse(digits.substring(i, i + 2), radix: 16),
  ]);
}

/// A frame as `channel kind payload-hex`, for comparing frames.
String describe(HcFrame frame) =>
    '${frame.channel} ${frame.kind} ${[for (final byte in frame.payload) byte.toRadixString(16).padLeft(2, '0')].join()}';

void main() {
  test(
    'Given a grant of 256 KiB on channel 1, '
    'when it is encoded as a CREDIT frame, '
    'then the bytes are channel, kind, length and amount, little-endian.',
    () {
      final bytes = HcFrame.credit(1, 256 * 1024).encode();

      expect(bytes, hex('01000000 01 04000000 00000400'));
    },
  );

  test(
    'Given a JSON-RPC call, '
    'when it is encoded, '
    'then it is a DATA frame on channel 0 carrying the JSON.',
    () {
      final bytes = HcFrame.rpc({'id': 1}).encode();

      expect(bytes, [
        ...hex('00000000 00 08000000'),
        ...utf8.encode('{"id":1}'),
      ]);
    },
  );

  group('Given a heartbeat DATA frame on channel 1 and a CREDIT frame,', () {
    final heartbeat = utf8.encode('{"method":"heartbeat"}\n');
    late Uint8List bytes;

    setUpAll(() {
      bytes = Uint8List.fromList([
        ...hex('01000000 00'),
        ...hex('17000000'),
        ...heartbeat,
        ...hex('01000000 01 04000000 10000000'),
      ]);
    });

    test(
      'when the bytes arrive in one read, '
      'then both frames come out with their channel, kind and payload.',
      () {
        final frames = HcFrameDecoder().add(bytes);

        expect(
          [
            for (final frame in frames) describe(frame),
          ],
          [
            '1 0 ${heartbeatHex()}',
            '1 1 10000000',
          ],
        );
      },
    );

    test(
      'when the bytes arrive split at any byte, '
      'then the same two frames come out.',
      () {
        final cuts = <List<String>>[];
        for (var cut = 0; cut <= bytes.length; cut++) {
          final decoder = HcFrameDecoder();
          final frames = [
            ...decoder.add(Uint8List.sublistView(bytes, 0, cut)),
            ...decoder.add(Uint8List.sublistView(bytes, cut)),
          ];
          cuts.add([
            for (final frame in frames) describe(frame),
          ]);
        }

        expect(
          cuts,
          everyElement([
            '1 0 ${heartbeatHex()}',
            '1 1 10000000',
          ]),
        );
      },
    );
  });

  test(
    'Given a frame header announcing 16 MiB and one byte, '
    'when it is decoded, '
    'then it is refused as a protocol error.',
    () {
      expect(
        () => HcFrameDecoder().add(hex('01000000 00 01000001')),
        throwsA(isA<HcProtocolException>()),
      );
    },
  );

  test(
    'Given a frame header announcing a payload not yet received, '
    'when it is decoded, '
    'then no frame comes out.',
    () {
      final frames = HcFrameDecoder().add(hex('01000000 00 05000000 7b22'));

      expect(frames, isEmpty);
    },
  );

  group(
    'Given an event line split across two DATA payloads, '
    'when both payloads are read in order,',
    () {
      late List<String> first;
      late List<String> second;

      setUpAll(() {
        final lines = HcLineBuffer();
        first = lines.add(utf8.encode('{"seq":1}\n{"se'));
        second = lines.add(utf8.encode('q":2}\n'));
      });

      test('then the first read yields only its whole line.', () {
        expect(first, ['{"seq":1}']);
      });

      test('then the second read yields the split line whole.', () {
        expect(second, ['{"seq":2}']);
      });
    },
  );

  test(
    'Given a line buffer limited to 8 bytes, '
    'when 9 bytes arrive without a newline, '
    'then it is refused as a protocol error.',
    () {
      expect(
        () => HcLineBuffer(maxLine: 8).add(utf8.encode('{"seq":1}')),
        throwsA(isA<HcProtocolException>()),
      );
    },
  );

  test(
    'Given a line with a multi-byte character split between payloads, '
    'when both are read, '
    'then the character comes out whole.',
    () {
      final bytes = utf8.encode('{"msg":"é"}\n');
      final lines = HcLineBuffer();

      final out = [
        ...lines.add(bytes.sublist(0, 9)),
        ...lines.add(bytes.sublist(9)),
      ];

      expect(out, ['{"msg":"é"}']);
    },
  );

  test(
    'Given a line buffer limited to 8 bytes, '
    'when a 9-byte line arrives with its newline, '
    'then it is refused as a protocol error.',
    () {
      final lines = HcLineBuffer(maxLine: 8);

      expect(
        () => lines.add(utf8.encode('{"seq":1}\n')),
        throwsA(isA<HcProtocolException>()),
      );
    },
  );
}
