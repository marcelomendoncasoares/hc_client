# Changelog

## 0.3.0

- `attach(terminal, size: (cols: …, rows: …))`: a sizing viewer, which sizes
  the terminal instead of watching it, and `HcViewer.resize` to change its
  size. The terminal takes the size of the sizing viewer that attached or
  resized last; as each closes, the one before takes over, and with none
  left, hc's headless size. `HcViewer.sizing` tells the two kinds apart.
- A sizing viewer takes no output. The client credits what hc sends it as it
  comes and drops it, so hc holds no backlog for it, and the program's end,
  which hc sends only after the output before it, still reaches its `events`.
- `HcFrame.resize` builds a RESIZE frame, and `FakeHcClient.resizes` records
  the sizes a client sent.

## 0.2.0

- First release on pub.dev.
- `attach`, on `HcGateway` and `HcConnection`: a viewer of a terminal that
  only watches, never typing or resizing. Its `events` bring the terminal's
  size (`HcResize`), its current screen and then its live output, colours
  included (`HcOutput`), and the program's end (`HcEnd`). Credit goes back
  as the listener takes the output, so a listener that pauses holds hc back.
  `close`, or cancelling the listener, lets hc drop the viewer.
- `FakeHcCore` answers stream channels: `afterReply` sends frames right after
  a method's reply, and each client records its stream `credits` and
  `closes`, which the core answers unless `echoClose` is false.

## 0.1.0

- First release, taken out of Ruddr's server: `HcConnection`, `HcGateway`
  with its mirror, the typed calls `run`, `get`, `list`, `send`, `keys`,
  `interrupt`, `kill`, `rm`, `label` and `read`, the raw `call`, and
  `FakeHcCore` and `ScratchCore` for tests.
- Every setting the server had fixed is now the caller's: the subscription's
  labels (`filter`, every terminal by default), the features a core must offer
  (`requiredFeatures`), and each call's timeout.
