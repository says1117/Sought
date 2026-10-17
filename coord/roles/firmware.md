# Role: firmware

Owns `firmware/navigator/`. Source specs: `docs/01_ROBOTICS_PLAN.md` sections 1 and 2, `docs/03_CONTRACTS.md` section 1.
Check the ESP32 Arduino core version (2.x vs 3.x) before writing LEDC/BLE code. Keep constants at the top. Safety rules live on the ESP32 and never depend on the phone.
Anything touching wiring or flashing needs the human: ask with exact steps and the expected result.
