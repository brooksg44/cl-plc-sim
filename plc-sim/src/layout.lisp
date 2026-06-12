;;;; layout.lisp --- Two-pass ladder layout over the expression tree.
;;;;
;;;; The layout is deliberately backend-agnostic: it produces a flat list of
;;;; abstract drawing primitives in a grid coordinate system.  Both the SVG
;;;; renderer (svg.lisp) and the McCLIM UI (clim-ui.lisp) consume the same
;;;; primitives, so layout logic never leaks into a graphics toolkit.
;;;;
;;;; Pass 1 (EXPR-SIZE):  bottom-up, each node reports a (width . height) in
;;;;                      grid cells.  :AND sums widths; :OR sums heights.
;;;; Pass 2 (LAYOUT-RUNG): top-down, assign each node an origin and emit
;;;;                      primitives plus the connecting wires.
;;;;
;;;; Emitted primitives (grid units; x grows right, y grows down):
;;;;   (:contact x y mode operand)
;;;;   (:coil    x y kind operand [preset])   preset rides along for timers/counters
;;;;   (:cmp     x y op a b)         comparison element (contact-like, 2 cells)
;;;;   (:assign  x y w dst value)    unconditional numeric store box
;;;;   (:wire    x1 y1 x2 y2)        horizontal or vertical segment
;;;;   (:fb      x y w h name)

(in-package #:plc-sim)

;;; ---------------------------------------------------------------------------
;;; Pass 1: sizing
;;; ---------------------------------------------------------------------------

(defun expr-size (expr)
  "Return (values WIDTH HEIGHT) in grid cells for EXPR."
  (cond
    ((null expr) (values 1 1))          ; empty rung = a straight wire
    ((consp expr)
     (ecase (node-op expr)
       ;; A contact spans 2 cells: a compact glyph in the first cell plus a
       ;; lead-out wire in the second, so each operand label gets its own cell
       ;; and series labels never crowd their neighbours.
       (:contact (values 2 1))
       (:cmp     (values 2 1))
       (:fb      (values 2 1))
       (:not     (expr-size (second expr)))
       (:and (let ((w 0) (h 1))
               (dolist (e (node-args expr))
                 (multiple-value-bind (ew eh) (expr-size e)
                   (incf w ew) (setf h (max h eh))))
               (values w h)))
       (:or (let ((w 1) (h 0))
              (dolist (e (node-args expr))
                (multiple-value-bind (ew eh) (expr-size e)
                  (setf w (max w ew)) (incf h eh)))
              (values w h)))))
    (t (error "Not an IR expression: ~S" expr))))

;;; ---------------------------------------------------------------------------
;;; Pass 2: placement
;;; ---------------------------------------------------------------------------

(defun layout-rung (rung &key (row 0))
  "Return a list of drawing primitives for RUNG, with its top-left at ROW.
A :COIL rung places its coil one cell right of the contact network; an
:ASSIGN rung is a 2-cell store box hung straight off the rail (its EN is the
rail itself -- numeric stores are unconditional)."
  (when (eq (first rung) :assign)
    (destructuring-bind (dst v) (rest rung)
      (return-from layout-rung
        (list (list :wire 0 row 1 row)
              (list :assign 1 row 2 dst v)))))
  (destructuring-bind (tag kind operand expr &optional preset) rung
    (declare (ignore tag))
    (let ((prims '()))
      (labels ((emit (p) (push p prims))
               (place (e x y w)
                 "Place E in the box of width W with top-left at (X,Y)."
                 (cond
                   ((null e) (emit (list :wire x y (+ x w) y)))
                   ((eq (node-op e) :contact)
                    (destructuring-bind (mode op) (node-args e)
                      (emit (list :contact x y mode op))
                      (when (> w 1)               ; pad to fill the cell width
                        (emit (list :wire (1+ x) y (+ x w) y)))))
                   ((eq (node-op e) :cmp)         ; 2 cells, like a contact
                    (emit (list* :cmp x y (node-args e)))
                    (when (> w 2)
                      (emit (list :wire (+ x 2) y (+ x w) y))))
                   ((eq (node-op e) :fb)
                    (multiple-value-bind (ew eh) (expr-size e)
                      (emit (list :fb x y ew eh (second e)))))
                   ((eq (node-op e) :not)
                    (place (second e) x y w))     ; NC handled at contact level
                   ((eq (node-op e) :and)
                    (let ((cx x))
                      (dolist (c (node-args e))
                        (multiple-value-bind (cw ch) (expr-size c)
                          (declare (ignore ch))
                          (place c cx y cw)
                          (incf cx cw)))))
                   ((eq (node-op e) :or)
                    (let ((cy y))
                      (dolist (c (node-args e))
                        (multiple-value-bind (cw ch) (expr-size c)
                          (place c x cy cw)
                          ;; pad short branches out to the full width
                          (when (< cw w)
                            (emit (list :wire (+ x cw) cy (+ x w) cy)))
                          ;; vertical rails joining this branch to the trunk
                          (when (> cy y)
                            (emit (list :wire x y x cy))
                            (emit (list :wire (+ x w) y (+ x w) cy)))
                          (incf cy ch))))))))
        (multiple-value-bind (w h) (expr-size expr)
          (declare (ignore h))
          (place expr 0 row w)
          (emit (list :wire w row (1+ w) row))      ; stub into the coil
          (emit (list* :coil (1+ w) row kind operand
                       (and preset (list preset)))))
        (nreverse prims)))))

(defun layout-program (program &key (row-gap 1))
  "Lay out a whole PROGRAM, stacking rungs ROW-GAP cells apart.
Returns (values PRIMITIVES TOTAL-ROWS RUNG-ROWS), where RUNG-ROWS lists each
rung's starting row -- for callers that point at a rung (single-stepping)."
  (let ((all '()) (row 0) (starts '()))
    (dolist (rung program)
      (push row starts)
      (let ((h (ecase (first rung)
                 (:assign 1)
                 (:coil (nth-value 1 (expr-size (fourth rung)))))))
        (dolist (p (layout-rung rung :row row)) (push p all))
        (incf row (+ (max h 1) row-gap))))
    (values (nreverse all) row (nreverse starts))))
