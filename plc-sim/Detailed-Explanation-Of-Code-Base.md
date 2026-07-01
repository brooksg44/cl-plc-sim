# Detailed Explanation Of Code Base

This project is a small PLC simulator written in Common Lisp. It reads PLC
Instruction List (IL), converts it into an internal expression tree, evaluates
that tree like a PLC scan cycle, and can draw the same tree as a ladder diagram
using SVG or a McCLIM GUI.

The most important idea in the code base is this:

```text
IL text
  -> tokens
  -> expression-tree IR
  -> scan-cycle evaluator
  -> layout primitives
  -> SVG or McCLIM ladder drawing
```

For a beginning Common Lisp programmer, this is a useful project because it
uses simple Lisp data structures for real work. Most of the core program is
built from lists, symbols, strings, hash tables, structs, and ordinary
functions.

## Project Layout

The repository is organized like this:

```text
plc-sim.asd             ASDF definition for the dependency-free core system
plc-sim-clim.asd        ASDF definition for the McCLIM graphical front end
verify.lisp             Simple dependency-free smoke test
make-docs.lisp          Script that regenerates documentation SVG/PNG images
src/package.lisp        Package definition and exported public symbols
src/ir.lisp             Internal representation for ladder logic
src/parser.lisp         IL tokenizer, parser/folder, and IL pretty-printer
src/eval.lisp           Memory model, scan cycle, timers, counters, simulator
src/layout.lisp         Backend-independent ladder layout engine
src/svg.lisp            SVG renderer
src/clim-ui.lisp        Interactive McCLIM GUI
tests/tests.lisp        FiveAM test suite
examples/*.il           Example PLC Instruction List programs
docs/*                  Rendered ladder images used by README.md
```

The core system is intentionally dependency-free. You can load and use
`plc-sim` without Quicklisp libraries. The GUI system, `plc-sim-clim`, is
separate because it depends on McCLIM and Bordeaux Threads.

## ASDF Systems

Common Lisp projects often use ASDF, which is the Common Lisp build system.
This project has two ASDF files.

`plc-sim.asd` defines the core system:

```lisp
(asdf:defsystem "plc-sim"
  :depends-on ()
  :serial t
  :components ((:module "src"
                :components ((:file "package")
                             (:file "ir")
                             (:file "parser")
                             (:file "eval")
                             (:file "layout")
                             (:file "svg")))))
```

Important points:

- `:depends-on ()` means the core has no external library dependencies.
- `:serial t` means files load in the listed order.
- `package.lisp` loads first because the other files use the package it defines.
- `ir.lisp` loads before parser/evaluator/layout because those files use the IR
  helper functions.

`plc-sim-clim.asd` defines the GUI system:

```lisp
(asdf:defsystem "plc-sim-clim"
  :depends-on ("plc-sim" "mcclim" "bordeaux-threads")
  :components ((:module "src"
                :components ((:file "clim-ui")))))
```

This keeps the core simulator independent from GUI concerns.

## Packages

The file `src/package.lisp` defines the main package:

```lisp
(defpackage #:plc-sim
  (:use #:cl)
  (:export ...))
```

A Common Lisp package controls symbol names. In this project:

- `#:plc-sim` is the core simulator package.
- `(:use #:cl)` makes standard Common Lisp symbols available.
- `(:export ...)` lists symbols that users are expected to call from outside the
  package.

For example, because `parse-il-string`, `make-sim`, `step-scan`, and
`render-svg-to-file` are exported, users can call them as:

```lisp
(plc-sim:parse-il-string "LD A
ST Q")
```

Inside source files, you will see:

```lisp
(in-package #:plc-sim)
```

That means the rest of that file is compiled in the `plc-sim` package.

## The Intermediate Representation

The file `src/ir.lisp` defines the internal representation, often abbreviated
as IR.

The IR is not made from classes. It is made from ordinary Lisp lists. For
example:

```lisp
(:contact :no "A")
(:contact :nc "Stop")
(:and (:contact :no "A") (:contact :no "B"))
(:or (:contact :no "Start") (:contact :no "Run"))
```

This style is common in Lisp programs. A list starts with a keyword that says
what kind of node it is. The rest of the list contains that node's data.

### Boolean IR Nodes

The main boolean expression nodes are:

```lisp
(:contact mode operand)
(:and expr expr ...)
(:or expr expr ...)
(:not expr)
(:cmp op value value)
(:fb name operand ...)
```

Meanings:

- `:contact` represents a ladder contact.
- `:no` means normally open.
- `:nc` means normally closed.
- `:and` represents contacts in series.
- `:or` represents branches in parallel.
- `:not` represents boolean negation.
- `:cmp` represents numeric comparison used like a contact.
- `:fb` is reserved for future function-block support.

Example:

```lisp
(:and
  (:or (:contact :no "%IX0.0")
       (:contact :no "%QX0.0"))
  (:contact :nc "%IX0.1"))
```

This means:

```text
(Start OR Run) AND NOT Stop
```

### Value IR Nodes

The project also supports numeric values:

```lisp
(:lit 5)
(:word "%MW0")
(:arith :add (:word "%MW0") (:lit 5))
```

Meanings:

- `:lit` is an integer literal.
- `:word` is a word value in memory.
- `:arith` is arithmetic such as add, subtract, multiply, or divide.

### Rungs

A ladder rung is represented as either a coil rung or an assignment rung:

```lisp
(:coil kind operand expr)
(:coil kind operand expr preset)
(:assign dst value-expr)
```

Examples:

```lisp
(:coil :normal "Q" (:contact :no "A"))
(:coil :set "Run" (:contact :no "Start"))
(:coil :ton "T1" (:contact :no "Run") 5000)
(:assign "%MW0" (:arith :sub (:lit 3) (:word "C1.CV")))
```

The optional preset is used by timers and counters.

### Accessor Helpers

`ir.lisp` defines helpers such as:

```lisp
(defun node-op (node) (and (consp node) (car node)))
(defun node-args (node) (and (consp node) (cdr node)))
```

For a beginner, remember:

- `car` returns the first item in a list.
- `cdr` returns the rest of the list.
- `consp` checks whether something is a cons cell/list.

So for:

```lisp
(:contact :no "A")
```

`node-op` returns `:contact`, and `node-args` returns `(:no "A")`.

### Smart Constructors

The functions `contact`, `series`, `parallel`, and `negate` build IR nodes.

```lisp
(contact "A")
;; => (:contact :no "A")

(contact "A" :nc)
;; => (:contact :nc "A")
```

`series` combines two expressions with `:and`:

```lisp
(series (contact "A") (contact "B"))
;; => (:and (:contact :no "A") (:contact :no "B"))
```

`parallel` combines two expressions with `:or`:

```lisp
(parallel (contact "A") (contact "B"))
;; => (:or (:contact :no "A") (:contact :no "B"))
```

These constructors flatten nested expressions. That means:

```lisp
(series (series (contact "A") (contact "B"))
        (contact "C"))
```

becomes:

```lisp
(:and (:contact :no "A")
      (:contact :no "B")
      (:contact :no "C"))
```

instead of:

```lisp
(:and (:and (:contact :no "A")
            (:contact :no "B"))
      (:contact :no "C"))
```

Flat lists are easier for the evaluator and layout engine to walk.

## Parsing IL

The file `src/parser.lisp` turns Instruction List text into the IR.

Instruction List is stack-like. There is an accumulator, sometimes called the
current result. Each instruction changes the accumulator or stores it.

For example:

```il
LD A
AND B
OR C
ST Q
```

means:

```text
Q = (A AND B) OR C
```

The parser turns that into:

```lisp
((:coil :normal "Q"
  (:or (:and (:contact :no "A")
             (:contact :no "B"))
       (:contact :no "C"))))
```

Notice that the result is a list of rungs. A program can contain many rungs.

### Tokenizing

The parser begins with tokenization:

```lisp
(tokenize text)
```

Tokenizing performs simple source cleanup:

- Splits text into lines.
- Removes `//` and `;` comments.
- Ignores blank lines.
- Recognizes `NETWORK` markers and labels.
- Normalizes different mnemonic spellings.

For example, these are accepted spellings:

```text
LD, L
LDN, LN
AND, A, &
ANDN, AN, AND NOT
OR, O
ORN, ON, OR NOT
ST, =, :=
S, SET
R, RESET
```

The function `%normalize-mnemonic` maps source spellings to internal keywords.
For example, `"AND"` and `"A"` both become `:and`.

Names beginning with `%` are not special to the tokenizer. They are preserved as
strings, such as `"%IX0.0"`.

### The Accumulator Fold

The most important parser function is:

```lisp
(fold-ops ops)
```

It takes a flat list of parsed operations and folds them into rung trees.

Internally it keeps:

- `acc`: the current accumulator.
- `paren`: a stack for parenthesized `AND(` and `OR(` blocks.
- `rungs`: the rungs emitted so far.

Here is the rough idea:

```text
LD A      -> acc = contact A
AND B     -> acc = acc AND contact B
OR C      -> acc = acc OR contact C
ST Q      -> emit a coil rung using acc
```

The code uses `ecase` heavily:

```lisp
(ecase m
  (:ld ...)
  (:and ...)
  (:or ...)
  (:st ...))
```

`ecase` is like `case`, but stricter. If no branch matches, it signals an
error. That is useful when you want unknown instructions to fail loudly.

### Parentheses

IL supports parenthesized blocks:

```il
LD A
OR( B
AND C
)
ST Q
```

This means:

```text
A OR (B AND C)
```

The parser handles this by pushing the old accumulator onto `paren` when it sees
`OR(` or `AND(`. At `)`, it pops the saved accumulator and combines it with the
current one.

This is a classic stack technique.

### Numeric Accumulator

The accumulator can be boolean or numeric.

This is boolean:

```il
LD A
AND B
ST Q
```

This is numeric:

```il
LD 3
SUB C1.CV
ST %MW0
```

The parser decides that `LD` is numeric when the operand is:

- An integer literal, such as `3`.
- A word address, such as `%MW0`.
- A timer/counter value, such as `C1.CV` or `T1.ET`.

Arithmetic instructions build `:arith` nodes. Comparison instructions build
`:cmp` nodes and turn the accumulator back into a boolean.

Example:

```il
LD C1.CV
GE 2
ST %QX0.2
```

becomes:

```lisp
(:coil :normal "%QX0.2"
  (:cmp :ge (:word "C1.CV") (:lit 2)))
```

That comparison can be evaluated like a ladder contact.

### Timers And Counters

The parser recognizes:

```text
TON, TOF, TP, CTU, CTD
```

Timer instructions use time presets:

```il
TON T1, T#5s
TON T1, T#500ms
TON T1, T#1m30s
```

The function `%parse-time-literal` converts those into milliseconds.

Example:

```il
LD Run
TON T1, T#5s
```

becomes:

```lisp
(:coil :ton "T1" (:contact :no "Run") 5000)
```

Counter presets are plain integer counts:

```il
LD Sensor
CTU C1, 3
```

becomes:

```lisp
(:coil :ctu "C1" (:contact :no "Sensor") 3)
```

### Pretty-Printing Back To IL

`parser.lisp` also contains functions that turn IR back into IL:

```lisp
(rung->il rung)
(program->il program)
```

This is valuable for testing. The test suite checks that:

```text
IL -> IR -> IL -> IR
```

reaches the same IR again.

That is called a round-trip test.

The same printer also feeds the GUI's IL pane, which displays the loaded
program as IL text.

## Memory Model

The file `src/eval.lisp` defines the simulator's memory.

Memory is a Common Lisp struct:

```lisp
(defstruct (memory (:constructor %make-memory))
  (bits  (make-hash-table :test 'equal) :type hash-table)
  (words (make-hash-table :test 'equal) :type hash-table)
  (dt-ms 1000 :type unsigned-byte))
```

This creates a `memory` type with three slots:

- `bits`: hash table for boolean values.
- `words`: hash table for numeric values.
- `dt-ms`: elapsed time for the current scan, in milliseconds.

The public constructor is:

```lisp
(make-memory)
```

The internal constructor `%make-memory` is generated by `defstruct`, but the
project wraps it so callers use the simpler exported function.

### Hash Tables

The memory tables use `:test 'equal`, which means string keys compare by
contents instead of object identity.

These accessors read and write bits:

```lisp
(mem-bit memory operand)
(setf (mem-bit memory operand) value)
```

These accessors read and write words:

```lisp
(mem-word memory operand)
(setf (mem-word memory operand) value)
```

Example:

```lisp
(let ((m (plc-sim:make-memory)))
  (setf (plc-sim:mem-bit m "IX0.0") t)
  (plc-sim:mem-bit m "%IX0.0"))
;; => T
```

The `%canon` helper canonicalizes names:

- Converts to uppercase.
- Removes a leading `%`.

So `"IX0.0"` and `"%ix0.0"` refer to the same key.

## Evaluating Expressions

The function:

```lisp
(eval-expr expr memory)
```

evaluates boolean IR.

It handles:

- `nil` as an always-true empty rail.
- `:contact` by reading `mem-bit`.
- `:and` by using `every`.
- `:or` by using `some`.
- `:not` by recursively negating.
- `:cmp` by evaluating two numeric expressions and comparing them.

For a beginning Lisp programmer, `every` and `some` are useful sequence
functions:

- `(every predicate list)` returns true if all items satisfy the predicate.
- `(some predicate list)` returns true if at least one item satisfies it.

So this expression:

```lisp
(:and expr1 expr2 expr3)
```

is evaluated by checking every child expression.

The function:

```lisp
(eval-value v memory)
```

evaluates numeric value IR.

It handles:

- `:lit` by returning the literal number.
- `:word` by reading `mem-word`.
- `:arith` by applying arithmetic left-to-right.

Division truncates, and division by zero returns `0`. The comment notes that a
real PLC might fault, but this simulator keeps scanning.

## Executing Rungs

The function:

```lisp
(execute-rung rung memory)
```

executes one rung.

There are two main cases.

### Assignment Rung

An assignment rung looks like this:

```lisp
(:assign "%MW0" (:lit 5))
```

It writes a word value:

```lisp
(setf (mem-word memory "%MW0") 5)
```

Numeric stores execute unconditionally every scan. They are not gated by a
contact network.

### Coil Rung

A coil rung looks like this:

```lisp
(:coil :normal "Q" (:contact :no "A"))
```

First the expression is evaluated:

```lisp
(eval-expr expr memory)
```

Then the coil action is applied:

- `:normal` writes the result to a bit.
- `:set` sets the bit only when the result is true.
- `:reset` resets the bit only when the result is true.
- `:ton`, `:tof`, `:tp` run timer logic.
- `:ctu`, `:ctd` run counter logic.

This is a good example of how the project separates concerns:

- The parser decides what kind of rung exists.
- The evaluator decides what the rung does at runtime.

## Timers And Counters

Timers and counters are implemented in `eval.lisp`.

They store their state in ordinary simulator memory:

```text
bit  "T1"       timer/counter done bit
word "T1"       elapsed time or count
bit  "T1#P"     previous input, used for rising-edge detection
word "C1#PV"    preset value for CTD reload
```

The `#` names are internal. The UI hides them.

### TON

`%eval-ton` implements an on-delay timer.

Behavior:

- If input is true, elapsed time increases by `dt-ms`.
- When elapsed time reaches the preset, the done bit becomes true.
- If input is false, elapsed time resets to zero and the done bit becomes false.

### TOF

`%eval-tof` implements an off-delay timer.

Behavior:

- If input is true, output is true.
- When input goes false, output stays true until elapsed time reaches the preset.
- Then output becomes false.

### TP

`%eval-tp` implements a pulse timer.

Behavior:

- A rising edge starts a pulse.
- The output stays true for the preset time.
- Holding the input true does not retrigger the pulse.

### CTU

`%eval-ctu` implements a count-up counter.

Behavior:

- Counts rising edges.
- Done bit becomes true when count reaches the preset.
- Reset clears the count to zero.

### CTD

`%eval-ctd` implements a count-down counter.

Behavior:

- Loads the preset on first execution.
- Counts rising edges downward.
- Done bit becomes true when count reaches zero.
- Reset reloads the preset.

## The Simulator Object

`eval.lisp` also defines:

```lisp
(defstruct (sim (:constructor %make-sim))
  program
  memory
  running-p
  scan-count
  next-rung
  clock-ms
  scan-period-ms
  time-fn)
```

A `sim` ties a parsed program to its memory and scan state.

Important slots:

- `program`: list of rungs.
- `memory`: the current bit/word memory.
- `scan-count`: how many full scans have completed.
- `next-rung`: which rung will execute next when single-stepping.
- `clock-ms`: simulator clock in milliseconds.
- `scan-period-ms`: virtual time increment per manual scan.
- `time-fn`: optional function for realtime wall-clock mode.

The main constructor is:

```lisp
(make-sim)
```

You can load IL into a simulator:

```lisp
(let ((sim (plc-sim:make-sim)))
  (plc-sim:load-il sim #p"examples/motor-seal-in.il")
  sim)
```

`load-il` accepts either IL text or a file path.

## Scan Cycle

A PLC normally executes the same program repeatedly. One pass through all rungs
is called a scan.

This project has three scan-related functions:

```lisp
(scan program memory)
(step-rung sim)
(step-scan sim)
```

### `scan`

`scan` is the simplest:

```lisp
(dolist (rung program)
  (execute-rung rung memory))
```

It executes every rung in order.

### `step-rung`

`step-rung` executes exactly one rung and updates `sim-next-rung`.

This supports single-stepping in the GUI and tests.

If the rung was the last rung in the program, `step-rung` wraps back to rung
zero and increments `sim-scan-count`.

### `step-scan`

`step-scan` runs to the end of the current scan.

If the simulator is at the beginning of a scan, it runs all rungs. If it is
mid-scan because you previously called `step-rung`, it only runs the remaining
rungs.

### Time Sampling

The function `%begin-scan` advances the simulator clock at the start of a scan.

Paused/manual mode:

```text
clock-ms += scan-period-ms
```

Realtime mode:

```text
clock-ms = value returned by time-fn
```

The important design choice is that time is sampled once per scan. Every rung in
the same scan sees the same `dt-ms`, which is how real PLC scan behavior is
usually modeled.

## Stabilizing

The function:

```lisp
(stabilize sim &key (max-scans 100))
```

runs scans until the simulator's bits stop changing or until a maximum number
of scans is reached.

This is useful because some PLC programs have one-scan transients. For example,
if rung 2 reads an output and rung 4 resets that output later in the same scan,
the display can briefly show a stale value.

`stabilize` compares only bits, not words. That is deliberate. If it compared
timer elapsed-time words, then running timers would force stabilization to keep
advancing time.

## Layout Engine

The file `src/layout.lisp` converts IR into drawing primitives.

It does not draw SVG or CLIM directly. Instead, it emits backend-independent
instructions such as:

```lisp
(:contact x y mode operand)
(:coil x y kind operand)
(:coil x y kind operand preset)
(:cmp x y op a b)
(:assign x y width dst value)
(:wire x1 y1 x2 y2)
(:fb x y width height name)
```

This is another important design separation:

```text
layout.lisp decides where things go
svg.lisp decides how to draw them as SVG
clim-ui.lisp decides how to draw them in McCLIM
```

### Two-Pass Layout

The layout engine uses two passes.

Pass 1:

```lisp
(expr-size expr)
```

This calculates the width and height of an expression in grid cells.

Rules:

- A contact is 2 cells wide and 1 cell tall.
- A comparison is 2 cells wide and 1 cell tall.
- `:and` adds widths because series elements go left to right.
- `:or` adds heights because parallel branches stack vertically.

Pass 2:

```lisp
(layout-rung rung)
```

This places the expression at concrete grid coordinates and emits primitives.

`layout-program` stacks multiple rungs vertically and returns:

```lisp
(values primitives total-rows rung-start-rows)
```

The GUI uses `rung-start-rows` to draw the single-step marker.

## SVG Renderer

The file `src/svg.lisp` consumes layout primitives and writes SVG XML.

The public functions are:

```lisp
(render-svg program :memory memory :stream stream)
(render-svg-to-file program path :memory memory)
```

If memory is provided, energized contacts and coils are drawn green.

The renderer has helper functions for each primitive:

- `%svg-contact`
- `%svg-coil`
- `%svg-box-coil`
- `%svg-cmp`
- `%svg-assign`
- `%svg-wire`
- `%svg-fb`

The SVG renderer is dependency-free. It writes XML text with `format`.

For example:

```lisp
(plc-sim:render-svg-to-file
  (plc-sim:parse-il #p"examples/motor-seal-in.il")
  #p"/tmp/motor.svg")
```

## McCLIM GUI

The file `src/clim-ui.lisp` implements the graphical interactive viewer.

It lives in its own package:

```lisp
(defpackage #:plc-sim-clim
  (:use #:clim #:clim-lisp)
  (:export #:run #:ladder-frame))
```

The GUI depends on:

- `plc-sim`
- `mcclim`
- `bordeaux-threads`

The application frame is defined with:

```lisp
(define-application-frame ladder-frame ()
  ((sim :initarg :sim :accessor frame-sim))
  ...)
```

The frame contains:

- A ladder pane.
- An IL pane showing the loaded program as IL source text.
- An I/O pane.
- An interactor command pane.

The GUI draws the same primitives produced by `layout-program`. This is why the
SVG and GUI views stay consistent.

The IL pane prints the program rung by rung with `rung->il`, producing the
same text as `program->il`. Printing per rung lets it highlight the network
whose rung executes next in orange while a scan is mid-flight, matching the
step marker arrowhead in the ladder pane.

### Clickable Operands

The GUI defines a presentation type:

```lisp
(define-presentation-type operand () :inherit-from 'string)
```

When drawing a contact label or I/O row, it wraps the label with
`with-output-as-presentation`. McCLIM can then treat that drawn text as an
interactive object.

The `Toggle` command toggles a clicked bit.

### Commands

The GUI defines commands such as:

- `Toggle`
- `Scan`
- `Step`
- `Run`
- `Stop`
- `Set`
- `Load`

`Run` starts realtime scanning. A background thread queues events, but the
actual simulator mutation happens in the frame event loop. That avoids changing
simulator state from two threads at once.

## Scripts

### `verify.lisp`

`verify.lisp` is a dependency-free smoke test. It manually loads:

```lisp
package
ir
parser
eval
layout
svg
```

Then it runs simple checks using a custom `check` macro.

This is useful when Quicklisp or FiveAM are not available:

```sh
sbcl --script verify.lisp
```

### `make-docs.lisp`

`make-docs.lisp` regenerates ladder images under `docs/`.

It:

- Loads the core files.
- Parses example IL programs.
- Sets up simulator states.
- Runs scans or stabilization.
- Renders SVG files.
- Optionally uses macOS `qlmanage` to make PNG thumbnails.

This script shows how the core can be used without the GUI.

## Examples

The `examples/` directory contains IL programs that demonstrate supported
features.

### `motor-seal-in.il`

Demonstrates:

- Start/stop latch.
- Seal-in contact.
- Indicator lamp.
- Parenthesized branch.
- Reset coil.

The main latch is:

```text
Run = (Start OR Run) AND NOT Stop
```

The fault reset happens in a later rung, so this example can show a one-scan
transient where the lamp still reflects the old run state.

### `motor-interlock.il`

Demonstrates the same motor control idea, but with the fault included directly
in the main rung:

```text
Run = (Start OR Run) AND NOT Stop AND NOT Fault
```

Because the fault is part of the same expression, the run output and lamp stay
consistent in one scan.

### `pump-on-delay.il`

Demonstrates timers:

- `TON` on-delay timer.
- `TOF` off-delay timer.
- Latched run relay.
- Pump and fan outputs.

### `batch-counter.il`

Demonstrates counters:

- `CTU` count-up counter.
- `CTD` count-down counter.
- Rising-edge counting.
- Reset behavior.

### `stamp-press.il`

Demonstrates:

- `TP` pulse timer.
- One-shot behavior.
- Normally closed contact using `LDN`.

### `parts-remaining.il`

Demonstrates numeric operations:

- Arithmetic with `SUB`.
- Word assignment to `%MW0`.
- Comparison with `GE`.
- Counter current value access with `C1.CV`.

## Tests

The full test suite is in `tests/tests.lisp` and uses FiveAM.

It covers:

- IR constructors.
- Parser behavior.
- Parenthesized expressions.
- Set/reset coils.
- Round-trip printing.
- Boolean evaluation.
- Scan stepping.
- Stabilization.
- Timers and counters.
- Realtime clock injection.
- Numeric operations.
- Layout primitives.
- Example programs.

The tests are a good learning resource because they show expected input and
output side by side.

For example, this test shows exactly how a simple IL program is parsed:

```lisp
(parse-il-string "LD A
AND B
OR C
ST Q")
```

expected result:

```lisp
((:coil :normal "Q"
  (:or (:and (:contact :no "A")
             (:contact :no "B"))
       (:contact :no "C"))))
```

## Common Lisp Techniques Used In This Code

### Lists As Data

The IR uses lists directly. This is idiomatic Lisp. Instead of defining many
classes, the code uses simple tagged lists:

```lisp
(:contact :no "A")
(:and expr1 expr2)
(:coil :normal "Q" expr)
```

This makes the IR easy to print, inspect, compare with `equal`, and test.

### Keywords

Symbols beginning with `:` are keywords:

```lisp
:contact
:and
:normal
```

Keywords evaluate to themselves and are commonly used as tags or option names.

### `defstruct`

`memory` and `sim` are structs. `defstruct` creates:

- A type.
- A constructor.
- Slot accessors.
- A predicate.

For `sim`, accessors include:

```lisp
sim-program
sim-memory
sim-running-p
sim-scan-count
```

### `setf`

`setf` is Common Lisp's general assignment operator.

This project defines custom places:

```lisp
(setf (mem-bit memory "A") t)
(setf (mem-word memory "%MW0") 42)
```

That works because the code defines functions named:

```lisp
(defun (setf mem-bit) ...)
(defun (setf mem-word) ...)
```

### `destructuring-bind`

The code often uses `destructuring-bind` to unpack lists.

Example:

```lisp
(destructuring-bind (kind operand expr &optional preset) (rest rung)
  ...)
```

This is clearer than writing many `first`, `second`, `third`, and `fourth`
calls.

### `ecase`

`ecase` dispatches on known cases and errors if the value is unexpected.

That is appropriate for IR tags and parsed opcodes because an unknown tag means
the program is malformed or a case was forgotten.

### Local Functions

The code uses `flet` and `labels`.

- `flet` defines local non-recursive functions.
- `labels` defines local recursive functions.

`layout-rung` uses `labels` so its local `place` function can call itself while
walking nested expressions.

### Multiple Values

Common Lisp functions can return multiple values.

`expr-size` returns width and height:

```lisp
(values width height)
```

Callers receive them with:

```lisp
(multiple-value-bind (w h) (expr-size expr)
  ...)
```

`layout-program` returns three values:

```lisp
(values primitives total-rows rung-rows)
```

### Error Signaling

The parser uses `error` when input is invalid:

```lisp
(error "Unknown IL mnemonic ~S in line: ~A" head line)
```

This is better than silently producing bad IR.

## How To Read The Code In Order

For a beginner, this is the recommended reading order:

1. `src/package.lisp`
   Learn what public functions the project exposes.

2. `src/ir.lisp`
   Understand the list-shaped data model.

3. `tests/tests.lisp`, first parser tests
   See examples of IL input and exact IR output.

4. `src/parser.lisp`
   Study tokenization first, then `fold-ops`.

5. `src/eval.lisp`
   Study `memory`, `eval-expr`, `eval-value`, and `execute-rung`.

6. `examples/motor-seal-in.il`
   Connect the parser and evaluator to a real PLC example.

7. `src/layout.lisp`
   See how the same IR becomes drawing primitives.

8. `src/svg.lisp`
   See how primitives are rendered to an output format.

9. `src/clim-ui.lisp`
   Read this last. It is useful, but it uses more advanced McCLIM concepts.

## A Small End-To-End Example

Suppose the IL is:

```il
LD A
ANDN B
ST Q
```

Tokenization produces operations roughly like:

```lisp
((:ld "A")
 (:andn "B")
 (:st "Q"))
```

Folding produces a program:

```lisp
((:coil :normal "Q"
  (:and (:contact :no "A")
        (:contact :nc "B"))))
```

Simulation:

```lisp
(let* ((program (plc-sim:parse-il-string "LD A
ANDN B
ST Q"))
       (sim (plc-sim:make-sim program))
       (m (plc-sim:sim-memory sim)))
  (setf (plc-sim:mem-bit m "A") t)
  (setf (plc-sim:mem-bit m "B") nil)
  (plc-sim:step-scan sim)
  (plc-sim:mem-bit m "Q"))
```

Result:

```lisp
T
```

Why?

- `A` is true.
- `B` is false.
- `ANDN B` means `AND NOT B`.
- So `A AND NOT B` is true.
- The normal coil stores true into `Q`.

Rendering:

```lisp
(plc-sim:render-svg-to-file program #p"/tmp/example.svg"
                            :memory (plc-sim:sim-memory sim))
```

The SVG renderer uses the same parsed program and current memory state.

## Important Design Choices

### One IR, Many Uses

The expression-tree IR is the center of the project.

It is used by:

- Parser.
- Evaluator.
- Layout engine.
- SVG renderer.
- McCLIM GUI.
- Pretty-printer.
- Tests.

This avoids duplicating the meaning of IL in many places.

### Core Is Dependency-Free

The core simulator uses plain Common Lisp. That makes it easier to test,
understand, and run in minimal environments.

### GUI Is Separate

The McCLIM GUI is useful, but it is not required to parse, evaluate, or render
SVGs. Keeping it in a separate system prevents GUI dependencies from complicating
the core.

### Scan Order Matters

The simulator executes rungs in order. That means later rungs can affect what
happens in the next scan, and in some cases can create visible one-scan
transients.

This is not a bug in the simulator. It is part of PLC behavior.

### Memory Is Symbolic

The current memory model treats addresses like names:

```text
IX0.0
QX0.0
MW0
T1
C1
```

It does not yet model overlapping byte/word/bit address arithmetic. That keeps
the code simple and clear.

## Current Limitations

The README lists future directions. The important current limitations are:

- No full IEC address-space model with overlapping bits, bytes, words, and data
  blocks.
- No `JMP`, `JMPC`, or `JMPCN`, so conditional numeric stores are not
  implemented.
- Function-block `CAL` support is reserved in the IR but not implemented.
- Layout is readable but not a polished industrial ladder editor.
- The GUI needs McCLIM and a working display environment.

## Summary

This code base is a compact example of building a simulator around a simple
intermediate representation.

The parser turns text into plain Lisp lists. The evaluator recursively walks
those lists against hash-table memory. The scan functions provide PLC-like
execution. The layout engine walks the same lists to produce drawing primitives.
SVG and McCLIM render those primitives in different ways.

For a Common Lisp beginner, the most important lesson is that simple Lisp data
structures can carry a lot of meaning when they are used consistently. The
project does not need a large object hierarchy to parse, simulate, test, and
draw PLC ladder logic.
