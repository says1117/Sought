// Navigator ESP32 BLE link test (no motors needed yet)
// Phone sends "L,R\n" with L and R in -255..255. Phone must resend every ~100 ms.
// If nothing arrives for 300 ms, the watchdog zeroes the motors.
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define SERVICE_UUID "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define RX_UUID      "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  // phone -> ESP32 (write)
#define TX_UUID      "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // ESP32 -> phone (notify)

const int LED = 2;
const unsigned long WATCHDOG_MS = 300;

BLEServer* server = nullptr;
BLECharacteristic* txChar = nullptr;
bool connected = false;
volatile int leftCmd = 0, rightCmd = 0;
volatile unsigned long lastCmdMs = 0;
bool stopped = true;

void setMotors(int l, int r) {
  // Motor code goes here once the TB6612 arrives.
  Serial.printf("MOTORS L=%d R=%d\n", l, r);
}

class ServerCb : public BLEServerCallbacks {
  void onConnect(BLEServer*) override { connected = true; Serial.println("phone connected"); }
  void onDisconnect(BLEServer*) override {
    connected = false;
    leftCmd = rightCmd = 0;
    Serial.println("phone disconnected, restarting advertising");
    BLEDevice::startAdvertising();
  }
};

class RxCb : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String s = String(c->getValue().c_str());
    int comma = s.indexOf(',');
    if (comma < 0) return;
    leftCmd  = constrain(s.substring(0, comma).toInt(), -255, 255);
    rightCmd = constrain(s.substring(comma + 1).toInt(), -255, 255);
    lastCmdMs = millis();
  }
};

void setup() {
  Serial.begin(115200);
  pinMode(LED, OUTPUT);
  BLEDevice::init("Navigator");
  server = BLEDevice::createServer();
  server->setCallbacks(new ServerCb());
  BLEService* svc = server->createService(SERVICE_UUID);
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
  Serial.println("advertising as Navigator");
}

void loop() {
  unsigned long now = millis();
  bool fresh = (now - lastCmdMs) < WATCHDOG_MS;

  if (fresh) {
    setMotors(leftCmd, rightCmd);
    stopped = false;
  } else if (!stopped) {
    setMotors(0, 0);          // watchdog fired
    stopped = true;
    Serial.println("WATCHDOG STOP");
  }

  // LED: solid when receiving commands, slow blink when connected, fast blink when waiting
  if (fresh)            digitalWrite(LED, HIGH);
  else if (connected)   digitalWrite(LED, (now / 500) % 2);
  else                  digitalWrite(LED, (now / 150) % 2);

  // status notify once a second
  static unsigned long lastTx = 0;
  if (connected && now - lastTx > 1000) {
    lastTx = now;
    char buf[40];
    snprintf(buf, sizeof(buf), "up=%lus L=%d R=%d", now / 1000, (int)leftCmd, (int)rightCmd);
    txChar->setValue((uint8_t*)buf, strlen(buf));
    txChar->notify();
  }
  delay(10);
}
