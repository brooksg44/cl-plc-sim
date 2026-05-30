;;;; parser.lisp --- IL tokenizer, the stack-machine fold, and IL pretty-print.
;;;;
;;;; IL is a 1-D stack machine; ladder is a 2-D planar graph.  The crux of the
;;;; whole project is FOLD-OPS, which reconstructs the boolean expression tree
;;;; that the stack program encodes:
;;;;
;;;;   AND   -> series   (horizontal)
;;;;   OR    -> parallel (vertical branch)
;;;;   A( O( -> push the accumulator, start a fresh sub-expression
;;;;   )     -> pop and combine
;;;;   ST/S/R-> terminate the rung with a coil
;;;;
;;;; Both Siemens STL mnemonics (A, AN, O, ON, =, A(, O()  and IEC textual IL
;;;; mnemonics (AND, ANDN, OR, ORN, ST, AND(, OR()  are accepted.

(in-package #:plc-sim)

;;; ---------------------------------------------------------------------------
;;; Tokenizing
;;; ---------------------------------------------------------------------------

(defparameter *whitespace* '(#\Space #\Tab #\Return #\Linefeed))

(defun %strip-comment (line)
  "Remove a trailing // or (* ... *)-free ; comment from LINE."
  (let ((p (or (search "//" line) (position #\; line))))
    (if p (subseq line 0 p) line)))

(defun %split-ws (string)
  "Split STRING on runs of whitespace, dropping empties."
  (loop with len = (length string)
        with start = 0
        for i = (position-if (lambda (c) (member c *whitespace*)) string
                             :start start)
        when (and i (> i start)) collect (subseq string start i)
        when (and (null i) (< start len)) collect (subseq string start)
        while i
        do (setf start (1+ i))))

(defparameter *mnemonics*
  ;; canonical-keyword  <-  set of accepted spellings
  '((:ld        "LD" "L")
    (:ldn       "LDN" "LN")
    (:and       "AND" "A" "&")
    (:andn      "ANDN" "AN")
    (:or        "OR" "O")
    (:orn       "ORN" "ON")
    (:and-open  "AND(" "A(")
    (:or-open   "OR(" "O(")
    (:close     ")")
    (:st        "ST" "=" ":=")
    (:stn       "STN")
    (:s         "S" "SET")
    (:r         "R" "RESET"))
  "Mapping from canonical op keyword to accepted source spellings.")

(defun %normalize-mnemonic (word)
  "Return the canonical keyword for the mnemonic WORD, or NIL if unknown."
  (let ((up (string-upcase word)))
    (loop for (kw . spellings) in *mnemonics*
          when (member up spellings :test #'string=)
            do (return kw))))

(defun %parse-line (line)
  "Parse one source LINE into (mnemonic operand) or NIL for blank/comment/label.
A leading \"NETWORK ...\" marker or a bare \"name:\" label returns
the keyword :NETWORK so the caller can split rungs on it."
  (let* ((clean (string-trim *whitespace* (%strip-comment line))))
    (when (plusp (length clean))
      (let* ((parts (%split-ws clean))
             (head (first parts)))
        (cond
          ;; explicit network / label boundary
          ((string-equal head "NETWORK") (list :network nil))
          ((and (= (length parts) 1)
                (char= (char head (1- (length head))) #\:))
           (list :network nil))
          ;; "AND NOT" / "OR NOT" written as two words
          ((and (>= (length parts) 2)
                (member (string-upcase head) '("AND" "OR" "A" "O") :test #'string=)
                (string-equal (second parts) "NOT"))
           (list (if (member (string-upcase head) '("AND" "A") :test #'string=)
                     :andn :orn)
                 (third parts)))
          (t
           (let ((kw (%normalize-mnemonic head)))
             (unless kw
               (error "Unknown IL mnemonic ~S in line: ~A" head line))
             (list kw (second parts)))))))))

(defun tokenize (text)
  "Tokenize IL TEXT into a list of (mnemonic operand) ops, dropping blanks."
  (loop for line in (uiop-lines text)
        for op = (%parse-line line)
        when op collect op))

(defun uiop-lines (text)
  "Split TEXT into lines without depending on UIOP."
  (loop with start = 0
        for nl = (position #\Newline text :start start)
        collect (subseq text start (or nl (length text)))
        while nl do (setf start (1+ nl))))

;;; ---------------------------------------------------------------------------
;;; The fold: ops -> list of rung trees   (the heart of IL -> LD)
;;; ---------------------------------------------------------------------------

(defun fold-ops (ops)
  "Fold a flat op list into a list of rung trees (each a :COIL node).

Maintains the IL accumulator ACC and a PAREN stack for A( / O( blocks.  A
store (ST/S/R) emits a rung; the accumulator persists afterward, matching the
PLC RLO semantics where a fresh LD is what restarts a rung."
  (let ((acc nil) (paren '()) (rungs '()))
    (flet ((emit (kind operand)
             (push (list :coil kind operand acc) rungs)))
      (dolist (op ops (nreverse rungs))
        (destructuring-bind (m &optional operand) op
          (ecase m
            (:network  (setf acc nil paren '())) ; defensive boundary reset
            (:ld   (setf acc (contact operand :no)))
            (:ldn  (setf acc (contact operand :nc)))
            (:and  (setf acc (series acc (contact operand :no))))
            (:andn (setf acc (series acc (contact operand :nc))))
            (:or   (setf acc (parallel acc (contact operand :no))))
            (:orn  (setf acc (parallel acc (contact operand :nc))))
            ;; A(/O( open a deferred sub-expression.  Per IEC IL an operand may
            ;; ride along ("OR( B" starts the block already holding B); without
            ;; one the block starts empty and the next LD seeds it.
            (:and-open (push (cons :and acc) paren)
                       (setf acc (and operand (contact operand :no))))
            (:or-open  (push (cons :or  acc) paren)
                       (setf acc (and operand (contact operand :no))))
            (:close
             (when (null paren)
               (error "Unbalanced ) in IL: no open block"))
             (destructuring-bind (comb . saved) (pop paren)
               (setf acc (if (eq comb :and)
                             (series saved acc)
                             (parallel saved acc)))))
            (:st  (emit :normal operand))
            (:stn (let ((acc (negate acc))) (emit :normal operand)))
            (:s   (emit :set   operand))
            (:r   (emit :reset operand))))))))

(defun parse-il-string (text)
  "Parse IL TEXT into a program: a list of rung trees."
  (fold-ops (tokenize text)))

(defun parse-il (pathname)
  "Parse the IL file at PATHNAME into a program."
  (with-open-file (s pathname :direction :input)
    (let ((text (make-string (file-length s))))
      (read-sequence text s)
      (parse-il-string text))))

;;; ---------------------------------------------------------------------------
;;; Pretty-printer: expr tree -> IL  (inverse of the fold)
;;;
;;; Linearizing the tree back to a stack program gives us a cheap, powerful
;;; test: parse -> tree -> print -> parse should reach a fixed point.
;;; ---------------------------------------------------------------------------

(defun %il-load (expr)
  "Ops (as (mnemonic operand) lists) that LOAD EXPR onto a fresh accumulator."
  (ecase (node-op expr)
    (:contact
     (list (list (if (eq (contact-mode expr) :nc) :ldn :ld)
                 (contact-operand expr))))
    (:not (append (%il-load (second expr)) (list (list :not nil))))
    ((:and :or)
     (let ((parts (node-args expr))
           (combiner (if (eq (node-op expr) :and) :and :or)))
       (append (%il-load (first parts))
               (loop for p in (rest parts)
                     append (%il-combine combiner p)))))))

(defun %il-combine (combiner expr)
  "Ops that combine EXPR into the accumulator using COMBINER (:AND or :OR)."
  (if (contactp expr)
      (let ((nc (eq (contact-mode expr) :nc)))
        (list (list (ecase combiner
                      (:and (if nc :andn :and))
                      (:or  (if nc :orn  :or)))
                    (contact-operand expr))))
      ;; a block: parenthesize
      (append (list (list (ecase combiner (:and :and-open) (:or :or-open)) nil))
              (%il-load expr)
              (list (list :close nil)))))

(defun %mnemonic-string (kw)
  (ecase kw
    (:ld "LD") (:ldn "LDN") (:and "AND") (:andn "ANDN")
    (:or "OR") (:orn "ORN") (:and-open "AND(") (:or-open "OR(")
    (:close ")") (:st "ST") (:s "S") (:r "R") (:not "NOT")))

(defun rung->il (rung &key (stream nil))
  "Return (or print to STREAM) the IL text for one RUNG (:COIL node)."
  (destructuring-bind (tag kind operand expr) rung
    (declare (ignore tag))
    (let* ((load-ops (%il-load expr))
           (store (ecase kind (:normal :st) (:set :s) (:reset :r)))
           (lines (append (mapcar (lambda (op)
                                    (destructuring-bind (m operand) op
                                      (if operand
                                          (format nil "~A ~A"
                                                  (%mnemonic-string m) operand)
                                          (%mnemonic-string m))))
                                  load-ops)
                          (list (format nil "~A ~A"
                                        (%mnemonic-string store) operand)))))
      (if stream
          (dolist (l lines) (write-line l stream))
          (format nil "~{~A~%~}" lines)))))

(defun program->il (program &key (stream nil))
  "Return (or print) IL text for a whole PROGRAM, networks separated."
  (with-output-to-string (s)
    (let ((out (or stream s)))
      (loop for rung in program
            for i from 1
            do (format out "NETWORK ~D~%" i)
               (rung->il rung :stream out)
               (terpri out)))))
