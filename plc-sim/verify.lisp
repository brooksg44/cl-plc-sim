;;;; verify.lisp --- Dependency-free smoke test, runnable with:
;;;;
;;;;     sbcl --script verify.lisp
;;;;
;;;; Loads the core files in order and asserts core behaviour without needing
;;;; Quicklisp or FiveAM.  The full suite lives in tests/ (FiveAM).

(let ((src (merge-pathnames "src/" *load-pathname*)))
  (dolist (f '("package" "ir" "parser" "eval" "layout" "svg"))
    (load (merge-pathnames (concatenate 'string f ".lisp") src))))

(in-package #:plc-sim)

(defvar *fails* 0)
(defmacro check (form)
  `(if ,form
       (format t "  ok   ~S~%" ',form)
       (progn (incf *fails*) (format t "  FAIL ~S~%" ',form))))

(format t "~%== IR smart constructors ==~%")
(check (equal (series (contact "A") (contact "B"))
              '(:and (:contact :no "A") (:contact :no "B"))))
(check (equal (series (series (contact "A") (contact "B")) (contact "C"))
              '(:and (:contact :no "A") (:contact :no "B") (:contact :no "C"))))
(check (equal (parallel (contact "A") (contact "B"))
              '(:or (:contact :no "A") (:contact :no "B"))))
(check (equal (negate (contact "A" :no)) '(:contact :nc "A")))
(check (equal (negate (negate (contact "A"))) '(:contact :no "A")))

(format t "~%== Fold: IL -> tree ==~%")
(let ((prog (parse-il-string "LD A
AND B
OR C
ST Q")))
  ;; (A AND B) OR C
  (check (equal prog
                '((:coil :normal "Q"
                   (:or (:and (:contact :no "A") (:contact :no "B"))
                        (:contact :no "C")))))))

(let ((prog (parse-il-string "LD A
OR( B
AND C
)
ST Q")))
  ;; A OR (B AND C)
  (check (equal prog
                '((:coil :normal "Q"
                   (:or (:contact :no "A")
                        (:and (:contact :no "B") (:contact :no "C"))))))))

(format t "~%== Round-trip: tree -> IL -> tree (fixed point) ==~%")
(dolist (text '("LD A
AND B
OR C
ST Q"
                "LD A
OR( B
AND C
)
ANDN D
ST Q"))
  (let* ((p1 (parse-il-string text))
         (il (program->il p1))
         (p2 (parse-il-string il)))
    (check (equal p1 p2))))

(format t "~%== Evaluator ==~%")
(let ((m (make-memory))
      ;; (A AND B) OR C  ->  Q
      (rung (first (parse-il-string "LD A
AND B
OR C
ST Q"))))
  (setf (mem-bit m "A") t (mem-bit m "B") t)
  (check (eq t (execute-rung rung m)))
  (check (eq t (mem-bit m "Q")))
  (setf (mem-bit m "B") nil (mem-bit m "C") nil)
  (check (null (execute-rung rung m)))
  (check (null (mem-bit m "Q")))
  (setf (mem-bit m "C") t)
  (check (eq t (execute-rung rung m))))

(format t "~%== Seal-in latch over multiple scans ==~%")
(let ((sim (make-sim)))
  (load-il sim (merge-pathnames "examples/motor-seal-in.il" *load-pathname*))
  (let ((m (sim-memory sim)))
    (setf (mem-bit m "IX0.1") nil)      ; Stop NC -> not pressed (field state 0)
    (setf (mem-bit m "IX0.0") t)        ; press Start
    (step-scan sim)
    (check (eq t (mem-bit m "QX0.0")))  ; Run latched on
    (setf (mem-bit m "IX0.0") nil)      ; release Start
    (step-scan sim)
    (check (eq t (mem-bit m "QX0.0")))  ; still running (sealed in)
    (check (eq t (mem-bit m "QX0.1")))  ; lamp follows Run
    (setf (mem-bit m "IX0.1") t)        ; press Stop
    (step-scan sim)
    (check (null (mem-bit m "QX0.0")))  ; Run drops out
    (setf (mem-bit m "IX0.1") nil)
    (setf (mem-bit m "IX0.7") t)        ; fault -> reset coil
    (step-scan sim)
    (check (null (mem-bit m "QX0.0")))))

(format t "~%== Layout + SVG ==~%")
(let* ((prog (parse-il-string "LD A
AND B
OR C
ST Q"))
       (prims (layout-rung (first prog))))
  (check (find :coil prims :key #'first))
  (check (find :contact prims :key #'first))
  (let ((out (merge-pathnames "examples/motor-seal-in.svg" *load-pathname*)))
    (render-svg-to-file (parse-il (merge-pathnames "examples/motor-seal-in.il"
                                                   *load-pathname*))
                        out)
    (check (probe-file out))))

(format t "~%~[ALL CHECKS PASSED~:;~:*~D CHECK(S) FAILED~]~%" *fails*)
(sb-ext:exit :code (if (zerop *fails*) 0 1))
