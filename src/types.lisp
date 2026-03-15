;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: Apache-2.0

(in-package #:cl-kademlia)

;;; Core types for cl-kademlia
(deftype cl-kademlia-id () '(unsigned-byte 64))
(deftype cl-kademlia-status () '(member :ready :active :error :shutdown))
