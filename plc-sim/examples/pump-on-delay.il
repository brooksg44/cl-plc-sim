// Pump with an on-delay start and a cooling-fan run-on (TON + TOF).
//
// Presets are TIME literals (real milliseconds).  In the GUI's Run mode the
// timers follow the wall clock; paused, each Scan press advances the frozen
// virtual clock by the scan period (default 1 second).
//
//   Run  = (Start OR Run) AND NOT Stop      seal-in latch
//   T1   = TON(Run, T#5s)                   5-second on delay
//   Pump = T1                               pump starts 5s after Run
//   T2   = TOF(Pump, T#8s)                  off delay follows the pump
//   Fan  = T2                               fan holds until 8s past pump stop
//
// Try it: toggle %IX0.0 (Start), then Run (or press Scan five times) until T1
// reads 5s/5s and the pump starts.  Toggle %IX0.1 (Stop) and keep going: the
// pump drops at once but the fan keeps running until T2 counts out.

NETWORK 1   // seal-in latch
LD   %IX0.0      // Start pushbutton
OR   %MX0.0      // seal-in around Start
ANDN %IX0.1      // Stop pushbutton
ST   %MX0.0      // Run (internal relay)

NETWORK 2   // on-delay: T1 done 5 seconds after Run goes true
LD   %MX0.0
TON  T1, T#5s

NETWORK 3   // pump follows the timer's done bit
LD   T1
ST   %QX0.0      // Pump contactor

NETWORK 4   // off-delay: T2 holds after the pump stops, until ET reaches 8s
LD   %QX0.0
TOF  T2, T#8s

NETWORK 5   // cooling fan follows the off-delay
LD   T2
ST   %QX0.1      // Cooling fan
