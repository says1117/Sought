// Navigator firmware v1: ESP32 + TB6612 + 2x HC-SR04, driven by the phone over BLE.
// Written for ESP32 Arduino core 3.x (ledcAttach, String getValue()). Does NOT build on 2.x.
// Spec: docs/03_CONTRACTS.md section 1 and docs/01_ROBOTICS_PLAN.md section 2.
// Safety (watchdog, sonar stops, disconnect stop) lives here and never depends on the phone.
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ---------------------------------------------------------------- constants
#define SERVICE_UUID "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define RX_UUID      "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  // phone -> ESP32 (write)
#define TX_UUID      "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // ESP32 -> phone (notify)

// Pins (docs/01_ROBOTICS_PLAN.md 1.2)
const int PIN_STBY = 4;
const int PIN_PWMA = 25, PIN_AIN1 = 26, PIN_AIN2 = 27;   // left
const int PIN_PWMB = 14, PIN_BIN1 = 13, PIN_BIN2 = 33;   // right
const int PIN_FRONT_TRIG = 19, PIN_FRONT_ECHO = 21;
const int PIN_REAR_TRIG  = 5,  PIN_REAR_ECHO  = 18;
const int PIN_LED = 2;

// Motor tuning. Set from bench tests 3, 7, 8 (plan 1.3). Placeholders until measured.
const int MAX_PWM   = 200;   // demo speed cap (contract)
const int PWM_MIN   = 70;    // deadband: lowest PWM that moves the rover. MEASURE (bench test 8)
const int LEFT_SIGN = 1;     // flip to -1 if left motors spin the wrong way (bench test 3)
const int RIGHT_SIGN = 1;
const int LEFT_TRIM  = 100;  // percent, for driving straight (bench test 7)
const int RIGHT_TRIM = 100;
const int PWM_FREQ_HZ = 20000;
const int PWM_BITS    = 8;

// Timing
const unsigned long WATCHDOG_MS = 300;
const unsigned long LOOP_MS     = 10;
const int SLEW_PER_TICK         = 10;    // max change of applied speed per 10 ms tick
const unsigned long SONAR_SLOT_MS = 50;  // alternate front/rear
const unsigned long SONAR_TIMEOUT_US = 25000;
const unsigned long STATUS_MS   = 200;   // 5 Hz
const unsigned long DEBUG_MS    = 500;   // 2 Hz

// Safety thresholds (contract)
const int FRONT_STOP_CM = 20;
const int REAR_STOP_CM  = 15;
const int NO_ECHO_CM    = 999;

// Status flags
const int FLAG_WATCHDOG = 1, FLAG_FRONT = 2, FLAG_REAR = 4, FLAG_CONNECTED = 8;

// ---------------------------------------------------------------- shared state
BLEServer* server = nullptr;
BLECharacteristic* txChar = nullptr;
volatile bool connected = false;
volatile int cmdL = 0, cmdR = 0;           // last command from the phone
volatile unsigned long lastCmdMs = 0;
volatile bool cmdValid = false;            // false at boot, after STOP, after disconnect
volatile bool pongPending = false;

int appliedL = 0, appliedR = 0;            // speeds actually applied (-255..255)

// ---------------------------------------------------------------- motors
void fatal(const char* why) {
  digitalWrite(PIN_STBY, LOW);
  for (;;) {                               // motors stay off; fast blink so it is noticed
    Serial.printf("FATAL: %s\n", why);
    digitalWrite(PIN_LED, !digitalRead(PIN_LED));
    delay(150);
  }
}

// One side of the TB6612. v in -255..255 after safety and ramping.
void driveSide(int pwmPin, int in1, int in2, int v, int sign, int trim) {
  v *= sign;
  if (v == 0) {                            // short brake
    digitalWrite(in1, HIGH);
    digitalWrite(in2, HIGH);
    ledcWrite(pwmPin, 0);
    return;
  }
  int mag = abs(v);
  int pwm = PWM_MIN + mag * (MAX_PWM - PWM_MIN) / 255;
  pwm = constrain(pwm * trim / 100, 0, MAX_PWM);
  digitalWrite(in1, v > 0 ? HIGH : LOW);
  digitalWrite(in2, v > 0 ? LOW : HIGH);
  ledcWrite(pwmPin, pwm);
}

void applyMotors(int l, int r) {
  driveSide(PIN_PWMA, PIN_AIN1, PIN_AIN2, l, LEFT_SIGN, LEFT_TRIM);
  driveSide(PIN_PWMB, PIN_BIN1, PIN_BIN2, r, RIGHT_SIGN, RIGHT_TRIM);
}

int slew(int cur, int target) {
  if (target > cur + SLEW_PER_TICK) return cur + SLEW_PER_TICK;
  if (target < cur - SLEW_PER_TICK) return cur - SLEW_PER_TICK;
  return target;
}

// ---------------------------------------------------------------- sonar
// Echo timing is done in interrupts so the 10 ms control loop never blocks.
struct Sonar {
  int trigPin, echoPin;
  volatile uint32_t riseUs;
  volatile uint32_t widthUs;
  volatile bool done;
  int hist[3];
  int cm;                                  // median of last 3, 999 = no echo
};
Sonar sonars[2] = {
  {PIN_FRONT_TRIG, PIN_FRONT_ECHO, 0, 0, false, {NO_ECHO_CM, NO_ECHO_CM, NO_ECHO_CM}, NO_ECHO_CM},
  {PIN_REAR_TRIG,  PIN_REAR_ECHO,  0, 0, false, {NO_ECHO_CM, NO_ECHO_CM, NO_ECHO_CM}, NO_ECHO_CM},
};
int sonarActive = -1;                      // index being measured, -1 before first trigger

void IRAM_ATTR echoEdge(Sonar& s) {
  uint32_t t = micros();
  if (digitalRead(s.echoPin)) { s.riseUs = t; }
  else { s.widthUs = t - s.riseUs; s.done = true; }
}
void IRAM_ATTR frontEdge() { echoEdge(sonars[0]); }
void IRAM_ATTR rearEdge()  { echoEdge(sonars[1]); }

int median3(const int* h) {
  int a = h[0], b = h[1], c = h[2];
  if (a > b) { int t = a; a = b; b = t; }
  if (b > c) { b = c; }
  return a > b ? a : b;
}

void sonarTick(unsigned long now) {
  static unsigned long lastSlot = 0;
  if (now - lastSlot < SONAR_SLOT_MS) return;
  lastSlot = now;

  if (sonarActive >= 0) {                  // collect the previous measurement
    Sonar& p = sonars[sonarActive];
    int cm = NO_ECHO_CM;
    if (p.done && p.widthUs < SONAR_TIMEOUT_US) cm = min((int)(p.widthUs / 58), NO_ECHO_CM);
    p.hist[0] = p.hist[1]; p.hist[1] = p.hist[2]; p.hist[2] = cm;
    p.cm = median3(p.hist);
  }
  sonarActive = (sonarActive + 1) % 2;     // -1 -> 0 on the first call
  Sonar& s = sonars[sonarActive];
  s.done = false;
  digitalWrite(s.trigPin, HIGH);
  delayMicroseconds(10);
  digitalWrite(s.trigPin, LOW);
}

// ---------------------------------------------------------------- BLE
class ServerCb : public BLEServerCallbacks {
  void onConnect(BLEServer*) override { connected = true; }
  void onDisconnect(BLEServer*) override {
    connected = false;
    cmdValid = false;                      // loop() brakes within one tick
    cmdL = cmdR = 0;
    BLEDevice::startAdvertising();
  }
};

// Accepts "L,R" with L and R integers; out-of-range values are clamped, anything else is ignored.
bool parseSpeeds(const char* s, int& l, int& r) {
  char* end;
  long a = strtol(s, &end, 10);
  if (end == s || *end != ',') return false;
  const char* second = end + 1;
  long b = strtol(second, &end, 10);
  if (end == second || *end != '\0') return false;
  l = constrain(a, -255, 255);
  r = constrain(b, -255, 255);
  return true;
}

void handleLine(const char* line) {
  int l, r;
  if (strcmp(line, "STOP") == 0) {
    cmdL = cmdR = 0;
    cmdValid = false;
  } else if (strcmp(line, "PING") == 0) {
    pongPending = true;
  } else if (parseSpeeds(line, l, r)) {
    cmdL = l; cmdR = r;
    lastCmdMs = millis();
    cmdValid = true;
  }
}

class RxCb : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    static char buf[24];
    static size_t len = 0;
    static bool overflow = false;
    String v = c->getValue();
    for (size_t i = 0; i < v.length(); i++) {
      char ch = v[i];
      if (ch == '\n' || ch == '\r') {
        if (!overflow && len > 0) { buf[len] = '\0'; handleLine(buf); }
        len = 0; overflow = false;
      } else if (len < sizeof(buf) - 1) {
        buf[len++] = ch;
      } else {
        overflow = true;
      }
    }
  }
};

void setupBle() {
  BLEDevice::init("Navigator");
  BLEDevice::setMTU(185);                  // status line is ~35 bytes; default MTU only carries 20
  server = BLEDevice::createServer();
  if (!server) fatal("BLE server");
  server->setCallbacks(new ServerCb());
  BLEService* svc = server->createService(SERVICE_UUID);
  if (!svc) fatal("BLE service");
  BLECharacteristic* rx = svc->createCharacteristic(
      RX_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rx->setCallbacks(new RxCb());
  txChar = svc->createCharacteristic(TX_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  txChar->addDescriptor(new BLE2902());
  svc->start();
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();
}

void notifyText(const char* s) {
  txChar->setValue((uint8_t*)s, strlen(s));
  txChar->notify();
}

// ---------------------------------------------------------------- setup / loop
void setup() {
  Serial.begin(115200);
  pinMode(PIN_LED, OUTPUT);
  pinMode(PIN_STBY, OUTPUT);
  digitalWrite(PIN_STBY, LOW);             // motors disabled until BLE is up
  const int dirPins[] = {PIN_AIN1, PIN_AIN2, PIN_BIN1, PIN_BIN2};
  for (int p : dirPins) { pinMode(p, OUTPUT); digitalWrite(p, HIGH); }  // brake
  if (!ledcAttach(PIN_PWMA, PWM_FREQ_HZ, PWM_BITS) || !ledcAttach(PIN_PWMB, PWM_FREQ_HZ, PWM_BITS))
    fatal("LEDC attach");
  ledcWrite(PIN_PWMA, 0);
  ledcWrite(PIN_PWMB, 0);

  for (Sonar& s : sonars) {
    pinMode(s.trigPin, OUTPUT);
    digitalWrite(s.trigPin, LOW);
    pinMode(s.echoPin, INPUT);
  }
  attachInterrupt(digitalPinToInterrupt(PIN_FRONT_ECHO), frontEdge, CHANGE);
  attachInterrupt(digitalPinToInterrupt(PIN_REAR_ECHO), rearEdge, CHANGE);

  setupBle();
  digitalWrite(PIN_STBY, HIGH);            // only after BLE init succeeded
  Serial.println("advertising as Navigator");
}

void loop() {
  static unsigned long nextTick = 0, lastStatus = 0, lastDebug = 0;
  unsigned long now = millis();
  if ((long)(now - nextTick) < 0) { delay(1); return; }
  nextTick = now + LOOP_MS;

  sonarTick(now);
  int front = sonars[0].cm, rear = sonars[1].cm;
  bool frontBlocked = front < FRONT_STOP_CM;
  bool rearBlocked  = rear < REAR_STOP_CM;

  bool fresh = cmdValid && connected && (now - lastCmdMs) < WATCHDOG_MS;

  if (!fresh) {
    // Watchdog / STOP / disconnect: brake and zero immediately, no ramp.
    appliedL = appliedR = 0;
    applyMotors(0, 0);
  } else {
    int l = cmdL, r = cmdR;
    int linear = (l + r) / 2, angular = (r - l) / 2;
    int safeLinear = linear;
    if (frontBlocked) safeLinear = min(safeLinear, 0);
    if (rearBlocked)  safeLinear = max(safeLinear, 0);
    bool clamped = safeLinear != linear;
    int tl = constrain(safeLinear - angular, -255, 255);
    int tr = constrain(safeLinear + angular, -255, 255);
    if (clamped) { appliedL = tl; appliedR = tr; }   // obstacle stops are immediate, not ramped
    else { appliedL = slew(appliedL, tl); appliedR = slew(appliedR, tr); }
    applyMotors(appliedL, appliedR);
  }

  // LED: solid when commands are fresh, slow blink when connected and idle, fast blink when advertising
  if (fresh)          digitalWrite(PIN_LED, HIGH);
  else if (connected) digitalWrite(PIN_LED, (now / 500) % 2);
  else                digitalWrite(PIN_LED, (now / 150) % 2);

  if (connected && pongPending) { pongPending = false; notifyText("PONG\n"); }

  if (connected && now - lastStatus >= STATUS_MS) {
    lastStatus = now;
    int flags = (fresh ? 0 : FLAG_WATCHDOG) | (frontBlocked ? FLAG_FRONT : 0) |
                (rearBlocked ? FLAG_REAR : 0) | FLAG_CONNECTED;
    char buf[64];
    snprintf(buf, sizeof(buf), "T,%lu,%d,%d,%d,%d,%d\n", now, appliedL, appliedR, front, rear, flags);
    notifyText(buf);
  }

  if (now - lastDebug >= DEBUG_MS) {
    lastDebug = now;
    Serial.printf("conn=%d fresh=%d cmd=%d,%d applied=%d,%d front=%d rear=%d\n", (int)connected, (int)fresh,
                  (int)cmdL, (int)cmdR, appliedL, appliedR, front, rear);
  }
}
