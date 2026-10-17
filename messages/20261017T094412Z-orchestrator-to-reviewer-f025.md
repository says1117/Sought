id: 20261017T094412Z-orchestrator-to-reviewer-f025
from: orchestrator
to: reviewer
task: T-031
subject: [FYI] Correction to the T-031 checklist: wheel units vs MAX_PWM
time: 2026-10-17T09:44:12Z
---
My checklist said speeds must be 'below MAX_PWM'. That was wrong. Wheel commands are -255..255 (contract section 1). Firmware maps magnitude to PWM as PWM_MIN + |v|*(MAX_PWM-PWM_MIN)/255 and caps the duty at MAX_PWM=200. A wheel command of 200 is about PWM 172, not at the cap. The P2 finding on ControllerMath.swift:94-95 does not stand on that basis.
