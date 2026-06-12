;;;; svg.lisp --- Render layout primitives to SVG (dependency-free).
;;;;
;;;; This lets you SEE a ladder before any GUI toolkit is involved -- dump an
;;;; .svg, open it in a browser, and confirm the layout engine is sane.  The
;;;; McCLIM UI later draws the very same primitives interactively.
;;;;
;;;; An optional MEMORY argument colours energized contacts/coils, so an SVG
;;;; snapshot doubles as a scan-state visualization.

(in-package #:plc-sim)

(defparameter *cell* 48 "Pixels per grid cell.")
(defparameter *margin* 24)

(defun %px (grid) (+ *margin* (* grid *cell*)))

(defun %xml-escape (s)
  "Escape <, > and & for SVG text content (comparison labels contain them)."
  (with-output-to-string (out)
    (loop for c across s
          do (case c
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (#\& (write-string "&amp;" out))
               (t (write-char c out))))))

(defun %energized-contact-p (mode operand memory)
  (and memory
       (let ((v (mem-bit memory operand)))
         (if (eq mode :nc) (not v) v))))

(defun %svg-contact (out x y mode operand memory)
  (let* ((cx (%px x)) (cy (%px y))
         (live (%energized-contact-p mode operand memory))
         (color (if live "#1a7f37" "#444"))
         (x0 (+ cx (* *cell* 1/4))) (x1 (+ cx (* *cell* 3/4))))
    ;; lead-in / lead-out wires
    (format out "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='2'/>~%"
            cx cy x0 cy color)
    (format out "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='2'/>~%"
            x1 cy (+ cx *cell*) cy color)
    ;; the two contact bars
    (format out "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='3'/>~%"
            x0 (- cy 12) x0 (+ cy 12) color)
    (format out "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='3'/>~%"
            x1 (- cy 12) x1 (+ cy 12) color)
    (when (eq mode :nc)                 ; the slash of a normally-closed contact
      (format out "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='2'/>~%"
              x0 (+ cy 12) x1 (- cy 12) color))
    (format out "  <text x='~D' y='~D' text-anchor='middle' font-size='11' font-family='monospace'>~A</text>~%"
            (+ cx (/ *cell* 2)) (- cy 18) operand)))

(defun %svg-box-coil (out x y kind operand memory preset)
  "A timer/counter rung terminator: a box showing the kind and CV/PT, with the
instance name above.  Green once the instance's done bit is set.  The box is
TWO cells wide -- duration text like \"300ms/8s\" doesn't fit in one -- which
fits because the extent math already pads a spare cell past every coil."
  (let* ((cx (%px x)) (cy (%px y))
         (live (and memory (mem-bit memory operand)))
         (color (if live "#1a7f37" "#444"))
         (x0 (+ cx 5)) (x1 (+ cx (* 2 *cell*) -5))
         (mid (+ cx *cell*)))
    (format out "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='2'/>~%"
            cx cy x0 cy color)
    ;; half-height 18 (vs a coil's 12) so the two text lines clear the borders
    (format out "  <rect x='~D' y='~D' width='~D' height='~D' fill='white' stroke='~A' stroke-width='2'/>~%"
            x0 (- cy 18) (- x1 x0) 36 color)
    (format out "  <text x='~D' y='~D' text-anchor='middle' font-size='10' font-family='monospace'>~A</text>~%"
            mid (- cy 5) (symbol-name kind))
    (format out "  <text x='~D' y='~D' text-anchor='middle' font-size='10' font-family='monospace'>~A</text>~%"
            mid (+ cy 12)
            (flet ((fmt (v) (if (timer-kind-p kind)
                                (format-duration v)
                                (princ-to-string v))))
              (if memory
                  (format nil "~A/~A" (fmt (mem-word memory operand)) (fmt preset))
                  (format nil "PT=~A" (fmt preset)))))
    (format out "  <text x='~D' y='~D' text-anchor='middle' font-size='11' font-family='monospace'>~A</text>~%"
            mid (- cy 22) operand)))

(defun %svg-coil (out x y kind operand memory &optional preset)
  (when preset                          ; timer/counter -> instruction box
    (return-from %svg-coil
      (%svg-box-coil out x y kind operand memory preset)))
  (let* ((cx (%px x)) (cy (%px y))
         (live (and memory (mem-bit memory operand)))
         (color (if live "#1a7f37" "#444"))
         (x0 (+ cx (* *cell* 1/4))) (x1 (+ cx (* *cell* 3/4)))
         (label (ecase kind (:normal "( )") (:set "(S)") (:reset "(R)"))))
    (format out "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='2'/>~%"
            cx cy x0 cy color)
    (format out "  <path d='M ~D ~D A 10 12 0 0 0 ~D ~D' fill='none' stroke='~A' stroke-width='3'/>~%"
            x0 (- cy 12) x0 (+ cy 12) color)
    (format out "  <path d='M ~D ~D A 10 12 0 0 1 ~D ~D' fill='none' stroke='~A' stroke-width='3'/>~%"
            x1 (- cy 12) x1 (+ cy 12) color)
    (format out "  <text x='~D' y='~D' text-anchor='middle' font-size='11' font-family='monospace'>~A ~A</text>~%"
            (+ cx (/ *cell* 2)) (- cy 18) operand label)))

(defun %svg-cmp (out x y op a b memory)
  "A comparison element: a contact-sized box showing e.g. C1.CV>=2, green
while the comparison currently holds."
  (let* ((cx (%px x)) (cy (%px y))
         (live (and memory (eval-expr (list :cmp op a b) memory)))
         (color (if live "#1a7f37" "#444"))
         (x0 (+ cx 5)) (x1 (+ cx (* 2 *cell*) -5)))
    (format out "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='2'/>~%"
            cx cy x0 cy color)
    (format out "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='2'/>~%"
            x1 cy (+ cx (* 2 *cell*)) cy color)
    (format out "  <rect x='~D' y='~D' width='~D' height='~D' fill='white' stroke='~A' stroke-width='2'/>~%"
            x0 (- cy 12) (- x1 x0) 24 color)
    (format out "  <text x='~D' y='~D' text-anchor='middle' font-size='10' font-family='monospace'>~A</text>~%"
            (+ cx *cell*) (+ cy 4)
            (%xml-escape (format-cmp-expr (list :cmp op a b))))))

(defun %svg-assign (out x y w dst v memory)
  "An unconditional numeric store box (its EN is the rail): the op label on
top, the value expression -- with its live value when MEMORY is supplied --
below, and the destination above the box like an instance name."
  (let* ((cx (%px x)) (cy (%px y))
         (color "#444")
         (x0 (+ cx 5)) (x1 (+ cx (* w *cell*) -5))
         (mid (+ cx (/ (* w *cell*) 2))))
    (format out "  <rect x='~D' y='~D' width='~D' height='~D' fill='white' stroke='~A' stroke-width='2'/>~%"
            x0 (- cy 18) (- x1 x0) 36 color)
    (format out "  <text x='~D' y='~D' text-anchor='middle' font-size='10' font-family='monospace'>~A</text>~%"
            mid (- cy 5) (value-op-label v))
    (format out "  <text x='~D' y='~D' text-anchor='middle' font-size='10' font-family='monospace'>~A</text>~%"
            mid (+ cy 12)
            (%xml-escape (if memory
                             (format nil "~A=~D" (format-value-expr v)
                                     (eval-value v memory))
                             (format-value-expr v))))
    (format out "  <text x='~D' y='~D' text-anchor='middle' font-size='11' font-family='monospace'>~A</text>~%"
            mid (- cy 22) dst)))

(defun %svg-wire (out x1 y1 x2 y2)
  (format out "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='#444' stroke-width='2'/>~%"
          (%px x1) (%px y1) (%px x2) (%px y2)))

(defun %svg-fb (out x y w h name)
  (format out "  <rect x='~D' y='~D' width='~D' height='~D' fill='#eef' stroke='#446' stroke-width='2'/>~%"
          (%px x) (- (%px y) 16) (* w *cell*) (+ (* (max 1 h) *cell*) 0))
  (format out "  <text x='~D' y='~D' text-anchor='middle' font-size='12' font-family='monospace'>~A</text>~%"
          (+ (%px x) (/ (* w *cell*) 2)) (+ (%px y) 4) name))

(defun render-svg (program &key memory (stream *standard-output*))
  "Render PROGRAM to an SVG document on STREAM.  If MEMORY is supplied,
energized elements are drawn in green."
  (multiple-value-bind (prims rows) (layout-program program)
    (let* ((max-x (loop for p in prims maximize
                        (ecase (first p)
                          ((:contact :coil :cmp) (+ 2 (second p)))
                          (:wire (max (second p) (fourth p)))
                          ((:fb :assign) (+ (second p) (fourth p))))))
           (width (+ (* 2 *margin*) (* (+ max-x 1) *cell*)))
           (height (+ (* 2 *margin*) (* (max rows 1) *cell*))))
      (format stream "<svg xmlns='http://www.w3.org/2000/svg' width='~D' height='~D'>~%"
              width height)
      (format stream "  <rect width='100%' height='100%' fill='white'/>~%")
      (dolist (p prims)
        (ecase (first p)
          (:contact (destructuring-bind (x y mode op) (rest p)
                      (%svg-contact stream x y mode op memory)))
          (:coil (destructuring-bind (x y kind op &optional preset) (rest p)
                   (%svg-coil stream x y kind op memory preset)))
          (:cmp (destructuring-bind (x y op a b) (rest p)
                  (%svg-cmp stream x y op a b memory)))
          (:assign (destructuring-bind (x y w dst v) (rest p)
                     (%svg-assign stream x y w dst v memory)))
          (:wire (apply #'%svg-wire stream (rest p)))
          (:fb (apply #'%svg-fb stream (rest p)))))
      (format stream "</svg>~%"))))

(defun render-svg-to-file (program path &key memory)
  "Render PROGRAM to an SVG file at PATH."
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (render-svg program :memory memory :stream out))
  path)
