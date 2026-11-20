import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'errors.dart';
import 'frame.dart';
import 'notification.dart';
import 'terminal.dart';

/// One framed connection to an hc core: JSON-RPC on
/// channel 0, and the event subscription on its own channel with credit.
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
  final _channels = <int, _Channel>{};
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
    final completer = _pending.remove(message['id']);
    if (completer == null) return;
    final error = message['error'];
    if (error is Map) {
      completer.completeError(HcException.fromJson(error.cast()));
    } else {
      completer.complete(message['result']);
    }
  }

  _Channel _channel(int number) => _channels.putIfAbsent(number, _Channel.new);

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

final class _Channel {
  final lines = HcLineBuffer();
  final controller = StreamController<HcNotification>();
}
