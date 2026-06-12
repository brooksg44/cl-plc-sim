# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An IEC 61131-3 PLC simulator in Common Lisp: parses Instruction List (IL), converts it to a Ladder Diagram, renders it (SVG or McCLIM GUI), and simulates the scan cycle. Two ASDF systems:

- `plc-sim` (plc-sim.asd) — the core. **Intentionally zero external dependencies** (plain ANSI CL); keep it that way so it loads without Quicklisp.
- `plc-sim-clim` (plc-sim-clim.asd) — McCLIM front-end, depends on the core.

## Commands

```sh
# Dependency-free smoke test (no Quicklisp needed; exits 1 on failure)
sbcl --script verify.lisp

# Full FiveAM suite
sbcl --non-interactive \
  --eval '(push (truename ".") asdf:*central-registry*)' \
  --eval '(ql:quickload "fiveam" :silent t)' \
  --eval '(asdf:test-system "plc-sim")'

# Single test (after loading the "plc-sim/tests" system)
(fiveam:run! 'plc-sim/tests::ton-delays-then-fires-then-resets)

# Regenerate docs/ ladder images (SVGs always; PNGs only if qlmanage exists)
sbcl --script make-docs.lisp

# GUI (needs XQuartz on macOS; DISPLAY=:0, not the launchd socket path)
DISPLAY=:0 sbcl --load load-clim.lisp
# then: (plc-sim-clim:run :il #p"examples/motor-seal-in.il")
```

`load-clim.lisp` contains a shim re-creating `CL-PPCRE:*STANDARD-OPTIMIZE-SETTINGS*` before McCLIM loads (Quicklisp dist 2026-01-01 packaging bug between cl-ppcre and cl-unicode). Don't remove it until upstream is fixed.

## Architecture: one IR, four consumers

The entire system pivots on a single intermediate representation — a boolean expression tree built from plain lists (so it prints readably at the REPL):

```
IL text ──parse──▶ Expression Tree ──┬──evaluate──▶ Simulation state   (eval.lisp)
                                     ├──layout────▶ LD primitives ──▶ SVG / McCLIM
                                     └──print─────▶ IL  (round-trip validation)
```

Node forms (defined in `src/ir.lisp` header comments): boolean — `(:contact :no|:nc op)`, n-ary `(:and …)` / `(:or …)` (smart constructors `series`/`parallel` flatten associatively and reject numeric args), `(:not …)`, `(:cmp :gt|… <v> <v>)` (a comparison leaf, contact-like), `(:fb …)` (reserved for CAL; evaluator intentionally errors on it); numeric value expressions — `(:lit n)`, `(:word "spelling")` (original spelling kept; eval strips `.CV`/`.ET` via `%word-key`), `(:arith :add|… v v …)` (left-folded, same-op flattened, so right-args are always leaves — that's what lets the printer linearize back to flat IL). A rung is `(:coil <kind> <operand> <expr> [<preset>])` (kind `:normal`/`:set`/`:reset` or timer/counter `:ton :tof :tp :ctu :ctd` carrying the preset) or `(:assign <dst> <value-expr>)` — a numeric store that runs **unconditionally every scan** (IEC semantics; conditional stores need JMP, not implemented). Rung consumers (`execute-rung`, `layout-rung`/`layout-program`, `rung->il`) dispatch on the rung's first element.

**Round-trip is a fixed point**: `parse-il-string` → `program->il` → `parse-il-string` must yield an `equal` tree. Tests and verify.lisp assert this; any parser or pretty-printer change must preserve it.

### Load order is maintained in three places

`src/` files load serially: `package → ir → parser → eval → layout → svg`. This order is hardcoded in `plc-sim.asd`, **and also in `verify.lisp` and `make-docs.lisp`** (both load src/ manually to stay Quicklisp-free). Adding or renaming a source file means updating all three.

### Simulation model (eval.lisp)

- Memory is two name→value hash tables (bits and words); `%canon` upcases and strips the leading `%`, so `"%IX0.0"` and `"IX0.0"` are the same operand.
- **The time base is sim milliseconds, sampled once per scan boundary** (`%begin-scan`): all rungs in a scan see the same timestamp. With `time-fn` nil (the default) the clock is frozen virtual time — each scan advances `clock-ms` by `scan-period-ms` (default 1000, so one manual Scan = one second, keeping stepping and tests deterministic). `sim-start-realtime`/`sim-stop-realtime` switch to/from a wall-clock `time-fn` (used by the GUI's Run mode; tests inject fake time-fns instead of sleeping). Timers advance by the scan's `memory-dt-ms`; timer presets are IEC TIME literals (`T#5s`) or bare-integer ms, counter presets are counts.
- The GUI's Run command free-runs via a bordeaux-threads ticker that only queues `tick-event`s onto the frame's event queue (`handle-event` scans + redisplays in the frame's own process) — there is no locking. Keep it that way: never touch the sim directly from a background thread, and don't route ticks through `execute-frame-command`/the command loop — that echoes next to the interactor's `Command:` prompt and makes it untypable.
- Timer/counter instance state lives in ordinary memory under the instance name (done bit + elapsed/count word) plus internal keys suffixed with `#` (e.g. `"T1#P"` for edge detection, `"C1#PV"` for CTD reload). `#` can't appear in an IL operand, so no collisions; UIs filter `#` keys out of I/O panels.
- The `sim` struct tracks `next-rung` for single-stepping: `step-rung` runs one rung, `step-scan` completes the current scan (all rungs at a boundary, the remainder mid-flight), `stabilize` runs scans to quiescence comparing **bits only** — deliberately, so it never fast-forwards a running timer to its preset.

### Layout/rendering

`layout.lisp` is a two-pass engine producing backend-agnostic primitives (`(:contact …)`, `(:coil …)`, `(:wire …)` …); `svg.lisp` and `clim-ui.lisp` are pure consumers of those primitives. Rendering changes usually belong in layout, not in both backends.

## Conventions

- The README's example programs in `examples/` are load-bearing documentation: the two motor examples demonstrate the one-scan stale-lamp transient (seal-in with RESET coil) vs. its fix (series interlock), and the docs/ images are rendered from specific scan states by `make-docs.lisp`. If you change examples or rendering, rerun `sbcl --script make-docs.lisp` and keep the README's narrative in sync.
- Both Siemens STL and IEC mnemonics are accepted (`A`/`AND`, `O`/`OR`, `=`/`ST`, …); see the README dialect table before touching the tokenizer.
- File headers carry substantial design commentary (ir.lisp, eval.lisp especially) — keep them current when changing behavior.
