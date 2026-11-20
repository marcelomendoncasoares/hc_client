/// An error hc returned for a call, with its stable `data.kind`, such as
/// `not_found`, `blocked`, `status_mismatch` or `conflict`.
final class HcException implements Exception {
  const HcException(this.kind, this.message, {this.hint, this.code});

  /// Reads a JSON-RPC `error` object.
  factory HcException.fromJson(Map<String, Object?> error) {
    final data = error['data'];
    final details = data is Map ? data : const {};
    return HcException(
      details['kind'] is String ? details['kind'] as String : 'unknown',
      error['message'] is String ? error['message'] as String : '',
      hint: details['hint'] is String ? details['hint'] as String : null,
      code: error['code'] is int ? error['code'] as int : null,
    );
  }

  final String kind;
  final String message;
  final String? hint;
  final int? code;

  @override
  String toString() =>
      'HcException($kind: $message${hint == null ? '' : '; $hint'})';
}

/// The call never reached hc, or its answer never came back: there is no
/// connection, it closed during the call, or the call timed out. Whether a
/// call that was sent took effect is unknown.
final class HcUnavailableException implements Exception {
  const HcUnavailableException(this.message, {this.sent = true});

  final String message;

  /// Whether the call may have reached hc. False only when it never left
  /// the client, for want of a connection: then hc did nothing.
  final bool sent;

  @override
  String toString() => 'HcUnavailableException: $message';
}

/// The core broke the wire format, or speaks a protocol this client doesn't.
final class HcProtocolException implements Exception {
  const HcProtocolException(this.message);

  final String message;

  @override
  String toString() => 'HcProtocolException: $message';
}
