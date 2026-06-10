// Pump with an on-delay start and a cooling-fan run-on (TON + TOF).
//
// Presets are in SCAN TICKS: each Scan command advances every timer by one
// tick (the simulator has no real-time clock; the scan is the clock).
//
//   Run  = (Start OR Run) AND NOT Stop      seal-in latch
//   T1   = TON(Run, 5)                      5-tick on delay
//   Pump = T1                               pump starts 5 scans after Run
//   T2   = TOF(Pump, 8)                     off delay follows the pump
//   Fan  = T2                               fan holds until 8 ticks past pump stop
//
// Try it: toggle %IX0.0 (Start), then press Scan until T1 reads 5/5 and the
// pump starts.  Toggle %IX0.1 (Stop) and keep scanning: the pump drops at
// once but the fan keeps running until T2 counts out.

NETWORK 1   // seal-in latch
LD   %IX0.0      // Start pushbutton
OR   %MX0.0      // seal-in around Start
ANDN %IX0.1      // Stop pushbutton
ST   %MX0.0      // Run (internal relay)

NETWORK 2   // on-delay: T1 done 5 ticks after Run goes true
LD   %MX0.0
TON  T1, 5

NETWORK 3   // pump follows the timer's done bit
LD   T1
ST   %QX0.0      // Pump contactor

NETWORK 4   // off-delay: T2 holds after the pump stops, until ET reaches 8
LD   %QX0.0
TOF  T2, 8

NETWORK 5   // cooling fan follows the off-delay
LD   T2
ST   %QX0.1      // Cooling fan
