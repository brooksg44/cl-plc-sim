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
  (words (make-hash-table :test 'equal) :type hash-table)
  ;; Sim-time elapsed over the current scan, in milliseconds.  Set at each
  ;; scan boundary by the sim's clock (see %BEGIN-SCAN); timers advance by it.
  ;; Lives on MEMORY so EXECUTE-RUNG's (rung memory) signature stays put.
  (dt-ms 1000 :type unsigned-byte))

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

(defun %word-key (name)
  "Memory key for a :WORD reference: a .CV/.ET suffix is IEC access to a
timer/counter's current value, which lives under the bare instance name
(\"C1.CV\" -> word \"C1\").  %CANON handles the % prefix and case."
  (let ((dot (position #\. name :from-end t)))
    (if (and dot (member (string-upcase (subseq name (1+ dot))) '("CV" "ET")
                         :test #'string=))
        (subseq name 0 dot)
        name)))

(defun eval-value (v memory)
  "Evaluate value expression V against MEMORY, returning an integer.
DIV truncates; dividing by zero yields 0 (a real PLC would raise a fault --
the sim shrugs and keeps scanning)."
  (ecase (car v)
    (:lit  (second v))
    (:word (mem-word memory (%word-key (second v))))
    (:arith
     (destructuring-bind (op first . rest) (cdr v)
       (let ((x (eval-value first memory)))
         (dolist (a rest x)
           (let ((y (eval-value a memory)))
             (setf x (ecase op
                       (:add (+ x y))
                       (:sub (- x y))
                       (:mul (* x y))
                       (:div (if (zerop y) 0 (truncate x y))))))))))))

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
       (:cmp
        (destructuring-bind (op a b) (node-args expr)
          (let ((x (eval-value a memory))
                (y (eval-value b memory)))
            (and (ecase op
                   (:gt (> x y)) (:ge (>= x y)) (:eq (= x y))
                   (:ne (/= x y)) (:le (<= x y)) (:lt (< x y)))
                 t))))
       (:fb  (error "FB evaluation not implemented for ~S" expr))))
    (t (error "Not an IR expression: ~S" expr))))

(defun execute-rung (rung memory)
  "Execute RUNG against MEMORY: evaluate a :COIL rung and apply its coil, or
perform an :ASSIGN rung's store (unconditionally -- IEC numeric semantics).
Returns the rung's result (the boolean RLO, or the stored value)."
  (ecase (first rung)
    (:assign
     (destructuring-bind (dst v) (rest rung)
       (setf (mem-word memory (%word-key dst)) (eval-value v memory))))
    (:coil
     (destructuring-bind (kind operand expr &optional preset) (rest rung)
       (let ((result (eval-expr expr memory)))
         (ecase kind
           (:normal (setf (mem-bit memory operand) result))
           (:set    (when result (setf (mem-bit memory operand) t)))
           (:reset  (when result (%reset-operand memory operand)))
           (:ton (%eval-ton memory operand preset result))
           (:tof (%eval-tof memory operand preset result))
           (:tp  (%eval-tp  memory operand preset result))
           (:ctu (%eval-ctu memory operand preset result))
           (:ctd (%eval-ctd memory operand preset result)))
         result)))))

;;; ---------------------------------------------------------------------------
;;; Timers and counters
;;;
;;; The time base is SIM TIME in milliseconds.  The clock is sampled once per
;;; scan (at the boundary; all rungs in a scan see the same timestamp, like a
;;; real PLC), and timers advance by the scan's elapsed DT-MS.  Where that
;;; time comes from is the sim's business: wall clock in free-run mode, or a
;;; frozen virtual clock that each manual Scan advances by SCAN-PERIOD-MS
;;; (default 1000 -- one Scan press = one second).  Counters are unaffected:
;;; they count rising edges, not time.  Per instance (say T1) the state lives
;;; in ordinary memory:
;;;
;;;   bit  "T1"     the output / done bit Q  -- readable by plain contacts
;;;   word "T1"     the current value CV (elapsed ms, or the count)
;;;   bit  "T1#P"   previous rung input, for edge detection (counters, TP)
;;;   word "C1#PV"  recorded preset, so RESET can reload a CTD
;;;
;;; The #\# in internal keys cannot appear in an IL operand (it would not
;;; survive tokenizing), so they can never collide; UIs filter them out.
;;; ---------------------------------------------------------------------------

(defun %aux (operand suffix)
  "Internal state key for OPERAND, e.g. (%aux \"C1\" \"P\") => \"C1#P\"."
  (format nil "~A#~A" (%canon operand) suffix))

(defun %eval-ton (memory op pt in)
  "On-delay timer: Q goes true once IN has held true for PT milliseconds of
sim time; IN going false resets elapsed and Q immediately."
  (if in
      (let ((cv (min pt (+ (mem-word memory op) (memory-dt-ms memory)))))
        (setf (mem-word memory op) cv
              (mem-bit memory op) (>= cv pt)))
      (setf (mem-word memory op) 0
            (mem-bit memory op) nil)))

(defun %eval-tof (memory op pt in)
  "Off-delay timer: Q follows IN going true; after IN goes false Q holds until
ET reaches PT, dropping on that very scan (Q=0 once ET>=PT, per IEC 61131-3 --
the exact mirror of TON, whose Q rises on the scan where ET reaches PT)."
  (cond (in (setf (mem-word memory op) 0
                  (mem-bit memory op) t))
        ((mem-bit memory op)
         (let ((cv (min pt (+ (mem-word memory op) (memory-dt-ms memory)))))
           (setf (mem-word memory op) cv)
           (when (>= cv pt)
             (setf (mem-bit memory op) nil))))))

(defun %eval-tp (memory op pt in)
  "Pulse timer: a rising edge on IN fires Q for PT milliseconds of sim time.
The pulse is not retriggerable, and IN must drop before a new pulse can fire."
  (let ((edge (and in (not (mem-bit memory (%aux op "P"))))))
    (setf (mem-bit memory (%aux op "P")) in)
    (cond ((mem-bit memory op)                    ; pulse in progress
           (let ((cv (+ (mem-word memory op) (memory-dt-ms memory))))
             (setf (mem-word memory op) cv)
             (when (>= cv pt)
               (setf (mem-bit memory op) nil))))
          (edge
           (setf (mem-word memory op) 0
                 (mem-bit memory op) (plusp pt))))))

(defun %eval-ctu (memory op pv in)
  "Up counter: count rising edges of IN; Q true once the count reaches PV.
A RESET coil (R C1) clears the count."
  (let ((edge (and in (not (mem-bit memory (%aux op "P"))))))
    (setf (mem-bit memory (%aux op "P")) in)
    (when edge
      (setf (mem-word memory op) (1+ (mem-word memory op))))
    (setf (mem-bit memory op) (>= (mem-word memory op) pv))))

(defun %eval-ctd (memory op pv in)
  "Down counter: starts at PV, counts rising edges of IN down; Q true at zero.
A RESET coil (R C1) reloads PV (recorded under the #PV key)."
  (let ((words (memory-words memory))
        (pv-key (%aux op "PV")))
    (unless (nth-value 1 (gethash pv-key words))  ; first execution: load PV
      (setf (mem-word memory op) pv))
    (setf (gethash pv-key words) pv)
    (let ((edge (and in (not (mem-bit memory (%aux op "P"))))))
      (setf (mem-bit memory (%aux op "P")) in)
      (when edge
        (setf (mem-word memory op) (max 0 (1- (mem-word memory op)))))
      (setf (mem-bit memory op) (<= (mem-word memory op) 0)))))

(defun %reset-operand (memory operand)
  "RESET coil action: clear OPERAND's bit and restore its instance value --
the recorded preset for a CTD, zero for timers/CTU.  Plain bits (no word
entry) are untouched beyond the bit itself, as before."
  (setf (mem-bit memory operand) nil)
  (let ((words (memory-words memory)))
    (multiple-value-bind (pv pv-p) (gethash (%aux operand "PV") words)
      (cond (pv-p (setf (mem-word memory operand) pv))
            ((nth-value 1 (gethash (%canon operand) words))
             (setf (mem-word memory operand) 0))))))

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
  (scan-count 0 :type unsigned-byte)
  ;; Index of the NEXT rung to execute: 0 at a scan boundary, >0 while a scan
  ;; is mid-flight under STEP-RUNG (single-stepping).
  (next-rung 0 :type unsigned-byte)
  ;; The sim clock, in milliseconds.  TIME-FN nil means a frozen virtual
  ;; clock: each scan advances CLOCK-MS by SCAN-PERIOD-MS (one manual Scan =
  ;; one second by default), so single-stepping stays deterministic.  In
  ;; free-run mode TIME-FN is a function of no arguments returning wall
  ;; milliseconds (see SIM-START-REALTIME) and each scan samples it.
  (clock-ms 0 :type unsigned-byte)
  (scan-period-ms 1000 :type unsigned-byte)
  (time-fn nil :type (or null function)))

(defun make-sim (&optional program)
  (%make-sim :program program))

(defun load-il (sim text-or-pathname)
  "Parse IL into SIM's program.  Accepts an IL string or a pathname."
  (setf (sim-program sim)
        (if (%looks-like-file-p text-or-pathname)
            (parse-il text-or-pathname)
            (parse-il-string text-or-pathname))
        (sim-next-rung sim) 0)          ; a new program starts at a scan boundary
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

(defun %begin-scan (sim)
  "Advance SIM's clock at a scan boundary and record the elapsed DT-MS for the
timers.  Time is sampled ONCE per scan, so every rung sees the same timestamp
(like a real PLC).  Virtual clock (TIME-FN nil): advance by SCAN-PERIOD-MS.
Realtime: sample TIME-FN; DT clamps at 0 so a clock going backwards (or a
realtime->virtual switch) never yields negative elapsed time."
  (let* ((now (if (sim-time-fn sim)
                  (funcall (sim-time-fn sim))
                  (+ (sim-clock-ms sim) (sim-scan-period-ms sim))))
         (dt (max 0 (- now (sim-clock-ms sim)))))
    (setf (sim-clock-ms sim) (max now (sim-clock-ms sim))
          (memory-dt-ms (sim-memory sim)) dt)))

(defun step-rung (sim)
  "Single-step: execute ONE rung and advance SIM's position within the scan.
Executing the last rung completes the scan (wrapping NEXT-RUNG to 0 and
bumping the scan counter).  Returns the index of the rung just executed, or
NIL when the program is empty."
  (let ((program (sim-program sim)))
    (when program
      (let ((i (sim-next-rung sim)))
        (when (zerop i) (%begin-scan sim))    ; new scan: sample the clock
        (execute-rung (nth i program) (sim-memory sim))
        (if (< (1+ i) (length program))
            (setf (sim-next-rung sim) (1+ i))
            (setf (sim-next-rung sim) 0
                  (sim-scan-count sim) (1+ (sim-scan-count sim))))
        i))))

(defun step-scan (sim)
  "Run SIM to the end of the current scan and bump the scan counter: all rungs
when at a scan boundary, or just the remaining rungs when mid-scan after
STEP-RUNG."
  (if (null (sim-program sim))
      (incf (sim-scan-count sim))
      (loop do (step-rung sim)
            until (zerop (sim-next-rung sim))))
  sim)

;;; ---------------------------------------------------------------------------
;;; Realtime mode (free run)
;;;
;;; The core stays thread-free: these just switch the sim's clock source and
;;; the RUNNING-P flag.  A front-end (e.g. plc-sim-clim) owns the actual scan
;;; loop / thread and keeps scanning while RUNNING-P holds.
;;; ---------------------------------------------------------------------------

(defun wall-time-ms ()
  "Wall-clock milliseconds from a monotonic base (GET-INTERNAL-REAL-TIME)."
  (values (round (* 1000 (get-internal-real-time))
                 internal-time-units-per-second)))

(defun sim-start-realtime (sim &optional (time-fn #'wall-time-ms))
  "Switch SIM's clock to realtime (TIME-FN, default the wall clock) and raise
RUNNING-P.  CLOCK-MS syncs to TIME-FN's current value so the first scan sees a
near-zero DT rather than the whole gap since the epoch."
  (setf (sim-time-fn sim) time-fn
        (sim-clock-ms sim) (funcall time-fn)
        (sim-running-p sim) t)
  sim)

(defun sim-stop-realtime (sim)
  "Drop RUNNING-P and return SIM to its frozen virtual clock.  CLOCK-MS keeps
its value, so subsequent manual scans continue from where realtime left off."
  (setf (sim-running-p sim) nil
        (sim-time-fn sim) nil)
  sim)

(defun %copy-bits (h)
  "Shallow copy of a bits hash table, for change detection between scans."
  (let ((c (make-hash-table :test 'equal :size (max 1 (hash-table-count h)))))
    (maphash (lambda (k v) (setf (gethash k c) v)) h)
    c))

(defun %bits-equal (a b)
  "True when bits tables A and B hold the same keys and values."
  (and (= (hash-table-count a) (hash-table-count b))
       (loop for k being the hash-keys of a using (hash-value v)
             always (eq v (gethash k b)))))

(defun stabilize (sim &key (max-scans 100))
  "Run scans until SIM's memory stops changing (its quiescent state, the way a
real continuously-scanning PLC would settle) or MAX-SCANS is reached.  Returns
the number of scans run.

A single scan can leave the display on a mid-cycle transient: a rung that reads
an output earlier than a later rung writes it (e.g. a lamp following a coil that
a downstream RESET clears in the same scan).  Settling to steady state hides
that transient.  The cap bounds programs that never settle, such as a one-rung
blinker (LDN Q / ST Q), which toggles every scan by design.

Only BITS are compared, deliberately: a running timer changes its word (elapsed
ms) every scan, and comparing words would make stabilize fast-forward every
timer to its preset.  Instead a running timer gains a scan-period or two here
and then advances one scan-period per explicit Scan (or follows the wall clock
in free-run mode)."
  (let ((mem (sim-memory sim)))
    (loop for n from 1 to max-scans
          for before = (%copy-bits (memory-bits mem))
          do (step-scan sim)
          when (%bits-equal before (memory-bits mem))
            do (return n)
          finally (return max-scans))))
