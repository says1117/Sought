// Host tests for the Navigator safety logic (firmware/navigator/safety.h). No hardware, no Arduino.
// Build and run from the repo root: see firmware/test/README.md.
#include "../navigator/safety.h"
#include "legacy_reference.h"

#include <stdio.h>
#include <fstream>
#include <sstream>
#include <string>

static int g_checks = 0, g_failed = 0;
#define CHECK(cond) do { g_checks++; if (!(cond)) { g_failed++; \
  printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define CHECK_EQ(a, b) do { g_checks++; long _a = (long)(a), _b = (long)(b); if (_a != _b) { g_failed++; \
  printf("  FAIL %s:%d  %s == %s  (%ld vs %ld)\n", __FILE__, __LINE__, #a, #b, _a, _b); } } while (0)

typedef void (*TestFn)();
struct Test { const char* name; TestFn fn; };
static Test g_tests[64];
static int g_nTests = 0;
struct Reg { Reg(const char* n, TestFn f) { g_tests[g_nTests++] = {n, f}; } };
#define TEST(name) static void name(); static Reg reg_##name(#name, name); static void name()

// ------------------------------------------------------------------ simulated firmware
// Mirrors navigator.ino's shared state, BLE callbacks and loop(), calling the same nav:: functions.
struct Sim {
  // shared state (written by the "BLE task")
  bool connected = false, cmdValid = false, pongPending = false;
  int cmdL = 0, cmdR = 0;
  uint32_t lastCmdMs = 0;
  char rx[24]; size_t rxLen = 0; bool rxOver = false;
  // loop state
  int appliedL = 0, appliedR = 0;
  int front = nav_NO_ECHO(), rear = nav_NO_ECHO();
  nav::BlockLatch frontLatch, rearLatch;
  bool frontNew = false, rearNew = false;   // set by feedFront/feedRear = sonarTick publishing a reading
  uint32_t now = 0;
  // last tick outputs
  bool fresh = false; int flags = 0;
  nav::SideDrive left{}, right{};

  static int nav_NO_ECHO() { return NO_ECHO_CM; }

  void onConnect()    { cmdL = cmdR = 0; cmdValid = false; pongPending = false; rxLen = 0; rxOver = false; connected = true; }
  void onDisconnect() { connected = false; cmdValid = false; cmdL = cmdR = 0; pongPending = false; rxLen = 0; rxOver = false; }

  void handleLine(const char* line) {
    int l = 0, r = 0;
    switch (nav::classifyLine(line, l, r)) {
      case nav::LINE_STOP:   cmdL = cmdR = 0; cmdValid = false; break;
      case nav::LINE_PING:   pongPending = true; break;
      case nav::LINE_SPEEDS: cmdL = l; cmdR = r; lastCmdMs = now; cmdValid = true; break;
      case nav::LINE_IGNORED: break;
    }
  }
  void write(const std::string& bytes) {   // RxCb::onWrite
    if (!connected) return;
    for (char ch : bytes)
      if (nav::rxFeed(rx, sizeof(rx), rxLen, rxOver, ch)) handleLine(rx);
  }
  void feedFront(int cm) { front = cm; frontNew = true; }
  void feedRear(int cm)  { rear = cm;  rearNew = true; }
  void tick() {                            // one pass of loop(): advance 10 ms, then run it
    now += LOOP_MS;
    bool fr = nav::updateFrontBlock(frontLatch, frontNew, front), re = nav::updateRearBlock(rearLatch, rearNew, rear);
    frontNew = rearNew = false;
    fresh = nav::commandFresh(cmdValid, connected, now, lastCmdMs);
    nav::computeApplied(fresh, cmdL, cmdR, fr, re, appliedL, appliedR);
    left  = nav::sideDrive(appliedL, LEFT_SIGN, LEFT_TRIM);
    right = nav::sideDrive(appliedR, RIGHT_SIGN, RIGHT_TRIM);
    flags = nav::statusFlags(fresh, fr, re);
  }
  void run(int ms) { for (int t = 0; t < ms; t += (int)LOOP_MS) tick(); }
};

// ------------------------------------------------------------------ command parsing
static bool parse(const char* s, int& l, int& r) { return nav::parseSpeeds(s, l, r); }

TEST(parse_valid_and_clamped) {
  int l = 99, r = 99;
  CHECK(parse("100,-100", l, r)); CHECK_EQ(l, 100); CHECK_EQ(r, -100);
  CHECK(parse("0,0", l, r));      CHECK_EQ(l, 0);   CHECK_EQ(r, 0);
  CHECK(parse("-255,255", l, r)); CHECK_EQ(l, -255); CHECK_EQ(r, 255);
  CHECK(parse("999,-999", l, r)); CHECK_EQ(l, 255); CHECK_EQ(r, -255);        // out of range is clamped
  CHECK(parse("99999999999,-99999999999", l, r)); CHECK_EQ(l, 255); CHECK_EQ(r, -255);
  CHECK(parse("+5,+6", l, r));    CHECK_EQ(l, 5);   CHECK_EQ(r, 6);           // strtol accepts a sign
  CHECK(parse(" 7,8", l, r));     CHECK_EQ(l, 7);                              // and leading space (existing behavior)
}

TEST(parse_malformed_rejected_and_outputs_untouched) {
  const char* bad[] = {"", ",", "1", "1,", ",1", "a,b", "1,b", "a,1", "1 ,2", "1,2 ", "1,2,3", "1;2",
                       "1.5,2", "1,2x", "--1,2", "stop", "Stop", "PINGx", "0x10,1", "1,\t2x"};
  for (const char* s : bad) {
    int l = 41, r = 42;
    bool ok = parse(s, l, r);
    if (ok) printf("  unexpectedly accepted: \"%s\"\n", s);
    CHECK(!ok);
    CHECK_EQ(l, 41); CHECK_EQ(r, 42);
  }
}

TEST(classify_stop_ping_exact_match_only) {
  int l = 0, r = 0;
  CHECK_EQ(nav::classifyLine("STOP", l, r), nav::LINE_STOP);
  CHECK_EQ(nav::classifyLine("PING", l, r), nav::LINE_PING);
  CHECK_EQ(nav::classifyLine("stop", l, r), nav::LINE_IGNORED);
  CHECK_EQ(nav::classifyLine("STOP ", l, r), nav::LINE_IGNORED);
  CHECK_EQ(nav::classifyLine("", l, r), nav::LINE_IGNORED);
  CHECK_EQ(nav::classifyLine("5,5", l, r), nav::LINE_SPEEDS); CHECK_EQ(l, 5); CHECK_EQ(r, 5);
}

TEST(rx_framing_newline_cr_split_and_multiple_lines) {
  Sim s; s.onConnect();
  s.write("10,10\n");                      CHECK(s.cmdValid); CHECK_EQ(s.cmdL, 10);
  s.write("20,2"); CHECK_EQ(s.cmdL, 10);   // incomplete: nothing happens yet
  s.write("0\r");                          CHECK_EQ(s.cmdL, 20); CHECK_EQ(s.cmdR, 20);
  s.write("1,1\n2,2\n3,3\n");              CHECK_EQ(s.cmdL, 3);       // all lines in one write are processed in order
  s.write("\n\r\n\n");                     CHECK_EQ(s.cmdL, 3);       // empty lines ignored
  s.write("PING\n");                       CHECK(s.pongPending);
  s.write("STOP\n");                       CHECK(!s.cmdValid); CHECK_EQ(s.cmdL, 0); CHECK_EQ(s.cmdR, 0);
}

TEST(rx_oversize_line_dropped_and_recovers) {
  Sim s; s.onConnect();
  // buffer is 24 bytes: 23 chars fit, the 24th overflows.
  std::string ok23 = "1," + std::string(21, '0');              // "1,000...0" (23 chars) parses as 1,0
  CHECK_EQ(ok23.size(), 23);
  s.write(ok23 + "\n");                    CHECK(s.cmdValid); CHECK_EQ(s.cmdL, 1);
  s.write("STOP\n");                       CHECK(!s.cmdValid);
  std::string big24 = "1," + std::string(22, '0');             // 24 chars
  s.write(big24 + "\n");                   CHECK(!s.cmdValid);  // dropped, not truncated-and-parsed
  s.write(std::string(200, '9') + "\n");   CHECK(!s.cmdValid);
  s.write("7,7\n");                        CHECK(s.cmdValid); CHECK_EQ(s.cmdL, 7);   // next line is clean
}

TEST(rx_control_bytes_poison_the_line) {
  Sim s; s.onConnect();
  s.write(std::string("5,5\x01") + "\n");  CHECK(!s.cmdValid);   // control byte -> whole line dropped
  s.write(std::string("5,\x7f" "5\n"));    CHECK(!s.cmdValid);   // 127 is out of printable range
  s.write(std::string("5,5\xff\n"));       CHECK(!s.cmdValid);   // high byte
  s.write(std::string("5,\0" "5\n", 5));   CHECK(!s.cmdValid);   // embedded NUL
  s.write("\t5,5\n");                      CHECK(!s.cmdValid);   // tab is a control byte
  s.write("5,5\n");                        CHECK(s.cmdValid);    // recovers on the next line
}

TEST(rx_ignored_when_not_connected) {
  Sim s;                                   // never connected
  s.write("50,50\n");                      CHECK(!s.cmdValid); CHECK_EQ(s.cmdL, 0);
  s.onConnect(); s.write("50,50\n");       CHECK(s.cmdValid);
  s.onDisconnect(); s.write("60,60\n");    CHECK(!s.cmdValid); CHECK_EQ(s.cmdL, 0);
}

TEST(connect_and_disconnect_reset_partial_line_and_state) {
  Sim s; s.onConnect();
  s.write("5,");                           // half a line pending
  s.onDisconnect(); s.onConnect();
  s.write("5\n");                          // must NOT complete the old "5,"
  CHECK(!s.cmdValid);
  s.write("PING\n"); s.onDisconnect(); CHECK(!s.pongPending);
}

// ------------------------------------------------------------------ watchdog
TEST(watchdog_boundary_299_fresh_300_stale) {
  CHECK(nav::commandFresh(true, true, 1299, 1000));     // age 299
  CHECK(!nav::commandFresh(true, true, 1300, 1000));    // age 300
  CHECK(nav::commandFresh(true, true, 1000, 1000));     // age 0
  CHECK(!nav::commandFresh(false, true, 1000, 1000));   // no valid command
  CHECK(!nav::commandFresh(true, false, 1000, 1000));   // not connected
}

// Mutation target: if commandFresh compared unsigned, this fails (BLE task wrote a newer lastCmdMs).
TEST(watchdog_signed_age_future_timestamp_is_fresh) {
  CHECK(nav::commandFresh(true, true, 1000, 1003));     // last is 3 ms ahead of now
  CHECK(nav::commandFresh(true, true, 1000, 1299));
  CHECK(nav::commandFresh(true, true, 0, 1));
  // 32-bit millis wraparound: age stays correct across the wrap
  CHECK(nav::commandFresh(true, true, 5, 0xFFFFFFF0u));     // age 21
  CHECK(!nav::commandFresh(true, true, 400, 0xFFFFFFF0u));  // age 416
}

TEST(no_valid_command_after_connect_means_stopped_with_watchdog_flag) {
  Sim s; s.onConnect();
  s.run(500);
  CHECK(!s.fresh); CHECK_EQ(s.appliedL, 0); CHECK_EQ(s.appliedR, 0);
  CHECK(s.flags & FLAG_WATCHDOG); CHECK(s.flags & FLAG_CONNECTED);
  CHECK(s.left.brake && s.right.brake);
}

TEST(disconnect_brakes_within_one_tick_and_clears_connected_flag_source) {
  Sim s; s.onConnect(); s.write("200,200\n"); s.run(200);
  CHECK(s.appliedL > 0);
  s.onDisconnect(); s.tick();
  CHECK_EQ(s.appliedL, 0); CHECK_EQ(s.appliedR, 0);
  CHECK(s.left.brake && s.right.brake && s.left.pwm == 0 && s.right.pwm == 0);
  // reconnect without a new command stays stopped
  s.onConnect(); s.run(100);
  CHECK_EQ(s.appliedL, 0);
}

TEST(stop_command_zeroes_immediately_without_ramp) {
  Sim s; s.onConnect(); s.write("255,255\n"); s.run(150);
  CHECK(s.appliedL > 50);
  s.write("STOP\n"); s.tick();
  CHECK_EQ(s.appliedL, 0); CHECK_EQ(s.appliedR, 0); CHECK(s.flags & FLAG_WATCHDOG);
}

TEST(watchdog_resumes_on_next_command_and_ramps_from_zero) {
  Sim s; s.onConnect(); s.write("100,100\n"); s.run(100);
  s.run(400);                                           // no commands: watchdog fired
  CHECK(!s.fresh); CHECK_EQ(s.appliedL, 0);
  s.write("100,100\n"); s.tick();
  CHECK(s.fresh); CHECK(!(s.flags & FLAG_WATCHDOG));
  CHECK_EQ(s.appliedL, SLEW_PER_TICK);                  // resumes from 0, one slew step
}

// ------------------------------------------------------------------ clamps
TEST(front_obstacle_clamps_forward_keeps_turning) {
  int l = 0, r = 0;
  // linear=100 angular=0, front blocked: immediate zero
  nav::computeApplied(true, 100, 100, true, false, l, r); CHECK_EQ(l, 0); CHECK_EQ(r, 0);
  // spin right: linear 0, angular 100 -> unaffected, but slewed
  l = r = 0;
  nav::computeApplied(true, -100, 100, true, false, l, r); CHECK_EQ(l, -SLEW_PER_TICK); CHECK_EQ(r, SLEW_PER_TICK);
  // arc forward-right (L=50,R=150): linear 100 -> 0, angular 50 kept: L=-50, R=50 applied immediately
  l = r = 0;
  nav::computeApplied(true, 50, 150, true, false, l, r); CHECK_EQ(l, -50); CHECK_EQ(r, 50);
  // reversing is allowed with front blocked (linear <= 0 not clamped), ramped
  l = r = 0;
  nav::computeApplied(true, -100, -100, true, false, l, r); CHECK_EQ(l, -SLEW_PER_TICK); CHECK_EQ(r, -SLEW_PER_TICK);
}

TEST(rear_obstacle_clamps_reverse_keeps_turning) {
  int l = 0, r = 0;
  nav::computeApplied(true, -100, -100, false, true, l, r); CHECK_EQ(l, 0); CHECK_EQ(r, 0);
  l = r = 0;
  nav::computeApplied(true, -150, -50, false, true, l, r); CHECK_EQ(l, -50); CHECK_EQ(r, 50);   // linear -100 -> 0, angular 50
  l = r = 0;
  nav::computeApplied(true, 100, 100, false, true, l, r); CHECK_EQ(l, SLEW_PER_TICK); CHECK_EQ(r, SLEW_PER_TICK);
}

TEST(clamp_thresholds_front_lt20_rear_lt15_and_999_is_no_echo) {
  CHECK(nav::frontBlocked(19));  CHECK(!nav::frontBlocked(20));  CHECK(!nav::frontBlocked(21));
  CHECK(nav::rearBlocked(14));   CHECK(!nav::rearBlocked(15));   CHECK(!nav::rearBlocked(16));
  CHECK(nav::frontBlocked(0));
  CHECK(!nav::frontBlocked(NO_ECHO_CM)); CHECK(!nav::rearBlocked(NO_ECHO_CM));
  CHECK(!nav::rearBlocked(19));          // 19 cm behind is fine (rear threshold is 15)
  CHECK_EQ(nav::statusFlags(true, true, false), FLAG_FRONT | FLAG_CONNECTED);
  CHECK_EQ(nav::statusFlags(false, false, true), FLAG_WATCHDOG | FLAG_REAR | FLAG_CONNECTED);
  CHECK_EQ(nav::statusFlags(true, false, false), FLAG_CONNECTED);
  CHECK_EQ(nav::statusFlags(false, true, true), 15);
}

TEST(sonar_echo_conversion_and_median) {
  CHECK_EQ(nav::echoToCm(false, 1000), NO_ECHO_CM);        // no falling edge seen
  CHECK_EQ(nav::echoToCm(true, 25000), NO_ECHO_CM);        // at timeout = no echo
  CHECK_EQ(nav::echoToCm(true, 24999), 24999 / 58);
  CHECK_EQ(nav::echoToCm(true, 580), 10);
  CHECK_EQ(nav::echoToCm(true, 0), 0);
  CHECK_EQ(nav::echoToCm(true, 24999) < NO_ECHO_CM, 1);
  int a[3] = {999, 999, 15};  CHECK_EQ(nav::median3(a), 999);   // a single close reading is outvoted
  int b[3] = {10, 10, 999};   CHECK_EQ(nav::median3(b), 10);
  int c[3] = {30, 5, 20};     CHECK_EQ(nav::median3(c), 20);
  int d[3] = {1, 2, 3};       CHECK_EQ(nav::median3(d), 2);
  int e[3] = {3, 2, 1};       CHECK_EQ(nav::median3(e), 2);
}

// Mutation target: if the second clamp after slew is removed, the mid-ramp cases fail.
TEST(clamp_reapplied_after_slew_mid_ramp) {
  // Driving forward at 100, then the phone asks for 0,0 (not clamped since linear == 0) while the
  // front just became blocked: slew alone would leave 90,90. The post-slew clamp must zero it.
  int l = 100, r = 100;
  nav::computeApplied(true, 0, 0, true, false, l, r);
  CHECK_EQ(l, 0); CHECK_EQ(r, 0);
  // Same for requested reverse while still rolling forward.
  l = r = 100;
  nav::computeApplied(true, -50, -50, true, false, l, r);
  CHECK(l + r <= 0);
  // Rear mirror: rolling backward, rear blocks, phone asks 0,0.
  l = r = -100;
  nav::computeApplied(true, 0, 0, false, true, l, r);
  CHECK_EQ(l, 0); CHECK_EQ(r, 0);
  // Turning while rolling is preserved by the post-slew clamp: applied (110,90) -> slew toward (0,0)
  // gives (100,80) sum>0 -> becomes pure rotation (-angular, angular) with angular=(80-100)/2.
  l = 110; r = 90;
  nav::computeApplied(true, 0, 0, true, false, l, r);
  CHECK(l + r <= 0);
  CHECK_EQ(l, 10); CHECK_EQ(r, -10);
}

TEST(clamp_exhaustive_never_drives_into_obstacle) {
  // For every applied state, request, and blocked combination, output never moves toward a blocked side.
  for (int al = -255; al <= 255; al += 5)
    for (int ar = -255; ar <= 255; ar += 5)
      for (int rl = -255; rl <= 255; rl += 15)
        for (int rr = -255; rr <= 255; rr += 15)
          for (int f = 0; f < 2; f++)
            for (int b = 0; b < 2; b++) {
              int l = al, r = ar;
              nav::computeApplied(true, rl, rr, f, b, l, r);
              if (f && l + r > 0) { CHECK(false); return; }
              if (b && l + r < 0) { CHECK(false); return; }
              CHECK(l >= -255 && l <= 255 && r >= -255 && r <= 255);
            }
}

TEST(slew_ten_per_tick) {
  CHECK_EQ(nav::slew(0, 100), 10);  CHECK_EQ(nav::slew(0, -100), -10);
  CHECK_EQ(nav::slew(95, 100), 100); CHECK_EQ(nav::slew(100, 0), 90);
  CHECK_EQ(nav::slew(5, 15), 15);   CHECK_EQ(nav::slew(5, 16), 15);   CHECK_EQ(nav::slew(5, 14), 14);
  Sim s; s.onConnect(); s.write("255,255\n");
  for (int i = 1; i <= 5; i++) { s.write("255,255\n"); s.tick(); CHECK_EQ(s.appliedL, 10 * i); }
}

// ------------------------------------------------------------------ PWM mapping
TEST(pwm_mapping_formula_and_cap) {
  nav::SideDrive d;
  d = nav::sideDrive(0, 1, 100);   CHECK(d.brake); CHECK(d.in1High && d.in2High); CHECK_EQ(d.pwm, 0);
  d = nav::sideDrive(1, 1, 100);   CHECK(!d.brake); CHECK_EQ(d.pwm, PWM_MIN + 1 * (MAX_PWM - PWM_MIN) / 255);   // 70
  d = nav::sideDrive(255, 1, 100); CHECK_EQ(d.pwm, MAX_PWM);
  d = nav::sideDrive(128, 1, 100); CHECK_EQ(d.pwm, 70 + 128 * 130 / 255);                                       // 135
  d = nav::sideDrive(-128, 1, 100); CHECK_EQ(d.pwm, 135);
  CHECK_EQ(MAX_PWM, 200); CHECK_EQ(PWM_MIN, 70);
  for (int v = -255; v <= 255; v++) {
    d = nav::sideDrive(v, 1, 100);
    CHECK(d.pwm >= 0 && d.pwm <= MAX_PWM);
    if (v != 0) CHECK(d.pwm >= PWM_MIN);
  }
  // monotonic in magnitude
  for (int v = 1; v < 255; v++) CHECK(nav::sideDrive(v + 1, 1, 100).pwm >= nav::sideDrive(v, 1, 100).pwm);
}

TEST(pwm_direction_sign_and_trim) {
  nav::SideDrive f = nav::sideDrive(100, 1, 100), b = nav::sideDrive(-100, 1, 100);
  CHECK(f.in1High && !f.in2High); CHECK(!b.in1High && b.in2High);
  nav::SideDrive flipped = nav::sideDrive(100, -1, 100);              // sign -1 reverses direction
  CHECK(!flipped.in1High && flipped.in2High); CHECK_EQ(flipped.pwm, f.pwm);
  CHECK_EQ(nav::sideDrive(255, 1, 80).pwm, 160);                      // trim scales, then caps
  CHECK_EQ(nav::sideDrive(255, 1, 150).pwm, MAX_PWM);                 // trim cannot exceed the cap
  CHECK_EQ(nav::sideDrive(1, 1, 50).pwm, 35);
  CHECK(nav::sideDrive(0, -1, 50).brake);                             // zero is always a short brake
  CHECK_EQ(LEFT_SIGN, 1); CHECK_EQ(RIGHT_SIGN, -1);   // right side measured inverted on the rover CHECK_EQ(LEFT_TRIM, 100); CHECK_EQ(RIGHT_TRIM, 100);
}

// ------------------------------------------------------------------ scenarios (simulated time)
TEST(scenario_command_stream_stops_motors_zero_within_300ms_plus_one_tick) {
  Sim s; s.onConnect();
  uint32_t t0 = 0;
  // stream 200,200 every 50 ms for 1 s, last command lands exactly at the end of the stream
  for (int i = 0; i < 20; i++) { s.write("200,200\n"); for (int k = 0; k < 5; k++) s.tick(); }
  CHECK(s.appliedL > 100); CHECK(s.fresh);
  t0 = s.lastCmdMs;                          // "t = 0": the stream stops, the last command is at lastCmdMs
  bool zeroSeen = false; uint32_t zeroAt = 0;
  for (int i = 0; i < 100 && !zeroSeen; i++) {
    s.tick();
    if (s.appliedL == 0 && s.appliedR == 0) { zeroSeen = true; zeroAt = s.now - t0; }
  }
  CHECK(zeroSeen);
  CHECK(zeroAt <= WATCHDOG_MS + LOOP_MS);    // 300 ms + one loop tick
  CHECK(zeroAt >= WATCHDOG_MS - LOOP_MS);    // and it did not stop before the watchdog window
  CHECK(s.flags & FLAG_WATCHDOG);
  CHECK(s.left.brake && s.right.brake);
  // and it stays stopped
  s.run(1000); CHECK_EQ(s.appliedL, 0); CHECK_EQ(s.appliedR, 0); CHECK(s.flags & FLAG_WATCHDOG);
}

TEST(scenario_front_obstacle_appears_mid_ramp_forward_output_never_positive) {
  for (int rampTicks = 1; rampTicks <= 25; rampTicks++) {
    for (int req : {255, 100, 30}) {
      Sim s; s.onConnect();
      char cmd[32]; snprintf(cmd, sizeof cmd, "%d,%d\n", req, req);
      for (int i = 0; i < rampTicks; i++) { s.write(cmd); s.tick(); }
      s.feedFront(12);                       // obstacle appears at an arbitrary point of the ramp
      for (int i = 0; i < 40; i++) {
        s.write(cmd); s.tick();              // phone keeps asking for full forward
        CHECK(s.appliedL + s.appliedR <= 0);
        CHECK(s.appliedL <= 0 && s.appliedR <= 0);
        CHECK(s.flags & FLAG_FRONT);
        if (s.appliedL + s.appliedR > 0) return;
      }
      for (int i = 0; i < 2; i++) { s.feedFront(200); s.write(cmd); s.tick(); CHECK(s.flags & FLAG_FRONT); }
      s.feedFront(200);                      // 3rd consecutive clear reading: obstacle left, driving resumes with a ramp
      s.write(cmd); s.tick();
      CHECK(!(s.flags & FLAG_FRONT));
      CHECK_EQ(s.appliedL, SLEW_PER_TICK);
    }
  }
}

TEST(scenario_front_obstacle_while_phone_slows_to_zero_post_slew_clamp_needed) {
  Sim s; s.onConnect();
  for (int i = 0; i < 20; i++) { s.write("200,200\n"); s.tick(); }
  CHECK_EQ(s.appliedL, 200);
  s.feedFront(10);
  s.write("0,0\n"); s.tick();                // phone releases the stick the same tick the obstacle shows
  CHECK_EQ(s.appliedL, 0); CHECK_EQ(s.appliedR, 0);
}

TEST(scenario_turning_allowed_when_blocked_front_and_rear) {
  Sim s; s.onConnect(); s.feedFront(5); s.feedRear(5);
  for (int i = 0; i < 30; i++) { s.write("-100,100\n"); s.tick(); }
  CHECK_EQ(s.appliedL, -100); CHECK_EQ(s.appliedR, 100);
  CHECK((s.flags & (FLAG_FRONT | FLAG_REAR)) == (FLAG_FRONT | FLAG_REAR));
  for (int i = 0; i < 30; i++) { s.write("100,100\n"); s.tick(); CHECK(s.appliedL + s.appliedR == 0); }
}

// ------------------------------------------------------------------ differential vs original code
TEST(differential_vs_legacy_loop_body) {
  uint32_t seed = 12345;
  auto rnd = [&]() { seed = seed * 1664525u + 1013904223u; return seed >> 8; };
  long compared = 0;
  for (int trial = 0; trial < 400000; trial++) {
    uint32_t now = (rnd() % 4) == 0 ? 0xFFFFFF00u + rnd() % 400 : rnd() % 100000;
    uint32_t last = now + (int)(rnd() % 700) - 350;
    bool valid = rnd() % 8 != 0, conn = rnd() % 8 != 0;
    int reqL = (int)(rnd() % 511) - 255, reqR = (int)(rnd() % 511) - 255;
    int front = rnd() % 3 == 0 ? (int)(rnd() % 40) : (rnd() % 2 ? 999 : (int)(rnd() % 400));
    int rear = rnd() % 3 == 0 ? (int)(rnd() % 40) : (rnd() % 2 ? 999 : (int)(rnd() % 400));
    int aL = (int)(rnd() % 511) - 255, aR = (int)(rnd() % 511) - 255;
    int nL = aL, nR = aR, oL = aL, oR = aR, oflags = 0;
    bool oFresh = legacy::loopBody(now, last, valid, conn, reqL, reqR, front, rear, oL, oR, oflags);
    bool fr = nav::frontBlocked(front), re = nav::rearBlocked(rear);
    bool nFresh = nav::commandFresh(valid, conn, now, last);
    nav::computeApplied(nFresh, reqL, reqR, fr, re, nL, nR);
    nav::SideDrive dl = nav::sideDrive(nL, LEFT_SIGN, LEFT_TRIM), dr = nav::sideDrive(nR, RIGHT_SIGN, RIGHT_TRIM);
    int nflags = nav::statusFlags(nFresh, fr, re);
    const legacy::Pins& pl = legacy::side(0); const legacy::Pins& pr = legacy::side(1);
    bool same = oFresh == nFresh && oL == nL && oR == nR && oflags == nflags &&
                pl.in1 == dl.in1High && pl.in2 == dl.in2High && pl.pwm == dl.pwm &&
                pr.in1 == dr.in1High && pr.in2 == dr.in2High && pr.pwm == dr.pwm;
    if (!same) { CHECK(same); printf("  mismatch trial %d\n", trial); return; }
    compared++;
  }
  CHECK_EQ(compared, 400000);
  // parse + sonar
  for (int i = 0; i < 100000; i++) {
    char buf[24]; int n = (int)(rnd() % 12);
    const char alphabet[] = "0123456789,-+ aS";
    for (int k = 0; k < n; k++) buf[k] = alphabet[rnd() % (sizeof(alphabet) - 1)];
    buf[n] = 0;
    int l1 = 7, r1 = 7, l2 = 7, r2 = 7;
    bool a = legacy::parseSpeeds(buf, l1, r1), b = nav::parseSpeeds(buf, l2, r2);
    if (a != b || l1 != l2 || r1 != r2) { CHECK(false); printf("  parse mismatch \"%s\"\n", buf); return; }
    uint32_t w = rnd() % 40000;
    if (legacy::sonarCm(i & 1, w) != nav::echoToCm(i & 1, w)) { CHECK(false); return; }
    int h[3] = {(int)(rnd() % 1000), (int)(rnd() % 1000), (int)(rnd() % 1000)};
    if (legacy::median3(h) != nav::median3(h)) { CHECK(false); return; }
  }
  CHECK(true);
}

// ------------------------------------------------------------------ source checks on navigator.ino
static std::string readFile(const char* path) {
  std::ifstream f(path); std::stringstream ss; ss << f.rdbuf(); return ss.str();
}

TEST(ino_stby_high_only_after_ble_init_and_low_first) {
  std::string ino = readFile("firmware/navigator/navigator.ino");
  CHECK(!ino.empty());
  size_t low = ino.find("digitalWrite(PIN_STBY, LOW);");
  size_t ble = ino.find("  setupBle();");
  size_t high = ino.find("digitalWrite(PIN_STBY, HIGH);");
  CHECK(low != std::string::npos && ble != std::string::npos && high != std::string::npos);
  CHECK(low < ble); CHECK(ble < high);
  CHECK(ino.find("digitalWrite(PIN_STBY, HIGH);", high + 1) == std::string::npos);   // exactly one enable
}

// ---- release hysteresis (T-043). One feed = one fresh sonar measurement; run(100) = ~10 ticks between them.
static void front100(Sim& s) { s.onConnect(); for (int i = 0; i < 50; i++) { s.write("100,100\n"); s.tick(); } }   // ramped up, driving

TEST(hysteresis_replays_observed_front_trace) {
  Sim s; front100(s);
  CHECK(s.appliedL > 0);
  const int trace[] = {11, 13, 16, 39, 16, 15, 13};   // real bench trace, hand 11-16 cm in front
  for (int cm : trace) {
    s.feedFront(cm);
    for (int i = 0; i < 10; i++) {                    // 100 ms of ticks, command kept fresh
      if (i == 0) s.write("100,100\n");
      s.tick();
      CHECK_EQ(s.appliedL, 0); CHECK_EQ(s.appliedR, 0);   // forward output stays 0 through the 39
      CHECK(s.flags & FLAG_FRONT);
    }
  }
}

TEST(hysteresis_engages_on_single_close_reading) {
  Sim s; front100(s);
  s.feedFront(19); s.tick();
  CHECK(s.flags & FLAG_FRONT); CHECK_EQ(s.appliedL, 0);
  Sim r; r.onConnect(); for (int i = 0; i < 50; i++) { r.write("-100,-100\n"); r.tick(); }
  r.feedRear(14); r.tick();
  CHECK(r.flags & FLAG_REAR); CHECK_EQ(r.appliedL, 0);
  Sim t; t.feedFront(20); t.feedRear(15); t.tick();                  // at threshold is clear
  CHECK(!(t.flags & (FLAG_FRONT | FLAG_REAR)));
}

TEST(hysteresis_front_releases_only_on_third_consecutive_clear) {
  Sim s; front100(s);
  s.feedFront(10); s.tick(); CHECK(s.flags & FLAG_FRONT);
  s.feedFront(50); s.tick(); CHECK(s.flags & FLAG_FRONT);            // clear 1
  s.tick(); s.tick(); CHECK(s.flags & FLAG_FRONT);                   // no new measurement: no progress
  s.feedFront(50); s.tick(); CHECK(s.flags & FLAG_FRONT);            // clear 2
  s.feedFront(12); s.tick(); CHECK(s.flags & FLAG_FRONT);            // close: count resets
  s.feedFront(50); s.tick(); CHECK(s.flags & FLAG_FRONT);            // clear 1
  s.feedFront(NO_ECHO_CM); s.tick(); CHECK(s.flags & FLAG_FRONT);    // 999 counts as clear: 2
  s.feedFront(50); s.write("100,100\n"); s.tick();                  // clear 3: released
  CHECK(!(s.flags & FLAG_FRONT));
  for (int i = 0; i < 10; i++) { s.write("100,100\n"); s.tick(); } CHECK(s.appliedL > 0);                                 // forward moves again
}

TEST(hysteresis_rear_releases_only_on_third_consecutive_clear) {
  Sim s; s.onConnect(); for (int i = 0; i < 50; i++) { s.write("-100,-100\n"); s.tick(); }
  s.feedRear(5); s.tick(); CHECK(s.flags & FLAG_REAR); CHECK_EQ(s.appliedL, 0);
  s.feedRear(200); s.tick(); CHECK(s.flags & FLAG_REAR);
  s.feedRear(200); s.tick(); CHECK(s.flags & FLAG_REAR);
  s.feedRear(14); s.tick(); CHECK(s.flags & FLAG_REAR);              // close resets
  s.feedRear(200); s.tick(); s.feedRear(200); s.tick();
  CHECK(s.flags & FLAG_REAR);                                        // only 2 clear so far
  s.write("-100,-100\n"); s.feedRear(200); s.tick();
  CHECK(!(s.flags & FLAG_REAR));
  for (int i = 0; i < 10; i++) { s.write("-100,-100\n"); s.tick(); } CHECK(s.appliedL < 0);
}

TEST(hysteresis_turning_and_opposite_direction_stay_allowed_while_blocked) {
  Sim s; s.onConnect(); for (int i = 0; i < 30; i++) { s.write("-100,100\n"); s.tick(); }   // turn in place
  s.feedFront(10); s.feedRear(10); s.tick();
  CHECK(s.flags & FLAG_FRONT); CHECK(s.flags & FLAG_REAR);
  for (int i = 0; i < 10; i++) { s.write("-100,100\n"); s.tick(); }
  CHECK(s.appliedL < 0); CHECK(s.appliedR > 0);                      // turning allowed with both blocked
  Sim f; f.onConnect(); for (int i = 0; i < 30; i++) { f.write("-100,-100\n"); f.tick(); }         // front blocked, reversing
  f.feedFront(10); f.write("-100,-100\n"); f.tick();
  CHECK(f.flags & FLAG_FRONT); for (int i = 0; i < 10; i++) { f.write("-100,-100\n"); f.tick(); } CHECK(f.appliedL < 0);
  Sim r; r.onConnect(); for (int i = 0; i < 30; i++) { r.write("100,100\n"); r.tick(); }           // rear blocked, going forward
  r.feedRear(10); r.write("100,100\n"); r.tick();
  CHECK(r.flags & FLAG_REAR); for (int i = 0; i < 10; i++) { r.write("100,100\n"); r.tick(); } CHECK(r.appliedL > 0);
}

TEST(ino_uses_safety_h_and_does_not_redefine_its_constants) {
  std::string ino = readFile("firmware/navigator/navigator.ino");
  CHECK(ino.find("#include \"safety.h\"") != std::string::npos);
  const char* consts[] = {"const int MAX_PWM", "const int PWM_MIN", "const int LEFT_SIGN", "const int RIGHT_SIGN",
                          "const int LEFT_TRIM", "const int RIGHT_TRIM", "const unsigned long WATCHDOG_MS",
                          "const int SLEW_PER_TICK", "const int FRONT_STOP_CM", "const int REAR_STOP_CM",
                          "const int NO_ECHO_CM", "const int FLAG_WATCHDOG", "const unsigned long SONAR_TIMEOUT_US"};
  for (const char* c : consts) { if (ino.find(c) != std::string::npos) printf("  duplicated: %s\n", c); CHECK(ino.find(c) == std::string::npos); }
  std::string hdr = readFile("firmware/navigator/safety.h");
  CHECK(hdr.find("#include <Arduino.h>") == std::string::npos);
  CHECK(hdr.find("#include <BLE") == std::string::npos);
}

int main() {
  for (int i = 0; i < g_nTests; i++) {
    int before = g_failed;
    g_tests[i].fn();
    printf("%s %s\n", g_failed == before ? "ok  " : "FAIL", g_tests[i].name);
  }
  printf("\n%d tests, %d checks, %d failed\n", g_nTests, g_checks, g_failed);
  return g_failed ? 1 : 0;
}
