#pragma once
#include <Arduino.h>

// ─────────────────────────────────────────────────────────────────────────────
// Single TB6612FNG channel (one wheel)
// ─────────────────────────────────────────────────────────────────────────────
struct WheelChannel {
    uint8_t in1;
    uint8_t in2;
    uint8_t pwm;
    uint8_t ledcCh;   // LEDC PWM channel (0–7)
};

// ─────────────────────────────────────────────────────────────────────────────
// MotorDriver — 4 independent wheels via 2× TB6612FNG
//
// Chip 1 (Left):  PWMA/AIN1/AIN2 → FL  |  PWMB/BIN1/BIN2 → RL
// Chip 2 (Right): PWMA/AIN1/AIN2 → FR  |  PWMB/BIN1/BIN2 → RR
// ─────────────────────────────────────────────────────────────────────────────
class MotorDriver {
public:
    struct Trim {
        int fl = 100;
        int fr = 97;
        int rl = 102;
        int rr = 99;
    };

    volatile bool motorsActive  = false;
    volatile bool isTurning      = false;  // true during CW/CCW turns
    volatile bool isMovingBack   = false;  // true during backward movement

    MotorDriver(
        uint8_t fl_in1, uint8_t fl_in2, uint8_t fl_pwm,
        uint8_t rl_in1, uint8_t rl_in2, uint8_t rl_pwm,
        uint8_t l_stby,
        uint8_t fr_in1, uint8_t fr_in2, uint8_t fr_pwm,
        uint8_t rr_in1, uint8_t rr_in2, uint8_t rr_pwm,
        uint8_t r_stby
    ) :
        _fl{fl_in1, fl_in2, fl_pwm, 0},
        _rl{rl_in1, rl_in2, rl_pwm, 1},
        _fr{fr_in1, fr_in2, fr_pwm, 2},
        _rr{rr_in1, rr_in2, rr_pwm, 3},
        _l_stby(l_stby), _r_stby(r_stby)
    {}

    void begin() {
        pinMode(_l_stby, OUTPUT); digitalWrite(_l_stby, HIGH);
        pinMode(_r_stby, OUTPUT); digitalWrite(_r_stby, HIGH);

        WheelChannel* wheels[] = { &_fl, &_rl, &_fr, &_rr };
        for (auto* w : wheels) {
            ledcAttach(w->pwm, 5000, 8);
            pinMode(w->in1, OUTPUT);
            pinMode(w->in2, OUTPUT);
        }
        brake();
        Serial.println("[MOTOR] Driver initialized. 4 wheels ready.");
    }

    void setTrim(int fl, int fr, int rl, int rr) {
        _trim.fl = constrain(fl, 80, 120);
        _trim.fr = constrain(fr, 80, 120);
        _trim.rl = constrain(rl, 80, 120);
        _trim.rr = constrain(rr, 80, 120);
        Serial.printf("[MOTOR] Trim: FL=%d FR=%d RL=%d RR=%d\n",
                      _trim.fl, _trim.fr, _trim.rl, _trim.rr);
    }

    void forward(int speed) {
        motorsActive = true;
        isTurning    = false;
        isMovingBack = false;
        _setWheel(_fl,  speed, _trim.fl);
        _setWheel(_fr,  speed, _trim.fr);
        _setWheel(_rl,  speed, _trim.rl);
        _setWheel(_rr,  speed, _trim.rr);
    }

    void backward(int speed) {
        motorsActive = true;
        isTurning    = false;
        isMovingBack = true;
        _setWheel(_fl, -speed, _trim.fl);
        _setWheel(_fr, -speed, _trim.fr);
        _setWheel(_rl, -speed, _trim.rl);
        _setWheel(_rr, -speed, _trim.rr);
    }

    void turnCW(int speed) {   // left fwd, right back
        motorsActive = true;
        isTurning    = true;
        isMovingBack = false;
        _setWheel(_fl,  speed, _trim.fl);
        _setWheel(_rl,  speed, _trim.rl);
        _setWheel(_fr, -speed, _trim.fr);
        _setWheel(_rr, -speed, _trim.rr);
    }

    void turnCCW(int speed) {  // right fwd, left back
        motorsActive = true;
        isTurning    = true;
        isMovingBack = false;
        _setWheel(_fl, -speed, _trim.fl);
        _setWheel(_rl, -speed, _trim.rl);
        _setWheel(_fr,  speed, _trim.fr);
        _setWheel(_rr,  speed, _trim.rr);
    }

    void coast() {
        motorsActive = false;
        isTurning    = false;
        isMovingBack = false;
        _setWheel(_fl, 0, 100); _setWheel(_fr, 0, 100);
        _setWheel(_rl, 0, 100); _setWheel(_rr, 0, 100);
    }

    void brake() {
        motorsActive = false;
        isTurning    = false;
        isMovingBack = false;
        WheelChannel* wheels[] = { &_fl, &_rl, &_fr, &_rr };
        for (auto* w : wheels) {
            digitalWrite(w->in1, HIGH);
            digitalWrite(w->in2, HIGH);
            ledcWrite(w->pwm, 255);
        }
    }

    void wakeup()   { digitalWrite(_l_stby, HIGH); digitalWrite(_r_stby, HIGH); }
    void standby()  { digitalWrite(_l_stby, LOW);  digitalWrite(_r_stby, LOW);  }

    void express(const char* emotion) {
        Serial.printf("[MOTOR] Express: %s\n", emotion);
        if (strcmp(emotion, "happy") == 0) {
            turnCW(50); delay(300); brake(); delay(100); turnCCW(50); delay(300); brake();
        } else if (strcmp(emotion, "excited") == 0) {
            turnCW(60); delay(200); turnCCW(60); delay(200); brake();
        } else if (strcmp(emotion, "curious") == 0) {
            turnCW(35); delay(400); brake(); delay(100); turnCCW(35); delay(200); brake();
        } else if (strcmp(emotion, "sad") == 0) {
            backward(25); delay(400); brake();
        }
    }

private:
    WheelChannel _fl, _rl, _fr, _rr;
    uint8_t _l_stby, _r_stby;
    Trim _trim;

    // speed: -100 to +100, trim: 80–120
    void _setWheel(WheelChannel& w, int speed, int trim) {
        int corrected = constrain((speed * trim) / 100, -100, 100);
        int pwm = abs(corrected) * 255 / 100;
        if (corrected > 0) {
            digitalWrite(w.in1, HIGH); digitalWrite(w.in2, LOW);
        } else if (corrected < 0) {
            digitalWrite(w.in1, LOW);  digitalWrite(w.in2, HIGH);
        } else {
            digitalWrite(w.in1, HIGH); digitalWrite(w.in2, HIGH);
            pwm = 255;
        }
        ledcWrite(w.pwm, pwm);
    }
};
