// Stamp press one-shot: a part edge fires a fixed 2-second stamp pulse (TP).
//
// TP is EDGE-triggered and not retriggerable: the pulse runs exactly its
// preset from the rising edge of the rung -- holding the sensor on does not
// stretch it, and a new pulse cannot fire until the sensor drops first.
//
//   P1    = TP(Sensor, T#2s)     pulse fires on the part's rising edge
//   Press = P1                   stamp solenoid follows the pulse
//   Ready = NOT P1               ready lamp lit while the press is idle
//
// Try it: toggle %IX0.0 (part sensor) on, then Run (or two Scan presses):
// the press fires for 2 seconds and drops even though the sensor is still
// held on -- and it stays off until the sensor goes off and on again for
// the next part.

NETWORK 1   // part sensor fires the one-shot
LD   %IX0.0      // part-present sensor
TP   P1, T#2s

NETWORK 2   // stamp solenoid follows the pulse
LD   P1
ST   %QX0.0      // press solenoid

NETWORK 3   // ready lamp: lit whenever the press is idle
LDN  P1
ST   %QX0.1      // ready lamp
