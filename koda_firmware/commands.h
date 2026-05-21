#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>
#include "motor.h"

// ─────────────────────────────────────────────────────────────────────────────
// CommandExecutor — parses BLE JSON payloads and drives the MotorDriver
//
// Supported payloads:
//   Single:  {"cmd":"forward","speed":60,"ms":800}
//   Batch:   {"cmds":[{"cmd":"turn_cw","speed":40,"ms":600},{"cmd":"stop"}]}
//   Ping:    {"cmd":"ping"}
//   Trim:    {"cmd":"trim","fl":100,"fr":97,"rl":102,"rr":99}
//   Express: {"cmd":"express","emotion":"happy"}
//
// Note: turn commands accepted as both snake_case (LLM) and camelCase (joystick)
//   "turn_cw" == "turnCw"   |   "turn_ccw" == "turnCcw"
// ─────────────────────────────────────────────────────────────────────────────
class CommandExecutor {
public:
    // Safety threshold in mm — brake immediately if obstacle closer than this
    static const uint16_t COLLISION_GUARD_MM = 250;

    // LiDAR angular offset (degrees) — raw angle of robot's forward direction.
    // Must match AppSettings.lidarAngularOffset in the Flutter app (default 105°).
    static const int LIDAR_FORWARD_OFFSET_DEG = 105;

    // scanDist pointer is set by main.ino so we can read live LiDAR data
    uint16_t* scanDist = nullptr;

    explicit CommandExecutor(MotorDriver& motor) : _motor(motor) {}

    String execute(const String& payload) {
        JsonDocument doc;
        DeserializationError err = deserializeJson(doc, payload);
        if (err) {
            Serial.printf("[CMD] JSON error: %s\n", err.c_str());
            return "{\"status\":\"error\",\"msg\":\"bad json\"}";
        }

        // Batch
        if (doc["cmds"].is<JsonArray>()) {
            for (JsonObject obj : doc["cmds"].as<JsonArray>()) {
                String r = _runSingle(obj);
                if (r.indexOf("error") != -1) return r;
                delay(10);
            }
            return "{\"status\":\"ok\"}";
        }

        // Single
        return _runSingle(doc.as<JsonObject>());
    }

    void resetWatchdog()                                { _lastCmdMs = millis(); }
    bool watchdogExpired(unsigned long timeout_ms) const {
        return (millis() - _lastCmdMs) > timeout_ms;
    }

private:
    MotorDriver& _motor;
    unsigned long _lastCmdMs = 0;

    String _runSingle(JsonObject obj) {
        const char* cmd   = obj["cmd"]   | "stop";
        int         speed = constrain((int)(obj["speed"] | 60), 0, 100);
        int         ms    = obj["ms"]    | 0;

        if      (strcmp(cmd, "forward")  == 0)                               { _motor.wakeup(); _motor.forward(speed);  }
        else if (strcmp(cmd, "backward") == 0)                               { _motor.wakeup(); _motor.backward(speed); }
        else if (strcmp(cmd, "turn_cw")  == 0 || strcmp(cmd, "turnCw")  == 0){ _motor.wakeup(); _motor.turnCW(speed);   }
        else if (strcmp(cmd, "turn_ccw") == 0 || strcmp(cmd, "turnCcw") == 0){ _motor.wakeup(); _motor.turnCCW(speed);  }
        else if (strcmp(cmd, "stop")     == 0)                               { _motor.brake();                          }
        else if (strcmp(cmd, "express")  == 0) {
            _motor.wakeup();
            _motor.express(obj["emotion"] | "idle");
            return "{\"status\":\"ok\"}";
        }
        else if (strcmp(cmd, "trim")     == 0) {
            _motor.setTrim(obj["fl"]|100, obj["fr"]|97, obj["rl"]|102, obj["rr"]|99);
            return "{\"status\":\"ok\",\"msg\":\"trim updated\"}";
        }
        else if (strcmp(cmd, "ping")     == 0) {
            return "{\"status\":\"ok\",\"msg\":\"pong\"}";
        }
        else {
            Serial.printf("[CMD] Unknown: %s\n", cmd);
            return String("{\"status\":\"error\",\"msg\":\"unknown: ") + cmd + "\"}";
        }

        // Timed command — auto-brake after ms, but poll LiDAR for collisions
        if (ms > 0 && strcmp(cmd, "stop") != 0) {
            const bool movingForward  = (strcmp(cmd, "forward") == 0);
            const unsigned long deadline = millis() + ms;

            while (millis() < deadline) {
                delay(20);

                // Only guard FORWARD movement.
                // BACKWARD is a blindspot (phone holder blocks that LiDAR sector).
                if (scanDist != nullptr && movingForward) {
                    uint16_t minDist = 65535;
                    // Check a ±25° arc dead ahead, offset by LIDAR_FORWARD_OFFSET_DEG
                    // so that the guard checks the actual forward direction of the robot.
                    for (int a = -25; a <= 25; a++) {
                        int idx = (LIDAR_FORWARD_OFFSET_DEG + a + 360) % 360;
                        if (scanDist[idx] > 0 && scanDist[idx] < minDist) {
                            minDist = scanDist[idx];
                        }
                    }

                    if (minDist < COLLISION_GUARD_MM) {
                        _motor.brake();
                        Serial.printf("[GUARD] Collision! %dmm ahead. Braking early.\n", minDist);
                        return "{\"status\":\"collision\",\"dist_mm\":" + String(minDist) + "}";
                    }
                }
            }
            _motor.brake();
        }
        return "{\"status\":\"ok\"}";
    }
};
