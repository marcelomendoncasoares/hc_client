import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'errors.dart';
import 'frame.dart';
import 'notification.dart';
import 'terminal.dart';
import 'viewer.dart';

/// One framed connection to an hc core: JSON-RPC on channel 0, and the
/// event subscription and each viewer on channels of their own, with credit.
///
/// It only ever connects to an existing socket, so it never starts a core.
final class HcConnection {
  HcConnection._(this._socket);

  /// The `hello` line, sent before the connection is framed.
  static const helloLine =
      '{"jsonrpc":"2.0","id":0,"method":"hello",'
      '"params":{"framed":true,"generation":1}}\n';

  /// The protocol generation this client speaks.
  static const generation = 1;

  /// The features [open] asks of a core unless told otherwise: framed
  /// mode and the event channel.
  static const defaultRequiredFeatures = {'framed', 'events'};

  /// Connects to the core at [socketPath] and shakes hands. Throws
  /// [HcUnavailableException] when nothing answers there, and
  /// [HcProtocolException] when the core speaks another protocol, or lacks
  /// one of [requiredFeatures], such as `status` for OSC 7501 reports.
  static Future<HcConnection> open(
    String socketPath, {
    Duration timeout = const Duration(seconds: 10),
    Set<String> requiredFeatures = defaultRequiredFeatures,
  }) async {
    final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
        timeout: timeout,
      );
    } on SocketException catch (error) {
      throw HcUnavailableException('no core at $socketPath: ${error.message}');
    }
    final connection = HcConnection._(socket);
    try {
      connection._listen();
      connection.hello = await connection._handshake(
        timeout,
        requiredFeatures,
      );
      return connection;
    } catch (_) {
      connection.close();
      rethrow;
    }
  }

  final Socket _socket;
  final _decoder = HcFrameDecoder();
  final _plain = BytesBuilder(copy: false);
  final _pending = <int, Completer<Object?>>{};

  /// What a call whose reply opens a stream does with it, run as the reply
  /// is read, before the frames after it: a viewer's first ones may come in
  /// the same read.
  final _opens = <int, void Function(Object? result)>{};
  final _channels = <int, _Channel>{};
  final _viewers = <int, HcViewer>{};

  /// The viewers this client closed, until hc's CLOSE says it let them go:
  /// what hc sent before that is dropped.
  final _closing = <int, Completer<void>>{};
  final _done = Completer<void>();
  Completer<Object?>? _hello;
  var _framed = false;
  var _nextId = 1;
  Object? _closeReason;

  /// What the core said in `hello`.
  late final HcHello hello;

  /// Completes when the connection is over, for whatever reason.
  Future<void> get done => _done.future;

  bool get isClosed => _done.isCompleted;

  /// Calls [method] and returns its `result`. Throws [HcException] for an
  /// error reply, and [HcUnavailableException] when the connection is or
  /// goes down, or the reply takes longer than [timeout].
  Future<Object?> call(
    String method,
    Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 30),
  }) => _call(method, params, timeout);

  Future<Object?> _call(
    String method,
    Map<String, Object?> params,
    Duration timeout, {
    void Function(Object? result)? opens,
  }) {
    if (isClosed) {
      return Future.error(
        const HcUnavailableException(
          'the connection to hc is closed',
          sent: false,
        ),
      );
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    if (opens != null) _opens[id] = opens;
    _write(
      HcFrame.rpc({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw HcUnavailableException(
          '$method had no answer in ${timeout.inMilliseconds} ms',
        );
      },
    );
  }

  /// Subscribes to the terminals carrying [labels]. The notifications that
  /// follow the snapshot arrive on [HcSubscription.notifications], in order,
  /// including any that arrived before the reply.
  Future<HcSubscription> subscribe(Map<String, String> labels) async {
    final result = await call('events.subscribe', {'labels': labels});
    if (result is! Map || result['channel'] is! int || result['seq'] is! int) {
      throw const HcProtocolException(
        'events.subscribe answered without a channel and seq',
      );
    }
    final channel = _channel(result['channel'] as int);
    return HcSubscription._(
      result['seq'] as int,
      terminalsFromJson(result['terminals']),
      channel.controller.stream,
    );
  }

  /// `terminal.attach`, watching only: a viewer of [terminal]'s screen that
  /// never types into it or resizes it, whatever the other viewers do. Its
  /// [HcViewer.events] start with the screen as it is and follow it live.
  ///
  /// [history] adds that many lines of scrollback before the first paint
  /// (on the main screen only). [caller] names the terminal calling, if one
  /// does: hc refuses a terminal watching itself. Throws [HcException] as
  /// hc refuses, such as `not_found` or `finished`, and as [call] does.
  Future<HcViewer> attach(
    String terminal, {
    int history = 0,
    String? caller,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    HcViewer? viewer;
    Object? failure;
    var abandoned = false;
    try {
      await _call(
        'terminal.attach',
        {
          'terminal': terminal,
          'observe': true,
          'resize_notifications': true,
          'history': history,
          // hc needs a viewer's size, but a watching one's never counts.
          'cols': 80,
          'rows': 24,
          'caller': ?caller,
        },
        timeout,
        opens: (result) {
          if (result is! Map || result['channel'] is! int) return;
          final channel = result['channel'] as int;
          // An answer that came after the call gave up: no one watches it.
          if (abandoned) return unawaited(_closeViewer(channel));
          final record = result['terminal'];
          try {
            viewer = _viewers[channel] = HcViewer._(
              this,
              channel,
              record is Map ? record.cast<String, Object?>() : const {},
              resizeNotifications: result['resize_notifications'] == true,
            );
          } on FormatException catch (error) {
            failure = HcProtocolException(error.message);
            unawaited(_closeViewer(channel));
          }
        },
      );
    } catch (_) {
      abandoned = true;
      rethrow;
    }
    if (failure case final failure?) throw failure;
    return viewer ??
        (throw const HcProtocolException(
          'terminal.attach answered without a channel',
        ));
  }

  /// Ends the connection. Pending calls fail with [HcUnavailableException].
  void close([Object? reason]) {
    _closeReason ??= reason;
    _socket.destroy();
    _finish();
  }

  void _listen() {
    _socket.listen(
      _onBytes,
      onError: (Object error) => close(error),
      onDone: close,
      cancelOnError: true,
    );
    // A write to a socket the core already closed, such as the credit for
    // its last event, fails here, not in add: it ends the connection.
    unawaited(
      _socket.done.then<void>(
        (_) {},
        onError: (Object error) => close(error),
      ),
    );
  }

  Future<HcHello> _handshake(
    Duration timeout,
    Set<String> requiredFeatures,
  ) async {
    _hello = Completer<Object?>();
    _socket.write(helloLine);
    final reply = await _hello!.future.timeout(
      timeout,
      onTimeout: () => throw const HcUnavailableException(
        'hc did not answer hello',
      ),
    );
    if (reply is! Map) {
      throw const HcProtocolException('hello answered without a result');
    }
    final hello = HcHello.fromJson(reply.cast<String, Object?>());
    if (hello.generation != generation) {
      throw HcProtocolException(
        'hc speaks protocol generation ${hello.generation}, '
        'this client $generation',
      );
    }
    final missing = requiredFeatures.difference(hello.features);
    if (missing.isNotEmpty || !hello.framed) {
      throw HcProtocolException(
        'hc lacks ${missing.isEmpty ? 'framed mode' : missing.join(', ')}',
      );
    }
    return hello;
  }

  void _onBytes(Uint8List chunk) {
    try {
      var bytes = chunk;
      if (!_framed) {
        final newline = bytes.indexOf(0x0a);
        if (newline < 0) {
          _plain.add(bytes);
          return;
        }
        _plain.add(Uint8List.sublistView(bytes, 0, newline));
        _framed = true;
        _onHello(utf8.decode(_plain.takeBytes()));
        bytes = Uint8List.sublistView(bytes, newline + 1);
      }
      final credits = <int, int>{};
      for (final frame in _decoder.add(bytes)) {
        _onFrame(frame, credits);
      }
      for (final entry in credits.entries) {
        _write(HcFrame.credit(entry.key, entry.value));
      }
    } on Object catch (error) {
      close(error);
    }
  }

  void _onHello(String line) {
    final hello = _hello;
    if (hello == null || hello.isCompleted) return;
    final message = jsonDecode(line);
    if (message is Map && message['error'] is Map) {
      hello.completeError(
        HcException.fromJson((message['error'] as Map).cast()),
      );
    } else {
      hello.complete(message is Map ? message['result'] : null);
    }
  }

  void _onFrame(HcFrame frame, Map<int, int> credits) {
    if (frame.channel == 0) {
      if (frame.kind == HcFrameKind.data) _onReply(frame.payload);
      if (frame.kind == HcFrameKind.close) close('hc closed the connection');
      return;
    }
    final closing = _closing[frame.channel];
    if (closing != null) {
      if (frame.kind == HcFrameKind.close) {
        _closing.remove(frame.channel);
        closing.complete();
      }
      return;
    }
    final viewer = _viewers[frame.channel];
    if (viewer != null) {
      viewer._onFrame(frame);
      return;
    }
    final channel = _channel(frame.channel);
    switch (frame.kind) {
      case HcFrameKind.data:
        credits[frame.channel] =
            (credits[frame.channel] ?? 0) + frame.payload.length;
        for (final line in channel.lines.add(frame.payload)) {
          final message = jsonDecode(line);
          if (message is Map) {
            channel.controller.add(
              HcNotification.fromJson(message.cast<String, Object?>()),
            );
          }
        }
      case HcFrameKind.close:
        channel.controller.addError(
          HcUnavailableException(
            'hc closed channel ${frame.channel}: '
            '${utf8.decode(frame.payload, allowMalformed: true)}',
          ),
        );
        unawaited(channel.controller.close());
    }
  }

  void _onReply(Uint8List payload) {
    final message = jsonDecode(utf8.decode(payload));
    if (message is! Map || message['id'] is! int) return;
    final error = message['error'];
    final opens = _opens.remove(message['id']);
    if (opens != null && error is! Map) opens(message['result']);
    final completer = _pending.remove(message['id']);
    if (completer == null) return;
    if (error is Map) {
      completer.completeError(HcException.fromJson(error.cast()));
    } else {
      completer.complete(message['result']);
    }
  }

  _Channel _channel(int number) => _channels.putIfAbsent(number, _Channel.new);

  /// Sends CLOSE for [channel] and lets the viewer go: completes when hc
  /// says it let go too, or the connection ends.
  Future<void> _closeViewer(int channel) {
    _viewers.remove(channel);
    if (isClosed) return Future.value();
    final closing = _closing[channel] ??= Completer<void>();
    _write(HcFrame(channel, HcFrameKind.close, Uint8List(0)));
    return closing.future;
  }

  void _write(HcFrame frame) {
    if (isClosed) return;
    try {
      _socket.add(frame.encode());
    } on Object catch (error) {
      close(error);
    }
  }

  void _finish() {
    if (_done.isCompleted) return;
    final reason = _closeReason ?? 'hc closed the connection';
    final error = HcUnavailableException(
      'the connection to hc closed: $reason',
    );
    final hello = _hello;
    if (hello != null && !hello.isCompleted) hello.completeError(error);
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
    _opens.clear();
    for (final viewer in [..._viewers.values]) {
      viewer._fail(error);
    }
    _viewers.clear();
    for (final closing in _closing.values) {
      closing.complete();
    }
    _closing.clear();
    for (final channel in _channels.values) {
      if (channel.controller.isClosed) continue;
      channel.controller.addError(error);
      unawaited(channel.controller.close());
    }
    _done.complete();
  }
}

/// A subscription's snapshot, and what follows it.
final class HcSubscription {
  HcSubscription._(this.seq, this.terminals, this.notifications);

  /// Events after this sequence follow.
  final int seq;
  final List<HcTerminal> terminals;

  /// Events, heartbeats and `missed`, in order. Ends with an
  /// [HcUnavailableException] when the channel or the connection closes.
  final Stream<HcNotification> notifications;
}

/// One viewer of a terminal, watching only, from [HcConnection.attach]:
/// its output, its resizes and its end, in order.
final class HcViewer {
  HcViewer._(
    this._connection,
    this._channel,
    Map<String, Object?> record, {
    required this.resizeNotifications,
  }) : terminal = HcTerminal.fromJson(record),
       cols = record['cols'] is int ? record['cols'] as int : 0,
       rows = record['rows'] is int ? record['rows'] as int : 0 {
    _controller = StreamController<HcViewerEvent>(
      // A listener that cancels lets the viewer go, without waiting on hc.
      onCancel: () => unawaited(close()),
    );
    // Credit goes back as the listener takes each output, not as it comes
    // in: a listener that pauses holds hc back, and past hc's limit gets a
    // fresh paint in place of what it missed.
    events = _controller.stream.map((event) {
      if (event is HcOutput && !_ended && !_connection.isClosed) {
        _connection._write(HcFrame.credit(_channel, event.bytes.length));
      }
      return event;
    });
  }

  final HcConnection _connection;
  final int _channel;
  late final StreamController<HcViewerEvent> _controller;
  var _ended = false;
  Future<void>? _closed;

  /// The terminal as it was when the viewer attached.
  final HcTerminal terminal;

  /// The terminal's size when the viewer attached, in cells.
  final int cols;
  final int rows;

  /// Whether [events] carry each [HcResize]: always for a terminal on this
  /// core. For one on another machine whose core can't relay them, they
  /// don't, and [cols] and [rows] are all the viewer knows of its size.
  final bool resizeNotifications;

  /// What hc sends this viewer: an [HcResize] and the first paint, then the
  /// live output. A single-subscription stream: listen once, at once.
  ///
  /// It ends after an [HcEnd] when the program ends, when [close] is
  /// called or the listener cancels, and with an [HcUnavailableException]
  /// when the connection goes or hc ends the stream for another reason.
  late final Stream<HcViewerEvent> events;

  /// Stops watching: [events] ends, and hc lets the viewer go. Completes
  /// once hc says it did, or the connection is over.
  Future<void> close() => _closed ??= _close();

  Future<void> _close() async {
    if (_ended) return;
    _ended = true;
    unawaited(_controller.close());
    await _connection._closeViewer(_channel);
  }

  void _onFrame(HcFrame frame) {
    if (_ended) return;
    switch (frame.kind) {
      case HcFrameKind.data:
        _controller.add(HcOutput(frame.payload));
      case HcFrameKind.resize when frame.payload.length == 4:
        final size = ByteData.sublistView(frame.payload);
        _controller.add(
          HcResize(
            size.getUint16(0, Endian.little),
            size.getUint16(2, Endian.little),
          ),
        );
      case HcFrameKind.close:
        _connection._viewers.remove(_channel);
        _ended = true;
        if (frame.payload.isEmpty) {
          _controller.addError(
            const HcUnavailableException('hc ended the viewer\'s stream'),
          );
        } else {
          _controller.add(HcEnd.fromPayload(frame.payload));
        }
        unawaited(_controller.close());
    }
  }

  void _fail(Object error) {
    if (_ended) return;
    _ended = true;
    _controller.addError(error);
    unawaited(_controller.close());
  }
}

final class _Channel {
  final lines = HcLineBuffer();
  final controller = StreamController<HcNotification>();
}
