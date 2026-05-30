;;;; plc-sim-clim.asd --- McCLIM front-end (depends on the core).
;;;;
;;;;   (ql:quickload "plc-sim-clim")
;;;;   (plc-sim-clim:run)

(asdf:defsystem "plc-sim-clim"
  :description "McCLIM ladder-diagram viewer and I/O simulator for plc-sim."
  :author "brooksg44 <brooksg44@gmail.com>"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("plc-sim" "mcclim" "bordeaux-threads")
  :serial t
  :components ((:module "src"
                :components ((:file "clim-ui")))))
