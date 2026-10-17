// Navigator firmware v1: ESP32 + TB6612 + 2x HC-SR04, driven by the phone over BLE.
// Written for ESP32 Arduino core 3.x (ledcAttach, String getValue()). Does NOT build on 2.x.
// Spec: docs/03_CONTRACTS.md section 1 and docs/01_ROBOTICS_PLAN.md section 2.
// Safety (watchdog, sonar stops, disconnect stop) lives here and never depends on the phone.
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "safety.h"   // pure safety/motion logic + tuning constants (host-tested, firmware/test/)

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
// MAX_PWM, PWM_MIN, LEFT/RIGHT_SIGN, LEFT/RIGHT_TRIM now live in safety.h
const int PWM_FREQ_HZ = 20000;
const int PWM_BITS    = 8;

// Timing
// WATCHDOG_MS, LOOP_MS, SLEW_PER_TICK, SONAR_TIMEOUT_US now live in safety.h
const unsigned long SONAR_SLOT_MS = 50;  // alternate front/rear
const unsigned long STATUS_MS   = 200;   // 5 Hz
const unsigned long DEBUG_MS    = 500;   // 2 Hz

// Safety thresholds (FRONT_STOP_CM, REAR_STOP_CM, NO_ECHO_CM) and status FLAG_* now live in safety.h

// ---------------------------------------------------------------- shared state
BLEServer* server = nullptr;
BLECharacteristic* txChar = nullptr;
volatile bool connected = false;
volatile int cmdL = 0, cmdR = 0;           // last command from the phone
volatile unsigned long lastCmdMs = 0;
volatile bool cmdValid = false;            // false at boot, after STOP, after disconnect
volatile bool pongPending = false;
portMUX_TYPE commandMux = portMUX_INITIALIZER_UNLOCKED;
char rxBuffer[24];
size_t rxLength = 0;
bool rxOverflow = false;

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
  nav::SideDrive d = nav::sideDrive(v, sign, trim);   // brake (IN1=IN2=HIGH, PWM 0) when v == 0
  digitalWrite(in1, d.in1High ? HIGH : LOW);
  digitalWrite(in2, d.in2High ? HIGH : LOW);
  ledcWrite(pwmPin, d.pwm);
}

void applyMotors(int l, int r) {
  driveSide(PIN_PWMA, PIN_AIN1, PIN_AIN2, l, LEFT_SIGN, LEFT_TRIM);
  driveSide(PIN_PWMB, PIN_BIN1, PIN_BIN2, r, RIGHT_SIGN, RIGHT_TRIM);
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

void sonarTick(unsigned long now) {
  static unsigned long lastSlot = 0;
  if (now - lastSlot < SONAR_SLOT_MS) return;
  lastSlot = now;

  if (sonarActive >= 0) {                  // collect the previous measurement
    Sonar& p = sonars[sonarActive];
    int cm = nav::echoToCm(p.done, p.widthUs);
    p.hist[0] = p.hist[1]; p.hist[1] = p.hist[2]; p.hist[2] = cm;
    p.cm = nav::median3(p.hist);
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
  void onConnect(BLEServer*) override {
    portENTER_CRITICAL(&commandMux);
    cmdL = cmdR = 0;
    cmdValid = false;
    pongPending = false;
    rxLength = 0; rxOverflow = false;
    connected = true;
    portEXIT_CRITICAL(&commandMux);
  }
  void onDisconnect(BLEServer*) override {
    portENTER_CRITICAL(&commandMux);
    connected = false;
    cmdValid = false;                      // loop() brakes within one tick
    cmdL = cmdR = 0;
    pongPending = false;
    rxLength = 0; rxOverflow = false;
    portEXIT_CRITICAL(&commandMux);
    BLEDevice::startAdvertising();
  }
};

void handleLine(const char* line) {
  int l, r;
  switch (nav::classifyLine(line, l, r)) {
    case nav::LINE_STOP:
      cmdL = cmdR = 0;
      cmdValid = false;
      break;
    case nav::LINE_PING:
      pongPending = true;
      break;
    case nav::LINE_SPEEDS:
      cmdL = l; cmdR = r;
      lastCmdMs = millis();
      cmdValid = true;
      break;
    default:
      break;
  }
}

class RxCb : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String v = c->getValue();
    portENTER_CRITICAL(&commandMux);
    if (!connected) { portEXIT_CRITICAL(&commandMux); return; }
    for (size_t i = 0; i < v.length(); i++) {
      char ch = v[i];
      if (nav::rxFeed(rxBuffer, sizeof(rxBuffer), rxLength, rxOverflow, ch)) handleLine(rxBuffer);
    }
    portEXIT_CRITICAL(&commandMux);
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
  size_t length = strlen(s);
  for (size_t offset = 0; offset < length; offset += 20) {
    size_t count = min((size_t)20, length - offset);
    txChar->setValue((uint8_t*)s + offset, count);
    txChar->notify();
  }
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
  bool frontBlocked = nav::frontBlocked(front);
  bool rearBlocked  = nav::rearBlocked(rear);

  portENTER_CRITICAL(&commandMux);
  unsigned long last = lastCmdMs;
  bool valid = cmdValid, connectedNow = connected;
  int requestedL = cmdL, requestedR = cmdR;
  bool sendPong = pongPending;
  pongPending = false;
  portEXIT_CRITICAL(&commandMux);
  bool fresh = nav::commandFresh(valid, connectedNow, now, last);   // signed age: see safety.h

  // Watchdog/STOP/disconnect brake and zero with no ramp; otherwise clamp, slew, clamp again (safety.h).
  nav::computeApplied(fresh, requestedL, requestedR, frontBlocked, rearBlocked, appliedL, appliedR);
  applyMotors(appliedL, appliedR);

  // LED: solid when commands are fresh, slow blink when connected and idle, fast blink when advertising
  if (fresh)          digitalWrite(PIN_LED, HIGH);
  else if (connectedNow) digitalWrite(PIN_LED, (now / 500) % 2);
  else                digitalWrite(PIN_LED, (now / 150) % 2);

  if (connectedNow && sendPong) { notifyText("PONG\n"); }

  if (connectedNow && now - lastStatus >= STATUS_MS) {
    lastStatus = now;
    int flags = nav::statusFlags(fresh, frontBlocked, rearBlocked);
    char buf[64];
    snprintf(buf, sizeof(buf), "T,%lu,%d,%d,%d,%d,%d\n", now, appliedL, appliedR, front, rear, flags);
    notifyText(buf);
  }

  if (now - lastDebug >= DEBUG_MS) {
    lastDebug = now;
    Serial.printf("conn=%d fresh=%d cmd=%d,%d applied=%d,%d front=%d rear=%d\n", (int)connectedNow, (int)fresh,
                  requestedL, requestedR, appliedL, appliedR, front, rear);
  }
}
