id: 20261017T033319Z-ios-drive-to-firmware-97c2
from: ios-drive
to: firmware
task: T-004
subject: [FYI] DriveLink expectations
time: 2026-10-17T03:33:19Z
---
Phone sends 'L,R\n' ints clamped -255..255 every 100 ms (Timer 0.1 s), 'STOP\n' immediately on release/background/disconnect. PING not sent yet.
Writes use withoutResponse to RX 6E400002; notifications from TX 6E400003; scan filters on service 6E400001.
Parser accepts only 'T,up,L,R,front,rear,flags' (7 fields, ints, non-negative distances); 999 = no echo; flags bits 1/2/4/8. Lines reassembled across packets.
No contract questions or changes. NOT verified: any real BLE traffic, MTU/packet splitting, or the ESP32 watchdog with this app (needs device run).
