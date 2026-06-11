;;;; ir.lisp --- The intermediate representation: a boolean expression tree.
;;;;
;;;; This single tree is the hub of the whole system:
;;;;   * the IL parser builds it,
;;;;   * the evaluator walks it each scan,
;;;;   * the layout engine renders it as ladder geometry,
;;;;   * the pretty-printer turns it back into IL (free round-trip validation).
;;;;
;;;; Node forms (plain lists, so they print readably at the REPL):
;;;;
;;;;   (:contact <mode> <operand>)   mode is :NO (normally open  --| |--)
;;;;                                          or :NC (normally closed --|/|--)
;;;;   (:and <expr> <expr> ...)      elements in SERIES   (horizontal)
;;;;   (:or  <expr> <expr> ...)      elements in PARALLEL (vertical branch)
;;;;   (:not <expr>)                 boolean negation of a sub-expression
;;;;   (:fb <name> <operand> ...)    function-block / non-boolean box
;;;;
;;;; A rung (one ladder row) is:
;;;;
;;;;   (:coil <kind> <operand> <expr> [<preset>])
;;;;
;;;; kind is :NORMAL, :SET, or :RESET for plain coils, or a timer/counter kind
;;;; (:TON :TOF :TP :CTU :CTD) -- those carry the extra <preset>: milliseconds
;;;; of sim time for timers, an edge count for counters.

(in-package #:plc-sim)

;;; ---------------------------------------------------------------------------
;;; Accessors
;;; ---------------------------------------------------------------------------

(declaim (inline node-op node-args))
(defun node-op (node) (and (consp node) (car node)))
(defun node-args (node) (and (consp node) (cdr node)))

(defun contactp (node)
  (and (consp node) (eq (car node) :contact)))

(defun timer-kind-p (kind)
  "True for coil kinds whose preset is a duration in milliseconds (timers),
as opposed to an edge count (counters)."
  (and (member kind '(:ton :tof :tp)) t))

(defun contact-mode (node) (second node))
(defun contact-operand (node) (third node))

;;; ---------------------------------------------------------------------------
;;; Smart constructors
;;;
;;; SERIES and PARALLEL flatten associatively so that e.g. a chain of three
;;; ANDs becomes (:and a b c) rather than (:and a (:and b c)).  Flat n-ary
;;; nodes keep the layout engine simple and the printed IR readable.
;;; ---------------------------------------------------------------------------

(defun contact (operand &optional (mode :no))
  "Construct a contact node for OPERAND.  MODE is :NO (default) or :NC."
  (check-type mode (member :no :nc))
  (list :contact mode operand))

(defun %parts (node op)
  "If NODE is an OP node, return its arguments; otherwise the singleton list."
  (if (and (consp node) (eq (car node) op))
      (cdr node)
      (list node)))

(defun series (a b)
  "Combine A and B in series (logical AND).  NIL acts as identity so callers
can fold an empty accumulator."
  (cond ((null a) b)
        ((null b) a)
        (t (cons :and (append (%parts a :and) (%parts b :and))))))

(defun parallel (a b)
  "Combine A and B in parallel (logical OR).  NIL acts as identity."
  (cond ((null a) b)
        ((null b) a)
        (t (cons :or (append (%parts a :or) (%parts b :or))))))

(defun negate (expr)
  "Logical negation.  For a single contact we flip its mode; for anything
else we wrap it in a :NOT node."
  (cond ((null expr) nil)
        ((contactp expr)
         (contact (contact-operand expr)
                  (if (eq (contact-mode expr) :no) :nc :no)))
        ((eq (node-op expr) :not) (second expr)) ; double negation
        (t (list :not expr))))
