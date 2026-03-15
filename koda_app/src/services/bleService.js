// ─────────────────────────────────────────
// KODA APP — BLE Service
// Handles BLE scan, connect, command sending
// ─────────────────────────────────────────

// GATT UUIDs — must match ESP32 firmware
export const BLE_UUIDS = {
  SERVICE:     "12345678-1234-1234-1234-123456789012",
  CMD_WRITE:   "12345678-1234-1234-1234-123456789013",  // Write commands to ESP32
  STATUS_NOTIFY: "12345678-1234-1234-1234-123456789014", // Receive status from ESP32
};

// Command builder helpers
export const buildCommand = (cmd, speed = 50, ms = 500, emotion = null) => {
  const obj = { cmd, speed, ms };
  if (emotion) obj.emotion = emotion;
  return JSON.stringify(obj);
};

export const buildCommandChain = (cmds, speech = "", context = "") => {
  return JSON.stringify({ cmds, speech, context });
};

// Predefined command presets
export const COMMANDS = {
  stop:       () => buildCommand("stop"),
  forward:    (speed, ms) => buildCommand("forward", speed, ms),
  backward:   (speed, ms) => buildCommand("backward", speed, ms),
  turnCW:     (speed, ms) => buildCommand("turn_cw", speed, ms),
  turnCCW:    (speed, ms) => buildCommand("turn_ccw", speed, ms),
  express:    (emotion)   => buildCommand("express", 0, 0, emotion),
};

// Watchdog timeout — ESP32 stops motors if no heartbeat within this ms
export const BLE_WATCHDOG_MS = 3000;

// Heartbeat interval
export const BLE_HEARTBEAT_MS = 1000;

/*
  NOTE: This module contains logic and constants.
  Actual BLE calls (flutter_blue_plus) are implemented
  in the Flutter layer: lib/services/ble_service.dart
  
  For the React prototype, BLE is simulated via state.
*/
