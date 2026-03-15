// ─────────────────────────────────────────
// KODA APP — Motor Config
// Speed, trim, and command constants
// ─────────────────────────────────────────

// Speed presets (percent 0-100)
export const SPEED_PRESETS = {
  SLOW:   35,
  NORMAL: 60,
  FAST:   85,
};

// Default motor trim (100 = no compensation)
// Adjust per physical robot after calibration
export const DEFAULT_TRIM = {
  FL: 100,   // Front Left
  FR: 97,    // Front Right — slightly faster motor
  RL: 102,   // Rear Left   — slightly slower motor
  RR: 99,    // Rear Right
};

// Trim bounds
export const TRIM_MIN = 80;
export const TRIM_MAX = 120;

// Convert speed percent to ESP32 PWM (0-255)
export const percentToPWM = (percent) => Math.round((percent / 100) * 255);

// Calibrated turn durations at SPEED_PRESETS.NORMAL (60%)
// Tune on your actual floor after assembly
export const TURN_CALIBRATION = {
  QUARTER:  500,   // ~90 degrees
  HALF:     1000,  // ~180 degrees
  FULL:     2000,  // ~360 degrees
};

// Valid commands
export const VALID_COMMANDS = [
  "forward",
  "backward",
  "turn_cw",
  "turn_ccw",
  "stop",
  "express",
];

// Emotion expressions
export const EMOTIONS = {
  happy:    { cmd: "turn_cw",  speed: 50, ms: 600 },   // quick spin
  curious:  { cmd: "forward",  speed: 30, ms: 400 },   // slow approach
  sad:      { cmd: "backward", speed: 25, ms: 500 },   // slow retreat
  excited:  { cmd: "turn_cw",  speed: 70, ms: 1200 },  // fast spin
  idle:     { cmd: "stop",     speed: 0,  ms: 0 },
};
