import 'terminal.dart';

/// One message on the event channel.
sealed class HcNotification {
  const HcNotification();

  /// Reads one decoded JSON-RPC notification.
  factory HcNotification.fromJson(Map<String, Object?> json) {
    final method = json['method'];
    final params = json['params'] is Map
        ? (json['params'] as Map).cast<String, Object?>()
        : const <String, Object?>{};
    final seq = params['seq'] is int ? params['seq'] as int : -1;
    switch (method) {
      case 'event':
        return HcEvent(
          seq: seq,
          type: params['type'] is String ? params['type'] as String : '',
          terminal: params['terminal'] is String
              ? params['terminal'] as String
              : '',
          data: params['data'],
        );
      case 'heartbeat':
        return HcHeartbeat(seq);
      case 'missed':
        return HcMissed(seq, terminalsFromJson(params['terminals']));
      default:
        return HcOtherNotification(method is String ? method : '');
    }
  }
}

/// `event {seq, type, terminal, data}`: one fact change.
final class HcEvent extends HcNotification {
  const HcEvent({
    required this.seq,
    required this.type,
    required this.terminal,
    this.data,
  });

  final int seq;
  final String type;
  final String terminal;
  final Object? data;

  /// [data] as a map, or empty.
  Map<String, Object?> get fields =>
      data is Map ? (data as Map).cast<String, Object?>() : const {};

  @override
  String toString() => 'HcEvent($seq $type $terminal)';
}

/// `heartbeat {seq}`, every 15 s.
final class HcHeartbeat extends HcNotification {
  const HcHeartbeat(this.seq);

  final int seq;
}

/// `missed {seq, terminals}`: the client fell behind, and this fresh snapshot
/// replaces the events it lost.
final class HcMissed extends HcNotification {
  const HcMissed(this.seq, this.terminals);

  final int seq;
  final List<HcTerminal> terminals;
}

/// A notification method this client doesn't know: the API only grows.
final class HcOtherNotification extends HcNotification {
  const HcOtherNotification(this.method);

  final String method;
}

/// Reads a list of terminal records, skipping any without an address.
List<HcTerminal> terminalsFromJson(Object? json) => [
  if (json is List)
    for (final record in json)
      if (record is Map && record['address'] is String)
        HcTerminal.fromJson(record.cast<String, Object?>()),
];
