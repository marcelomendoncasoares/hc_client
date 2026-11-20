import 'dart:collection';

import 'notification.dart';
import 'terminal.dart';

/// What changed in the mirror.
sealed class HcChange {
  const HcChange();
}

/// The mirror was replaced from a snapshot: after a (re)connect, a core
/// restart or a `missed`. Whatever was built from the mirror is rebuilt
/// from it.
final class HcResync extends HcChange {
  const HcResync(this.terminals);

  final Map<String, HcTerminal> terminals;
}

/// A terminal entered the scope: created, or newly labelled into it.
final class HcAdded extends HcChange {
  const HcAdded(this.terminal);

  final HcTerminal terminal;
}

/// A terminal in the scope changed, by an event of [type].
final class HcChanged extends HcChange {
  const HcChanged(this.before, this.terminal, this.type);

  final HcTerminal before;
  final HcTerminal terminal;
  final String type;
}

/// A terminal left the scope: removed from hc, or labelled out of it.
final class HcRemoved extends HcChange {
  const HcRemoved(this.terminal);

  /// The terminal as the mirror last held it.
  final HcTerminal terminal;
}

/// A view of hc's terminals that carry [filter]'s labels: a snapshot, then
/// every event after it, in order. An empty [filter] holds them all.
final class HcMirror {
  HcMirror(this.filter, {int Function()? nowMs})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// The event types whose effect the mirror models. Others change nothing
  /// it keeps (`foreground`, `size`, `doc`), or are newer than it.
  static const modelledTypes = {
    'created',
    'status',
    'turn',
    'labels',
    'finished',
    'lost',
    'restarted',
    'removed',
    'title',
    'keep',
  };

  /// The event types that change nothing the mirror keeps.
  static const ignoredTypes = {'foreground', 'size', 'doc'};

  final Map<String, String> filter;
  final int Function() _nowMs;
  final _terminals = <String, HcTerminal>{};
  var _seq = -1;

  /// The terminals in the scope, by address.
  Map<String, HcTerminal> get terminals => UnmodifiableMapView(_terminals);

  /// The sequence the mirror is at: the snapshot's, or the last event's.
  int get seq => _seq;

  /// Replaces everything with a snapshot at [seq]. Sequences restart with
  /// each core process, so a snapshot's seq may be below the last event's.
  HcResync replace(int seq, Iterable<HcTerminal> terminals) {
    _terminals
      ..clear()
      ..addEntries([
        for (final terminal in terminals)
          if (matches(terminal.labels)) MapEntry(terminal.address, terminal),
      ]);
    _seq = seq;
    return HcResync(Map.unmodifiable(_terminals));
  }

  /// Applies [event]. Returns the change, or null when the event is already
  /// in the snapshot (its seq is not above the mirror's) or changes nothing
  /// the mirror keeps.
  HcChange? apply(HcEvent event) {
    if (event.seq <= _seq) return null;
    _seq = event.seq;
    final before = _terminals[event.terminal];
    final fields = event.fields;
    switch (event.type) {
      case 'created' || 'restarted':
        return _put(HcTerminal.fromJson(fields), before, event.type);
      case 'labels':
        final labels = labelsFromJson(fields['labels']);
        final record = fields['record'];
        if (before == null) {
          if (record is! Map || !matches(labels)) return null;
          return _put(
            HcTerminal.fromJson(
              record.cast<String, Object?>(),
            ).copyWith(labels: labels),
            null,
            event.type,
          );
        }
        if (!matches(labels)) return _remove(before);
        return _change(
          before,
          before.copyWith(labels: labels),
          event.type,
        );
      case 'removed':
        return before == null ? null : _remove(before);
    }
    if (before == null) return null;
    final after = switch (event.type) {
      'status' => _status(before, fields),
      'turn' => before.copyWith(
        turn: fields['turn'] is int ? fields['turn'] as int : before.turn,
      ),
      'finished' => _ended(before, fields).copyWith(state: 'finished'),
      'lost' => _ended(before, fields),
      'title' => before.copyWith(
        title: fields['title'] is String ? fields['title'] as String : '',
      ),
      'keep' => before.copyWith(keep: fields['keep'] == true),
      _ => null,
    };
    return after == null ? null : _change(before, after, event.type);
  }

  /// Whether [labels] carry every label of the filter.
  bool matches(Map<String, String> labels) =>
      filter.entries.every((entry) => labels[entry.key] == entry.value);

  HcTerminal _status(HcTerminal before, Map<String, Object?> fields) {
    final status = HcStatus.fromJson(fields['status']);
    final changed = status?.state != before.status?.state;
    return before.copyWith(
      status: status,
      statusMs: changed ? _nowMs() : before.statusMs,
      records: recordsFromJson(fields['records']),
      reported: fields['reported'] is bool
          ? fields['reported'] as bool
          : before.reported,
    );
  }

  HcTerminal _ended(HcTerminal before, Map<String, Object?> fields) =>
      before.copyWith(
        exitCode: fields['exit_code'] is int ? fields['exit_code'] : null,
        finishedMs: fields['finished_ms'] is int ? fields['finished_ms'] : null,
        reason: fields['reason'] is String ? fields['reason'] : null,
        signal: fields['signal'] is int ? fields['signal'] : null,
      );

  HcChange? _put(HcTerminal terminal, HcTerminal? before, String type) {
    if (!matches(terminal.labels)) {
      return before == null ? null : _remove(before);
    }
    _terminals[terminal.address] = terminal;
    return before == null
        ? HcAdded(terminal)
        : HcChanged(before, terminal, type);
  }

  HcChange _change(HcTerminal before, HcTerminal after, String type) {
    _terminals[after.address] = after;
    return HcChanged(before, after, type);
  }

  HcChange _remove(HcTerminal before) {
    _terminals.remove(before.address);
    return HcRemoved(before);
  }
}
