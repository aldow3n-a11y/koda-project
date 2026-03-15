# Koda Hardware Reference

## Platform
- 4WD wheeled robot chassis
- Microcontroller: ESP32-S3 (BLE 5.0)
- Motor driver: TB6612FNG (dual H-bridge)
- Connected via BLE to the companion phone app

## Movement
- Speed: 0–100% (mapped to 0–255 PWM)
- Safe indoor speed: 35–65%
- Each `move` or `turn` command runs for exactly `ms` milliseconds, then stops automatically.
- NEVER use a stop command — the `ms` parameter handles stopping.
- Chain multiple moves for complex paths.
- Max single command: 1500ms

## Camera
- Phone camera mounted on robot (front or rear selectable)
- Images are captured and analyzed by the LLM for navigation and object recognition
- FRONT camera: vision points BACKWARD — use `backward` direction to approach what you see
- REAR camera: vision points FORWARD — use `forward` direction to approach what you see

## Skills Available
See skills.md for full list of available actions.

## Limitations
- No ultrasonic/distance sensor — rely on camera for obstacle detection
- No charging awareness — user must manually charge
- BLE range: ~10 meters line of sight
- No persistent map — must re-explore each session
