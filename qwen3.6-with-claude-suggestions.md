Building a full IEC 61131-3 PLC simulator in Common Lisp that converts IL to LD, renders it graphically, and simulates I/O is a substantial project. Common Lisp's strengths (CLOS, macro system, REPL-driven development, and flexible data structures) make it a viable choice, but the scope requires careful architecture and phased implementation.

Below is a pragmatic, production-minded roadmap covering architecture, key challenges, library recommendations, and concrete starting points.

> **Note (Claude additions, 2026-05-30):** This file is the original Qwen roadmap *with Claude's suggestions merged in*. The sharpened pieces — the core insight that drives the whole design, the actual IL→LD conversion algorithm, the layout pass, revised library choices, and the build order — are marked **▶ Claude.** A working scaffold implementing the foundation now lives in [`plc-sim/`](plc-sim/) and its tests pass.

---
## ▶ Claude — The core insight that should drive the whole design

The hard problem is **not** the parser, the simulator, or the graphics. It's that **IL is a 1-dimensional stack machine and LD is a 2-dimensional planar graph.** Converting IL→LD means *recovering* the boolean expression tree that the stack program encodes, then laying that tree out as a rung:

- **AND** → elements in **series** (horizontal)
- **OR** → elements in **parallel** (vertical branch)
- **`A(` … `)` / `O(`** → explicit parenthesized sub-expressions (the operator precedence the stack already gives you)
- **`ST` / `=`** → a coil terminating the rung
- **`S` / `R`** → set/reset (latch) coils

So the intermediate representation should **not** be a flat list of ops. It should be a **boolean expression tree**. IL parses *into* it; LD renders *from* it; the simulator *evaluates* it; the pretty-printer turns it *back* into IL (free round-trip validation). One IR, four consumers — that's the architecture.

```
IL text ──parse──▶ Expression Tree (the IR) ──┬──evaluate──▶ Simulation state
                                              ├──layout─────▶ LD geometry ──▶ graphics
                                              └──print──────▶ IL  (round-trip check)
```

This reframes the original "IL Parser → IR → IL→LD Converter" boxes below: there is no separate converter pass — **conversion is just rendering the IR the parser already produced.**

---
## 🔑 Core Architecture Overview

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   IL Parser     │───▶│   Intermediate   │───▶│  Simulation     │
│  (Lexer/AST)    │    │   Representation │    │  Engine         │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                              │                         │
                              ▼                         ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│ IL→LD Converter │───▶│   LD Node Graph  │───▶│  UI / Graphics  │
│  (Mapping/      │    │  (Contacts,      │    │  (Web/GUI)      │
│   Branch/Stack) │    │   Coils, FBs)    │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                              │                         │
                              ▼                         ▼
                        ┌──────────────────┐    ┌─────────────────┐
                        │   Memory Model   │    │   I/O Simulator │
                        │  (I/Q/M/T/C/DB)  │    │ (Virtual Toggles│
                        └──────────────────┘    │   & Monitoring) │
                                                └─────────────────┘
```

---
## 🧱 Phase-by-Phase Implementation Strategy

### 🔹 Phase 1: Core PLC Engine & Memory Model
Start with a minimal, working simulator before adding UI or LD conversion.

- **Memory Model**: Use byte/bit arrays with offset calculation for S7-style addressing (`%IX0.0`, `%MW10`, `%DB1.DBD4`, etc.)
  - **▶ Claude:** for the *first* cut a `name → value` hash table is accurate enough for boolean ladder and far less fiddly; swap in bit/byte arrays with offset arithmetic only when you need word/overlapping addressing. The scaffold uses the hash-table approach (`src/eval.lisp`).
- **Data Types**: Implement `BOOL`, `INT`, `DINT`, `REAL`, `WORD`, `DWORD`, `TIME`, `DATE_AND_TIME`
- **Scan Cycle**:
  ```lisp
  (defclass plc-sim ()
    ((io-memory   :initform (make-array 16384 :element-type 'bit))
     (db-memory   :initform (make-hash-table))
     (timers      :initform (make-hash-table))
     (counters    :initform (make-hash-table))
     (fb-instances :initform (make-hash-table))   ; note: was a typo in the original
     (scan-ms     :initarg :scan :initform 10)
     (running     :initarg :running :initform nil)))
  ```
- **Execution Loop**: Read inputs → Execute networks → Update timers/counters → Write outputs. Use a virtual clock (`get-internal-real-time`) for timing.
  - **▶ Claude:** don't `sleep` *inside* the scan (as the original sketch does). Run the scan loop in its own `bordeaux-threads` thread and let the UI read a shared state snapshot — otherwise the GUI blocks on every scan.

### 🔹 Phase 2: IL Parser & AST
Siemens IL syntax is stack-based and vertical. Parse into a networked AST.

- **Lexer/Parser**: Hand-written recursive descent or `cl-yacc`.
  - **▶ Claude:** **skip `cl-yacc`.** IL is line-oriented and trivial — a hand-written tokenizer plus the stack fold (below) is less code and easier to extend. Reach for `cl-ppcre` only if you want regex tokenizing. The scaffold's `src/parser.lisp` is ~150 lines with no parser-generator.
  - Instructions: `LD`, `AND`, `OR`, `NOT`, `AND NOT`, `OR NOT`, `SET`, `RESET`, `ST`, `:=`, `TON`, `TOF`, `TP`, `CTU`, `CTD`, `CALL`, `RET`, `END`, `Network`, etc.
  - Addressing: `%IX`, `%QX`, `%MW`, `%MD`, `%DBX`, `%DBD`, constants, registers
- **AST Structure** — **▶ Claude:** use the expression tree, not a flat op list. Nodes (plain lists, so they print readably at the REPL):
  ```lisp
  ;; (:contact <mode> <operand>)   mode :NO  --| |--   or :NC  --|/|--
  ;; (:and <expr> ...)             series   (horizontal)
  ;; (:or  <expr> ...)             parallel (vertical branch)
  ;; (:not <expr>)                 negation
  ;; (:fb  <name> <operand> ...)   function-block / non-boolean box
  ;; rung: (:coil <kind> <operand> <expr>)   kind :NORMAL | :SET | :RESET
  ```

### 🔹 Phase 3: IL to LD Conversion
⚠️ **Critical Limitation**: IL and LD are **not bijective**. Some IL constructs (nested branches, complex math, function calls, pointer arithmetic) do not map cleanly to ladder. Your converter must:
- Use a **hybrid IR** that natively supports both — **▶ Claude:** the expression tree *is* that hybrid IR. Boolean rungs convert perfectly; anything non-boolean becomes a `(:fb …)` box node in the rung.
- Map simple contact/coil logic directly
- Validate and warn on unsupported constructs

#### ▶ Claude — The conversion algorithm (the actual crux)

You reconstruct the tree by simulating the IL accumulator + nested-expression stack at *parse* time. This is ~80% of the IL→LD problem in one fold:

```lisp
(defun fold-ops (ops)
  "Fold a flat op list into a list of rung trees (each a :COIL node)."
  (let ((acc nil) (paren '()) (rungs '()))
    (flet ((emit (kind operand)
             (push (list :coil kind operand acc) rungs)))
      (dolist (op ops (nreverse rungs))
        (destructuring-bind (m &optional operand) op
          (ecase m
            (:ld   (setf acc (contact operand :no)))
            (:ldn  (setf acc (contact operand :nc)))
            (:and  (setf acc (series   acc (contact operand :no))))
            (:andn (setf acc (series   acc (contact operand :nc))))
            (:or   (setf acc (parallel acc (contact operand :no))))
            (:orn  (setf acc (parallel acc (contact operand :nc))))
            ;; A(/O( open a deferred sub-expression; an operand may ride along
            ;; ("OR( B" starts the block already holding B).
            (:and-open (push (cons :and acc) paren)
                       (setf acc (and operand (contact operand :no))))
            (:or-open  (push (cons :or  acc) paren)
                       (setf acc (and operand (contact operand :no))))
            (:close (destructuring-bind (comb . saved) (pop paren)
                      (setf acc (if (eq comb :and)
                                    (series   saved acc)
                                    (parallel saved acc)))))
            (:st (emit :normal operand))
            (:s  (emit :set    operand))
            (:r  (emit :reset  operand))))))))
```

`series`/`parallel` are smart constructors that flatten associatively
(`(:and a (:and b c))` → `(:and a b c)`) so layout stays clean. The inverse —
linearizing the tree back to IL — gives a cheap, powerful test: `parse → tree →
print → parse` should reach a fixed point. (Implemented and tested in the
scaffold.)

**Be honest about the boundary:** pure boolean rungs convert perfectly.
Arithmetic (`L`/`T`/`ADD`), `JMP`, `CAL` → render as **box/FB nodes** rather than
forcing them into contacts.

### 🔹 Phase 3.5 (▶ Claude) — Layout: turning the tree into geometry

The original plan skips this, but you can't draw a tree without coordinates. Do a
two-pass layout that emits **backend-agnostic** primitives (so SVG and McCLIM
share it):

1. **Size pass** (bottom-up): each node reports `(width . height)` in grid cells.
   `:and` sums child widths, height = max. `:or` sums heights, width = max.
   Contact = 1×1.
2. **Place pass** (top-down): assign each node an `(x y)` origin from its parent's
   box, emit contact/coil glyphs, connecting wires, and the vertical rails that
   join parallel branches.

Keep layout *out* of the graphics layer — it emits abstract `(:contact x y …)`,
`(:coil …)`, `(:wire …)`, `(:fb …)` primitives that any renderer consumes. The
scaffold's `src/layout.lisp` does this in ~80 lines, and `src/svg.lisp` renders
the primitives to an SVG file so you can **see** the ladder before touching a GUI
toolkit.

### 🔹 Phase 4: Graphics & UI
Common Lisp lacks a unified GUI standard. Choose based on your deployment target.

**▶ Claude — revised recommendation (the original table is dated):** for 2026,
two genuinely good paths.

| Backend | Why it fits | Tradeoff |
|---------|-------------|----------|
| **McCLIM** ✅ *(chosen)* | The *Lispy* answer and startlingly well-suited. **Presentation types** mean a drawn contact *is* a live object — click-to-toggle, hover, redraw-on-change come almost free. `incremental-redisplay` re-highlights the active path each scan with no manual diffing. Native, no JS, no browser. | Steeper curve; aesthetics need work. |
| **CLOG** | CLOS-driven GUI in the browser over websockets — modern, reactive, easy to make look good. Render the ladder as SVG, bind clicks to Lisp callbacks. | Browser dependency; you own the SVG layout. |

I would **not** reach for `lispbuilder-sdl` (effectively unmaintained) or raw Qt
bindings (heavy, fiddly) for this. **McCLIM was chosen** for this project; the
scaffold includes `src/clim-ui.lisp` (a frame that presents contacts as clickable
`operand` objects with a live I/O panel) and a separate `plc-sim-clim.asd` so the
core stays dependency-free.

*(Original options retained for reference: `cl-web` + JS Canvas; `qt.lisp`/`gdk`;
`cl-aggl` for CLI 2D; `cl-term`/ncurses for quick prototypes.)*

### 🔹 Phase 5: I/O Simulation & Controls
- **Input Simulation**: Virtual toggle grid, mouse-click contacts, or programmatic API
- **Output Monitoring**: Real-time coil state, logging, export
- **Control Panel**: Run/Stop/Step, scan interval, virtual clock speed, breakpoint/watch

---
## 📦 Recommended Common Lisp Libraries

| Purpose | Library | Notes |
|---------|---------|-------|
| Parsing | hand-written; `cl-ppcre` optional | **▶ Claude:** IL is too simple to warrant `cl-yacc`. |
| CLOS/MOP | `closer-mop` | Only if you need metaobject tricks. |
| Concurrency | `bordeaux-threads` | Run the scan loop off the UI thread. |
| GUI (chosen) | **`mcclim`** | Presentations + incremental redisplay. |
| GUI (alt) | `clog` | Browser/SVG, CLOS-driven. |
| Time/Clock | `get-internal-real-time` | Virtual scan clock; no FFI needed for a sim. |
| Testing | `fiveam` | The scaffold's suite. |
| Debugging | `sly`/`slime`, `trivial-backtrace` | REPL-driven dev is CL's superpower. |

---
## ⚠️ Key Challenges & Mitigations

| Challenge | Solution |
|-----------|----------|
| IL→LD not fully translatable | Expression-tree IR; non-boolean → `(:fb …)` box nodes; document limits |
| S7 addressing complexity | Start with a name→value table; abstract an address resolver later |
| Timer/Counter precision | Virtual clock + scan delta; stateful instruction nodes |
| FB state & DB management | CLOS instances or structs; separate DB memory from I/Q memory |
| Performance | Arrays over lists in the hot scan path; compile; avoid GC pressure |
| **▶ UI blocking** | Scan loop in its own thread; UI reads a state snapshot (never `sleep` in-scan) |

---
## 🛠️ Concrete Starting Point

**▶ Claude:** this is now a *built, tested* scaffold rather than a sketch — see
[`plc-sim/`](plc-sim/). Highlights:

- `src/ir.lisp` — the expression-tree IR with `series`/`parallel`/`negate` smart constructors.
- `src/parser.lisp` — IL tokenizer, the `fold-ops` stack machine (above), and an IL pretty-printer for round-trip testing.
- `src/eval.lisp` — memory model, `eval-expr` tree-walk, `scan`, and a `sim` object (`load-il`, `step-scan`).
- `src/layout.lisp` + `src/svg.lisp` — two-pass layout to abstract primitives, rendered to SVG.
- `src/clim-ui.lisp` — McCLIM viewer (clickable contacts, live I/O panel).
- `tests/tests.lisp` — FiveAM suite (**30/30 pass**); `verify.lisp` — a Quicklisp-free smoke test.
- `examples/motor-seal-in.il` — seal-in latch + indicator + parenthesized branch + fault reset.

```lisp
;; The whole pipeline in four lines:
(let ((sim (plc-sim:make-sim)))
  (plc-sim:load-il sim #p"plc-sim/examples/motor-seal-in.il")
  (setf (plc-sim:mem-bit (plc-sim:sim-memory sim) "IX0.0") t)  ; press Start
  (plc-sim:step-scan sim)
  (plc-sim:mem-bit (plc-sim:sim-memory sim) "QX0.0"))          ; => T (Run latched)
```

---
## 📚 References & Existing Work
- **IEC 61131-3**: Standards for data types, IL/LD semantics, timers, counters
- **Siemens S7 Manual**: Programming with STEP 7 (IL syntax, addressing, limits)
- **Open Source PLCs**: `openplc`, `plc2c`, `libplctag`, `s7comm` (for real hardware later)
- **PLC Simulation Research**: "PLC Simulator Architectures" (IEEE), Codesys SDK docs

---
## ✅ Recommended Development Order

**▶ Claude — revised.** The big shift: steps 1–2 give you a real, testable
simulator in **pure Lisp before any graphics**, because the expression-tree IR
replaces the flat op-list so conversion, simulation, and rendering share one
structure. (Steps 1–4 below are **done** in the scaffold.)

1. **IR + IL parser + the fold.** Pure data, fully REPL-testable. Round-trip IL→tree→IL as the test harness. ✅
2. **Evaluator + scan engine.** Tree-walk reads I/M, writes Q. CLI/REPL only — toggle inputs by `setf`, print outputs. A working simulator with zero graphics. ✅
3. **Layout pass → SVG dump.** Verify the ladder visually before any interactivity. ✅
4. **Tests + example program.** ✅
5. **McCLIM**: wire geometry to the screen, make contacts clickable, highlight the energized path each scan. *(compiles & loads against McCLIM; a live window needs an X11 display — XQuartz on macOS. A `cl-ppcre`/`cl-unicode` dist bug blocks a bare `quickload "mcclim"`; `plc-sim/load-clim.lisp` shims it — see the README.)*
6. Timers (`TON`/`TOF`/`TP`), counters, FB boxes, then polish.
7. Debugging, breakpoints, S7 comm, polishing.

*(Original week-by-week estimate, for planning: memory+parser (wk 1–2), interpreter+I/O (wk 3–4), timers/counters/FB stub (wk 5–6), IL→LD (wk 7–8), UI+renderer (wk 9–10), debugging/comms (wk 11+).)*

---
## 💡 Pro Tips
- **REPL-Driven Development**: Test parsing, execution, and rendering incrementally. CL's interactive nature is your biggest advantage.
- **Avoid Over-Engineering**: Start with `LD`, `AND`, `OR`, `NOT`, `ST`, `TON`, `TOF`. Add complexity only when needed.
- **▶ One IR, many consumers**: don't build a separate "converter." The tree the parser emits is what you evaluate, lay out, and print back to IL.
- **▶ Layout is backend-agnostic**: emit abstract geometry; let SVG *and* McCLIM render the same primitives. Graphics logic never leaks into layout.
- **Document IL→LD Limits Early**: parallel branches, complex math, pointer math, and `CALL`/`RET` chains map poorly. Use `(:fb …)` box nodes with a `⚠` warning.

---
**Target locked in:** macOS, native desktop UI via **McCLIM**, no real S7 hardware
for now. The scaffold reflects those choices. The foundation (everything except
the live McCLIM window) is implemented and green.
