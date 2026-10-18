# Controller (T-007)

`ControllerMath.swift`: pure go-to-pose and rotateBy math plus `ControlSession`, a tick-driven state machine (10 Hz).
`Controller.swift`: thin async driver over a `PoseSource` and a `DriveSink` (protocols, faked in tests).
`ControllerAdapters.swift`: `PoseTracker` and `DriveLink` conformances. App target only.

All speeds and gains in `ControllerTuning` are **placeholders** to be tuned on the rover. `TURN_SIGN` (top of `ControllerMath.swift`)
is the single place to flip if a positive `angular` does not reduce the heading error on the first drive test.
`GuardState` is an input only; ObstacleGuard is a separate task. Guard `stop` holds the wheels at zero (the timeout still runs);
it does not do the detour logic from the plan.

`goTo` fixes its time budget from the first normal, finite pose: `15 + 12 * max(0, distance - stopDistance)` seconds,
with a 30 s minimum and a 75 s maximum. These allowances are tuning placeholders, not measured rover speeds.
The clock starts at the first tick; progress, guard stops, and brief tracking gaps never renew it. The per-goTo cap leaves
15 s before the companion's 90 s polling deadline for completion delivery (not a network delivery guarantee).
Each leg has its own budget, so a route with multiple legs can still exceed the companion's overall deadline.
`rotateBy` keeps its separate 15 s timeout. Tracking loss and Stop still stop the wheels immediately.

Tests: `Tests/ControllerTests` use a simulated kinematic rover. They check the logic against that model, not the real robot.

PR14's stack review also applies guard-stop to rotation, resets arrival confirmation across tracking dropouts, and rejects controller-adapter poses whose AR frame is absent or older than one second. A higher-level coordinator must supply obstacle decisions and serialize movement ownership; default-clear input does not connect the guard automatically. Detour requests do not authorize bypassing a stop to force rotation. These stack fixes are not automatically backported to the standalone PR13 branch.
