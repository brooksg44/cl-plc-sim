;;;; plc-sim.asd --- Core system: dependency-free ANSI Common Lisp.

(asdf:defsystem "plc-sim"
  :description "IEC 61131-3 simulator core: IL parser, expression-tree IR, scan evaluator, ladder layout, SVG renderer."
  :author "brooksg44 <brooksg44@gmail.com>"
  :license "MIT"
  :version "0.1.0"
  :depends-on ()                        ; intentionally zero external deps
  :serial t
  :components ((:module "src"
                :components ((:file "package")
                             (:file "ir")
                             (:file "parser")
                             (:file "eval")
                             (:file "layout")
                             (:file "svg"))))
  :in-order-to ((test-op (test-op "plc-sim/tests"))))

(asdf:defsystem "plc-sim/tests"
  :description "FiveAM test suite for plc-sim."
  :depends-on ("plc-sim" "fiveam")
  :serial t
  :components ((:module "tests"
                :components ((:file "tests"))))
  :perform (test-op (op c)
             (uiop:symbol-call :fiveam :run!
                               (uiop:find-symbol* '#:plc-sim :plc-sim/tests))))
