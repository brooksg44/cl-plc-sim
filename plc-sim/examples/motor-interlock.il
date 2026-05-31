// Motor seal-in with the fault folded in as a series INTERLOCK.
//
// Compare with motor-seal-in.il, which clears Run with a separate RESET coil
// in a later rung.  There the lamp (Run follower) reads Run one scan before the
// reset clears it, so the lamp lags by one scan.  Here the fault is a
// normally-closed contact in series with the seal-in, so Run already accounts
// for it and every rung that reads Run sees a consistent value in the SAME scan.
//
//   Run  = (Start OR Run) AND NOT Stop AND NOT Fault
//   Lamp = Run

NETWORK 1   // seal-in rung with stop + fault interlocks
LD   %IX0.0      // Start pushbutton
OR   %QX0.0      // seal-in around Start using the Run output
ANDN %IX0.1      // Stop pushbutton (normally closed in the field)
ANDN %IX0.7      // Fault interlock -- drops Run in this very rung
ST   %QX0.0      // Run

NETWORK 2   // indicator lamp follows Run (now always consistent)
LD   %QX0.0
ST   %QX0.1      // Run lamp
