// Pure safety and motion logic for the Navigator firmware. No Arduino.h, no BLE, no millis().
// navigator.ino includes this; firmware/test/test_safety.cpp compiles it on a Mac with plain C++.
// Time and sensor values come in as arguments. uint32_t/int32_t match the ESP32's 32-bit
// `unsigned long`/`long`, so wraparound behaves the same on the host as on the chip.
// Spec: docs/03_CONTRACTS.md section 1. Do not change a value here without changing the contract.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------- constants
// Motor tuning. Set from bench tests 3, 7, 8 (plan 1.3). Placeholders until measured.
const int MAX_PWM   = 200;   // demo speed cap (contract)
const int PWM_MIN   = 70;    // deadband: lowest PWM that moves the rover. MEASURE (bench test 8)
const int LEFT_SIGN = 1;     // flip to -1 if left motors spin the wrong way (bench test 3)
const int RIGHT_SIGN = -1;   // MEASURED on the rover 2026-10-17: right motors spin backward on a positive command, so flip
const int LEFT_TRIM  = 100;  // percent, for driving straight (bench test 7)
const int RIGHT_TRIM = 100;

// Timing
const unsigned long WATCHDOG_MS = 300;
const unsigned long LOOP_MS     = 10;
const int SLEW_PER_TICK         = 10;    // max change of applied speed per 10 ms tick
const unsigned long SONAR_TIMEOUT_US = 25000;

// Safety thresholds (contract)
const int FRONT_STOP_CM = 20;
const int REAR_STOP_CM  = 15;
const int NO_ECHO_CM    = 999;
// Release hysteresis: a blocked flag engages on ONE close reading but releases only after this many
// CONSECUTIVE clear readings. A "reading" is one fresh sonar measurement for that sensor (about
// every 100 ms per sensor), not a 10 ms loop tick, so release takes about 300 ms.
const int CLEAR_READINGS_TO_RELEASE = 3;

// Status flags
const int FLAG_WATCHDOG = 1, FLAG_FRONT = 2, FLAG_REAR = 4, FLAG_CONNECTED = 8;

namespace nav {

inline int clampInt(long v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : (int)v); }
inline int minInt(int a, int b) { return a < b ? a : b; }
inline int maxInt(int a, int b) { return a > b ? a : b; }

// ---------------------------------------------------------------- watchdog
// lastCmdMs is written from the BLE task and can be newer than `now`; compare as
// signed so that reads as age <= 0 (fresh) instead of wrapping to a huge age.
inline bool commandFresh(bool valid, bool connected, uint32_t now, uint32_t lastCmdMs) {
  return valid && connected && (int32_t)(now - lastCmdMs) < (int32_t)WATCHDOG_MS;
}

inline bool frontBlocked(int frontCm) { return frontCm < FRONT_STOP_CM; }
inline bool rearBlocked(int rearCm)   { return rearCm < REAR_STOP_CM; }

// Latched blocked state for one sensor. Feed it once per loop tick with `newMeasurement` true only on
// ticks where the sensor published a fresh reading (see sonarTick in navigator.ino); ticks without a
// new reading change nothing. 999 (no echo) counts as a clear reading, same as before (fail-open).
struct BlockLatch {
  bool blocked = false;
  int clearCount = 0;
};

inline bool updateBlock(BlockLatch& b, bool newMeasurement, int cm, int stopCm) {
  if (!newMeasurement) return b.blocked;
  if (cm < stopCm) {                       // close: engage immediately, restart the clear count
    b.blocked = true;
    b.clearCount = 0;
  } else if (b.blocked && ++b.clearCount >= CLEAR_READINGS_TO_RELEASE) {
    b.blocked = false;
    b.clearCount = 0;
  }
  return b.blocked;
}
inline bool updateFrontBlock(BlockLatch& b, bool newMeasurement, int cm) { return updateBlock(b, newMeasurement, cm, FRONT_STOP_CM); }
inline bool updateRearBlock(BlockLatch& b, bool newMeasurement, int cm)  { return updateBlock(b, newMeasurement, cm, REAR_STOP_CM); }

inline int statusFlags(bool fresh, bool front, bool rear) {
  return (fresh ? 0 : FLAG_WATCHDOG) | (front ? FLAG_FRONT : 0) | (rear ? FLAG_REAR : 0) | FLAG_CONNECTED;
}

// ---------------------------------------------------------------- slew / clamp
inline int slew(int cur, int target) {
  if (target > cur + SLEW_PER_TICK) return cur + SLEW_PER_TICK;
  if (target < cur - SLEW_PER_TICK) return cur - SLEW_PER_TICK;
  return target;
}

// One 10 ms control tick of the speed pipeline: watchdog stop, obstacle clamp, slew, then the
// clamp again on the ramped value. appliedL/R are in/out (-255..255). The result is what the
// motor driver must be given.
inline void computeApplied(bool fresh, int requestedL, int requestedR, bool front, bool rear,
                           int& appliedL, int& appliedR) {
  if (!fresh) {
    // Watchdog / STOP / disconnect: brake and zero immediately, no ramp.
    appliedL = appliedR = 0;
    return;
  }
  int l = requestedL, r = requestedR;
  int linear = (l + r) / 2, angular = (r - l) / 2;
  int safeLinear = linear;
  if (front) safeLinear = minInt(safeLinear, 0);
  if (rear)  safeLinear = maxInt(safeLinear, 0);
  bool clamped = safeLinear != linear;
  int tl = clampInt(safeLinear - angular, -255, 255);
  int tr = clampInt(safeLinear + angular, -255, 255);
  if (clamped) { appliedL = tl; appliedR = tr; }   // obstacle stops are immediate, not ramped
  else { appliedL = slew(appliedL, tl); appliedR = slew(appliedR, tr); }
  int appliedSum = appliedL + appliedR;
  if ((front && appliedSum > 0) || (rear && appliedSum < 0)) {
    int appliedAngular = (appliedR - appliedL) / 2;
    appliedL = -appliedAngular;
    appliedR = appliedAngular;
  }
}

// ---------------------------------------------------------------- PWM mapping
struct SideDrive {
  bool brake;     // true: IN1 = IN2 = HIGH, PWM 0 (short brake)
  bool in1High;
  bool in2High;
  int pwm;        // 0..MAX_PWM
};

// One side of the TB6612. v in -255..255 after safety and ramping.
inline SideDrive sideDrive(int v, int sign, int trim) {
  SideDrive d;
  v *= sign;
  if (v == 0) {
    d.brake = true; d.in1High = true; d.in2High = true; d.pwm = 0;
    return d;
  }
  int mag = v < 0 ? -v : v;
  int pwm = PWM_MIN + mag * (MAX_PWM - PWM_MIN) / 255;
  pwm = clampInt((long)pwm * trim / 100, 0, MAX_PWM);
  d.brake = false;
  d.in1High = v > 0;
  d.in2High = !(v > 0);
  d.pwm = pwm;
  return d;
}

// ---------------------------------------------------------------- sonar
// Echo pulse width to cm. done = the falling edge was seen since the trigger.
inline int echoToCm(bool done, uint32_t widthUs) {
  int cm = NO_ECHO_CM;
  if (done && widthUs < SONAR_TIMEOUT_US) cm = minInt((int)(widthUs / 58), NO_ECHO_CM);
  return cm;
}

inline int median3(const int* h) {
  int a = h[0], b = h[1], c = h[2];
  if (a > b) { int t = a; a = b; b = t; }
  if (b > c) { b = c; }
  return a > b ? a : b;
}

// ---------------------------------------------------------------- command parsing
// Accepts "L,R" with L and R integers; out-of-range values are clamped, anything else is ignored.
inline bool parseSpeeds(const char* s, int& l, int& r) {
  char* end;
  long a = strtol(s, &end, 10);
  if (end == s || *end != ',') return false;
  const char* second = end + 1;
  long b = strtol(second, &end, 10);
  if (end == second || *end != '\0') return false;
  l = clampInt(a, -255, 255);
  r = clampInt(b, -255, 255);
  return true;
}

enum LineKind { LINE_IGNORED, LINE_STOP, LINE_PING, LINE_SPEEDS };

// Classifies a complete line. For LINE_SPEEDS, l and r are set.
inline LineKind classifyLine(const char* line, int& l, int& r) {
  if (strcmp(line, "STOP") == 0) return LINE_STOP;
  if (strcmp(line, "PING") == 0) return LINE_PING;
  if (parseSpeeds(line, l, r)) return LINE_SPEEDS;
  return LINE_IGNORED;
}

// Feeds one received byte to the line buffer. Returns true when a complete, non-overflowed,
// non-empty line is in buf (NUL terminated) and should be handled.
inline bool rxFeed(char* buf, size_t cap, size_t& length, bool& overflow, char ch) {
  if (ch == '\n' || ch == '\r') {
    bool ready = !overflow && length > 0;
    if (ready) buf[length] = '\0';
    length = 0; overflow = false;
    return ready;
  }
  if (ch < 32 || ch > 126) {
    overflow = true;
  } else if (length < cap - 1) {
    buf[length++] = ch;
  } else {
    overflow = true;
  }
  return false;
}

}  // namespace nav
