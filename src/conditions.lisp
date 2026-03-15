;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: Apache-2.0

(in-package #:cl-kademlia)

(define-condition cl-kademlia-error (error)
  ((message :initarg :message :reader cl-kademlia-error-message))
  (:report (lambda (condition stream)
             (format stream "cl-kademlia error: ~A" (cl-kademlia-error-message condition)))))
