import 'dart:convert';
import 'dart:typed_data';

/// What a viewer receives from hc, in order: [HcOutput], [HcResize], and an
/// [HcEnd] last when the terminal's program ends.
sealed class HcViewerEvent {
  const HcViewerEvent();
}

/// Bytes for a terminal emulator, as the program printed them, colours and
/// all. The first ones paint the terminal's current screen; the rest follow
/// live. A viewer that fell behind gets a fresh paint in their place, which
/// starts with CAN (`0x18`) and redraws the whole screen.
final class HcOutput extends HcViewerEvent {
  const HcOutput(this.bytes);

  final Uint8List bytes;

  @override
  String toString() => 'HcOutput(${bytes.length} bytes)';
}

/// The terminal's size, in cells: the output after it is drawn at this size.
/// It comes first, before the first paint, and again each time the terminal
/// is resized, before the paint at the new size.
final class HcResize extends HcViewerEvent {
  const HcResize(this.cols, this.rows);

  final int cols;
  final int rows;

  @override
  bool operator ==(Object other) =>
      other is HcResize && other.cols == cols && other.rows == rows;

  @override
  int get hashCode => Object.hash(cols, rows);

  @override
  String toString() => 'HcResize($cols × $rows)';
}

/// The terminal's program ended, after its last output: the stream ends
/// here. [reason] is hc's, as on the terminal's record, such as `exited`,
/// `killed`, `server_stop` or `holder_lost`. A kept terminal (`hc keep`)
/// comes back with a new program: attach again after its `restarted` event.
final class HcEnd extends HcViewerEvent {
  const HcEnd({this.reason, this.exitCode, this.signal, this.finishedMs});

  /// Reads the reason hc gives as it closes the stream.
  factory HcEnd.fromPayload(List<int> payload) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(payload, allowMalformed: true));
    } on FormatException {
      return const HcEnd();
    }
    if (json is! Map) return const HcEnd();
    final end = json;
    int? number(String key) => end[key] is int ? end[key] as int : null;
    return HcEnd(
      reason: end['reason'] is String ? end['reason'] as String : null,
      exitCode: number('exit_code'),
      signal: number('signal'),
      finishedMs: number('finished_ms'),
    );
  }

  final String? reason;
  final int? exitCode;
  final int? signal;
  final int? finishedMs;

  @override
  bool operator ==(Object other) =>
      other is HcEnd &&
      other.reason == reason &&
      other.exitCode == exitCode &&
      other.signal == signal &&
      other.finishedMs == finishedMs;

  @override
  int get hashCode => Object.hash(reason, exitCode, signal, finishedMs);

  @override
  String toString() =>
      'HcEnd(reason: $reason, exitCode: $exitCode, signal: $signal)';
}
