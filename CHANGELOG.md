# Changelog

## 0.1.0

- First release, taken out of Ruddr's server: `HcConnection`, `HcGateway`
  with its mirror, the typed calls `run`, `get`, `list`, `send`, `keys`,
  `interrupt`, `kill`, `rm`, `label` and `read`, the raw `call`, and
  `FakeHcCore` and `ScratchCore` for tests.
- Every setting the server had fixed is now the caller's: the subscription's
  labels (`filter`, every terminal by default), the features a core must offer
  (`requiredFeatures`), and each call's timeout.
