/// The socket of the core the `hc` CLI would reach from [environment]:
/// `HC_SOCKET` when set, else `$XDG_RUNTIME_DIR/herdr-core/<HC_SESSION>.sock`
/// with the session `default`.
String hcSocketPath(Map<String, String> environment) {
  final socket = environment['HC_SOCKET'];
  if (socket != null && socket.isNotEmpty) return socket;
  final runtime = environment['XDG_RUNTIME_DIR'];
  if (runtime == null || runtime.isEmpty) {
    throw StateError(
      'XDG_RUNTIME_DIR is not set, so the hc socket is unknown: '
      'set HC_SOCKET',
    );
  }
  final session = environment['HC_SESSION'];
  return '$runtime/herdr-core/'
      '${session == null || session.isEmpty ? 'default' : session}.sock';
}
