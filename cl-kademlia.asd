;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: BSD-3-Clause

;;;; cl-kademlia.asd - Kademlia DHT System Definition
;;;;
;;;; BSD 3-Clause License
;;;; Copyright (c) 2024-2025, Parkian Company LLC
;;;; See LICENSE for details.

(asdf:defsystem #:"cl-kademlia"
  :description "Kademlia Distributed Hash Table implementation in pure Common Lisp"
  :version "0.1.0"
  :author "Parkian Company LLC"
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
  :in-order-to ((asdf:test-op (test-op "cl-kademlia/test"))))

(asdf:defsystem #:"cl-kademlia/test"
  :description "Tests for cl-kademlia"
  :depends-on ("cl-kademlia")
  :serial t
  :components ((:module "test"
                :components ((:file "test-kademlia"))))
  :perform (asdf:test-op (op c)
             (let ((result (uiop:symbol-call :cl-kademlia.test :run-tests)))
               (unless result
                 (error "Tests failed")))))
