import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../frame.dart';

/// An in-process stand-in for an hc core on a Unix socket: it shakes hands,
/// answers `events.subscribe` with [seq] and [terminals], and `terminal.list`
/// from [terminals], and lets a test push event-channel lines and stream
/// frames, drop connections and restart, at exact points.
///
/// It speaks the wire format as the real core does; this package's
/// scratch-core tests check the gateway against the real one.
final class FakeHcCore {
  FakeHcCore._(this._directory, this.socketPath);

  /// Starts a core whose socket is in a new temporary folder.
  static Future<FakeHcCore> start({
    int generation = 1,
    List<String> features = const ['framed', 'events', 'status'],
  }) async {
    final directory = await Directory.systemTemp.createTemp('hc.');
    final core = FakeHcCore._(directory, '${directory.path}/core.sock')
      ..generation = generation
      ..features = features;
    await core.listen();
    return core;
  }

  final Directory _directory;
  final String socketPath;
  int generation = 1;
  List<String> features = const [];

  /// What the next `events.subscribe` answers, and `terminal.list` lists.
  int seq = 0;
  List<Map<String, Object?>> terminals = [];

  /// Event-channel lines sent in the same write as the subscribe reply,
  /// before it.
  List<Map<String, Object?>> beforeSubscribeReply = [];

  /// Event-channel lines sent in the same write as the subscribe reply,
  /// after it.
  List<Map<String, Object?>> afterSubscribeReply = [];

  /// Accepts the subscription call but keeps its reply pending.
  bool holdSubscribeReply = false;

  /// A frame sent in the same write as the `hello` reply, after its newline.
  HcFrame? afterHello;

  /// Answers every call but `events.subscribe`: a result, or throws a
  /// [FakeHcError] for an error reply. A future holds the reply until it
  /// completes. Returning [noReply] sends nothing.
  Object? Function(String method, Map<String, Object?> params) onCall =
      (method, params) => throw FakeHcError('unknown_method', method);

  static const noReply = Object();

  /// Frames sent in the same write as a reply to the method named, after
  /// it, such as a viewer's first output after `terminal.attach`'s reply.
  Map<String, List<HcFrame>> afterReply = {};

  /// Whether a client's CLOSE on a stream channel is answered with one, as
  /// hc does once it let the viewer go.
  bool echoClose = true;

  /// The event channel the subscribe reply names.
  static const eventChannel = 1;

  final calls = <(String, Map<String, Object?>)>[];

  /// The plain-mode `hello` lines clients sent, as written.
  final helloLines = <String>[];
  final _clients = <FakeHcClient>[];
  final _subscribed = StreamController<FakeHcClient>.broadcast();
  ServerSocket? _server;
  var _connections = 0;

  /// How many connections reached the core so far.
  int get connections => _connections;

  /// The connections that subscribed and are still open.
  List<FakeHcClient> get subscribers => [
    for (final client in _clients)
      if (client.subscribed && !client.closed) client,
  ];

  /// The next client to subscribe.
  Future<FakeHcClient> nextSubscriber() => _subscribed.stream.first;

  Future<void> listen() async {
    _server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    _server!.listen((socket) {
      _connections++;
      _clients.add(FakeHcClient._(this, socket));
    });
  }

  /// Sends [message] as one event-channel line to every subscriber.
  void push(Map<String, Object?> message) {
    for (final client in subscribers) {
      client.pushLine(message);
    }
  }

  /// Drops every connection and stops listening, like a core that went away.
  Future<void> down() async {
    await _server?.close();
    _server = null;
    for (final client in _clients) {
      client.drop();
    }
    final socket = File(socketPath);
    if (socket.existsSync()) socket.deleteSync();
  }

  /// [down], then listening again with a new snapshot, like a core restart.
  Future<void> restart({
    required int seq,
    required List<Map<String, Object?>> terminals,
  }) async {
    await down();
    this.seq = seq;
    this.terminals = terminals;
    await listen();
  }

  Future<void> stop() async {
    await down();
    await _subscribed.close();
    await _directory.delete(recursive: true);
  }
}

/// An error reply with this `data.kind`.
final class FakeHcError {
  FakeHcError(this.kind, this.message);

  final String kind;
  final String message;
}

/// One connection to the fake core.
final class FakeHcClient {
  FakeHcClient._(this._core, this._socket) {
    _socket.listen(_onBytes, onDone: drop, onError: (_) => drop());
    // A write after the client closed its end, as a reset, fails here.
    unawaited(_socket.done.then<void>((_) {}, onError: (_) => drop()));
  }

  final FakeHcCore _core;
  final Socket _socket;
  final _decoder = HcFrameDecoder();
  final _plain = BytesBuilder();
  var _framed = false;
  var subscribed = false;
  var closed = false;

  final _done = Completer<void>();

  /// Completes when this side observes the connection close.
  Future<void> get done => _done.future;

  /// The CREDIT the client sent for the event channel, in bytes.
  var credit = 0;

  /// The CREDIT the client sent for each stream channel, in bytes.
  final credits = <int, int>{};

  /// The stream channels the client sent CLOSE on, in order.
  final closes = <int>[];

  /// The sizes the client sent in RESIZE, in order.
  final resizes = <({int channel, int cols, int rows})>[];

  /// The DATA bytes sent to the client on the event channel.
  var sent = 0;

  /// Sends [message] as one line on the event channel.
  void pushLine(Map<String, Object?> message) => _write([_line(message)]);

  /// Sends raw [frames] in one write.
  void pushFrames(List<HcFrame> frames) => _write(frames);

  /// Sends raw [bytes], framed or not.
  void pushBytes(List<int> bytes) {
    if (!closed) _socket.add(bytes);
  }

  void drop() {
    if (closed) return;
    closed = true;
    _socket.destroy();
    _done.complete();
  }

  HcFrame _line(Map<String, Object?> message) {
    final payload = utf8.encode('${jsonEncode(message)}\n');
    sent += payload.length;
    return HcFrame(FakeHcCore.eventChannel, HcFrameKind.data, payload);
  }

  void _write(List<HcFrame> frames, {String? plain}) {
    if (closed) return;
    final bytes = BytesBuilder();
    if (plain != null) bytes.add(utf8.encode(plain));
    for (final frame in frames) {
      bytes.add(frame.encode());
    }
    _socket.add(bytes.takeBytes());
  }

  void _onBytes(Uint8List chunk) {
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
    for (final frame in _decoder.add(bytes)) {
      if (frame.channel == FakeHcCore.eventChannel &&
          frame.kind == HcFrameKind.credit) {
        credit += frame.credit;
      } else if (frame.channel != 0 && frame.kind == HcFrameKind.credit) {
        credits[frame.channel] = (credits[frame.channel] ?? 0) + frame.credit;
      } else if (frame.channel != 0 && frame.kind == HcFrameKind.close) {
        closes.add(frame.channel);
        if (_core.echoClose) {
          _write([HcFrame(frame.channel, HcFrameKind.close, Uint8List(0))]);
        }
      } else if (frame.kind == HcFrameKind.resize &&
          frame.payload.length == 4) {
        final size = ByteData.sublistView(frame.payload);
        resizes.add((
          channel: frame.channel,
          cols: size.getUint16(0, Endian.little),
          rows: size.getUint16(2, Endian.little),
        ));
      } else if (frame.channel == 0 && frame.kind == HcFrameKind.data) {
        _onCall(
          (jsonDecode(utf8.decode(frame.payload)) as Map)
              .cast<String, Object?>(),
        );
      }
    }
  }

  void _onHello(String line) {
    _core.helloLines.add(line);
    final hello = jsonDecode(line) as Map;
    final reply = {
      'jsonrpc': '2.0',
      'id': hello['id'],
      'result': {
        'core': {'id': 'fake', 'name': 'fake'},
        'features': _core.features,
        'framed': true,
        'generation': _core.generation,
        'methods': <String>[],
        'version': '0.1.18',
      },
    };
    _write([
      ?_core.afterHello,
    ], plain: '${jsonEncode(reply)}\n');
  }

  void _onCall(Map<String, Object?> message) async {
    final method = message['method'] as String;
    final params = (message['params'] as Map? ?? {}).cast<String, Object?>();
    _core.calls.add((method, params));
    if (method == 'events.subscribe') {
      subscribed = true;
      if (_core.holdSubscribeReply) {
        _core._subscribed.add(this);
        return;
      }
      _write([
        for (final line in _core.beforeSubscribeReply) _line(line),
        HcFrame.rpc({
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': {
            'channel': FakeHcCore.eventChannel,
            'seq': _core.seq,
            'terminals': _core.terminals,
          },
        }),
        for (final line in _core.afterSubscribeReply) _line(line),
      ]);
      _core._subscribed.add(this);
      return;
    }
    if (method == 'terminal.list') {
      final labels = (params['labels'] as Map? ?? {}).cast<String, Object?>();
      _write([
        HcFrame.rpc({
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': {
            'terminals': [
              for (final terminal in _core.terminals)
                if ((params['all'] == true || terminal['state'] == 'live') &&
                    labels.entries.every(
                      (label) =>
                          (terminal['labels'] as Map?)?[label.key] ==
                          label.value,
                    ))
                  terminal,
            ],
            'hidden_finished': 0,
            'machines': <Object?>[],
          },
        }),
      ]);
      return;
    }
    final Object? result;
    try {
      final answer = _core.onCall(method, params);
      result = answer is Future<Object?> ? await answer : answer;
    } on FakeHcError catch (error) {
      _write([
        HcFrame.rpc({
          'jsonrpc': '2.0',
          'id': message['id'],
          'error': {
            'code': -32000,
            'message': error.message,
            'data': {'kind': error.kind},
          },
        }),
      ]);
      return;
    }
    if (identical(result, FakeHcCore.noReply)) return;
    _write([
      HcFrame.rpc({'jsonrpc': '2.0', 'id': message['id'], 'result': result}),
      ...?_core.afterReply[method],
    ]);
  }
}

/// A terminal record as hc sends it, with the given facts.
Map<String, Object?> terminalRecord(
  String address, {
  Map<String, String> labels = const {},
  Map<String, Object?>? status,
  int turn = 0,
  String state = 'live',
}) => {
  'address': address,
  'argv': ['claude'],
  'cols': 200,
  'created_ms': 1794031257032,
  'cwd': '/work/demo',
  'die_with_parent': false,
  'exit_code': null,
  'finished_ms': null,
  'identity': 'ghostty',
  'keep': false,
  'labels': labels,
  'name': null,
  'notify': false,
  'parent': null,
  'pid': 4242,
  'reason': null,
  'records': <String, Object?>{},
  'reported': status != null,
  'rm': false,
  'rows': 120,
  'screen': 'exact',
  'signal': null,
  'state': state,
  'status': status,
  'status_ms': status == null ? null : 1794031258000,
  'template': null,
  'title': '',
  'turn': turn,
};

/// An `event` notification.
Map<String, Object?> event(
  int seq,
  String type,
  String terminal, [
  Object? data = const <String, Object?>{},
]) => {
  'jsonrpc': '2.0',
  'method': 'event',
  'params': {'seq': seq, 'type': type, 'terminal': terminal, 'data': data},
};
