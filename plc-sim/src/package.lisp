;;;; package.lisp --- Package definition for the PLC-SIM core.
;;;;
;;;; The core is intentionally dependency-free (plain ANSI Common Lisp) so it
;;;; can be loaded and tested without Quicklisp.  The McCLIM GUI lives in a
;;;; separate system (PLC-SIM-CLIM) and depends on this one.

(defpackage #:plc-sim
  (:use #:cl)
  (:documentation
   "IEC 61131-3 simulator core: IL parser, expression-tree IR, scan-cycle
    evaluator, and a backend-agnostic ladder-diagram layout engine.")
  (:export
   ;; --- IR (ir.lisp) ----------------------------------------------------
   #:contact #:series #:parallel #:negate
   #:contactp #:contact-mode #:contact-operand
   #:node-op #:node-args
   ;; --- Parser (parser.lisp) -------------------------------------------
   #:parse-il #:parse-il-string #:fold-ops #:tokenize
   ;; --- IL pretty-printer / round-trip (parser.lisp) -------------------
   #:rung->il #:program->il
   ;; --- Memory model + evaluator (eval.lisp) ---------------------------
   #:make-memory #:memory #:mem-bit #:mem-word
   #:eval-expr #:execute-rung #:scan
   #:make-sim #:sim #:sim-memory #:sim-program #:sim-running-p #:sim-scan-count
   #:load-il #:step-scan
   ;; --- Layout (layout.lisp) -------------------------------------------
   #:expr-size #:layout-rung #:layout-program
   ;; --- SVG renderer (svg.lisp) ----------------------------------------
   #:render-svg #:render-svg-to-file))
