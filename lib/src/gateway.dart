import 'dart:async';
import 'dart:math';

import 'connection.dart';
import 'errors.dart';
import 'mirror.dart';
import 'notification.dart';
import 'terminal.dart';

/// A lasting connection to an hc core: typed calls on its terminals, and a
/// mirror of the terminals carrying [filter]'s labels that equals hc's
/// after every event, reconnect and core restart.
///
/// It connects to an existing core only, never starting one, and keeps
/// reconnecting with backoff while it runs.
final class HcGateway {
  HcGateway({
    required this.socketPath,
    this.filter = const {},
    this.heartbeatTimeout = const Duration(seconds: 45),
    this.minBackoff = const Duration(milliseconds: 250),
    this.maxBackoff = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 10),
    this.requiredFeatures = HcConnection.defaultRequiredFeatures,
    void Function(String message)? log,
    Random? random,
  }) : _log = log ?? ((_) {}),
       _random = random ?? Random(),
       _mirror = HcMirror(filter);

  /// The core's socket, such as `$XDG_RUNTIME_DIR/herdr-core/default.sock`.
  final String socketPath;

  /// The labels that scope the subscription and the mirror: the terminals
  /// carrying every one of them. Empty, the default, holds them all.
  final Map<String, String> filter;

  /// hc sends a heartbeat every 15 s. With nothing on the event channel for
  /// this long, the connection is taken for dead and made again.
  final Duration heartbeatTimeout;

  /// The first wait before reconnecting; each failure doubles it, up to
  /// [maxBackoff], and a subscription resets it.
  final Duration minBackoff;
  final Duration maxBackoff;
  final Duration connectTimeout;

  /// The features a core must offer, checked at each connect
  /// ([HcConnection.open]).
  final Set<String> requiredFeatures;

  final void Function(String message) _log;
  final Random _random;
  final HcMirror _mirror;
  final _changes = StreamController<HcChange>.broadcast(sync: true);
  final _connectedChanges = StreamController<bool>.broadcast(sync: true);
  HcConnection? _connection;

  /// The connection being subscribed, before its snapshot makes it live.
  HcConnection? _opening;
  Future<void>? _loop;
  Completer<void>? _wake;
  var _stopped = false;
  var _synced = false;
  final _firstTry = Completer<bool>();
  var _failures = 0;

  /// The terminals in the scope, by address, as of the last event. While
  /// disconnected, the last view hc gave.
  Map<String, HcTerminal> get terminals => _mirror.terminals;

  /// Whether the mirror is live: connected and subscribed.
  bool get connected => _connection != null;

  /// Whether hc has given the mirror its terminals once: until then,
  /// [terminals] knows none of them, as while the gateway starts.
  bool get synced => _synced;

  /// Completes with [synced] once the gateway's first try to subscribe
  /// ends: true when hc gave the mirror its terminals, false when the try
  /// failed or the gateway stopped first.
  Future<bool> get firstTry => _firstTry.future;

  /// Every change to the mirror, starting with an [HcResync] at each
  /// subscription.
  Stream<HcChange> get changes => _changes.stream;

  /// Whether the mirror is live, each time that changes.
  Stream<bool> get connectedChanges => _connectedChanges.stream;

  /// Starts connecting in the background.
  void start() {
    if (_loop != null) throw StateError('the gateway is already running');
    _loop = _run();
  }

  /// Stops reconnecting and closes the connection.
  Future<void> stop() async {
    _stopped = true;
    if (!_firstTry.isCompleted) _firstTry.complete(_synced);
    (_connection ?? _opening)?.close('the gateway stopped');
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
    await _loop;
  }

  /// `terminal.run`: starts [argv] in a new terminal. The gateway adds no
  /// labels: [labels] must include the filter's for the mirror to hold it.
  ///
  /// With [parent], the terminal is that one's child: [outliveParent] keeps
  /// it running when the parent's program ends, and [noNotify] keeps hc
  /// from typing its own notes about it into the parent. Without, it has
  /// no parent.
  Future<HcTerminal> run({
    required List<String> argv,
    String? cwd,
    Map<String, String> env = const {},
    Map<String, String> labels = const {},
    String? name,
    String? parent,
    bool outliveParent = false,
    bool noNotify = false,
    Duration timeout = const Duration(seconds: 60),
  }) async => _terminal(
    await call('terminal.run', {
      'argv': argv,
      'cwd': ?cwd,
      'env': env,
      'labels': labels,
      'name': ?name,
      if (parent == null)
        'no_parent': true
      else ...{
        'parent': parent,
        'outlive_parent': outliveParent,
        'no_notify': noNotify,
      },
    }, timeout: timeout),
  );

  /// `terminal.get`: one terminal's facts, live or finished.
  Future<HcTerminal> get(
    String terminal, {
    Duration timeout = defaultTimeout,
  }) async => _terminal(
    await call('terminal.get', {'terminal': terminal}, timeout: timeout),
  );

  /// `terminal.send`: pastes [text] and presses Enter. hc refuses a blocked
  /// program with `blocked`. With [caller], another terminal sends it, and
  /// hc wraps it as from that one (`<hc from="t7">…</hc>`).
  Future<HcSendResult> send(
    String terminal,
    String text, {
    String? caller,
    Duration timeout = const Duration(seconds: 60),
  }) async => HcSendResult.fromJson(
    _map(
      await call('terminal.send', {
        'terminal': terminal,
        'text': text,
        'caller': ?caller,
      }, timeout: timeout),
    ),
  );

  /// `terminal.keys`: presses named keys, such as `enter` or `esc`.
  Future<HcKeysResult> keys(
    String terminal,
    List<String> keys, {
    Duration timeout = defaultTimeout,
  }) async => HcKeysResult.fromJson(
    _map(
      await call('terminal.keys', {
        'terminal': terminal,
        'keys': keys,
      }, timeout: timeout),
    ),
  );

  /// `terminal.interrupt`: presses the stop key and reports what followed.
  Future<HcInterruptResult> interrupt(
    String terminal, {
    Duration timeout = defaultTimeout,
  }) async => HcInterruptResult.fromJson(
    _map(
      await call('terminal.interrupt', {
        'terminal': terminal,
      }, timeout: timeout),
    ),
  );

  /// `terminal.kill`: ends the program and returns its record.
  Future<HcTerminal> kill(
    String terminal, {
    Duration timeout = defaultTimeout,
  }) async => _terminal(
    await call('terminal.kill', {'terminal': terminal}, timeout: timeout),
  );

  /// `terminal.rm`: removes a finished terminal.
  Future<void> rm(String terminal, {Duration timeout = defaultTimeout}) async {
    await call('terminal.rm', {'terminal': terminal}, timeout: timeout);
  }

  /// `terminal.label`: sets labels; an empty value removes one.
  Future<HcTerminal> label(
    String terminal,
    Map<String, String> labels, {
    Duration timeout = defaultTimeout,
  }) async => _terminal(
    await call('terminal.label', {
      'terminal': terminal,
      'labels': labels,
    }, timeout: timeout),
  );

  /// `terminal.read`: the screen, plus [lines] of history, as text.
  Future<HcScreen> read(
    String terminal, {
    int? lines,
    Duration timeout = defaultTimeout,
  }) async => HcScreen.fromJson(
    _map(
      await call('terminal.read', {
        'terminal': terminal,
        'lines': ?lines,
      }, timeout: timeout),
    ),
  );

  /// `terminal.list`: hc's live terminals carrying every one of [labels],
  /// whatever the [filter], and finished ones too with [all]. Throws as
  /// [call] does.
  Future<List<HcTerminal>> list({
    Map<String, String> labels = const {},
    bool all = false,
    Duration timeout = defaultTimeout,
  }) async {
    final listed = await call('terminal.list', {
      if (labels.isNotEmpty) 'labels': labels,
      if (all) 'all': true,
    }, timeout: timeout);
    return terminalsFromJson(listed is Map ? listed['terminals'] : null);
  }

  /// How long a call waits for hc's answer unless told otherwise: `run`
  /// and `send` wait 60 s, since hc answers them once the program runs or
  /// the text went in.
  static const defaultTimeout = Duration(seconds: 30);

  /// Calls [method] on the live connection. Throws [HcUnavailableException]
  /// while disconnected, and [HcException] for hc's errors.
  Future<Object?> call(
    String method,
    Map<String, Object?> params, {
    Duration timeout = defaultTimeout,
  }) {
    final connection = _connection;
    if (connection == null) {
      return Future.error(
        const HcUnavailableException(
          'the gateway is not connected to hc',
          sent: false,
        ),
      );
    }
    return connection.call(method, params, timeout: timeout);
  }

  Future<void> _run() async {
    while (!_stopped) {
      HcConnection? connection;
      try {
        connection = _opening = await HcConnection.open(
          socketPath,
          timeout: connectTimeout,
          requiredFeatures: requiredFeatures,
        );
        if (_stopped) break;
        final subscription = await connection.subscribe(filter);
        if (_stopped) break;
        _failures = 0;
        _connection = connection;
        _synced = true;
        _changes.add(_mirror.replace(subscription.seq, subscription.terminals));
        if (!_firstTry.isCompleted) _firstTry.complete(true);
        _connectedChanges.add(true);
        _log(
          'connected to hc ${connection.hello.version} at $socketPath: '
          '${subscription.terminals.length} terminals at seq '
          '${subscription.seq}',
        );
        await _follow(connection, subscription.notifications);
      } on Object catch (error) {
        if (!_stopped) _log('hc: $error');
      } finally {
        if (!_firstTry.isCompleted) _firstTry.complete(_synced);
        _opening = null;
        connection?.close();
        if (identical(_connection, connection) && connection != null) {
          _connection = null;
          _connectedChanges.add(false);
        }
      }
      if (_stopped) break;
      await _backoff();
    }
  }

  Future<void> _follow(
    HcConnection connection,
    Stream<HcNotification> notifications,
  ) async {
    Timer? watchdog;
    void watch() {
      watchdog?.cancel();
      watchdog = Timer(heartbeatTimeout, () {
        _log('hc: nothing on the event channel for $heartbeatTimeout');
        connection.close('no heartbeat');
      });
    }

    watch();
    try {
      await for (final notification in notifications) {
        watch();
        switch (notification) {
          case HcEvent():
            _onEvent(notification);
          case HcMissed(:final seq, :final terminals):
            _log('hc: missed events up to seq $seq; resyncing');
            _changes.add(_mirror.replace(seq, terminals));
          case HcHeartbeat():
            break;
          case HcOtherNotification(:final method):
            _log('hc: ignored a "$method" notification');
        }
      }
    } finally {
      watchdog?.cancel();
    }
  }

  void _onEvent(HcEvent event) {
    if (!HcMirror.modelledTypes.contains(event.type) &&
        !HcMirror.ignoredTypes.contains(event.type)) {
      _log('hc: ignored a "${event.type}" event on ${event.terminal}');
    }
    final change = _mirror.apply(event);
    if (change != null) _changes.add(change);
  }

  Future<void> _backoff() async {
    final exponent = min(_failures++, 16);
    final ceiling = min(
      maxBackoff.inMicroseconds,
      minBackoff.inMicroseconds * (1 << exponent),
    );
    // Half fixed, half random, so many clients would not retry in step.
    final delay = Duration(
      microseconds: ceiling ~/ 2 + _random.nextInt(max(1, ceiling ~/ 2)),
    );
    final wake = _wake = Completer<void>();
    final timer = Timer(delay, () {
      if (!wake.isCompleted) wake.complete();
    });
    await wake.future;
    timer.cancel();
    _wake = null;
  }

  static Map<String, Object?> _map(Object? result) {
    if (result is Map) return result.cast<String, Object?>();
    throw HcProtocolException('hc answered $result where a record was due');
  }

  static HcTerminal _terminal(Object? result) {
    try {
      return HcTerminal.fromJson(_map(result));
    } on FormatException catch (error) {
      throw HcProtocolException(error.message);
    }
  }
}
