;;;; load-clim.lisp --- Load the McCLIM GUI, working around a dist bug.
;;;;
;;;;   sbcl --load load-clim.lisp
;;;;   (plc-sim-clim:run :il #p"examples/motor-seal-in.il")
;;;;
;;;; WHY THE SHIM:
;;;; In Quicklisp dist 2026-01-01, cl-ppcre-20250622 dropped the symbol
;;;; CL-PPCRE:*STANDARD-OPTIMIZE-SETTINGS*, but cl-unicode (pulled in by McCLIM
;;;; via CLX) still does (:import-from :cl-ppcre :*standard-optimize-settings*).
;;;; That makes a bare (ql:quickload "mcclim") abort with
;;;;   "no symbol named *STANDARD-OPTIMIZE-SETTINGS* in CL-PPCRE".
;;;; We re-create the symbol before cl-unicode compiles.  Remove this shim once
;;;; upstream cl-ppcre/cl-unicode are back in sync.
;;;;
;;;; DISPLAY REQUIREMENT (macOS):
;;;; McCLIM's default backend is CLX (X11).  Install XQuartz and start it
;;;; (`open -a XQuartz`) so $DISPLAY is set, otherwise RUN cannot open a window.

(require :asdf)

(let ((ql (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql) (load ql)))

(funcall (read-from-string "ql:quickload") "cl-ppcre" :silent t)

;; --- the compatibility shim ------------------------------------------------
(unless (find-symbol "*STANDARD-OPTIMIZE-SETTINGS*" :cl-ppcre)
  (let ((s (intern "*STANDARD-OPTIMIZE-SETTINGS*" :cl-ppcre)))
    (proclaim (list 'special s))
    (set s '(optimize speed (safety 0) (space 0) (debug 1) (compilation-speed 0)))
    (export s :cl-ppcre)
    (format t "~&; shim: re-created ~S~%" s)))

;; --- make this directory's systems visible, then load the GUI -------------
(pushnew (or *load-truename* (truename "."))
         asdf:*central-registry* :test #'equal)
;; strip the filename so the registry entry is the directory
(setf (first asdf:*central-registry*)
      (make-pathname :name nil :type nil :defaults (first asdf:*central-registry*)))

(funcall (read-from-string "ql:quickload") "mcclim" :silent t)
(funcall (read-from-string "ql:quickload") "plc-sim-clim")

(format t "~&;; Ready.  Launch with:  (plc-sim-clim:run :il #p\"examples/motor-seal-in.il\")~%")
