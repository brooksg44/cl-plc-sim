;;;; make-docs.lisp --- Regenerate the rendered ladder images under docs/.
;;;;
;;;;     sbcl --script make-docs.lisp
;;;;
;;;; Dependency-free: loads the core src/ files in order (like verify.lisp), then
;;;; renders each documented scan state to docs/<name>.svg.  The SVGs are the
;;;; canonical source committed to the repo.  If `qlmanage` is on PATH (macOS) it
;;;; also refreshes docs/<name>.png, which is what the README embeds (GitHub
;;;; renders PNG reliably but may sanitize inline SVG).  On other platforms the
;;;; PNGs are left untouched -- regenerate them with any SVG->PNG tool, e.g.
;;;;     rsvg-convert -w 1000 docs/foo.svg -o docs/foo.png

(let ((src (merge-pathnames "src/" *load-pathname*)))
  (dolist (f '("package" "ir" "parser" "eval" "layout" "svg"))
    (load (merge-pathnames (concatenate 'string f ".lisp") src))))

(in-package #:plc-sim)

(defparameter *here*
  ;; The project directory.  NAME/TYPE are stripped so that bare-directory
  ;; merges like (merge-pathnames "docs/" *here*) don't inherit "make-docs.lisp".
  (make-pathname :name nil :type nil
                 :defaults (or *load-pathname* *default-pathname-defaults*)))

(defun %example (name)
  (parse-il (merge-pathnames (format nil "examples/~A" name) *here*)))

(defun %doc-svg (name) (merge-pathnames (format nil "docs/~A.svg" name) *here*))

(defun render-state (program out &key setup (stabilize-p t))
  "Render PROGRAM to OUT after applying SETUP (a function of the sim) and either
stabilizing or running a single scan (STABILIZE-P nil, to capture a transient)."
  (let ((sim (make-sim program)))
    (when setup (funcall setup sim))
    (if stabilize-p (stabilize sim) (step-scan sim))
    (render-svg-to-file program out :memory (sim-memory sim))
    (format t "  wrote ~A~%" (enough-namestring out *here*))))

(defun latch-run (sim)
  "Press Start and settle, latching Run on (shared by both examples)."
  (setf (mem-bit (sim-memory sim) "IX0.0") t)
  (stabilize sim))

(ensure-directories-exist (merge-pathnames "docs/" *here*))

(format t "~%Rendering ladder images to docs/ ...~%")

;; 1) Seal-in, normal energized steady state: Start held, no fault.
(render-state (%example "motor-seal-in.il") (%doc-svg "motor-seal-in-energized")
              :setup #'latch-run)

;; 2) Seal-in, the one-scan transient: Run latched, then the fault asserts and we
;;    run a SINGLE scan.  Rung 4's RESET clears Run *after* rung 2 copied it to
;;    the lamp, so QX0.1 stays lit while QX0.0 reads off -- the lamp-lag bug.
(render-state (%example "motor-seal-in.il") (%doc-svg "motor-seal-in-transient")
              :stabilize-p nil
              :setup (lambda (sim)
                       (latch-run sim)
                       (setf (mem-bit (sim-memory sim) "IX0.0") nil)
                       (setf (mem-bit (sim-memory sim) "IX0.7") t)))

;; 3) Interlock, energized steady state: the fault is folded into rung 1, so no
;;    transient is reachable.
(render-state (%example "motor-interlock.il") (%doc-svg "motor-interlock-energized")
              :setup #'latch-run)

;; 4) Timers: Start latched and 10 scans run, so the TON has elapsed (5/5, pump
;;    on) and the TOF is following the pump (fan on).  Scans are stepped
;;    explicitly because stabilize compares bits only -- it deliberately does
;;    not fast-forward running timers.
(render-state (%example "pump-on-delay.il") (%doc-svg "pump-on-delay-running")
              :stabilize-p nil
              :setup (lambda (sim)
                       (setf (mem-bit (sim-memory sim) "IX0.0") t)
                       (dotimes (i 9) (step-scan sim))))

;; 5) Counters: three sensor pulses counted, batch complete -- CTU at 3/3 and
;;    CTD at 0/3, gate and lamp on.
(render-state (%example "batch-counter.il") (%doc-svg "batch-counter-complete")
              :stabilize-p nil
              :setup (lambda (sim)
                       (let ((m (sim-memory sim)))
                         (dotimes (i 3)
                           (setf (mem-bit m "IX0.0") t) (step-scan sim)
                           (setf (mem-bit m "IX0.0") nil) (step-scan sim)))))

;; 6) Numeric ops: two parts counted -- the SUB box reads 3-C1.CV=1 and the
;;    GE comparison is green (almost-full lamp lit), gate still shut.
(render-state (%example "parts-remaining.il") (%doc-svg "parts-remaining")
              :stabilize-p nil
              :setup (lambda (sim)
                       (let ((m (sim-memory sim)))
                         (dotimes (i 2)
                           (setf (mem-bit m "IX0.0") t) (step-scan sim)
                           (setf (mem-bit m "IX0.0") nil) (step-scan sim)))))

;;; ---------------------------------------------------------------------------
;;; Optional: refresh PNGs via macOS qlmanage, if present.
;;; ---------------------------------------------------------------------------

(defun qlmanage-available-p ()
  "True when the macOS `qlmanage` tool can be launched."
  (handler-case
      (zerop (sb-ext:process-exit-code
              (sb-ext:run-program "qlmanage" '("-h")
                                  :search t :output nil :error nil)))
    (error () nil)))

(defun qlmanage-pngs (names)
  "Render docs/<name>.svg -> docs/<name>.png for each NAME via a SINGLE qlmanage
call.  Batching matters: qlmanage drives the asynchronous QuickLook daemon, and
rapid back-to-back invocations flakily exit 0 without writing the file.  qlmanage
names each output <input>.png, so we move <name>.svg.png into place afterward."
  (let* ((docs (truename (merge-pathnames "docs/" *here*)))
         (svgs (mapcar (lambda (n)
                         (namestring (merge-pathnames (format nil "~A.svg" n) docs)))
                       names)))
    (sb-ext:run-program "qlmanage"
                        (list* "-t" "-s" "1000" "-o" (namestring docs) svgs)
                        :search t :output nil :error nil)
    (dolist (n names)
      (let ((tmp (merge-pathnames (format nil "~A.svg.png" n) docs))
            (png (merge-pathnames (format nil "~A.png" n) docs)))
        (cond ((probe-file tmp)
               (when (probe-file png) (delete-file png)) ; rename won't overwrite
               (rename-file tmp png)
               (format t "  wrote ~A~%" (enough-namestring png *here*)))
              (t
               (format t "  WARN: no thumbnail produced for ~A.svg~%" n)))))))

(format t "~%Refreshing PNGs (macOS qlmanage) ...~%")
(if (qlmanage-available-p)
    (qlmanage-pngs '("motor-seal-in-energized" "motor-seal-in-transient"
                     "motor-interlock-energized"
                     "pump-on-delay-running" "batch-counter-complete"
                     "parts-remaining"))
    (format t "  qlmanage unavailable; SVGs updated, PNGs left as-is.~%"))

(format t "~%Done.~%")
(sb-ext:exit :code 0)
