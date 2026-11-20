/// Stand-ins for testing code that talks to hc: [FakeHcCore], an
/// in-process core that answers at exact points, and [ScratchCore], a real
/// core of the test's own that never reaches yours.
library;

export 'src/testing/fake_core.dart';
export 'src/testing/scratch_core.dart';
