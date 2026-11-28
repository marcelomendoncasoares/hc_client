import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

/// The kinds of hc frames. The client uses DATA (calls on channel 0, and a
/// viewer's output and input on its own), CREDIT, CLOSE and, for a viewer,
/// RESIZE; it never sends the others, which carry a terminal emulator's
/// focus, display facts and automatic replies.
abstract final class HcFrameKind {
  static const data = 0;
  static const credit = 1;
  static const close = 2;
  static const resize = 3;
  static const focus = 4;
  static const facts = 5;
  static const automaticInput = 6;
}

/// One frame: `[channel u32 LE][kind u8][len u32 LE][payload]`.
final class HcFrame {
  const HcFrame(this.channel, this.kind, this.payload);

  /// A CREDIT frame granting [bytes] more bytes on [channel].
  factory HcFrame.credit(int channel, int bytes) => HcFrame(
    channel,
    HcFrameKind.credit,
    (ByteData(4)..setUint32(0, bytes, Endian.little)).buffer.asUint8List(),
  );

  /// A RESIZE frame: [cols] × [rows] cells, for a viewer on [channel].
  factory HcFrame.resize(int channel, int cols, int rows) => HcFrame(
    channel,
    HcFrameKind.resize,
    (ByteData(4)
          ..setUint16(0, cols, Endian.little)
          ..setUint16(2, rows, Endian.little))
        .buffer
        .asUint8List(),
  );

  /// A DATA frame on channel 0 carrying one JSON-RPC message.
  factory HcFrame.rpc(Object message) => HcFrame(
    0,
    HcFrameKind.data,
    utf8.encode(jsonEncode(message)),
  );

  final int channel;
  final int kind;
  final Uint8List payload;

  /// The CREDIT amount, for a CREDIT frame.
  int get credit => ByteData.sublistView(payload).getUint32(0, Endian.little);

  Uint8List encode() {
    final bytes = Uint8List(headerLength + payload.length);
    ByteData.sublistView(bytes)
      ..setUint32(0, channel, Endian.little)
      ..setUint8(4, kind)
      ..setUint32(5, payload.length, Endian.little);
    bytes.setRange(headerLength, bytes.length, payload);
    return bytes;
  }

  static const headerLength = 9;

  /// The largest payload hc sends or accepts.
  static const maxPayload = 16 * 1024 * 1024;
}

/// Cuts a byte stream into frames, whatever the read boundaries.
final class HcFrameDecoder {
  final _pending = BytesBuilder(copy: false);

  /// Adds [chunk] and returns the frames it completes, in order.
  ///
  /// Throws [HcProtocolException] for a payload above
  /// [HcFrame.maxPayload].
  List<HcFrame> add(List<int> chunk) {
    _pending.add(chunk);
    final bytes = _pending.takeBytes();
    final frames = <HcFrame>[];
    var offset = 0;
    while (bytes.length - offset >= HcFrame.headerLength) {
      final header = ByteData.sublistView(bytes, offset);
      final length = header.getUint32(5, Endian.little);
      if (length > HcFrame.maxPayload) {
        throw HcProtocolException(
          'a frame of $length bytes, above the ${HcFrame.maxPayload} limit',
        );
      }
      final end = offset + HcFrame.headerLength + length;
      if (end > bytes.length) break;
      frames.add(
        HcFrame(
          header.getUint32(0, Endian.little),
          header.getUint8(4),
          Uint8List.sublistView(bytes, offset + HcFrame.headerLength, end),
        ),
      );
      offset = end;
    }
    if (offset < bytes.length) {
      _pending.add(Uint8List.sublistView(bytes, offset));
    }
    return frames;
  }
}

/// Cuts a stream channel's bytes into lines: the event channel carries one
/// JSON message per line, and a line may span frames.
final class HcLineBuffer {
  HcLineBuffer({this.maxLine = 64 * 1024 * 1024});

  /// The longest line accepted, so a broken stream cannot grow without
  /// bound. A `missed` snapshot of many terminals is the longest real line.
  final int maxLine;

  final _pending = BytesBuilder(copy: false);

  /// Adds [chunk] and returns the lines it completes, without their `\n`.
  List<String> add(List<int> chunk) {
    final lines = <String>[];
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 0x0a) continue;
      _checkLength(_pending.length + i - start);
      _pending.add(Uint8List.sublistView(_asBytes(chunk), start, i));
      final line = _pending.takeBytes();
      if (line.isNotEmpty) lines.add(utf8.decode(line));
      start = i + 1;
    }
    if (start < chunk.length) {
      _pending.add(Uint8List.sublistView(_asBytes(chunk), start));
    }
    _checkLength(_pending.length);
    return lines;
  }

  void _checkLength(int length) {
    if (length > maxLine) {
      throw HcProtocolException('an event line longer than $maxLine bytes');
    }
  }

  static Uint8List _asBytes(List<int> chunk) =>
      chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
}
