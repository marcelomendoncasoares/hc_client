# hc_client

[![GitHub](https://img.shields.io/badge/GitHub-marcelomendoncasoares-181717.svg?style=flat&logo=github)](https://github.com/marcelomendoncasoares)
[![Pub Package](https://img.shields.io/pub/v/hc_client.svg)](https://pub.dev/packages/hc_client)
[![Dart SDK Version](https://badgen.net/pub/sdk-version/hc_client)](https://pub.dev/packages/hc_client)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](https://github.com/marcelomendoncasoares/hc_client/blob/main/LICENSE)
[![CI](https://github.com/marcelomendoncasoares/hc_client/actions/workflows/ci.yaml/badge.svg?branch=main)](https://github.com/marcelomendoncasoares/hc_client/actions/workflows/ci.yaml)

An unofficial Dart client for [herdr-core](https://herdr.dev/core) (`hc`),
[herdr](https://herdr.dev)'s terminal runtime that keeps coding agents and
other programs running, and reports what they're doing. It isn't made by
herdr's maintainers.

It came out of Ruddr's server, which runs every one of its agents through it,
and it depends only on the Dart SDK.

## What it gives you

- **`HcGateway`**, a connection that lasts. It reconnects with backoff, takes
  a connection for dead when hc's 15-second heartbeat stops, and keeps a
  mirror of the terminals you follow. After every event, reconnect, `missed`
  snapshot and core restart, the mirror equals hc's, and each change arrives
  as an `HcChange`: `HcResync`, `HcAdded`, `HcChanged` or `HcRemoved`.
- **Typed calls** on terminals: `run`, `get`, `list`, `send`, `keys`,
  `interrupt`, `kill`, `rm`, `label` and `read`. `call` reaches any other
  method of hc's API (`hc schema` prints it).
- **`attach`**, a viewer that only watches: a terminal's screen as it is,
  then its live output, colours included, for a terminal emulator to draw.
  It never types or resizes, whatever the terminal's other viewers do.
- **`HcConnection`**, one framed connection to a core: JSON-RPC requests, and
  the event subscription on its own channel, with credit.
- **Typed errors.** `HcException` carries hc's stable `kind`, such as
  `not_found` or `blocked`. `HcUnavailableException` says whether a call
  ever left the client. `HcProtocolException` means the core speaks another
  protocol.
- **Fakes for tests**, in `package:hc_client/testing.dart`: `FakeHcCore`, a
  core in the test's own process that answers at exact points, and
  `ScratchCore`, a real core of the test's own that never reaches yours.

## Install

```sh
dart pub add hc_client
```

## Use

```dart
import 'dart:io';

import 'package:hc_client/hc_client.dart';

Future<void> main() async {
  final gateway = HcGateway(
    // HC_SOCKET, else $XDG_RUNTIME_DIR/herdr-core/<HC_SESSION>.sock, as hc
    // itself finds its core.
    socketPath: hcSocketPath(Platform.environment),
    // Follow only the terminals that carry these labels; leave it out to
    // follow them all.
    filter: {'app': 'demo'},
  );
  gateway.changes.listen((change) {
    if (change case HcChanged(:final terminal, type: 'status')) {
      print('${terminal.address}: ${terminal.status?.state}');
    }
  });
  gateway.start();
  await gateway.firstTry;

  final agent = await gateway.run(
    argv: ['claude'],
    cwd: '/path/to/project',
    labels: {'app': 'demo'},
  );
  await gateway.send(agent.address, 'Explain this repository.');
}
```

To watch a terminal, as a terminal emulator would draw it:

```dart
final viewer = await gateway.attach(agent.address);
await for (final event in viewer.events) {
  switch (event) {
    case HcResize(:final cols, :final rows):
      print('the terminal is $cols × $rows');
    case HcOutput(:final bytes):
      stdout.add(bytes); // the screen first, then what it prints
    case HcEnd(:final reason):
      print('it ended: $reason');
  }
}
```

The viewer ends after `HcEnd`, on `viewer.close()` or a cancelled listener,
and with `HcUnavailableException` when the connection goes: attach again once
the gateway is back. Typing stays on `send` and `keys`.

`example/hc_client_example.dart` follows a core's terminals and prints each
status as it changes: `dart run example/hc_client_example.dart app=demo`.

## Configure

| Setting | Default | What it does |
| --- | --- | --- |
| `socketPath` | required | The core's socket; `hcSocketPath` finds it as `hc` does |
| `filter` | `{}`, every terminal | The labels a terminal must carry to be followed |
| `requiredFeatures` | `framed`, `events` | The features a core must offer at each connect |
| `heartbeatTimeout` | 45 s | How long a quiet event channel lasts before the gateway reconnects |
| `minBackoff`, `maxBackoff` | 250 ms, 15 s | The first and longest wait between connection attempts |
| `connectTimeout` | 10 s | How long to wait for the socket and the handshake |
| `log` | none | Where connection news goes |

Each call also takes its own `timeout`: `run` and `send` wait 60 s by
default, and the others `HcGateway.defaultTimeout`, 30 s.

## Compatibility

Tested against hc 0.1.18, protocol generation 1. At each connect, the client
checks the core's `hello`: its generation, framed mode and the features you
require. hc's API only grows, so an event type or notification the client
doesn't know is let through unchanged, never treated as an error. The client
never starts a core: it connects to one that's already running.

## Test

```sh
dart test          # the gateway and the mirror against FakeHcCore
dart test -P hc    # also against a real core of the test's own
```

`-P hc` needs `hc` on PATH, or `HC_BIN` naming one. Its `ScratchCore` runs
with its own `HC_SESSION` and XDG folders and a clean environment, so it never
reaches the core you work in.

## License

Apache-2.0, as [hc's own](https://github.com/herdrdev/herdr-core). See
[LICENSE](LICENSE) and [NOTICE](NOTICE).
