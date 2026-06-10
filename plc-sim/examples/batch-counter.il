// Batch counter: count parts on a sensor, open the gate at 3 (CTU),
// and track remaining capacity with a down counter (CTD).
//
// CTU counts RISING EDGES of its rung: toggle %IX0.0 on, scan, toggle it
// off, scan -- that is one part past the sensor (holding it on does not
// keep counting).  At 3 parts C1's done bit closes and the gate opens.
//
// C2 runs from the same sensor in the other direction: it loads its preset
// (3) on first scan and counts DOWN, done when it hits zero.
//
// %IX0.1 (batch reset) resets both: R clears a CTU to 0 and reloads a CTD
// to its preset.

NETWORK 1   // count parts up:  C1 = 0,1,2,3 -> done at 3
LD   %IX0.0      // part sensor
CTU  C1, 3

NETWORK 2   // remaining capacity counts down:  C2 = 3,2,1,0 -> done at 0
LD   %IX0.0
CTD  C2, 3

NETWORK 3   // gate opens when the batch is complete
LD   C1
ST   %QX0.0      // gate solenoid

NETWORK 4   // batch-complete lamp: both counters agree by construction
LD   C1
AND  C2
ST   %QX0.1      // lamp

NETWORK 5   // reset starts the next batch
LD   %IX0.1      // reset pushbutton
R    C1

NETWORK 6
LD   %IX0.1
R    C2
