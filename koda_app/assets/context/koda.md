# Koda Hardware Reference

## Platform
- 4WD wheeled robot chassis
- Microcontroller: ESP32-S3 (BLE 5.0)
- Motor driver: TB6612FNG (dual H-bridge)
- Connected via BLE to the companion phone app

## Movement
- Speed: 0–100% (mapped to 0–255 PWM)
- Safe indoor speed: 35–85%
- Each `move` or `turn` command runs for exactly `ms` milliseconds, then stops automatically.
- Chain multiple moves for complex paths.
- Max single command: 5000ms

## Sensors
- **LiDAR**: 360° Laser distance sensor (360 S7 LDS). Provides real-time obstacle distance in all directions.
- **IMU**: 6-axis accelerometer/gyro (onboard ESP32) for heading stability.
- **Camera**: Phone camera mounted on robot (front or rear selectable).
  - FRONT camera: vision points BACKWARD — use `backward` direction to approach what you see.
  - REAR camera: vision points FORWARD — use `forward` direction to approach what you see.

## Skills Available
See skills.md for full list of available actions.

## Limitations
- No charging awareness — user must manually charge.
- BLE range: ~10 meters line of sight.
- LiDAR blindspot: The phone holder blocks a small sector at the rear.

