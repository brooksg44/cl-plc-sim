# Learning Common Lisp
Using AI to learn Common Lisp with a topic I am real familiar with PLC Programming.
This is very basic at the moment. Converts IL to LD and allows toggling Inputs by clicking on addresses. Then simulates a single scan. Pretty impressive for a first past.
# plc-sim

A scaffold for an **IEC 61131-3 simulator in Common Lisp** that parses
Instruction List (IL), converts it to a Ladder Diagram (LD), renders the
ladder graphically, and simulates inputs/outputs over a scan cycle.

The design rationale lives in
[`../qwen3.6-with-claude-suggestions.md`](../qwen3.6-with-claude-suggestions.md).
The one-line version: **IL is a 1-D stack machine, LD is a 2-D planar graph.**
Conversion means recovering the boolean *expression tree* the stack program
encodes. That tree is the single intermediate representation — the parser builds
it, the evaluator walks it, the layout engine renders it, and the pretty-printer
turns it back into IL.

```
IL text ──parse──▶ Expression Tree (IR) ──┬──evaluate──▶ Simulation state
                                          ├──layout─────▶ LD geometry ──▶ SVG / McCLIM
                                          └──print──────▶ IL  (round-trip validation)
```

## Layout

```
plc-sim.asd            Core system — zero external dependencies
plc-sim-clim.asd       McCLIM front-end (depends on the core)
verify.lisp            Dependency-free smoke test (sbcl --script verify.lisp)
src/
  package.lisp         Package + exports
  ir.lisp              Expression-tree IR + smart constructors (series/parallel)
  parser.lisp          IL tokenizer, the stack-machine fold, IL pretty-printer
  eval.lisp            Memory model, evaluator, scan cycle, sim object
  layout.lisp          Two-pass ladder layout -> backend-agnostic primitives
  svg.lisp             Renders primitives to SVG (lets you SEE output, no GUI)
  clim-ui.lisp         McCLIM viewer: clickable contacts, live I/O panel
tests/
  tests.lisp           FiveAM suite
examples/
  motor-seal-in.il     Seal-in latch, indicator, parenthesized branch, fault reset
```

## Status

| Layer | State |
|-------|-------|
| IR, IL parser, fold, pretty-printer | ✅ implemented, tested |
| Memory model, evaluator, scan cycle | ✅ implemented, tested |
| Layout engine + SVG renderer | ✅ implemented, tested |
| Round-trip (IL → tree → IL → tree) | ✅ fixed-point verified |
| McCLIM GUI | ✅ compiles & loads against McCLIM; a live window needs a display (XQuartz) |

**30/30 FiveAM checks pass; the `verify.lisp` smoke test passes; `plc-sim-clim`
compiles and loads against McCLIM.** The GUI window itself was not *displayed*
here because this machine has no X11 backend (XQuartz not installed, `DISPLAY`
unset) — see "Launch the McCLIM GUI" below.

### The McCLIM / cl-ppcre dist bug (and the fix)

McCLIM would not load out of the box: Quicklisp dist `2026-01-01` ships
`cl-ppcre-20250622`, which **dropped the symbol
`CL-PPCRE:*STANDARD-OPTIMIZE-SETTINGS*`**, but `cl-unicode` (pulled in by McCLIM
via CLX) still does `(:import-from :cl-ppcre :*standard-optimize-settings*)`. A
bare `(ql:quickload "mcclim")` therefore aborts with
*"no symbol named \*STANDARD-OPTIMIZE-SETTINGS\* in CL-PPCRE"*. This is an
upstream packaging bug, independent of this project.

`load-clim.lisp` works around it by re-creating that symbol in the `cl-ppcre`
package before `cl-unicode` compiles. Remove the shim once upstream is back in
sync.

> Environment changes made while fixing this: Ultralisp's dist *preference* was
> lowered (so Quicklisp's consistent versions win for shared systems), and the
> stale Ultralisp `cl-unicode` release was uninstalled. To restore Ultralisp's
> precedence: `(setf (ql-dist:preference (ql-dist:dist "ultralisp")) 0)`.

## Quick start

### Core only (no Quicklisp needed)

```sh
cd plc-sim
sbcl --script verify.lisp        # loads src/ in order, asserts behaviour
```

### Via ASDF / Quicklisp

```lisp
(push (truename "/Users/brooksg44/common-lisp/plc-planning/plc-sim/")
      asdf:*central-registry*)
(ql:quickload "plc-sim")

;; Parse IL into the expression-tree IR:
(plc-sim:parse-il-string "LD A
AND B
OR C
ST Q")
;; => ((:COIL :NORMAL "Q"
;;      (:OR (:AND (:CONTACT :NO "A") (:CONTACT :NO "B")) (:CONTACT :NO "C"))))

;; Simulate:
(let ((sim (plc-sim:make-sim)))
  (plc-sim:load-il sim #p"examples/motor-seal-in.il")
  (setf (plc-sim:mem-bit (plc-sim:sim-memory sim) "IX0.0") t)  ; press Start
  (plc-sim:step-scan sim)
  (plc-sim:mem-bit (plc-sim:sim-memory sim) "QX0.0"))          ; => T (Run latched)

;; Render a ladder to SVG (open it in a browser):
(plc-sim:render-svg-to-file
  (plc-sim:parse-il #p"examples/motor-seal-in.il")
  #p"/tmp/ladder.svg")
```

### Run the tests

```lisp
(ql:quickload "fiveam")
(asdf:test-system "plc-sim")
```

### Launch the McCLIM GUI

McCLIM's default backend is CLX (X11). On macOS install **XQuartz**
(`brew install --cask xquartz`), start it (`open -a XQuartz`) so `$DISPLAY` is
set, then:

```sh
cd plc-sim
sbcl --load load-clim.lisp
```
```lisp
(plc-sim-clim:run :il #p"examples/motor-seal-in.il")
;; Click a contact's label or an I/O row to toggle it; the energized
;; path recolours after each scan. Type "Scan" / "Toggle" / "Load" / "Quit"
;; in the interactor pane.
```

`load-clim.lisp` applies the cl-ppcre shim (above), loads McCLIM and
`plc-sim-clim`, and prints the launch line. Without a display you'll get a
"can't open display" error from CLX — that's the missing XQuartz, not the code.

## IL dialect supported

Both Siemens STL and IEC textual mnemonics are accepted:

| Operation | Spellings |
|-----------|-----------|
| Load          | `LD`, `L` |
| Load negated  | `LDN`, `LN` |
| And / And-not | `AND` / `ANDN`, `A` / `AN`, also `AND NOT` |
| Or / Or-not   | `OR` / `ORN`, `O` / `ON`, also `OR NOT` |
| Open block    | `AND(` / `OR(`, `A(` / `O(` (operand may ride along) |
| Close block   | `)` |
| Store         | `ST`, `=`, `:=` |
| Set / Reset   | `S` / `R`, `SET` / `RESET` |

Comments: `//…` and `;…` to end of line. Networks split on `NETWORK` markers or
`label:` lines (and each store ends a rung).

## Limitations & next steps (in priority order)

1. **Timers / counters** (`TON`, `TOF`, `TP`, `CTU`, `CTD`) — add stateful
   instruction nodes and a virtual scan clock. The `sim` object already carries
   a scan counter to build on.
2. **Function blocks & non-boolean ops** (`L`/`T`, `ADD`, `CAL`, `JMP`) — the IR
   reserves a `(:fb …)` node and the layout/SVG already draw a box for it; the
   evaluator currently errors on `:fb` (intentional TODO).
3. **Real addressing** — memory is a name→value hash table, which is accurate
   enough for boolean ladder. Swap in bit/byte arrays with offset arithmetic
   (`%MW10`, `%DB1.DBD4`) when you need word/overlapping addressing.
4. **Layout polish** — the two-pass engine handles series/parallel/nesting but
   does not yet vertically centre uneven `OR` branches or de-duplicate shared
   rails. Good enough to read; refine before shipping.
5. **Compile-verify and flesh out `clim-ui.lisp`** once McCLIM loads.
6. **Threaded run mode** — run the scan loop in a `bordeaux-threads` thread and
   have the UI read a state snapshot (don't `sleep` inside the scan).
```
