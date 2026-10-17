// Test-only oracle: the safety logic copied VERBATIM from navigator.ino at commit 1997c3c
// (before the safety.h extraction), with Arduino macros shimmed and hardware calls replaced by
// a recorder. test_safety.cpp compares nav:: (safety.h) against this over many inputs.
// Do not "improve" this file: its value is that it is the old code.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

namespace legacy {

const int MAX_PWM = 200, PWM_MIN = 70, LEFT_SIGN = 1, RIGHT_SIGN = 1, LEFT_TRIM = 100, RIGHT_TRIM = 100;
const unsigned long WATCHDOG_MS = 300;
const int SLEW_PER_TICK = 10;
const unsigned long SONAR_TIMEOUT_US = 25000;
const int FRONT_STOP_CM = 20, REAR_STOP_CM = 15, NO_ECHO_CM = 999;
const int FLAG_WATCHDOG = 1, FLAG_FRONT = 2, FLAG_REAR = 4, FLAG_CONNECTED = 8;
typedef uint32_t ulong32;   // the ESP32's `unsigned long` is 32 bits

template <class T> T constrain(T v, T lo, T hi) { return v < lo ? lo : (v > hi ? hi : v); }
template <class T> T min(T a, T b) { return a < b ? a : b; }
template <class T> T max(T a, T b) { return a > b ? a : b; }
inline int abs(int v) { return v < 0 ? -v : v; }

// Recorder in place of digitalWrite/ledcWrite.
struct Pins { int in1 = -1, in2 = -1, pwm = -1; };
inline Pins& side(int i) { static Pins p[2]; return p[i]; }

void driveSide(int idx, int v, int sign, int trim) {
  Pins& o = side(idx);
  v *= sign;
  if (v == 0) { o.in1 = 1; o.in2 = 1; o.pwm = 0; return; }
  int mag = abs(v);
  int pwm = PWM_MIN + mag * (MAX_PWM - PWM_MIN) / 255;
  pwm = constrain(pwm * trim / 100, 0, MAX_PWM);
  o.in1 = v > 0 ? 1 : 0;
  o.in2 = v > 0 ? 0 : 1;
  o.pwm = pwm;
}
void applyMotors(int l, int r) {
  driveSide(0, l, LEFT_SIGN, LEFT_TRIM);
  driveSide(1, r, RIGHT_SIGN, RIGHT_TRIM);
}

int slew(int cur, int target) {
  if (target > cur + SLEW_PER_TICK) return cur + SLEW_PER_TICK;
  if (target < cur - SLEW_PER_TICK) return cur - SLEW_PER_TICK;
  return target;
}

int median3(const int* h) {
  int a = h[0], b = h[1], c = h[2];
  if (a > b) { int t = a; a = b; b = t; }
  if (b > c) { b = c; }
  return a > b ? a : b;
}

int sonarCm(bool done, uint32_t widthUs) {
  int cm = NO_ECHO_CM;
  if (done && widthUs < SONAR_TIMEOUT_US) cm = min((int)(widthUs / 58), NO_ECHO_CM);
  return cm;
}

bool parseSpeeds(const char* s, int& l, int& r) {
  char* end;
  long a = strtol(s, &end, 10);
  if (end == s || *end != ',') return false;
  const char* second = end + 1;
  long b = strtol(second, &end, 10);
  if (end == second || *end != '\0') return false;
  l = constrain(a, -255L, 255L);
  r = constrain(b, -255L, 255L);
  return true;
}

// The body of loop() between the sonar read and the LED, with `last/valid/connectedNow/requested*`
// already snapshotted. Returns fresh; sets appliedL/R and drives the recorder.
bool loopBody(ulong32 now, ulong32 last, bool valid, bool connectedNow, int requestedL, int requestedR,
              int front, int rear, int& appliedL, int& appliedR, int& flags) {
  bool frontBlocked = front < FRONT_STOP_CM;
  bool rearBlocked  = rear < REAR_STOP_CM;
  bool fresh = valid && connectedNow && (long)(int32_t)(now - last) < (long)WATCHDOG_MS;

  if (!fresh) {
    appliedL = appliedR = 0;
    applyMotors(0, 0);
  } else {
    int l = requestedL, r = requestedR;
    int linear = (l + r) / 2, angular = (r - l) / 2;
    int safeLinear = linear;
    if (frontBlocked) safeLinear = min(safeLinear, 0);
    if (rearBlocked)  safeLinear = max(safeLinear, 0);
    bool clamped = safeLinear != linear;
    int tl = constrain(safeLinear - angular, -255, 255);
    int tr = constrain(safeLinear + angular, -255, 255);
    if (clamped) { appliedL = tl; appliedR = tr; }
    else { appliedL = slew(appliedL, tl); appliedR = slew(appliedR, tr); }
    int appliedSum = appliedL + appliedR;
    if ((frontBlocked && appliedSum > 0) || (rearBlocked && appliedSum < 0)) {
      int appliedAngular = (appliedR - appliedL) / 2;
      appliedL = -appliedAngular;
      appliedR = appliedAngular;
    }
    applyMotors(appliedL, appliedR);
  }
  flags = (fresh ? 0 : FLAG_WATCHDOG) | (frontBlocked ? FLAG_FRONT : 0) |
          (rearBlocked ? FLAG_REAR : 0) | FLAG_CONNECTED;
  return fresh;
}

}  // namespace legacy
