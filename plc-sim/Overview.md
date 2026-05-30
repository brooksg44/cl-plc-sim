# cl-plc-sim — Codebase Overview for Beginners

## What this project is

`cl-plc-sim` is a **PLC (Programmable Logic Controller) simulator** written in pure Common Lisp. It reads industrial automation programs written in **IL (Instruction List)** — a low-level language defined by the IEC 61131-3 standard — and simulates how a real PLC would run them. It can also render the program as a **ladder diagram** (the visual 2D representation electricians use) either as an SVG file or an interactive GUI.

---

## The big picture: data flow

```
IL text file
    │
    ▼
[parser.lisp]  tokenize + fold-ops
    │
    ▼
Expression tree (IR)           ← lives in ir.lisp
  e.g.  (:coil :normal "Q"
          (:or (:and A B) C))
    │
    ├──▶ [eval.lisp]    evaluate against memory → run scan cycles
    │
    ├──▶ [layout.lisp]  compute grid positions → drawing primitives
    │         │
    │         ├──▶ [svg.lisp]      write SVG file
    │         └──▶ [clim-ui.lisp]  draw interactively (McCLIM)
    │
    └──▶ [parser.lisp]  pretty-print back to IL text (round-trip test)
```

The **expression tree** (called the IR, Intermediate Representation) is the single hub everything passes through.

---

## File-by-file walkthrough

### `plc-sim.asd` — the project descriptor

This is an **ASDF system definition**. ASDF is Common Lisp's build system (like `Makefile` or `cargo.toml`). It tells Lisp which files to load and in what order.

```lisp
:serial t          ; load files one after another, in order
:components ((:module "src"
              :components ((:file "package")   ; first
                           (:file "ir")
                           (:file "parser")
                           (:file "eval")
                           (:file "layout")
                           (:file "svg"))))    ; last
```

The `:depends-on ()` line is intentional — no external libraries required for the core.

---

### `src/package.lisp` — the namespace declaration

```lisp
(defpackage #:plc-sim
  (:use #:cl)
  (:export #:contact #:series ...))
```

In Common Lisp, **packages** are namespaces. This file declares the `plc-sim` package and lists every public symbol (function, struct, etc.) that outside code is allowed to use. Everything prefixed with `%` in the source (like `%make-memory`, `%strip-comment`) is private by convention — not exported, not meant for callers.

---

### `src/ir.lisp` — the data model

The IR is just **nested Lisp lists** (no special struct). A contact looks like:

```lisp
'(:contact :no "%IX0.0")   ; normally-open contact
'(:contact :nc "%IX0.1")   ; normally-closed contact
```

A series (AND) of two contacts:
```lisp
'(:and (:contact :no "A") (:contact :no "B"))
```

A complete rung (one row of a ladder diagram):
```lisp
'(:coil :normal "Q"
   (:or (:and (:contact :no "A") (:contact :no "B"))
        (:contact :no "C")))
```
Reading this: "coil Q is set when (A AND B) OR C is true."

**Key Lisp concept here:** `cons`, `car`, `cdr`. Every list node like `(:and a b c)` is a chain of cons cells. `(car node)` gives `:and`; `(cdr node)` gives `(a b c)`. The helper `node-op` and `node-args` just wrap those:

```lisp
(defun node-op   (node) (and (consp node) (car node)))
(defun node-args (node) (and (consp node) (cdr node)))
```

**Smart constructors** (`series`, `parallel`, `negate`) build the tree while keeping it flat. Instead of `(:and A (:and B C))` they produce `(:and A B C)`. The `%parts` helper does this: if a node already is an `:and`, just steal its children.

---

### `src/parser.lisp` — reading IL text

IL is a stack-based language. Each line is an instruction:

```
LD   A      ; push A onto accumulator
AND  B      ; accumulator = accumulator AND B
OR   C      ; accumulator = accumulator OR C
ST   Q      ; store accumulator into Q (emit a rung)
```

**Tokenizing** (`tokenize`) splits the text into `(mnemonic operand)` pairs:
```lisp
((:ld "A") (:and "B") (:or "C") (:st "Q"))
```

**Folding** (`fold-ops`) converts that flat list into the expression tree by maintaining an accumulator `acc` and a parenthesis stack `paren`:

```lisp
(let ((acc nil) (paren '()) (rungs '()))
  (dolist (op ops ...)
    (ecase m
      (:ld  (setf acc (contact operand :no)))         ; fresh start
      (:and (setf acc (series acc (contact ...))))    ; extend series
      (:or  (setf acc (parallel acc (contact ...))))  ; branch
      (:st  (emit :normal operand)))))                ; finish rung
```

`ecase` is like `switch` but signals an error on unknown values (safer than `case`).

The **pretty-printer** (`rung->il`, `program->il`) walks the tree back to IL text — this gives a free correctness test: parse → tree → print → parse → same tree (a "round-trip").

---

### `src/eval.lisp` — running the simulation

**Memory model** uses a `defstruct` with two hash tables:

```lisp
(defstruct memory
  (bits  (make-hash-table :test 'equal))   ; boolean operands
  (words (make-hash-table :test 'equal)))  ; numeric operands
```

`defstruct` auto-generates a constructor (`%make-memory`), slot accessors (`memory-bits`, `memory-words`), and a predicate (`memory-p`).

**Reading/writing memory:**
```lisp
(defun mem-bit (memory operand) ...)               ; getter
(defun (setf mem-bit) (value memory operand) ...)  ; setter
```

The `(setf mem-bit)` form defines a **generalized setter** — it means you can write `(setf (mem-bit m "Q") t)` which looks like assignment but calls your function. This is a powerful Common Lisp feature.

**Evaluating an expression** is a recursive tree-walk:
```lisp
(defun eval-expr (expr memory)
  (ecase (node-op expr)
    (:contact (mem-bit memory (contact-operand expr)))
    (:and (every (lambda (e) (eval-expr e memory)) (node-args expr)))
    (:or  (some  (lambda (e) (eval-expr e memory)) (node-args expr)))
    (:not (not (eval-expr (second expr) memory)))))
```

`every` returns `T` if all elements satisfy the predicate (AND). `some` returns non-nil if any element does (OR). Both short-circuit, just like in a real PLC.

**The scan cycle** is simply iterating over all rungs:
```lisp
(defun scan (program memory)
  (dolist (rung program) (execute-rung rung memory))
  memory)
```

**The `sim` struct** ties a program to its memory and tracks scan count.

---

### `src/layout.lisp` — computing where to draw things

This does **two passes** over the expression tree:

**Pass 1 (`expr-size`)** — bottom-up, returns `(width . height)` in grid cells:
- A single contact → `(2, 1)` (2 wide, 1 tall)
- `:and` (series) → sum the widths, take max height
- `:or` (parallel) → take max width, sum the heights

**Pass 2 (`layout-rung`)** — top-down, walks the tree again assigning `(x, y)` positions and emitting drawing commands:
```lisp
(:contact x y mode operand)   ; draw a contact at grid pos x,y
(:coil    x y kind operand)   ; draw a coil
(:wire    x1 y1 x2 y2)        ; draw a wire segment
```

This is **backend-agnostic** — neither SVG nor GUI code lives here. The layout engine just produces abstract grid coordinates.

---

### `src/svg.lisp` — writing SVG output

Converts grid coordinates to pixel coordinates using:
```lisp
(defun %px (grid) (+ *margin* (* grid *cell*)))
```

Then writes SVG XML using `format` with `~D` (integer) and `~A` (any value) directives. If a `memory` argument is passed, energized contacts/coils are drawn in green (`#1a7f37`) instead of gray.

---

### `verify.lisp` — standalone smoke test

Can be run without any dependencies:
```bash
sbcl --script verify.lisp
```

Uses a simple home-grown `check` macro:
```lisp
(defmacro check (form)
  `(if ,form
       (format t "  ok   ~S~%" ',form)
       (progn (incf *fails*) (format t "  FAIL ~S~%" ',form))))
```

The backtick `` ` `` starts a **quasiquote** (template), `,` splices in the value of an expression, and `'` quotes a form so it prints as source code rather than evaluating. This is how you write macros in Lisp — you build new code as a list.

---

### `examples/motor-seal-in.il` — the example program

A classic **motor start/stop latch** ("seal-in" circuit):

```
LD   %IX0.0      ; read Start button
OR   %QX0.0      ; OR with Run output (the "seal")
ANDN %IX0.1      ; AND NOT Stop button
ST   %QX0.0      ; write to Run coil
```

Once started (`IX0.0` goes true), the motor output `QX0.0` seals in its own signal so it stays on even after the button is released. Pressing Stop (`IX0.1`) breaks the AND and drops the output.

---

## Common Lisp concepts used throughout

| Concept | Where used | What it does |
|---|---|---|
| `defpackage` / `in-package` | package.lisp | Namespaces |
| `defstruct` | eval.lisp | Auto-generates struct, constructor, accessors |
| `defun (setf ...)` | eval.lisp | Defines a custom setter |
| `ecase` | parser.lisp, eval.lisp | Exhaustive `switch` (errors on unknown) |
| `labels` | layout.lisp | Local named functions (like `letrec`) |
| `flet` | parser.lisp | Local anonymous functions (like `let` for functions) |
| Quasiquote / macro | verify.lisp | Code-as-data template |
| `every` / `some` | eval.lisp | Short-circuiting AND / OR over sequences |
| `multiple-value-bind` | layout.lisp | Receive multiple return values |
| `with-open-file` | parser.lisp, svg.lisp | File I/O with automatic close |

The architecture is clean and idiomatic: pure data in, pure data out at each layer, no global mutable state except inside the `sim` struct, and no external dependencies in the core.
