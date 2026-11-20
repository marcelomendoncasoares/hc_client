import 'package:hc_client/testing.dart';

/// The labels the tests' terminals carry, as an app's own would.
const demo = {'app': 'demo'};

/// [terminalRecord], labelled [demo] unless [labels] says otherwise.
Map<String, Object?> demoRecord(
  String address, {
  Map<String, String> labels = demo,
  Map<String, Object?>? status,
  int turn = 0,
  String state = 'live',
}) => terminalRecord(
  address,
  labels: labels,
  status: status,
  turn: turn,
  state: state,
);
