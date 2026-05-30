;;;; eval.lisp --- Memory model, expression evaluator, and the scan cycle.
;;;;
;;;; The simulator's job each scan is: read inputs, evaluate every rung against
;;;; the shared memory, write outputs.  Because the IR is a boolean expression
;;;; tree, evaluation is a plain recursive tree-walk.
;;;;
;;;; Memory is modelled as named operands ("%IX0.0", "%QX0.0", "%MX1.2", ...).
;;;; A scaffold keeps a hash table of boolean bits and a hash table of words;
;;;; byte/bit-array addressing with offset arithmetic is a future refinement
;;;; (see README "Limitations").

(in-package #:plc-sim)

;;; ---------------------------------------------------------------------------
;;; Memory model
;;; ---------------------------------------------------------------------------

(defstruct (memory (:constructor %make-memory))
  (bits  (make-hash-table :test 'equal) :type hash-table)
  (words (make-hash-table :test 'equal) :type hash-table))

(defun make-memory () (%make-memory))

(defun %canon (operand)
  "Canonicalize an operand name (upcase, trim leading %) for hashing."
  (let ((s (string-upcase (string operand))))
    (if (and (plusp (length s)) (char= (char s 0) #\%))
        (subseq s 1)
        s)))

(defun mem-bit (memory operand)
  "Read boolean OPERAND from MEMORY (defaults to NIL/false)."
  (values (gethash (%canon operand) (memory-bits memory))))

(defun (setf mem-bit) (value memory operand)
  (setf (gethash (%canon operand) (memory-bits memory)) (and value t)))

(defun mem-word (memory operand)
  "Read numeric OPERAND from MEMORY (defaults to 0)."
  (values (gethash (%canon operand) (memory-words memory) 0)))

(defun (setf mem-word) (value memory operand)
  (setf (gethash (%canon operand) (memory-words memory)) value))

;;; ---------------------------------------------------------------------------
;;; Evaluation
;;; ---------------------------------------------------------------------------

(defun eval-expr (expr memory)
  "Evaluate an IR boolean expression EXPR against MEMORY, returning T or NIL.
An empty (NIL) expression evaluates to T (a closed power rail)."
  (cond
    ((null expr) t)
    ((consp expr)
     (ecase (node-op expr)
       (:contact
        (let ((v (mem-bit memory (contact-operand expr))))
          (if (eq (contact-mode expr) :nc) (not v) (and v t))))
       (:and (every (lambda (e) (eval-expr e memory)) (node-args expr)))
       (:or  (some  (lambda (e) (eval-expr e memory)) (node-args expr)))
       (:not (not (eval-expr (second expr) memory)))
       (:fb  (error "FB evaluation not implemented for ~S" expr))))
    (t (error "Not an IR expression: ~S" expr))))

(defun execute-rung (rung memory)
  "Evaluate RUNG and apply its coil to MEMORY.  Returns the rung's result."
  (destructuring-bind (tag kind operand expr) rung
    (declare (ignore tag))
    (let ((result (eval-expr expr memory)))
      (ecase kind
        (:normal (setf (mem-bit memory operand) result))
        (:set    (when result (setf (mem-bit memory operand) t)))
        (:reset  (when result (setf (mem-bit memory operand) nil))))
      result)))

(defun scan (program memory)
  "Execute one scan: evaluate every rung of PROGRAM against MEMORY in order."
  (dolist (rung program) (execute-rung rung memory))
  memory)

;;; ---------------------------------------------------------------------------
;;; The simulator object (ties a program to its memory)
;;; ---------------------------------------------------------------------------

(defstruct (sim (:constructor %make-sim))
  (program nil :type list)
  (memory (make-memory) :type memory)
  (running-p nil :type boolean)
  (scan-count 0 :type unsigned-byte))

(defun make-sim (&optional program)
  (%make-sim :program program))

(defun load-il (sim text-or-pathname)
  "Parse IL into SIM's program.  Accepts an IL string or a pathname."
  (setf (sim-program sim)
        (if (%looks-like-file-p text-or-pathname)
            (parse-il text-or-pathname)
            (parse-il-string text-or-pathname)))
  sim)

(defun %looks-like-file-p (x)
  "True when X should be opened as a file rather than parsed as IL text.
A pathname always counts; a string only if it has no newline and names an
existing regular file (not a directory)."
  (or (pathnamep x)
      (and (stringp x)
           (plusp (length x))
           (not (find #\Newline x))
           (let ((p (probe-file x)))
             (and p (pathname-name p))))))   ; nil pathname-name => a directory

(defun step-scan (sim)
  "Run one scan of SIM and bump the scan counter."
  (scan (sim-program sim) (sim-memory sim))
  (incf (sim-scan-count sim))
  sim)
