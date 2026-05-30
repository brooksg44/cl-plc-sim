;;;; clim-ui.lisp --- McCLIM ladder viewer + I/O simulator.
;;;;
;;;; This consumes the SAME backend-agnostic layout primitives the SVG renderer
;;;; uses (PLC-SIM:LAYOUT-PROGRAM), so no graphics logic lives here -- only the
;;;; mapping from primitives to CLIM drawing, plus interaction.
;;;;
;;;; The McCLIM payoff: a contact is drawn via PRESENT as a live OPERAND object,
;;;; so clicking it to toggle the corresponding input bit is a one-liner command
;;;; (TOGGLE-OPERAND).  INCREMENTAL-REDISPLAY repaints the energized path after
;;;; each scan with no manual diffing.
;;;;
;;;;   (ql:quickload "plc-sim-clim")
;;;;   (plc-sim-clim:run :il #p".../examples/motor-seal-in.il")

(defpackage #:plc-sim-clim
  (:use #:clim #:clim-lisp)
  (:export #:run #:ladder-frame))

(in-package #:plc-sim-clim)

(defparameter *cell* 56 "Pixels per grid cell (max; shrunk to fit the viewport).")
(defparameter *margin* 30 "Pixels of padding around the ladder.")
(defparameter *min-cell* 44
  "Smallest cell size when fitting.  Kept large enough that operand labels stay
roomy; if the program is taller than the viewport at this size, the pane scrolls
rather than shrinking labels into each other.")

;;; A presentation type so drawn operands are clickable objects.
(define-presentation-type operand () :inherit-from 'string)

;;; ---------------------------------------------------------------------------
;;; The application frame
;;; ---------------------------------------------------------------------------

(define-application-frame ladder-frame ()
  ((sim :initarg :sim :accessor frame-sim))
  (:menu-bar nil)
  (:panes
   (ladder :application
           :display-function 'display-ladder
           :incremental-redisplay t
           :scroll-bars t
           :text-style (make-text-style :sans-serif :roman 12))
   (io :application
       :display-function 'display-io
       :scroll-bars t
       :text-style (make-text-style :fix :roman 12))
   (interactor :interactor :height 80))
  (:layouts
   (default
    (vertically ()
      (horizontally ()
        (4/5 (labelling (:label "Ladder") ladder))
        (1/5 (labelling (:label "I/O")    io)))
      (labelling (:label "Commands") interactor)))))

;;; ---------------------------------------------------------------------------
;;; Drawing the ladder from layout primitives
;;; ---------------------------------------------------------------------------

(defun gx (g) (+ *margin* (round (* g *cell*))))   ; grid -> pixel
(defun lbl-size ()                                 ; label font scales with cell
  (max 7 (round (* *cell* 0.2))))

(defun energized-contact-p (mode operand memory)
  (let ((v (plc-sim:mem-bit memory operand)))
    (if (eq mode :nc) (not v) v)))

(defun content-extent (prims rows)
  "Return (values COLS ROWS) — the grid the primitives actually occupy."
  (let ((maxx 1) (maxy 1))
    (dolist (p prims)
      (ecase (first p)
        ((:contact :coil)
         (setf maxx (max maxx (+ 2 (second p)))
               maxy (max maxy (+ 1 (third p)))))
        (:wire (destructuring-bind (x1 y1 x2 y2) (rest p)
                 (setf maxx (max maxx x1 x2) maxy (max maxy y1 y2))))
        (:fb (destructuring-bind (x y w h name) (rest p)
               (declare (ignore name))
               (setf maxx (max maxx (+ x w)) maxy (max maxy (+ y h)))))))
    (values (1+ maxx) (max (+ maxy 1) rows))))

(defun fit-cell (pane cols rows)
  "Largest cell size (<= *CELL*, >= *MIN-CELL*) that fits COLS x ROWS into
PANE's visible viewport — so the whole program shows without scrolling."
  (let* ((vp (or (pane-viewport-region pane) (sheet-region pane)))
         (w (- (bounding-rectangle-width vp) (* 2 *margin*)))
         (h (- (bounding-rectangle-height vp) (* 2 *margin*))))
    (max *min-cell*
         (min *cell*
              (floor (max 1 w) (max 1 cols))
              (floor (max 1 h) (max 1 rows))))))

(defun display-ladder (frame pane)
  (let* ((sim (frame-sim frame))
         (program (plc-sim:sim-program sim))
         (memory (plc-sim:sim-memory sim)))
    (multiple-value-bind (prims rows) (plc-sim:layout-program program)
      (multiple-value-bind (cols nrows) (content-extent prims rows)
        (let ((*cell* (fit-cell pane cols nrows)))   ; scale to fit the window
          (dolist (p prims)
            (ecase (first p)
              (:wire
               (destructuring-bind (x1 y1 x2 y2) (rest p)
                 (draw-line* pane (gx x1) (gx y1) (gx x2) (gx y2)
                             :line-thickness 2 :ink +gray40+)))
              (:contact
               (destructuring-bind (x y mode op) (rest p)
                 (draw-contact pane x y mode op
                               (energized-contact-p mode op memory))))
              (:coil
               (destructuring-bind (x y kind op) (rest p)
                 (draw-coil pane x y kind op (plc-sim:mem-bit memory op))))
              (:fb
               (destructuring-bind (x y w h name) (rest p)
                 (declare (ignore h))
                 (draw-rectangle* pane (gx x) (- (gx y) (round (* *cell* 1/3)))
                                  (gx (+ x w)) (+ (gx y) (round (* *cell* 1/3)))
                                  :filled nil :line-thickness 2)
                 (draw-text* pane name (gx x) (gx y) :text-size (lbl-size)))))))))))

(defun draw-contact (pane x y mode op live)
  (let* ((cx (gx x)) (cy (gx y)) (ink (if live +forest-green+ +gray40+))
         (q (round (* *cell* 1/4)))            ; bar inset and half-height
         (x0 (+ cx q)) (x1 (+ cx (* 3 q))))
    (draw-line* pane cx cy x0 cy :ink ink :line-thickness 2)
    (draw-line* pane x1 cy (+ cx *cell*) cy :ink ink :line-thickness 2)
    (draw-line* pane x0 (- cy q) x0 (+ cy q) :ink ink :line-thickness 3)
    (draw-line* pane x1 (- cy q) x1 (+ cy q) :ink ink :line-thickness 3)
    (when (eq mode :nc)
      (draw-line* pane x0 (+ cy q) x1 (- cy q) :ink ink :line-thickness 2))
    ;; the operand label is a clickable presentation
    (with-output-as-presentation (pane op 'operand)
      (draw-text* pane (princ-to-string op) x0 (- cy q 6) :text-size (lbl-size)))))

(defun draw-coil (pane x y kind op live)
  (let* ((cx (gx x)) (cy (gx y)) (ink (if live +forest-green+ +gray40+))
         (q (round (* *cell* 1/4))) (x0 (+ cx q))
         (label (ecase kind (:normal "( )") (:set "(S)") (:reset "(R)"))))
    (draw-line* pane cx cy x0 cy :ink ink :line-thickness 2)
    (draw-circle* pane (+ cx (round (* *cell* 1/2))) cy q
                  :filled nil :ink ink :line-thickness 3)
    (draw-text* pane (format nil "~A ~A" op label)
                x0 (- cy q 6) :text-size (lbl-size))))

;;; ---------------------------------------------------------------------------
;;; The I/O panel: every known bit, clickable to toggle
;;; ---------------------------------------------------------------------------

(defun display-io (frame pane)
  (let* ((memory (plc-sim:sim-memory (frame-sim frame)))
         (names (sort (loop for k being the hash-keys
                              of (plc-sim::memory-bits memory)
                            collect k)
                      #'string<)))
    (format pane "scan ~D~2%" (plc-sim:sim-scan-count (frame-sim frame)))
    (dolist (name names)
      (with-output-as-presentation (pane name 'operand)
        (format pane "~A ~A~%"
                (if (plc-sim:mem-bit memory name) "[#]" "[ ]")
                name)))))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(define-ladder-frame-command (com-toggle :name "Toggle")
    ((op 'operand :gesture :select))
  "Toggle a bit, then re-scan so the display reflects it."
  (let* ((sim (frame-sim *application-frame*))
         (m (plc-sim:sim-memory sim)))
    (setf (plc-sim:mem-bit m op) (not (plc-sim:mem-bit m op)))
    (plc-sim:step-scan sim)))

(define-ladder-frame-command (com-scan :name "Scan")
    ()
  "Run one scan cycle."
  (plc-sim:step-scan (frame-sim *application-frame*)))

(define-ladder-frame-command (com-load :name "Load")
    ((path 'pathname))
  "Load an IL file into the running simulator."
  (plc-sim:load-il (frame-sim *application-frame*) path))

(define-ladder-frame-command (com-quit :name "Quit") ()
  (frame-exit *application-frame*))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

(defun run (&key il)
  "Open the ladder viewer.  IL is an optional path to an IL file to preload."
  (let ((sim (plc-sim:make-sim)))
    (when il (plc-sim:load-il sim il))
    (run-frame-top-level
     (make-application-frame 'ladder-frame :sim sim
                                           :width 1000 :height 640))))
