# KODA App — React Prototype

Companion robot control app for **Koda** (4WD · ESP32-S3 · TB6612FNG · Samsung S21 FE).

---

## Folder Structure

```
koda_app/
├── src/
│   ├── KodaApp.jsx              ← Main app (all screens)
│   ├── theme/
│   │   └── theme.js             ← Colors, fonts, global CSS
│   ├── services/
│   │   ├── bleService.js        ← BLE UUIDs, command builders
│   │   ├── llmService.js        ← Claude API, prompt builders
│   │   └── motorConfig.js       ← Speed presets, trim, calibration
│   └── assets/
│       └── docs/
│           ├── soul.md          ← Koda's identity (edit in app)
│           └── user.md          ← User context (edit in app)
└── README.md
```

---

## Screens

| Screen | Description |
|--------|-------------|
| Home | Status dashboard, mode selection |
| 1. Brain Mode | LLM-autonomous, activity log |
| 2A. Joystick Remote | D-pad, speed slider, motor trim |
| 2B. Paired Remote | WiFi camera feed + remote joystick |
| 3. Settings | LLM, Voice, Motor, Memory, Connect, Docs, System |

---

## BLE Command Schema

```json
{
  "cmds": [
    {"cmd": "forward", "speed": 60, "ms": 800},
    {"cmd": "turn_cw", "speed": 45, "ms": 500},
    {"cmd": "stop"}
  ],
  "speech": "what Koda says via TTS",
  "context": "one sentence for memory log"
}
```

### Commands
| Command | Description |
|---------|-------------|
| `forward` | All 4 motors forward |
| `backward` | All 4 motors backward |
| `turn_cw` | Left fwd, right back (clockwise) |
| `turn_ccw` | Left back, right fwd (counter-clockwise) |
| `stop` | Brake all motors |
| `express` | Emotion movement pattern |

### Speed
- **0-100%** in the app UI
- Converted to **0-255 PWM** on ESP32: `pwm = (speed / 100.0) * 255`

---

## Motor Trim
Per-motor compensation (80-120%, default 100):
- FL Front Left  
- FR Front Right  
- RL Rear Left  
- RR Rear Right

---

## BLE GATT UUIDs

```
Service:          12345678-1234-1234-1234-123456789012
CMD Write:        12345678-1234-1234-1234-123456789013
Status Notify:    12345678-1234-1234-1234-123456789014
```

---

## Identity Documents

| File | Owner | Purpose |
|------|-------|---------|
| soul.md | You | Koda's personality, values, boundaries |
| user.md | You | Your name, preferences, context |
| skills.md | Koda (auto) | Learned capabilities |
| memory.md | Koda (auto) | Episodic memory |
| tools.md | Koda (auto) | Available hardware/tools |

Edit soul.md and user.md via Settings -> Docs in the app.

---

## Hardware

- Chassis: 4WD platform, rubber wheels
- MCU: ESP32-S3
- Motor driver: TB6612FNG x2
- Phone: Samsung S21 FE (Android 13+)
- Connection: BLE phone to ESP32, WiFi phone to phone for paired mode
- Power: 7.4V LiPo for motors, 3.3V from ESP32 for logic
