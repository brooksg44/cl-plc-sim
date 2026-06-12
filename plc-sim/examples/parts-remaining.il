// Parts remaining: arithmetic (3 - C1.CV) and a comparison lamp (GE 2).
//
// Numeric IL rides the same accumulator as boolean logic: LD of a literal,
// a word address (%MW0) or a counter/timer value (C1.CV, T1.ET) makes the
// accumulator NUMERIC; ADD/SUB/MUL/DIV fold into it; ST writes a word.
// Numeric stores execute EVERY scan, unconditionally -- IEC semantics; a
// conditional store needs JMP, which this simulator doesn't have (yet).
// A comparison (GT/GE/EQ/NE/LE/LT) turns the numeric accumulator back into
// a boolean, so it gates coils exactly like a contact.
//
// Try it: pulse %IX0.0 (part sensor) -- toggle on, off, on... -- and watch
// %MW0 count 3, 2, 1, 0 while the almost-full lamp trips at 2 parts and
// the gate opens at 3.

NETWORK 1   // count parts, batch of 3 (rising edges, as ever)
LD   %IX0.0      // part sensor
CTU  C1, 3

NETWORK 2   // remaining := 3 - C1.CV, recomputed every scan
LD   3
SUB  C1.CV
ST   %MW0        // remaining capacity

NETWORK 3   // almost-full lamp: two or more parts counted
LD   C1.CV
GE   2
ST   %QX0.2      // almost-full lamp

NETWORK 4   // gate opens when the batch is complete (counter done bit)
LD   C1
ST   %QX0.0      // gate solenoid
