/**
 * KODA ESP32-S3 Firmware
 * ─────────────────────────────────────────────────────────────────────────────
 * BLE GATT server that receives JSON motor commands from the KODA Flutter app
 * and drives a 4WD platform via 2× TB6612FNG motor drivers.
 *
 * Hardware:
 *   Chip 1 (Left):  AO → Front Left  |  BO → Rear Left
 *   Chip 2 (Right): AO → Front Right |  BO → Rear Right
 *
 * Arduino IDE setup:
 *   Board:    ESP32S3 Dev Module  (Tools > Board > esp32)
 *   Libraries (Tools > Manage Libraries):
 *     • NimBLE-Arduino  by h2zero         (search "NimBLE-Arduino")
 *     • ArduinoJson     by Benoit Blanchon (search "ArduinoJson", install v7.x)
 *
 * ─── ADJUST PINS BELOW TO MATCH YOUR WIRING ──────────────────────────────────
 */

#include <NimBLEDevice.h>
#include "motor.h"
#include "commands.h"

// ─────────────────────────────────────────────────────────────────────────────
// PIN CONFIGURATION
// ─────────────────────────────────────────────────────────────────────────────

// Chip 1 — Left side (IO35–41)
#define FL_IN1   35
#define FL_IN2   36
#define FL_PWM   37
#define RL_IN1   38
#define RL_IN2   39
#define RL_PWM   40
#define L_STBY   41

// Chip 2 — Right side (IO4-7, IO15-17)
#define FR_IN1   4
#define FR_IN2   5
#define FR_PWM   6
#define R_STBY   7      // shared STBY for right chip
#define RR_IN1   15
#define RR_IN2   16
#define RR_PWM   17
                        // IO18, IO42 available as spares

// Onboard LED (GPIO 48 on ESP32-S3-DevKitC-1 — change if different)
#define LED_PIN  48

// ─────────────────────────────────────────────────────────────────────────────
// BLE UUIDs — must match koda_app/lib/services/ble_service.dart exactly
// ─────────────────────────────────────────────────────────────────────────────
#define SERVICE_UUID   "12345678-1234-1234-1234-123456789012"
#define CMD_CHAR_UUID  "12345678-1234-1234-1234-123456789013"
#define STAT_CHAR_UUID "12345678-1234-1234-1234-123456789014"

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────
#define DEVICE_NAME      "KODA-ESP32"
#define WATCHDOG_TIMEOUT 5000   // ms — stop motors if no command received
#define BLINK_INTERVAL   800    // ms — LED blink when disconnected

// ─────────────────────────────────────────────────────────────────────────────
// Globals
// ─────────────────────────────────────────────────────────────────────────────
MotorDriver motor(
    FL_IN1, FL_IN2, FL_PWM,
    RL_IN1, RL_IN2, RL_PWM,
    L_STBY,
    FR_IN1, FR_IN2, FR_PWM,
    RR_IN1, RR_IN2, RR_PWM,
    R_STBY
);
CommandExecutor executor(motor);

NimBLEServer*         bleServer   = nullptr;
NimBLECharacteristic* cmdChar     = nullptr;
NimBLECharacteristic* statusChar  = nullptr;

bool bleConnected   = false;
unsigned long lastBlink = 0;
bool ledState = false;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────
void ledOn()  { digitalWrite(LED_PIN, HIGH); }
void ledOff() { digitalWrite(LED_PIN, LOW);  }

void ledPulse(int times = 3, int onMs = 80, int offMs = 80) {
    for (int i = 0; i < times; i++) {
        ledOn();  delay(onMs);
        ledOff(); delay(offMs);
    }
}

void notifyStatus(const String& json) {
    if (statusChar && bleConnected) {
        statusChar->setValue(json.c_str());
        statusChar->notify();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// BLE Callbacks
// ─────────────────────────────────────────────────────────────────────────────
class ServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* server, NimBLEConnInfo& connInfo) override {
        bleConnected = true;
        Serial.printf("[BLE] Client connected. Addr: %s\n",
                      connInfo.getAddress().toString().c_str());
        ledOn();
        executor.resetWatchdog();
        notifyStatus("{\"status\":\"ok\",\"msg\":\"KODA connected\"}");
    }

    void onDisconnect(NimBLEServer* server, NimBLEConnInfo& connInfo, int reason) override {
        bleConnected = false;
        Serial.println("[BLE] Client disconnected — stopping motors.");
        motor.brake();
        NimBLEDevice::startAdvertising();
        ledOff();
    }
};

class CmdCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo) override {
        String payload = pChar->getValue().c_str();
        Serial.printf("[CMD] RX: %s\n", payload.c_str());
        executor.resetWatchdog();
        String result = executor.execute(payload);
        Serial.printf("[CMD] Result: %s\n", result.c_str());
        notifyStatus(result);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Setup
// ─────────────────────────────────────────────────────────────────────────────
void setup() {
    Serial.begin(115200);
    delay(500);
    Serial.println("\n================================");
    Serial.println("  KODA ESP32-S3 Firmware v0.1");
    Serial.println("================================");

    pinMode(LED_PIN, OUTPUT);
    ledOff();

    motor.begin();

    NimBLEDevice::init(DEVICE_NAME);
    NimBLEDevice::setMTU(185);
    NimBLEDevice::setPower(ESP_PWR_LVL_P9);

    bleServer = NimBLEDevice::createServer();
    bleServer->setCallbacks(new ServerCallbacks());

    NimBLEService* service = bleServer->createService(SERVICE_UUID);

    cmdChar = service->createCharacteristic(
        CMD_CHAR_UUID,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
    );
    cmdChar->setCallbacks(new CmdCallbacks());

    statusChar = service->createCharacteristic(
        STAT_CHAR_UUID,
        NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
    );
    statusChar->setValue("{\"status\":\"idle\"}");

    service->start();

    NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
    adv->addServiceUUID(SERVICE_UUID);

    // Build scan response: puts the full device name in the scan-response packet
    // so Android shows the name without needing to connect first.
    NimBLEAdvertisementData scanResponse;
    scanResponse.setName(DEVICE_NAME);
    adv->setScanResponseData(scanResponse);

    // Main advertisement packet: service UUID + short name
    NimBLEAdvertisementData advData;
    advData.setFlags(0x06);                   // LE General Discoverable, no BR/EDR
    advData.setCompleteServices(BLEUUID(SERVICE_UUID));
    advData.setShortName("KODA");             // short name in main packet
    adv->setAdvertisementData(advData);

    NimBLEDevice::startAdvertising();

    Serial.printf("[BLE] Advertising as '%s'\n", DEVICE_NAME);
    ledPulse(3, 100, 100);
    Serial.println("[KODA] Ready. Waiting for connection...");
}

// ─────────────────────────────────────────────────────────────────────────────
// Loop
// ─────────────────────────────────────────────────────────────────────────────
void loop() {
    // Watchdog — stop motors if no command for WATCHDOG_TIMEOUT ms
    if (bleConnected && executor.watchdogExpired(WATCHDOG_TIMEOUT)) {
        Serial.println("[WATCHDOG] Timeout — stopping motors.");
        motor.brake();
        notifyStatus("{\"status\":\"watchdog\",\"msg\":\"timeout\"}");
        executor.resetWatchdog();
    }

    // LED blink when waiting for connection
    if (!bleConnected) {
        unsigned long now = millis();
        if (now - lastBlink >= BLINK_INTERVAL) {
            lastBlink = now;
            ledState = !ledState;
            digitalWrite(LED_PIN, ledState);
        }
    }

    delay(10);
}
