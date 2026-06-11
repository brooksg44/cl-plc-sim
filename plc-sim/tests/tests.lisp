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

(test stabilize-settles-transient
  ;; Rung order: lamp (rung 2) follows the Run coil, which the fault RESET
  ;; (rung 4) clears in the same scan.  A single scan leaves the lamp on a
  ;; one-scan-stale transient; stabilizing must settle both outputs to off.
  (let ((sim (make-sim
              (parse-il (merge-pathnames
                         "examples/motor-seal-in.il"
                         (asdf:system-source-directory "plc-sim"))))))
    (let ((m (sim-memory sim)))
      ;; Latch Run on, then assert the fault.
      (setf (mem-bit m "IX0.0") t) (stabilize sim)
      (is (eq t (mem-bit m "QX0.0")))
      (is (eq t (mem-bit m "QX0.1")))
      (setf (mem-bit m "IX0.0") nil)
      (setf (mem-bit m "IX0.7") t)
      (stabilize sim)
      ;; After settling, Run is reset AND its lamp follows it off.
      (is (eq nil (mem-bit m "QX0.0")))
      (is (eq nil (mem-bit m "QX0.1"))))))

(test step-rung-walks-one-rung-at-a-time
  (let* ((sim (make-sim (parse-il-string "LD A
ST X
LD X
ST Y")))
         (m (sim-memory sim)))
    (setf (mem-bit m "A") t)
    (is (= 0 (step-rung sim)))
    (is (eq t   (mem-bit m "X")))
    (is (eq nil (mem-bit m "Y")))       ; rung 2 has not run yet
    (is (= 1 (sim-next-rung sim)))
    (is (= 0 (sim-scan-count sim)))     ; scan still mid-flight
    (is (= 1 (step-rung sim)))
    (is (eq t (mem-bit m "Y")))
    (is (= 0 (sim-next-rung sim)))      ; wrapped: scan complete
    (is (= 1 (sim-scan-count sim)))))

(test step-scan-finishes-a-stepped-scan
  (let ((sim (make-sim (parse-il-string "LD A
ST X
LD B
ST Y
LD C
ST Z"))))
    (step-rung sim)                     ; mid-scan after rung 1
    (step-scan sim)                     ; finishes rungs 2-3, no second scan
    (is (= 1 (sim-scan-count sim)))
    (is (= 0 (sim-next-rung sim)))))

(test step-scan-handles-empty-program
  (is (= 1 (sim-scan-count (step-scan (make-sim))))))

(test single-step-freezes-seal-in-transient
  ;; Step through the fault scan of motor-seal-in one rung at a time: after
  ;; rung 2 the lamp still mirrors the latched Run; only rung 4's RESET drops
  ;; Run, leaving the lamp stale until the next scan -- visible mid-scan.
  (let* ((sim (make-sim
               (parse-il (merge-pathnames
                          "examples/motor-seal-in.il"
                          (asdf:system-source-directory "plc-sim")))))
         (m (sim-memory sim)))
    (setf (mem-bit m "IX0.0") t) (step-scan sim)   ; latch Run
    (setf (mem-bit m "IX0.0") nil)
    (setf (mem-bit m "IX0.7") t)                   ; assert the fault
    (step-rung sim) (step-rung sim)                ; rungs 1-2 of the fault scan
    (is (eq t (mem-bit m "QX0.0")))                ; Run still latched
    (is (eq t (mem-bit m "QX0.1")))                ; lamp copied it
    (step-rung sim) (step-rung sim)                ; rungs 3-4 (the RESET)
    (is (eq nil (mem-bit m "QX0.0")))              ; Run dropped ...
    (is (eq t   (mem-bit m "QX0.1")))              ; ... lamp stale: the transient
    (is (= 2 (sim-scan-count sim)))))

(test stabilize-caps-oscillator
  ;; A one-rung blinker (Q = NOT Q) never settles; stabilize must return the
  ;; cap rather than loop forever.
  (let ((sim (make-sim (parse-il-string "LDN Q
ST Q"))))
    (is (= 7 (stabilize sim :max-scans 7)))))

;;; ---------------------------------------------------------------------------
;;; Timers and counters (time base: sim milliseconds; the default virtual
;;; clock advances 1000 ms per scan, so one Scan = one second)
;;; ---------------------------------------------------------------------------

(test parse-timer-counter
  ;; a bare integer timer preset means milliseconds
  (is (equal '((:coil :ton "T1" (:contact :no "A") 5))
             (parse-il-string "LD A
TON T1, 5")))
  ;; IEC TIME literals
  (is (equal '((:coil :ton "T1" (:contact :no "A") 5000))
             (parse-il-string "LD A
TON T1, T#5s")))
  ;; the comma is optional
  (is (equal '((:coil :ctu "C1" (:contact :no "A") 3))
             (parse-il-string "LD A
CTU C1 3"))))

(test parse-time-literals
  (flet ((preset (text)
           (fifth (first (parse-il-string (format nil "LD A~%TON T1, ~A" text))))))
    (is (= 500 (preset "T#500ms")))
    (is (= 5000 (preset "T#5s")))
    (is (= 90000 (preset "T#1m30s")))
    (is (= 90000 (preset "T#1m_30s")))    ; underscore separators
    (is (= 1500 (preset "T#1.5s")))       ; decimal values
    (is (= 7200000 (preset "TIME#2h")))   ; long prefix, hours
    (signals error (preset "T#5x"))       ; unknown unit
    (signals error (preset "T#s"))))      ; missing value

(test format-time-literal-canonical
  (is (string= "T#500ms" (format-time-literal 500)))
  (is (string= "T#5s" (format-time-literal 5000)))
  (is (string= "T#90s" (format-time-literal 90000)))
  (is (string= "T#2m" (format-time-literal 120000)))
  (is (string= "T#0ms" (format-time-literal 0)))
  ;; the printer emits literals the parser reads back exactly
  (let ((p1 (parse-il-string "LD A
TON T1, T#1.5s")))
    (is (search "T#1500ms" (program->il p1)))
    (is (equal p1 (parse-il-string (program->il p1))))))

(test format-duration-display
  (is (string= "300ms" (format-duration 300)))
  (is (string= "5s" (format-duration 5000)))
  (is (string= "1.5s" (format-duration 1500))))

(test timer-counter-round-trips
  (let ((p1 (parse-il-string "LD A
TON T1, 5
LD T1
ST Q
LD B
CTU C1, 3")))
    (is (equal p1 (parse-il-string (program->il p1))))))

(test stn-stores-negated-accumulator
  (is (equal '((:coil :normal "Q" (:contact :nc "A")))
             (parse-il-string "LD A
STN Q"))))

(test ton-delays-then-fires-then-resets
  (let* ((sim (make-sim (parse-il-string "LD A
TON T1, T#3s
LD T1
ST Q")))
         (m (sim-memory sim)))
    (setf (mem-bit m "A") t)
    (step-scan sim) (is (eq nil (mem-bit m "Q")))   ; t=1s
    (step-scan sim) (is (eq nil (mem-bit m "Q")))   ; t=2s
    (step-scan sim) (is (eq t   (mem-bit m "Q")))   ; t=3s: done
    (step-scan sim) (is (= 3000 (mem-word m "T1"))) ; elapsed clamps at preset
    (setf (mem-bit m "A") nil)                      ; input drops -> resets
    (step-scan sim)
    (is (eq nil (mem-bit m "Q")))
    (is (= 0 (mem-word m "T1")))))

(test tof-drops-when-elapsed-reaches-preset
  ;; IEC 61131-3: Q=1 while IN=1; after IN drops, Q=0 once ET>=PT -- on the
  ;; very scan ET reaches PT, mirroring TON's rise.
  (let* ((sim (make-sim (parse-il-string "LD A
TOF F1, T#2s
LD F1
ST Q")))
         (m (sim-memory sim)))
    (step-scan sim) (is (eq nil (mem-bit m "Q")))   ; never energized -> off
    (setf (mem-bit m "A") t) (step-scan sim)
    (is (eq t (mem-bit m "Q")))                     ; follows IN at once
    (setf (mem-bit m "A") nil)
    (step-scan sim) (is (eq t   (mem-bit m "Q")))   ; ET=1s < PT: holding
    (step-scan sim) (is (eq nil (mem-bit m "Q")))   ; ET=2s = PT: Q drops
    (is (= 2000 (mem-word m "F1")))                 ; ET holds at PT
    ;; IN returning true mid-hold keeps Q on and restarts the hold
    (setf (mem-bit m "A") t) (step-scan sim)
    (setf (mem-bit m "A") nil) (step-scan sim)
    (is (eq t (mem-bit m "Q")))
    (is (= 1000 (mem-word m "F1")))))

(test tp-pulses-for-preset-scans-not-retriggerable
  (let* ((sim (make-sim (parse-il-string "LD A
TP P1, T#2s")))
         (m (sim-memory sim)))
    (setf (mem-bit m "A") t)
    (step-scan sim) (is (eq t (mem-bit m "P1")))    ; edge fires the pulse
    (step-scan sim) (is (eq t (mem-bit m "P1")))    ; tick 2
    (step-scan sim) (is (eq nil (mem-bit m "P1")))  ; pulse over
    (step-scan sim) (is (eq nil (mem-bit m "P1")))  ; held IN: no retrigger
    (setf (mem-bit m "A") nil) (step-scan sim)      ; release ...
    (setf (mem-bit m "A") t)   (step-scan sim)      ; ... new edge refires
    (is (eq t (mem-bit m "P1")))))

(test ctu-counts-edges-and-resets
  (let* ((sim (make-sim (parse-il-string "LD A
CTU C1, 2
LD B
R C1")))
         (m (sim-memory sim)))
    (flet ((pulse ()
             (setf (mem-bit m "A") t) (step-scan sim)
             (setf (mem-bit m "A") nil) (step-scan sim)))
      (pulse)
      (is (= 1 (mem-word m "C1")))
      (is (eq nil (mem-bit m "C1")))
      ;; holding the input true across scans must NOT keep counting
      (setf (mem-bit m "A") t) (step-scan sim) (step-scan sim)
      (is (= 2 (mem-word m "C1")))
      (is (eq t (mem-bit m "C1")))
      ;; reset clears the count and the done bit
      (setf (mem-bit m "A") nil)
      (setf (mem-bit m "B") t) (step-scan sim)
      (is (= 0 (mem-word m "C1")))
      (is (eq nil (mem-bit m "C1"))))))

(test ctd-loads-preset-counts-down-reloads-on-reset
  (let* ((sim (make-sim (parse-il-string "LD A
CTD C1, 2
LD B
R C1")))
         (m (sim-memory sim)))
    (step-scan sim)
    (is (= 2 (mem-word m "C1")))          ; first execution loads the preset
    (is (eq nil (mem-bit m "C1")))
    (flet ((pulse ()
             (setf (mem-bit m "A") t) (step-scan sim)
             (setf (mem-bit m "A") nil) (step-scan sim)))
      (pulse) (is (= 1 (mem-word m "C1")))
      (pulse) (is (= 0 (mem-word m "C1")))
      (is (eq t (mem-bit m "C1")))
      ;; reset RELOADS a down counter (vs clearing a CTU)
      (setf (mem-bit m "B") t) (step-scan sim)
      (is (= 2 (mem-word m "C1")))
      (is (eq nil (mem-bit m "C1"))))))

(test virtual-clock-scan-period-is-configurable
  ;; sub-second stepping: 100 ms per scan, a T#250ms TON fires on scan 3
  (let* ((sim (make-sim (parse-il-string "LD A
TON T1, T#250ms")))
         (m (sim-memory sim)))
    (setf (sim-scan-period-ms sim) 100)
    (setf (mem-bit m "A") t)
    (step-scan sim) (is (eq nil (mem-bit m "T1")))  ; 100ms
    (step-scan sim) (is (eq nil (mem-bit m "T1")))  ; 200ms
    (step-scan sim) (is (eq t   (mem-bit m "T1")))  ; 300ms >= 250ms
    (is (= 300 (sim-clock-ms sim)))))

(test realtime-clock-follows-injected-time-fn
  ;; realtime mode, but deterministic: the "wall clock" is a settable variable
  (let* ((now 1000000)
         (sim (make-sim (parse-il-string "LD A
TON T1, T#5s")))
         (m (sim-memory sim)))
    (sim-start-realtime sim (lambda () now))
    (is (eq t (sim-running-p sim)))
    (is (= now (sim-clock-ms sim)))       ; synced at start: no epoch-sized DT
    (setf (mem-bit m "A") t)
    (incf now 2000) (step-scan sim)
    (is (eq nil (mem-bit m "T1")))        ; 2s elapsed
    (is (= 2000 (mem-word m "T1")))
    (incf now 3000) (step-scan sim)
    (is (eq t (mem-bit m "T1")))          ; 5s elapsed: done
    ;; stopping freezes the clock and hands back to the virtual one
    (sim-stop-realtime sim)
    (is (eq nil (sim-running-p sim)))
    (is (null (sim-time-fn sim)))
    (let ((frozen (sim-clock-ms sim)))
      (step-scan sim)                     ; manual scan: +scan-period, not wall
      (is (= (+ frozen (sim-scan-period-ms sim)) (sim-clock-ms sim))))))

(test all-rungs-in-a-scan-see-the-same-timestamp
  ;; two identical timers in one program complete on the same scan even when
  ;; stepped rung by rung -- time is sampled once, at the scan boundary
  (let* ((sim (make-sim (parse-il-string "LD A
TON T1, T#2s
LD A
TON T2, T#2s")))
         (m (sim-memory sim)))
    (setf (mem-bit m "A") t)
    (dotimes (i 4) (step-rung sim))       ; two full scans, one rung at a time
    (is (eq t (mem-bit m "T1")))
    (is (eq t (mem-bit m "T2")))
    (is (= (mem-word m "T1") (mem-word m "T2")))))

(test timer-coil-prim-carries-preset
  (let ((prims (layout-rung (first (parse-il-string "LD A
TON T1, 5")))))
    (is (equal '(:coil 3 0 :ton "T1" 5)
               (find :coil prims :key #'first)))))

(test example-pump-and-counter-files-parse
  (dolist (name '("pump-on-delay.il" "batch-counter.il"))
    (let ((prog (parse-il (merge-pathnames
                           (format nil "examples/~A" name)
                           (asdf:system-source-directory "plc-sim")))))
      (is (plusp (length prog)))
      (is (equal prog (parse-il-string (program->il prog)))))))

;;; ---------------------------------------------------------------------------
;;; Interlock example: fault folded into the seal-in, no scan-order lag
;;; ---------------------------------------------------------------------------

(defun %motor-interlock-program ()
  (parse-il (merge-pathnames "examples/motor-interlock.il"
                             (asdf:system-source-directory "plc-sim"))))

(test interlock-folds-fault-into-rung-1
  ;; The fault is an NC contact in series inside rung 1, not a separate RESET.
  (let ((prog (%motor-interlock-program)))
    (is (= 2 (length prog)))
    (is (equal '(:coil :normal "%QX0.0"
                 (:and (:or (:contact :no "%IX0.0") (:contact :no "%QX0.0"))
                       (:contact :nc "%IX0.1")
                       (:contact :nc "%IX0.7")))
               (first prog)))))

(test interlock-lamp-tracks-run-in-one-scan
  ;; The whole point of the interlock form: a SINGLE scan (no stabilize) already
  ;; leaves Run and its lamp consistent when the fault is asserted.
  (let* ((sim (make-sim (%motor-interlock-program)))
         (m (sim-memory sim)))
    (setf (mem-bit m "IX0.0") t) (step-scan sim)   ; Start -> latch Run
    (is (eq t (mem-bit m "QX0.0")))
    (is (eq t (mem-bit m "QX0.1")))
    (setf (mem-bit m "IX0.0") nil)
    (setf (mem-bit m "IX0.7") t) (step-scan sim)   ; Fault -> drops both at once
    (is (eq nil (mem-bit m "QX0.0")))
    (is (eq nil (mem-bit m "QX0.1")))))

(test interlock-round-trips
  (let ((p1 (%motor-interlock-program)))
    (is (equal p1 (parse-il-string (program->il p1))))))

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
