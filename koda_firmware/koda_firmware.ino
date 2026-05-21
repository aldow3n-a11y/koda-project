/**
 * KODA ESP32-S3 Firmware - FINAL v3 (FreeRTOS Multithreaded)
 * ─────────────────────────────────────────────────────────────────────────────
 * Confirmed 360 S7 LDS packet layout (34 bytes):
 *   [0-1]   55 AA       sync
 *   [2-3]   03 08       type + 8 samples
 *   [4-5]   motor speed (fixed ~19881 at nominal RPM, ignore)
 *   [6-7]   angle       Mini-360 format: (raw & 0x7FFF) - 0x2000, units=0.01 deg
 *           sweeps ~4.55 deg per packet = full 360 every ~79 packets
 *   [8-31]  8x samples  dist_L dist_H intensity
 *   [32-33] checksum
 *
 * Distance: raw uint16 little endian, mm direct
 * Angle:    bytes 6-7, Mini-360 formula
 */

#include <NimBLEDevice.h>
#include <ArduinoJson.h>
#include "motor.h"
#include "commands.h"

// ─── PINS ────────────────────────────────────────────────────────────────────
#define FL_IN1  35
#define FL_IN2  36
#define FL_PWM  37
#define RL_IN1  38
#define RL_IN2  39
#define RL_PWM  40
#define L_STBY  41
#define FR_IN1  4
#define FR_IN2  5
#define FR_PWM  6
#define R_STBY  7
#define RR_IN1  15
#define RR_IN2  16
#define RR_PWM  17

#define LIDAR_RX_PIN  8
#define LIDAR_TX_PIN  -1
#define LED_PIN       48

// ─── BLE ─────────────────────────────────────────────────────────────────────
#define SERVICE_UUID    "12345678-1234-1234-1234-123456789012"
#define CMD_CHAR_UUID   "12345678-1234-1234-1234-123456789013"
#define STAT_CHAR_UUID  "12345678-1234-1234-1234-123456789014"
#define LIDAR_CHAR_UUID "12345678-1234-1234-1234-123456789015"
#define BODY_CHAR_UUID  "12345678-1234-1234-1234-123456789016"
#define DEVICE_NAME     "KODA"

// ─── CONSTANTS ───────────────────────────────────────────────────────────────
#define WATCHDOG_TIMEOUT  5000
#define BLINK_INTERVAL    800
#define LDS_PKT_SIZE      34
#define LDS_SAMPLES       8
#define LIDAR_DIST_MIN    130  // Mask out the phone holder (< 13cm)
#define LIDAR_DIST_MAX    6000
#define LIDAR_SWEEP_MS    350

// ─── GLOBALS ─────────────────────────────────────────────────────────────────
MotorDriver motor(
    FL_IN1, FL_IN2, FL_PWM, RL_IN1, RL_IN2, RL_PWM, L_STBY,
    FR_IN1, FR_IN2, FR_PWM, RR_IN1, RR_IN2, RR_PWM, R_STBY
);
CommandExecutor executor(motor);
HardwareSerial  LidarSerial(2);

NimBLEServer*         bleServer  = nullptr;
NimBLECharacteristic* cmdChar    = nullptr;
NimBLECharacteristic* statusChar = nullptr;
NimBLECharacteristic* lidarChar  = nullptr;
NimBLECharacteristic* bodyChar   = nullptr;

volatile bool bleConnected = false;
unsigned long lastBlink    = 0;
volatile bool ledState     = false;

// ─── LIDAR STATE ─────────────────────────────────────────────────────────────
uint8_t  ldsBuf[LDS_PKT_SIZE];
int      ldsBufIdx = 0;
bool     ldsSynced = false;

uint16_t scanDist[360];
uint8_t  scanHits[360];
volatile unsigned long parsedPackets = 0;

// Temporal Stability Buffer
#define STABILITY_FRAMES 5
#define STABILITY_TOLERANCE_MM 100
uint16_t frameBuffer[STABILITY_FRAMES][360];
int currentFrameIdx = 0;

// Angle range tracking for Serial report
uint16_t rawAngleMin = 0xFFFF;
uint16_t rawAngleMax = 0;

// FreeRTOS Synchronization
volatile bool collisionBrakeActive = false;

// Non-blocking Emotion Task Handle & Data
TaskHandle_t emotionTaskHandle = nullptr;
char activeEmotion[16] = {0};

struct __attribute__((__packed__)) KodaBodyPacket {
    uint8_t body_mood;
    uint8_t arousal;
    uint8_t front_cm;
    uint8_t left_cm;
    uint8_t right_cm;
    uint16_t flags;
};

void clearScan() {
    memset(scanDist, 0, sizeof(scanDist));
    memset(scanHits, 0, sizeof(scanHits));
}

// ─── LIDAR PARSER ────────────────────────────────────────────────────────────
void parseLdsPacket(uint8_t* p) {
    // bytes 6-7 = angle, Mini-360 format
    // confirmed from raw dump: increments ~458 counts per packet = 4.58 deg
    uint16_t rawAngle = p[6] | (p[7] << 8);
    uint16_t masked   = rawAngle & 0x7FFF;

    // Track for Serial report
    if (rawAngle < rawAngleMin) rawAngleMin = rawAngle;
    if (rawAngle > rawAngleMax) rawAngleMax = rawAngle;

    // Invalid if below offset
    if (masked < 0x2000) { parsedPackets++; return; }

    float startDeg = fmod((masked - 0x2000) * 0.01f, 360.0f);

    // 8 samples across ~4.58 deg arc
    float arcStep = 4.58f / (float)LDS_SAMPLES;

    for (int i = 0; i < LDS_SAMPLES; i++) {
        uint8_t*  s    = &p[8 + i * 3];
        uint16_t  dist = s[0] | (s[1] << 8);
        if (dist == 0x8000 || dist == 0x0080 ||
            dist == 0 || dist < LIDAR_DIST_MIN || dist > LIDAR_DIST_MAX) continue;

        float anglef = startDeg + arcStep * i;
        if (anglef >= 360.0f) anglef -= 360.0f;
        int slot = (int)anglef;

        // Running average per slot
        if (scanHits[slot] == 0) scanDist[slot] = dist;
        else scanDist[slot] = (scanDist[slot] + dist) / 2;
        if (scanHits[slot] < 255) scanHits[slot]++;
    }
    parsedPackets++;
}

// ─── HELPERS ─────────────────────────────────────────────────────────────────
void setLedColor(uint8_t r, uint8_t g, uint8_t b) {
    rgbLedWrite(LED_PIN, r, g, b);
}
void notifyStatus(const String& json) {
    if (statusChar && bleConnected) {
        statusChar->setValue(json.c_str());
        statusChar->notify();
    }
}

uint16_t getArcMin(uint16_t* dists, int centerAngle, int range) {
    uint16_t minDist = 0xFFFF;
    for (int a = -range; a <= range; a++) {
        int idx = (centerAngle + a + 360) % 360;
        if (dists[idx] > 0 && dists[idx] < minDist) {
            minDist = dists[idx];
        }
    }
    return minDist;
}

uint8_t constr_cm(int val) {
    return (val > 255) ? 255 : (uint8_t)val;
}

// ─── ASYNCHRONOUS EMOTIONS TASK ──────────────────────────────────────────────
void emotionTask(void *param) {
    const char* emotion = (const char*)param;
    Serial.printf("[MOTOR] Executing Async Emotion: %s\n", emotion);
    if (strcmp(emotion, "happy") == 0) {
        motor.turnCW(50); vTaskDelay(pdMS_TO_TICKS(300));
        motor.brake(); vTaskDelay(pdMS_TO_TICKS(100));
        motor.turnCCW(50); vTaskDelay(pdMS_TO_TICKS(300));
        motor.brake();
    } else if (strcmp(emotion, "excited") == 0) {
        motor.turnCW(60); vTaskDelay(pdMS_TO_TICKS(200));
        motor.turnCCW(60); vTaskDelay(pdMS_TO_TICKS(200));
        motor.brake();
    } else if (strcmp(emotion, "curious") == 0) {
        motor.turnCW(35); vTaskDelay(pdMS_TO_TICKS(400));
        motor.brake(); vTaskDelay(pdMS_TO_TICKS(100));
        motor.turnCCW(35); vTaskDelay(pdMS_TO_TICKS(200));
        motor.brake();
    } else if (strcmp(emotion, "sad") == 0) {
        motor.backward(25); vTaskDelay(pdMS_TO_TICKS(400));
        motor.brake();
    }
    emotionTaskHandle = nullptr;
    vTaskDelete(NULL);
}

void startEmotionTask(const char* emotion) {
    stopActiveEmotion();
    strncpy(activeEmotion, emotion, sizeof(activeEmotion) - 1);
    activeEmotion[sizeof(activeEmotion) - 1] = '\0';
    xTaskCreatePinnedToCore(emotionTask, "emotion", 2048, (void*)activeEmotion, 2, &emotionTaskHandle, 1);
}

void stopActiveEmotion() {
    if (emotionTaskHandle != nullptr) {
        vTaskDelete(emotionTaskHandle);
        emotionTaskHandle = nullptr;
        motor.brake();
    }
}

// ─── BLE CALLBACKS ───────────────────────────────────────────────────────────
class ServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* s, NimBLEConnInfo& i) override {
        bleConnected = true;
        setLedColor(0, 120, 120);
        executor.resetWatchdog();
        notifyStatus("{\"status\":\"ok\",\"msg\":\"KODA connected\"}");
        Serial.println("[BLE] Connected");
    }
    void onDisconnect(NimBLEServer* s, NimBLEConnInfo& i, int r) override {
        bleConnected = false;
        motor.brake();
        setLedColor(20, 0, 0);
        NimBLEDevice::startAdvertising();
        Serial.println("[BLE] Disconnected");
    }
};

class CmdCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* pChar, NimBLEConnInfo& i) override {
        String payload = pChar->getValue().c_str();
        Serial.printf("[CMD] %s\n", payload.c_str());
        StaticJsonDocument<128> doc;
        if (deserializeJson(doc, payload) == DeserializationError::Ok) {
            const char* cmd = doc["cmd"] | "";
            if      (strcmp(cmd, "forward")  == 0) setLedColor(0, 255, 0);
            else if (strcmp(cmd, "backward") == 0) setLedColor(255, 255, 0);
            else if (strstr(cmd, "turn"))          setLedColor(0, 0, 255);
            else if (strcmp(cmd, "stop")     == 0) setLedColor(255, 0, 0);
        }
        executor.resetWatchdog();
        notifyStatus(executor.execute(payload));
    }
};

// ─── SETUP ───────────────────────────────────────────────────────────────────
void setup() {
    Serial.begin(115200);
    delay(500);
    clearScan();

    pinMode(21, OUTPUT);
    digitalWrite(21, HIGH);
    setLedColor(50, 0, 50);

    LidarSerial.setRxBufferSize(1024);
    LidarSerial.begin(115200, SERIAL_8N1, LIDAR_RX_PIN, LIDAR_TX_PIN);
    motor.begin();
    executor.scanDist = scanDist; // Give guard loop live access to LiDAR data

    NimBLEDevice::init(DEVICE_NAME);
    NimBLEDevice::setPower(ESP_PWR_LVL_P9);
    bleServer = NimBLEDevice::createServer();
    bleServer->setCallbacks(new ServerCallbacks());

    NimBLEService* svc = bleServer->createService(SERVICE_UUID);
    cmdChar = svc->createCharacteristic(CMD_CHAR_UUID,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
    cmdChar->setCallbacks(new CmdCallbacks());
    statusChar = svc->createCharacteristic(STAT_CHAR_UUID,
        NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
    lidarChar = svc->createCharacteristic(LIDAR_CHAR_UUID,
        NIMBLE_PROPERTY::NOTIFY);
    bodyChar = svc->createCharacteristic(BODY_CHAR_UUID,
        NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
    svc->start();

    NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
    NimBLEDevice::setDeviceName(DEVICE_NAME);
    NimBLEAdvertisementData advData;
    advData.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
    advData.setName(DEVICE_NAME);
    adv->setAdvertisementData(advData);
    NimBLEAdvertisementData scanResp;
    scanResp.setCompleteServices(BLEUUID(SERVICE_UUID));
    scanResp.setName(DEVICE_NAME);
    adv->setScanResponseData(scanResp);
    adv->start();

    Serial.println("═══════════════════════════════════════════");
    Serial.println("[KODA] BLE Advertising STARTED");
    Serial.println("[KODA] Device: " DEVICE_NAME);
    Serial.println("[KODA] UUID:   " SERVICE_UUID);
    Serial.println("[KODA] LiDAR:  GPIO8 RX, UART2, 115200");
    Serial.println("═══════════════════════════════════════════");

    setLedColor(0, 50, 0); delay(200);
    setLedColor(10, 10, 0);
}

// ─── LOOP ────────────────────────────────────────────────────────────────────
void loop() {
    unsigned long now = millis();

    // ── Watchdog ─────────────────────────────────────────────────────────────
    if (bleConnected && executor.watchdogExpired(WATCHDOG_TIMEOUT)) {
        motor.brake();
        setLedColor(40, 0, 0);
        notifyStatus("{\"status\":\"watchdog\",\"msg\":\"timeout\"}");
        executor.resetWatchdog();
    }

    // ── LiDAR Parser ─────────────────────────────────────────────────────────
    while (LidarSerial.available() > 0) {
        uint8_t b = LidarSerial.read();
        if (!ldsSynced) {
            ldsBuf[0] = ldsBuf[1];
            ldsBuf[1] = ldsBuf[2];
            ldsBuf[2] = ldsBuf[3];
            ldsBuf[3] = b;
            if (ldsBuf[0] == 0x55 && ldsBuf[1] == 0xAA &&
                ldsBuf[2] == 0x03 && ldsBuf[3] == 0x08) {
                ldsBufIdx = 4;
                ldsSynced = true;
            }
        } else {
            ldsBuf[ldsBufIdx++] = b;
            if (ldsBufIdx >= LDS_PKT_SIZE) {
                parseLdsPacket(ldsBuf);
                ldsBufIdx = 0;
                ldsSynced = false;
                ldsBuf[0] = ldsBuf[1] = ldsBuf[2] = ldsBuf[3] = 0;
            }
        }
    }

    // ── Safety Collision Guard (50 Hz) ──────────────────────────────────────
    // Only guard FORWARD movement. Turns and backward are evasive maneuvers —
    // braking them mid-execution is the race condition that prevents avoidance.
    static unsigned long lastSafety = 0;
    if (now - lastSafety >= 20) {
        bool isMovingForward = motor.motorsActive && !motor.isTurning && !motor.isMovingBack;
        if (isMovingForward) {
            uint16_t frontMin = getArcMin(scanDist, CommandExecutor::LIDAR_FORWARD_OFFSET_DEG, 25);
            if (frontMin < CommandExecutor::COLLISION_GUARD_MM) {
                motor.brake();
                collisionBrakeActive = true;
                stopActiveEmotion();
                notifyStatus("{\"status\":\"collision\",\"dist_mm\":" + String(frontMin) + "}");
                Serial.printf("[SAFETY] Collision! %dmm ahead. Braked.\n", frontMin);
            }
        }
        lastSafety = now;
    }

    // ── Sweep report every LIDAR_SWEEP_MS ────────────────────────────────────
    static unsigned long lastSweep = 0;
    if (now - lastSweep >= LIDAR_SWEEP_MS) {
        int validCount = 0;
        uint16_t minD = 0xFFFF;
        int minAngle = 0;
        uint16_t tempScan[360];

        memcpy(tempScan, scanDist, sizeof(scanDist));

        for (int i = 0; i < 360; i++) {
            if (tempScan[i] == 0) continue;
            validCount++;
            if (tempScan[i] < minD) { minD = tempScan[i]; minAngle = i; }
        }
        if (minD == 0xFFFF) minD = 0;

        // ── Temporal Stability Filter (The Brain Filter) ──
        for (int i = 0; i < 360; i++) {
            frameBuffer[currentFrameIdx][i] = tempScan[i];
        }
        
        int stableCount = 0;
        for (int i = 0; i < 360; i++) {
            if (tempScan[i] == 0) continue;
            int appearanceCount = 0;
            for (int f = 0; f < STABILITY_FRAMES; f++) {
                uint16_t historicDist = frameBuffer[f][i];
                if (historicDist > 0 && abs((int)historicDist - (int)tempScan[i]) < STABILITY_TOLERANCE_MM) {
                    appearanceCount++;
                }
            }
            if (appearanceCount < 3) {
                tempScan[i] = 0;
            } else {
                stableCount++;
            }
        }
        currentFrameIdx = (currentFrameIdx + 1) % STABILITY_FRAMES;

        Serial.printf("[LIDAR] pkts:%lu pts:%d stable:%d closest:%dmm @%ddeg raw:[%u-%u]=%.0f-%.0fdeg\n",
            parsedPackets, validCount, stableCount, minD, minAngle,
            rawAngleMin, rawAngleMax,
            rawAngleMin == 0xFFFF ? 0 : (((rawAngleMin & 0x7FFF) - 0x2000) * 0.01f),
            rawAngleMax == 0 ? 0 : (((rawAngleMax & 0x7FFF) - 0x2000) * 0.01f));

        // BLE — push raw angle+distance binary pairs
        if (bleConnected && stableCount > 0) {
            uint8_t chunk[180];
            int chunkIdx = 0;
            for (int i = 0; i < 360; i++) {
                if (tempScan[i] == 0) continue;
                chunk[chunkIdx++] = i & 0xFF;
                chunk[chunkIdx++] = (i >> 8) & 0xFF;
                chunk[chunkIdx++] = tempScan[i] & 0xFF;
                chunk[chunkIdx++] = (tempScan[i] >> 8) & 0xFF;
                if (chunkIdx >= 176) {
                    lidarChar->setValue(chunk, chunkIdx);
                    lidarChar->notify();
                    chunkIdx = 0;
                    delay(30); // delay between chunks to prevent MTU drop
                }
            }
            if (chunkIdx > 0) {
                lidarChar->setValue(chunk, chunkIdx);
                lidarChar->notify();
            }
        }

        rawAngleMin = 0xFFFF; rawAngleMax = 0;
        clearScan();
        lastSweep = now;
    }

    // ── Body State stream every 500ms ────────────────────────────────────────
    static unsigned long lastBodyState = 0;
    if (now - lastBodyState >= 500) {
        uint16_t frontMin = getArcMin(scanDist, CommandExecutor::LIDAR_FORWARD_OFFSET_DEG, 25);
        uint16_t leftMin = getArcMin(scanDist, (CommandExecutor::LIDAR_FORWARD_OFFSET_DEG + 90) % 360, 25);
        uint16_t rightMin = getArcMin(scanDist, (CommandExecutor::LIDAR_FORWARD_OFFSET_DEG - 90 + 360) % 360, 25);

        uint8_t front_cm = (frontMin == 0xFFFF) ? 255 : constr_cm(frontMin / 10);
        uint8_t left_cm = (leftMin == 0xFFFF) ? 255 : constr_cm(leftMin / 10);
        uint8_t right_cm = (rightMin == 0xFFFF) ? 255 : constr_cm(rightMin / 10);

        bool isMoving = motor.motorsActive;
        bool isObstacleFront = (front_cm < 25);
        bool isObstacleLeft = (left_cm < 25);
        bool isObstacleRight = (right_cm < 25);

        uint8_t mood = 0;     // Calm
        uint8_t arousal = 15;  // Low/resting arousal

        if (isObstacleFront || isObstacleLeft || isObstacleRight) {
            mood = 2;         // Startled/Agitated
            arousal = 95;     // High arousal due to close obstacle
        } else if (isMoving) {
            mood = 1;         // Active/Moving
            arousal = 60;     // Moderate arousal
        }

        uint16_t flags = 0;
        if (isMoving)        flags |= (1 << 0);
        if (isObstacleFront) flags |= (1 << 1);
        if (isObstacleLeft)  flags |= (1 << 2);
        if (isObstacleRight) flags |= (1 << 3);

        KodaBodyPacket packet;
        packet.body_mood = mood;
        packet.arousal = arousal;
        packet.front_cm = front_cm;
        packet.left_cm = left_cm;
        packet.right_cm = right_cm;
        packet.flags = flags;

        if (bleConnected && bodyChar != nullptr) {
            bodyChar->setValue((uint8_t*)&packet, sizeof(packet));
            bodyChar->notify();
        }
        lastBodyState = now;
    }

    // ── Idle blink ───────────────────────────────────────────────────────────
    static unsigned long lastBlink = 0;
    if (!bleConnected && now - lastBlink >= BLINK_INTERVAL) {
        lastBlink = now;
        ledState = !ledState;
        setLedColor(ledState ? 10 : 0, ledState ? 10 : 0, 0);
    }

    delay(1);
}
