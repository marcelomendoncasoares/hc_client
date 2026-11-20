import 'dart:convert';
import 'dart:io';

/// A real hc core of its own for a test: its own `HC_SESSION` and XDG
/// folders in a new temporary folder, started with a clean environment,
/// and stopped by [stop]. It never reaches your own core: every `hc`
/// command it runs carries only that environment.
final class ScratchCore {
  ScratchCore._(this._directories, this._environment, this._hc, this.pid);

  /// The `hc` [start] runs: `HC_BIN`, else the one on PATH, else null, for
  /// a test to skip on.
  static String? get binary {
    final named = Platform.environment['HC_BIN'];
    if (named != null && named.isNotEmpty) return named;
    final found = Process.runSync('sh', ['-c', 'command -v hc']);
    final path = (found.stdout as String).trim();
    return found.exitCode == 0 && path.isNotEmpty ? path : null;
  }

  /// Starts the core [binary] names.
  static Future<ScratchCore> start() async {
    final hc = binary ?? (throw StateError('no hc on PATH: set HC_BIN'));
    final directory = await Directory.systemTemp.createTemp('hc.');
    final root = directory.path;
    // hc puts its holder's socket beside the core's, as
    // `<session>.holder.<8 hex>.sock`, and a Unix socket path holds at most
    // 107 bytes: a long temporary folder gets its sockets in /dev/shm.
    final runtime = '$root/r'.length + _socketsLength <= 107
        ? await Directory('$root/r').create()
        : await Directory(_shortTemp).createTemp('hc.');
    final environment = {
      'HOME': '$root/home',
      'PATH': '/usr/local/bin:/usr/bin:/bin',
      'HC_SESSION': _session,
      'XDG_RUNTIME_DIR': runtime.path,
      'XDG_STATE_HOME': '$root/state',
      'XDG_CONFIG_HOME': '$root/config',
      'XDG_DATA_HOME': '$root/data',
      'LANG': 'C.UTF-8',
    };
    for (final folder in ['home', 'state', 'config', 'data']) {
      await Directory('$root/$folder').create();
    }
    await Process.run('chmod', ['700', runtime.path]);

    final ProcessResult started;
    try {
      started = await Process.run(
        hc,
        ['server', 'start'],
        environment: environment,
        includeParentEnvironment: false,
      );
    } catch (_) {
      await _remove([directory, runtime]);
      rethrow;
    }
    final core = ScratchCore._(
      [directory, runtime],
      environment,
      hc,
      started.exitCode == 0 ? _json(started)['pid'] as int? : null,
    );
    if (core.pid == null || !File(core.socketPath).existsSync()) {
      await core.stop();
      throw StateError(
        'the scratch core did not start: ${started.stdout}${started.stderr}',
      );
    }
    return core;
  }

  static const _session = 's';

  static String get _shortTemp =>
      Directory('/dev/shm').existsSync() ? '/dev/shm' : '/tmp';

  /// `/herdr-core/s.holder.0123abcd.sock`.
  static const _socketsLength = 34;

  final List<Directory> _directories;
  final Map<String, String> _environment;
  final String _hc;

  /// The core process this scratch core started.
  int? pid;

  String get socketPath =>
      '${_environment['XDG_RUNTIME_DIR']}/herdr-core/$_session.sock';

  /// The `hc` this core runs.
  String get hcBinary => _hc;

  /// A folder of this core's own, for terminals to run in.
  String get home => _environment['HOME']!;

  /// Runs `hc` with [arguments] against this core and returns its JSON.
  Future<Map<String, Object?>> hc(List<String> arguments) async => _json(
    await Process.run(
      _hc,
      [...arguments],
      environment: _environment,
      includeParentEnvironment: false,
    ),
  );

  /// `hc server restart`: a new core process adopts the terminals, and its
  /// event sequence starts again from zero.
  Future<void> restart() async {
    await hc(['server', 'restart']);
    pid = (await hc(['server', 'status']))['pid'] as int;
  }

  /// Stops this core and its programs, then removes its folders.
  Future<void> stop() async {
    final pid = this.pid;
    if (pid != null) {
      await Process.run(
        _hc,
        ['server', 'stop'],
        environment: _environment,
        includeParentEnvironment: false,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (Directory('/proc/$pid').existsSync() &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (Directory('/proc/$pid').existsSync()) {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
    }
    await _remove(_directories);
  }

  static Future<void> _remove(List<Directory> directories) async {
    for (final directory in directories) {
      if (directory.existsSync()) await directory.delete(recursive: true);
    }
  }

  static Map<String, Object?> _json(ProcessResult result) {
    if (result.exitCode != 0) {
      throw StateError('hc failed (${result.exitCode}): ${result.stderr}');
    }
    final output = (result.stdout as String).trim();
    final decoded = output.isEmpty ? null : jsonDecode(output);
    return decoded is Map ? decoded.cast<String, Object?>() : const {};
  }
}
