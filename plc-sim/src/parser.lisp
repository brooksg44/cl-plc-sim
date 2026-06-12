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
;;;;   TON/TOF/TP/CTU/CTD -> terminate the rung with a timer/counter box,
;;;;          e.g. "TON T1, T#5s".  Timer presets are IEC TIME literals
;;;;          (T#5s, T#500ms, T#1m30s) or bare integers meaning milliseconds;
;;;;          counter presets are plain integer counts (see eval.lisp)
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
    (:r         "R" "RESET")
    (:ton       "TON")
    (:tof       "TOF")
    (:tp        "TP")
    (:ctu       "CTU")
    (:ctd       "CTD")
    (:not       "NOT")
    (:add       "ADD")
    (:sub       "SUB")
    (:mul       "MUL")
    (:div       "DIV")
    (:gt        "GT")
    (:ge        "GE")
    (:eq        "EQ")
    (:ne        "NE")
    (:le        "LE")
    (:lt        "LT")
    (:move      "MOVE"))
  "Mapping from canonical op keyword to accepted source spellings.")

(defparameter *arith-kinds* '(:add :sub :mul :div)
  "Accumulator arithmetic: combine the numeric accumulator with an operand.")

(defparameter *cmp-kinds* '(:gt :ge :eq :ne :le :lt)
  "Comparisons: numeric accumulator vs operand, leaving a BOOLEAN result.")

(defparameter *fb-kinds* '(:ton :tof :tp :ctu :ctd)
  "Rung-terminating instructions that take an instance name AND a preset.")

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
             (cond ((member kw *fb-kinds*)
                    (%parse-fb-args kw (rest parts) line))
                   ((eq kw :move)
                    (%parse-move-args (rest parts) line))
                   (t (list kw (second parts)))))))))))

(defun %parse-move-args (args line)
  "Parse MOVE's arguments, \"src, dst\" (comma optional), into (:MOVE src dst).
MOVE is sugar for LD src / ST dst -- the pretty-printer canonicalizes it away."
  (let ((args (%split-ws (substitute #\Space #\, (format nil "~{~A~^ ~}" args)))))
    (unless (= (length args) 2)
      (error "MOVE needs a source and a destination, e.g. \"MOVE 5, %MW0\", ~
              in line: ~A" line))
    (list* :move args)))

(defun %parse-fb-args (kw args line)
  "Parse a timer/counter line's arguments: \"T1, T#5s\" (comma optional) into
(KW \"T1\" 5000).  A timer preset is an IEC TIME literal or a bare integer
meaning milliseconds; a counter preset is a plain integer count."
  (let ((args (%split-ws (substitute #\Space #\, (format nil "~{~A~^ ~}" args)))))
    (unless (= (length args) 2)
      (error "~A needs an instance and a preset, e.g. \"~:*~A T1, ~A\", in line: ~A"
             (string kw) (if (timer-kind-p kw) "T#5s" "5") line))
    (destructuring-bind (instance preset) args
      (list kw instance
            (cond ((and (timer-kind-p kw) (%parse-time-literal preset)))
                  (t (handler-case (parse-integer preset)
                       (error ()
                         (error "Preset must be ~A, got ~S in line: ~A"
                                (if (timer-kind-p kw)
                                    "a TIME literal (T#5s) or integer milliseconds"
                                    "an integer count")
                                preset line)))))))))

;;; ---------------------------------------------------------------------------
;;; IEC TIME literals (timer presets): T#5s, T#500ms, T#1m30s, T#1.5s
;;; ---------------------------------------------------------------------------

(defparameter *time-units*
  ;; longest spelling first so "MS" is not consumed as "M" + garbage
  '(("MS" . 1) ("S" . 1000) ("M" . 60000) ("H" . 3600000) ("D" . 86400000))
  "TIME-literal unit suffixes and their value in milliseconds.")

(defun %parse-decimal (string)
  "Parse \"5\" or \"1.5\" into an exact rational, or NIL if malformed."
  (let ((dot (position #\. string)))
    (handler-case
        (if dot
            (let ((frac (subseq string (1+ dot))))
              (+ (if (zerop dot) 0 (parse-integer string :end dot))
                 (if (zerop (length frac))
                     0
                     (/ (parse-integer frac) (expt 10 (length frac))))))
            (parse-integer string))
      (error () nil))))

(defun %parse-time-literal (string)
  "Parse an IEC TIME literal -- \"T#5s\", \"TIME#1m30s\", \"T#1.5s\", with
optional underscore separators -- into total milliseconds (rounded).  Returns
NIL when STRING does not start with T#/TIME#; signals an error on a malformed
body (so \"T#5x\" is rejected rather than silently treated as an operand)."
  (let* ((up (remove #\_ (string-upcase string)))
         (body (cond ((and (> (length up) 5) (string= "TIME#" up :end2 5))
                      (subseq up 5))
                     ((and (> (length up) 2) (string= "T#" up :end2 2))
                      (subseq up 2))
                     (t (return-from %parse-time-literal nil)))))
    (loop with i = 0 and len = (length body) and total = 0
          while (< i len)
          do (let* ((num-end (or (position-if #'alpha-char-p body :start i) len))
                    (unit-end (or (position-if-not #'alpha-char-p body
                                                   :start num-end)
                                  len))
                    (value (%parse-decimal (subseq body i num-end)))
                    (factor (cdr (assoc (subseq body num-end unit-end)
                                        *time-units* :test #'string=))))
               (unless (and value factor)
                 (error "Malformed TIME literal ~S" string))
               (incf total (round (* value factor)))
               (setf i unit-end))
          finally (return total))))

(defun format-time-literal (ms)
  "Canonical TIME literal for MS milliseconds, using the largest unit that
divides evenly: 5000 -> \"T#5s\", 90000 -> \"T#90s\", 120000 -> \"T#2m\",
500 -> \"T#500ms\".  The pretty-printer's inverse of %PARSE-TIME-LITERAL."
  (loop for (unit . factor) in '(("d" . 86400000) ("h" . 3600000)
                                 ("m" . 60000) ("s" . 1000))
        when (and (plusp ms) (zerop (mod ms factor)))
          do (return (format nil "T#~D~A" (floor ms factor) unit))
        finally (return (format nil "T#~Dms" ms))))

(defun format-duration (ms)
  "Compact human form of MS milliseconds for instruction-box display:
300 -> \"300ms\", 5000 -> \"5s\", 1500 -> \"1.5s\"."
  (cond ((< ms 1000) (format nil "~Dms" ms))
        ((zerop (mod ms 1000)) (format nil "~Ds" (floor ms 1000)))
        (t (format nil "~,1Fs" (/ ms 1000.0)))))

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
;;; Value operands (numeric accumulator support)
;;; ---------------------------------------------------------------------------

(defun %int-literal (s)
  "S parsed as an integer literal, or NIL."
  (and s (handler-case (parse-integer s) (error () nil))))

(defun %cv-suffix-p (s)
  "True when S ends in .CV or .ET -- IEC access to a timer/counter's current
value (\"C1.CV\", \"T1.ET\").  %IX0.0-style bit addresses don't match."
  (let ((dot (position #\. s :from-end t)))
    (and dot (member (string-upcase (subseq s (1+ dot))) '("CV" "ET")
                     :test #'string=))))

(defun %word-address-p (s)
  "True for IEC word-size direct addresses: %MW0, %IW2, %QW1 (size letter W)."
  (and (> (length s) 3)
       (char= (char s 0) #\%)
       (member (char-upcase (char s 1)) '(#\M #\I #\Q))
       (char= (char-upcase (char s 2)) #\W)))

(defun %numeric-load-p (s)
  "Should LD of S start a NUMERIC accumulator?  Literals, .CV/.ET access and
word-size addresses are unambiguously numeric; anything else loads a contact."
  (and s
       (or (%int-literal s) (%cv-suffix-p s) (%word-address-p s))
       t))

(defun %value-operand (s)
  "Classify S in a VALUE position (arith/cmp operand, MOVE source): a literal
or a word reference.  Plain names are words here -- the position demands a
number, so there is no ambiguity with contacts."
  (let ((n (%int-literal s)))
    (if n (list :lit n) (list :word s))))

(defun %as-value (acc op-name)
  "Coerce the accumulator ACC to a value expression for OP-NAME.  A lone
normally-open contact leaf re-reads as a word (LD X / ADD 1 means word X);
boolean structure cannot."
  (cond ((value-expr-p acc) acc)
        ((and (contactp acc) (eq (contact-mode acc) :no))
         (list :word (contact-operand acc)))
        (t (error "~A needs a numeric accumulator, got ~S" op-name acc))))

;;; ---------------------------------------------------------------------------
;;; The fold: ops -> list of rung trees   (the heart of IL -> LD)
;;; ---------------------------------------------------------------------------

(defun fold-ops (ops)
  "Fold a flat op list into a list of rung trees (:COIL or :ASSIGN nodes).

Maintains the IL accumulator ACC -- boolean tree or numeric value expression,
IL's polymorphic current result -- and a PAREN stack for A( / O( blocks.  A
store (ST/S/R) emits a rung; the accumulator persists afterward, matching the
PLC RLO semantics where a fresh LD is what restarts a rung.  Numeric stores
emit :ASSIGN rungs that execute unconditionally each scan (IEC semantics;
conditional stores would need JMP)."
  (let ((acc nil) (paren '()) (rungs '()))
    (flet ((emit (kind operand &optional preset (expr acc))
             ;; PRESET (timers/counters only) rides along as a 5th element so
             ;; plain coils keep their original 4-element shape.
             (%check-boolean expr (format nil "Storing to ~A" operand))
             (push (if preset
                       (list :coil kind operand expr preset)
                       (list :coil kind operand expr))
                   rungs))
           (emit-assign (dst value)
             (when (%int-literal dst)
               (error "Cannot store to the literal ~A" dst))
             (push (list :assign dst value) rungs)))
      (dolist (op ops (nreverse rungs))
        (destructuring-bind (m &optional operand preset) op
          (ecase m
            (:network  (setf acc nil paren '())) ; defensive boundary reset
            (:ld   (setf acc (if (%numeric-load-p operand)
                                 (%value-operand operand)
                                 (contact operand :no))))
            (:ldn  (setf acc (contact operand :nc)))
            (:and  (setf acc (series acc (contact operand :no))))
            (:andn (setf acc (series acc (contact operand :nc))))
            (:or   (setf acc (parallel acc (contact operand :no))))
            (:orn  (setf acc (parallel acc (contact operand :nc))))
            (:not  (setf acc (negate acc)))
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
            ;; numeric accumulator: arithmetic left-folds (same op flattens);
            ;; a comparison consumes it and leaves a BOOLEAN result, so
            ;; numeric state can gate coils like a contact
            ((:add :sub :mul :div)
             (let ((a (%as-value acc (symbol-name m)))
                   (b (%value-operand operand)))
               (setf acc (if (and (eq (node-op a) :arith) (eq (second a) m))
                             (append a (list b))
                             (list :arith m a b)))))
            ((:gt :ge :eq :ne :le :lt)
             (setf acc (list :cmp m
                             (%as-value acc (symbol-name m))
                             (%value-operand operand))))
            (:move                      ; sugar: LD operand / ST preset(=dst)
             (setf acc (%value-operand operand))
             (emit-assign preset acc))
            (:st  (cond ((value-expr-p acc)
                         (emit-assign operand acc))
                        ;; a word-size destination demands a value: coerce a
                        ;; lone contact leaf (LD A / ST %MW0 copies word A)
                        ((or (%word-address-p operand) (%cv-suffix-p operand))
                         (emit-assign operand
                                      (%as-value acc (format nil "ST ~A" operand))))
                        (t (emit :normal operand))))
            (:stn (emit :normal operand nil (negate acc)))
            (:s   (emit :set   operand))
            (:r   (emit :reset operand))
            ;; timers/counters terminate a rung like a coil; their stateful
            ;; semantics live in eval.lisp
            ((:ton :tof :tp :ctu :ctd) (emit m operand preset))))))))

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

(defun %value-string (v)
  "The IL operand spelling of a LEAF value expression."
  (ecase (car v)
    (:lit (princ-to-string (second v)))
    (:word (second v))
    (:arith (error "Cannot linearize the nested right-argument ~S to flat IL ~
                    (the fold is left-associative, so this tree did not come ~
                    from PARSE-IL)" v))))

(defun %il-load-value (v)
  "Ops that load value expression V into a fresh numeric accumulator."
  (ecase (car v)
    ((:lit :word) (list (list :ld (%value-string v))))
    (:arith
     (destructuring-bind (op . args) (cdr v)
       (append (%il-load-value (first args))
               (loop for a in (rest args)
                     collect (list op (%value-string a))))))))

(defun %il-load (expr)
  "Ops (as (mnemonic operand) lists) that LOAD EXPR onto a fresh accumulator."
  (ecase (node-op expr)
    (:contact
     (list (list (if (eq (contact-mode expr) :nc) :ldn :ld)
                 (contact-operand expr))))
    (:cmp
     (destructuring-bind (op a b) (node-args expr)
       (append (%il-load-value a)
               (list (list op (%value-string b))))))
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
    (:close ")") (:st "ST") (:s "S") (:r "R") (:not "NOT")
    (:ton "TON") (:tof "TOF") (:tp "TP") (:ctu "CTU") (:ctd "CTD")
    (:add "ADD") (:sub "SUB") (:mul "MUL") (:div "DIV")
    (:gt "GT") (:ge "GE") (:eq "EQ") (:ne "NE") (:le "LE") (:lt "LT")))

(defun %op-lines (ops)
  "Format (mnemonic operand) op lists as IL source lines."
  (mapcar (lambda (op)
            (destructuring-bind (m operand) op
              (if operand
                  (format nil "~A ~A" (%mnemonic-string m) operand)
                  (%mnemonic-string m))))
          ops))

(defun %coil-lines (rung)
  (destructuring-bind (tag kind operand expr &optional preset) rung
    (declare (ignore tag))
    (append
     (%op-lines (%il-load expr))
     (list (if preset
               (format nil "~A ~A, ~A" (%mnemonic-string kind) operand
                       (if (timer-kind-p kind)
                           (format-time-literal preset)
                           preset))
               (format nil "~A ~A"
                       (%mnemonic-string
                        (ecase kind (:normal :st) (:set :s) (:reset :r)))
                       operand))))))

(defun %assign-lines (rung)
  (destructuring-bind (dst v) (rest rung)
    (append (%op-lines (%il-load-value v))
            (list (format nil "ST ~A" dst)))))

(defun rung->il (rung &key (stream nil))
  "Return (or print to STREAM) the IL text for one RUNG (:COIL or :ASSIGN)."
  (let ((lines (ecase (first rung)
                 (:coil (%coil-lines rung))
                 (:assign (%assign-lines rung)))))
    (if stream
        (dolist (l lines) (write-line l stream))
        (format nil "~{~A~%~}" lines))))

(defun program->il (program &key (stream nil))
  "Return (or print) IL text for a whole PROGRAM, networks separated."
  (with-output-to-string (s)
    (let ((out (or stream s)))
      (loop for rung in program
            for i from 1
            do (format out "NETWORK ~D~%" i)
               (rung->il rung :stream out)
               (terpri out)))))
