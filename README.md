# Koda - The Companion Robot

Koda is a small, curious, and playful wheeled robot companion. Built on an ESP32-S3 4WD platform, Koda combines physical movement with high-level intelligence through a BLE-connected companion app and LLM-driven vision.

## 🤖 Identity & Soul
Koda is more than just an AI assistant. Koda is designed with a distinct personality:
- **Curious**: Loves exploring and discovering new things.
- **Warm**: Bonds with users and remembers interactions.
- **Playful**: Expresses joy through spins, wiggles, and physical interaction.
- **Honest**: Simple and direct about its capabilities.

## 🛠 Hardware Platform
- **Base**: 4WD wheeled robot chassis.
- **Brain**: ESP32-S3 Microcontroller (BLE 5.0).
- **Drive**: TB6612FNG Dual H-Bridge motor driver.
- **Connection**: Low-latency BLE connection to the Koda Phone App.
- **Vision**: Utilizes the mounted phone's camera for real-time environment analysis.

## 📱 Software Stack
- **Companion App**: Built with Flutter (located in `koda_app/`).
- **Firmware**: Arduino/C++ code for ESP32-S3 (located in `koda_firmware/`).
- **Intelligence**: LLM-integrated vision system for navigation, object recognition, and personality-driven responses.

## 🚀 Key Features
- **Dynamic Movement**: Smooth turn and move commands with automatic stopping.
- **Embodied Vision**: Front/Rear camera switching with spatial awareness.
- **Expressive Emotions**: Physical wiggles and spins based on internal "feelings".
- **Context-Aware Skills**: A flexible skill system for complex tasks.

## 🛠 Setup
1. **Firmware**: Flash the files in `koda_firmware/` to your ESP32-S3.
2. **App**: Run `flutter pub get` and `flutter run` in the `koda_app/` directory.
3. **Connect**: Power on the robot and pair via the app's BLE interface.

---
*Created with ❤️ for robot companions.*
