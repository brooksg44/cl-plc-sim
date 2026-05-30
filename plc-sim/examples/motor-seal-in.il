// Classic motor seal-in (start/stop latch) plus an interlock.
//
//   Run  = (Start OR Run) AND NOT Stop
//   Lamp = Run
//   Fault-stops the motor via a RESET coil.

NETWORK 1   // seal-in rung
LD   %IX0.0      // Start pushbutton
OR   %QX0.0      // seal-in around Start using the Run output
ANDN %IX0.1      // Stop pushbutton (normally closed in the field)
ST   %QX0.0      // Run

NETWORK 2   // indicator lamp follows Run
LD   %QX0.0
ST   %QX0.1      // Run lamp

NETWORK 3   // a parenthesized branch: (A AND B) OR (C AND D)
LD   %IX1.0
AND  %IX1.1
OR(  %IX1.2
AND  %IX1.3
)
ST   %QX0.2

NETWORK 4   // fault resets the motor
LD   %IX0.7      // Fault input
R    %QX0.0      // force Run off
