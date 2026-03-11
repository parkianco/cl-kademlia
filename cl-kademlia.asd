;;;; cl-kademlia.asd - Kademlia DHT System Definition
;;;;
;;;; BSD 3-Clause License
;;;; Copyright (c) 2024-2025, CLPIC Contributors
;;;; See LICENSE for details.

(defsystem "cl-kademlia"
  :description "Kademlia Distributed Hash Table implementation in pure Common Lisp"
  :version "1.0.0"
  :author "CLPIC Contributors"
  :license "BSD-3-Clause"
  :depends-on ()
  :serial t
  :components ((:file "package")
               (:module "src"
                :serial t
                :components ((:file "util")
                             (:file "node-id")
                             (:file "routing")
                             (:file "lookup")
                             (:file "protocol"))))
  :in-order-to ((test-op (test-op "cl-kademlia/test"))))

(defsystem "cl-kademlia/test"
  :description "Tests for cl-kademlia"
  :depends-on ("cl-kademlia")
  :serial t
  :components ((:module "test"
                :components ((:file "test-kademlia"))))
  :perform (test-op (op c)
             (uiop:symbol-call :cl-kademlia.test :run-tests)))
