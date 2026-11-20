/// hc's records, as the client reads them. Words stay hc's own: a status
/// word this client doesn't know is kept as it came.
library;

/// One OSC 7501 record: the program's own word for what it's doing.
final class HcStatus {
  const HcStatus(
    this.state, {
    this.kind,
    this.app,
    this.msg,
    this.title,
    this.progress,
  });

  static HcStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    return HcStatus(
      _string(json['state']) ?? '',
      kind: _string(json['kind']),
      app: _string(json['app']),
      msg: _string(json['msg']),
      title: _string(json['title']),
      progress: _int(json['progress']),
    );
  }

  /// `idle`, `working`, `done`, `blocked` or `error`, or a newer word.
  final String state;

  /// `permission`, `question` or `auth`, when `blocked` says why.
  final String? kind;
  final String? app;
  final String? msg;
  final String? title;
  final int? progress;

  Map<String, Object?> toJson() => {
    'state': state,
    'kind': ?kind,
    'app': ?app,
    'msg': ?msg,
    'title': ?title,
    'progress': ?progress,
  };

  @override
  bool operator ==(Object other) =>
      other is HcStatus &&
      other.state == state &&
      other.kind == kind &&
      other.app == app &&
      other.msg == msg &&
      other.title == title &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(state, kind, app, msg, title, progress);

  @override
  String toString() => 'HcStatus(${toJson()})';
}

/// One hc terminal: the facts hc reports of it.
final class HcTerminal {
  const HcTerminal({
    required this.address,
    required this.state,
    this.name,
    this.argv = const [],
    this.cwd = '',
    this.labels = const {},
    this.status,
    this.statusMs,
    this.records = const {},
    this.reported = false,
    this.turn = 0,
    this.createdMs = 0,
    this.finishedMs,
    this.exitCode,
    this.signal,
    this.reason,
    this.title = '',
    this.keep = false,
    this.parent,
    this.pid,
  });

  /// Reads a terminal record (`Terminal` in hc's schema). Throws
  /// [FormatException] without an address.
  factory HcTerminal.fromJson(Map<String, Object?> json) {
    final address = _string(json['address']);
    if (address == null || address.isEmpty) {
      throw const FormatException('a terminal record without an address');
    }
    return HcTerminal(
      address: address,
      state: _string(json['state']) ?? 'live',
      name: _string(json['name']),
      argv: [
        for (final arg in json['argv'] is List ? json['argv'] as List : [])
          if (arg is String) arg,
      ],
      cwd: _string(json['cwd']) ?? '',
      labels: labelsFromJson(json['labels']),
      status: HcStatus.fromJson(json['status']),
      statusMs: _int(json['status_ms']),
      records: recordsFromJson(json['records']),
      reported: json['reported'] == true,
      turn: _int(json['turn']) ?? 0,
      createdMs: _int(json['created_ms']) ?? 0,
      finishedMs: _int(json['finished_ms']),
      exitCode: _int(json['exit_code']),
      signal: _int(json['signal']),
      reason: _string(json['reason']),
      title: _string(json['title']) ?? '',
      keep: json['keep'] == true,
      parent: _string(json['parent']),
      pid: _int(json['pid']),
    );
  }

  /// `t7`: the terminal's address on its core, forever.
  final String address;

  /// `live` or `finished`.
  final String state;
  final String? name;
  final List<String> argv;

  /// The launch folder.
  final String cwd;

  /// Its labels: hc's way to tag a terminal, and to scope a list or a
  /// subscription to the terminals that carry them.
  final Map<String, String> labels;

  /// The root OSC 7501 record; null if it never said, or after it exited.
  final HcStatus? status;

  /// When [status]'s word last changed, ms since the epoch.
  final int? statusMs;

  /// The program's other OSC 7501 records, by id.
  final Map<String, HcStatus> records;

  /// Whether the program ever sent an OSC 7501 report.
  final bool reported;

  /// Goes up each time the status leaves `working`, also into `blocked`.
  final int turn;
  final int createdMs;
  final int? finishedMs;
  final int? exitCode;
  final int? signal;

  /// Why the program ended or is pending, such as `exited` or `killed`.
  final String? reason;
  final String title;
  final bool keep;
  final String? parent;
  final int? pid;

  bool get live => state == 'live';

  /// Whether its program finished with no one choosing it: nothing ran it
  /// any more after hc's restart (`stopped_by_restart`), the host shut down
  /// or its user logged out (`host_shutdown`), or its holder died
  /// (`holder_lost`). The other reasons, `exited`, `killed` and the rest,
  /// are the program's or someone's choice.
  bool get lost => !live && _lostReasons.contains(reason);

  static const _lostReasons = {
    'stopped_by_restart',
    'host_shutdown',
    'holder_lost',
  };

  HcTerminal copyWith({
    String? state,
    Map<String, String>? labels,
    Object? status = _keep,
    Object? statusMs = _keep,
    Map<String, HcStatus>? records,
    bool? reported,
    int? turn,
    Object? finishedMs = _keep,
    Object? exitCode = _keep,
    Object? signal = _keep,
    Object? reason = _keep,
    String? title,
    bool? keep,
    Object? pid = _keep,
  }) => HcTerminal(
    address: address,
    state: state ?? this.state,
    name: name,
    argv: argv,
    cwd: cwd,
    labels: labels ?? this.labels,
    status: identical(status, _keep) ? this.status : status as HcStatus?,
    statusMs: identical(statusMs, _keep) ? this.statusMs : statusMs as int?,
    records: records ?? this.records,
    reported: reported ?? this.reported,
    turn: turn ?? this.turn,
    createdMs: createdMs,
    finishedMs: identical(finishedMs, _keep)
        ? this.finishedMs
        : finishedMs as int?,
    exitCode: identical(exitCode, _keep) ? this.exitCode : exitCode as int?,
    signal: identical(signal, _keep) ? this.signal : signal as int?,
    reason: identical(reason, _keep) ? this.reason : reason as String?,
    title: title ?? this.title,
    keep: keep ?? this.keep,
    parent: parent,
    pid: identical(pid, _keep) ? this.pid : pid as int?,
  );

  static const _keep = Object();

  Map<String, Object?> toJson() => {
    'address': address,
    'state': state,
    'name': name,
    'argv': argv,
    'cwd': cwd,
    'labels': labels,
    'status': status?.toJson(),
    'status_ms': statusMs,
    'records': {
      for (final entry in records.entries) entry.key: entry.value.toJson(),
    },
    'reported': reported,
    'turn': turn,
    'created_ms': createdMs,
    'finished_ms': finishedMs,
    'exit_code': exitCode,
    'signal': signal,
    'reason': reason,
    'title': title,
    'keep': keep,
    'parent': parent,
    'pid': pid,
  };

  @override
  bool operator ==(Object other) =>
      other is HcTerminal &&
      other.address == address &&
      other.state == state &&
      other.name == name &&
      _listEquals(other.argv, argv) &&
      other.cwd == cwd &&
      _mapEquals(other.labels, labels) &&
      other.status == status &&
      other.statusMs == statusMs &&
      _mapEquals(other.records, records) &&
      other.reported == reported &&
      other.turn == turn &&
      other.createdMs == createdMs &&
      other.finishedMs == finishedMs &&
      other.exitCode == exitCode &&
      other.signal == signal &&
      other.reason == reason &&
      other.title == title &&
      other.keep == keep &&
      other.parent == parent &&
      other.pid == pid;

  @override
  int get hashCode => Object.hash(address, state, turn, status, labels.length);

  @override
  String toString() => 'HcTerminal(${toJson()})';
}

/// The answer to `terminal.send`.
final class HcSendResult {
  const HcSendResult({required this.turn, this.status, this.started});

  factory HcSendResult.fromJson(Map<String, Object?> json) => HcSendResult(
    turn: _int(json['turn']) ?? 0,
    status: _string(json['status']),
    started: json['started'] is bool ? json['started'] as bool : null,
  );

  /// The turn when the text went in.
  final int turn;

  /// The status word when it went in.
  final String? status;

  /// Whether the agent started working on it.
  final bool? started;
}

/// The answer to `terminal.keys`.
final class HcKeysResult {
  const HcKeysResult({required this.turn, this.status});

  factory HcKeysResult.fromJson(Map<String, Object?> json) => HcKeysResult(
    turn: _int(json['turn']) ?? 0,
    status: _string(json['status']),
  );

  final int turn;
  final String? status;
}

/// The answer to `terminal.interrupt`: the key pressed and what followed.
final class HcInterruptResult {
  const HcInterruptResult({required this.key, required this.outcome});

  factory HcInterruptResult.fromJson(Map<String, Object?> json) =>
      HcInterruptResult(
        key: _string(json['key']) ?? '',
        outcome: _string(json['outcome']) ?? '',
      );

  final String key;
  final String outcome;
}

/// The answer to `terminal.read`: the screen plus history as text.
final class HcScreen {
  const HcScreen({
    required this.text,
    required this.complete,
    required this.how,
    this.why,
  });

  factory HcScreen.fromJson(Map<String, Object?> json) => HcScreen(
    text: _string(json['text']) ?? '',
    complete: json['complete'] == true,
    how: _string(json['how']) ?? '',
    why: _string(json['why']),
  );

  final String text;

  /// False when hc returned only the screen, with [why] the status word.
  final bool complete;
  final String how;
  final String? why;
}

/// What `hello` told the client about the core.
final class HcHello {
  const HcHello({
    required this.generation,
    required this.version,
    required this.coreId,
    required this.framed,
    required this.features,
  });

  factory HcHello.fromJson(Map<String, Object?> json) {
    final core = json['core'];
    return HcHello(
      generation: _int(json['generation']) ?? -1,
      version: _string(json['version']) ?? '',
      coreId: core is Map ? _string(core['id']) ?? '' : '',
      framed: json['framed'] == true,
      features: {
        for (final feature
            in json['features'] is List ? json['features'] as List : [])
          if (feature is String) feature,
      },
    );
  }

  final int generation;
  final String version;
  final String coreId;
  final bool framed;
  final Set<String> features;
}

/// Reads a `labels` object, keeping its string values.
Map<String, String> labelsFromJson(Object? json) => {
  if (json is Map)
    for (final entry in json.entries)
      if (entry.key is String && entry.value is String)
        entry.key as String: entry.value as String,
};

/// Reads a `records` object: a program's OSC 7501 records, by id.
Map<String, HcStatus> recordsFromJson(Object? json) => {
  if (json is Map)
    for (final entry in json.entries)
      if (entry.key is String && HcStatus.fromJson(entry.value) != null)
        entry.key as String: HcStatus.fromJson(entry.value)!,
};

String? _string(Object? value) => value is String ? value : null;

int? _int(Object? value) => value is int ? value : null;

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}
