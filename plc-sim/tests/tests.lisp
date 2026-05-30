;;;; tests.lisp --- FiveAM suite.   Run with:  (asdf:test-system "plc-sim")

(defpackage #:plc-sim/tests
  (:use #:cl #:fiveam #:plc-sim))

(in-package #:plc-sim/tests)

(def-suite plc-sim :description "plc-sim core suite.")
(in-suite plc-sim)

;;; ---------------------------------------------------------------------------
;;; IR
;;; ---------------------------------------------------------------------------

(test ir-series-flattens
  (is (equal '(:and (:contact :no "A") (:contact :no "B") (:contact :no "C"))
             (series (series (contact "A") (contact "B")) (contact "C"))))
  (is (equal '(:or (:contact :no "A") (:contact :no "B"))
             (parallel (contact "A") (contact "B")))))

(test ir-series-identity
  (is (equal (contact "A") (series nil (contact "A"))))
  (is (equal (contact "A") (series (contact "A") nil))))

(test ir-negate
  (is (equal '(:contact :nc "A") (negate (contact "A" :no))))
  (is (equal '(:contact :no "A") (negate (negate (contact "A")))))
  (is (equal '(:not (:and (:contact :no "A") (:contact :no "B")))
             (negate (series (contact "A") (contact "B"))))))

;;; ---------------------------------------------------------------------------
;;; Parser / fold
;;; ---------------------------------------------------------------------------

(test fold-precedence
  ;; (A AND B) OR C  -- OR applies to the whole running accumulator
  (is (equal '((:coil :normal "Q"
                (:or (:and (:contact :no "A") (:contact :no "B"))
                     (:contact :no "C"))))
             (parse-il-string "LD A
AND B
OR C
ST Q"))))

(test fold-parenthesized-block
  ;; A OR (B AND C)
  (is (equal '((:coil :normal "Q"
                (:or (:contact :no "A")
                     (:and (:contact :no "B") (:contact :no "C")))))
             (parse-il-string "LD A
OR( B
AND C
)
ST Q"))))

(test fold-and-not-two-words
  (is (equal '((:coil :normal "Q"
                (:and (:contact :no "A") (:contact :nc "B"))))
             (parse-il-string "LD A
AND NOT B
ST Q"))))

(test fold-set-reset
  (is (equal '((:coil :set "Q" (:contact :no "A")))
             (parse-il-string "LD A
S Q")))
  (is (equal '((:coil :reset "Q" (:contact :no "A")))
             (parse-il-string "LD A
R Q"))))

(test fold-multiple-rungs
  (is (= 4 (length (parse-il
                    (merge-pathnames
                     "examples/motor-seal-in.il"
                     (asdf:system-source-directory "plc-sim")))))))

(test parse-comments-and-blanks-ignored
  (is (equal (parse-il-string "LD A
ST Q")
             (parse-il-string "// header comment

LD A    // load
ST Q    ; trailing
"))))

;;; ---------------------------------------------------------------------------
;;; Round-trip:  tree -> IL -> tree  reaches a fixed point
;;; ---------------------------------------------------------------------------

(test round-trip-fixed-point
  (dolist (text '("LD A
AND B
OR C
ST Q"
                  "LD A
OR( B
AND C
)
ANDN D
ST Q"
                  "LD A
AND( B
OR C
)
ST Q"))
    (let ((p1 (parse-il-string text)))
      (is (equal p1 (parse-il-string (program->il p1)))
          "round-trip failed for:~%~A" text))))

;;; ---------------------------------------------------------------------------
;;; Evaluator
;;; ---------------------------------------------------------------------------

(defun eval1 (il &rest bits)
  "Parse a one-rung IL program, set BITS (name value name value ...), run one
scan, return the coil operand's value."
  (let* ((prog (parse-il-string il))
         (m (make-memory)))
    (loop for (name val) on bits by #'cddr do (setf (mem-bit m name) val))
    (scan prog m)
    (mem-bit m (third (first prog)))))

(test eval-and-or
  (is (eq t   (eval1 "LD A
AND B
OR C
ST Q" "A" t "B" t)))
  (is (eq nil (eval1 "LD A
AND B
OR C
ST Q" "A" t "B" nil)))
  (is (eq t   (eval1 "LD A
AND B
OR C
ST Q" "C" t))))

(test eval-normally-closed
  (is (eq t   (eval1 "LDN A
ST Q")))                ; A=nil -> NC true
  (is (eq nil (eval1 "LDN A
ST Q" "A" t))))

(test eval-empty-rail-is-true
  ;; An empty accumulator is a closed power rail (always-on coil).
  (is (eq t (eval-expr nil (make-memory)))))

(test eval-set-reset-latch
  (let ((prog (parse-il-string "LD SET_BTN
S Q"))
        (rst  (parse-il-string "LD RST_BTN
R Q"))
        (m (make-memory)))
    (setf (mem-bit m "SET_BTN") t) (scan prog m)
    (is (eq t (mem-bit m "Q")))
    (setf (mem-bit m "SET_BTN") nil) (scan prog m)
    (is (eq t (mem-bit m "Q")))       ; latch holds
    (setf (mem-bit m "RST_BTN") t) (scan rst m)
    (is (eq nil (mem-bit m "Q")))))

;;; ---------------------------------------------------------------------------
;;; Layout
;;; ---------------------------------------------------------------------------

(test layout-size-series-parallel
  ;; contacts are 2 cells wide; A AND B -> 4 wide, 1 tall
  (is (equal '(4 1)
             (multiple-value-list
              (expr-size (series (contact "A") (contact "B"))))))
  ;; A OR B   -> 2 wide, 2 tall
  (is (equal '(2 2)
             (multiple-value-list
              (expr-size (parallel (contact "A") (contact "B")))))))

(test layout-emits-contacts-and-coil
  (let ((prims (layout-rung (first (parse-il-string "LD A
AND B
OR C
ST Q")))))
    (is (= 3 (count :contact prims :key #'first)))
    (is (= 1 (count :coil prims :key #'first)))))
