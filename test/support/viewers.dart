import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hc_client/hc_client.dart';

import 'waits.dart';

/// Everything a viewer's events brought, as they come.
final class Watched {
  Watched(HcViewer viewer) {
    viewer.events.listen(
      events.add,
      onError: (Object error) => _error = error,
      onDone: () => _ended.complete(_error),
    );
  }

  final events = <HcViewerEvent>[];
  final _ended = Completer<Object?>();
  Object? _error;

  /// Completes when the events end: with the error they ended with, or null.
  Future<Object?> get ended => _ended.future;

  bool get isEnded => _ended.isCompleted;

  List<HcOutput> get outputs => [...events.whereType<HcOutput>()];

  /// The output so far as text.
  String get text => utf8.decode(
    [for (final output in outputs) ...output.bytes],
    allowMalformed: true,
  );

  Future<void> untilOutputHas(String wanted) =>
      until(() => text.contains(wanted), what: '"$wanted" in the output');
}

/// What a core answers `terminal.attach` with: [channel], [terminal]'s
/// record, and resize notifications.
Map<String, Object?> attachResult(
  int channel,
  Map<String, Object?> terminal,
) => {
  'channel': channel,
  'terminal': terminal,
  'resize_notifications': true,
  'automatic_input': true,
};

HcFrame outputFrame(int channel, String text) =>
    HcFrame(channel, HcFrameKind.data, utf8.encode(text));

HcFrame resizeFrame(int channel, int cols, int rows) => HcFrame(
  channel,
  HcFrameKind.resize,
  (ByteData(4)
        ..setUint16(0, cols, Endian.little)
        ..setUint16(2, rows, Endian.little))
      .buffer
      .asUint8List(),
);

/// hc's CLOSE: with [end], the program's end; without, a bare one.
HcFrame closeFrame(int channel, [Map<String, Object?>? end]) => HcFrame(
  channel,
  HcFrameKind.close,
  end == null ? Uint8List(0) : utf8.encode(jsonEncode(end)),
);
