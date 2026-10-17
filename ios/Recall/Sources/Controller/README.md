# Controller (T-007)

`ControllerMath.swift`: pure go-to-pose and rotateBy math plus `ControlSession`, a tick-driven state machine (10 Hz).
`Controller.swift`: thin async driver over a `PoseSource` and a `DriveSink` (protocols, faked in tests).
`ControllerAdapters.swift`: `PoseTracker` and `DriveLink` conformances. App target only.

All speeds and gains in `ControllerTuning` are **placeholders** to be tuned on the rover. `TURN_SIGN` (top of `ControllerMath.swift`)
is the single place to flip if a positive `angular` does not reduce the heading error on the first drive test.
`GuardState` is an input only; ObstacleGuard is a separate task. Guard `stop` holds the wheels at zero (the timeout still runs);
it does not do the detour logic from the plan.

Tests: `Tests/ControllerTests` use a simulated kinematic rover. They check the logic against that model, not the real robot.
