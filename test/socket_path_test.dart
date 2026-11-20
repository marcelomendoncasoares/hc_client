import 'package:hc_client/hc_client.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Given an environment with only XDG_RUNTIME_DIR, '
    'when the hc socket is resolved, '
    'then it is the default session\'s socket there.',
    () {
      final path = hcSocketPath({'XDG_RUNTIME_DIR': '/run/user/1000'});

      expect(path, '/run/user/1000/herdr-core/default.sock');
    },
  );

  test(
    'Given an environment with XDG_RUNTIME_DIR and HC_SESSION, '
    'when the hc socket is resolved, '
    'then it is that session\'s socket there.',
    () {
      final path = hcSocketPath({
        'XDG_RUNTIME_DIR': '/run/user/1000',
        'HC_SESSION': 'work',
      });

      expect(path, '/run/user/1000/herdr-core/work.sock');
    },
  );

  test(
    'Given an environment with HC_SOCKET, XDG_RUNTIME_DIR and HC_SESSION, '
    'when the hc socket is resolved, '
    'then it is HC_SOCKET.',
    () {
      final path = hcSocketPath({
        'HC_SOCKET': '/srv/hc.sock',
        'XDG_RUNTIME_DIR': '/run/user/1000',
        'HC_SESSION': 'work',
      });

      expect(path, '/srv/hc.sock');
    },
  );

  test(
    'Given an environment without HC_SOCKET or XDG_RUNTIME_DIR, '
    'when the hc socket is resolved, '
    'then it fails, naming HC_SOCKET.',
    () {
      expect(
        () => hcSocketPath({}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('HC_SOCKET'),
          ),
        ),
      );
    },
  );
}
