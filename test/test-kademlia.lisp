;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: BSD-3-Clause

;;;; test-kademlia.lisp - Tests for cl-kademlia
;;;;
;;;; BSD 3-Clause License
;;;; Copyright (c) 2024-2025, CLPIC Contributors

(in-package #:cl-kademlia.test)

;;; ============================================================================
;;; TEST FRAMEWORK
;;; ============================================================================

(defvar *test-count* 0)
(defvar *test-passed* 0)
(defvar *test-failed* 0)

(defmacro deftest (name &body body)
  "Define a test case."
  `(defun ,name ()
     (incf *test-count*)
     (handler-case
         (progn
           ,@body
           (incf *test-passed*)
           (format t "  PASS: ~A~%" ',name)
           t)
       (error (e)
         (incf *test-failed*)
         (format t "  FAIL: ~A - ~A~%" ',name e)
         nil))))

(defmacro assert-true (form &optional message)
  `(unless ,form
     (error "Assertion failed~@[: ~A~]" ,message)))

(defmacro assert-false (form &optional message)
  `(when ,form
     (error "Assertion failed (expected false)~@[: ~A~]" ,message)))

(defmacro assert-equal (expected actual &optional message)
  `(unless (equal ,expected ,actual)
     (error "Expected ~S but got ~S~@[: ~A~]" ,expected ,actual ,message)))

(defmacro assert-eql (expected actual &optional message)
  `(unless (eql ,expected ,actual)
     (error "Expected ~S but got ~S~@[: ~A~]" ,expected ,actual ,message)))

;;; ============================================================================
;;; NODE ID TESTS
;;; ============================================================================

(deftest test-generate-node-id
  "Test random node ID generation."
  (let ((id1 (generate-node-id))
        (id2 (generate-node-id)))
    (assert-true (dht-node-id-p id1) "Should return a dht-node-id")
    (assert-true (dht-node-id-p id2) "Should return a dht-node-id")
    (assert-false (node-id= id1 id2) "Two random IDs should be different")
    (assert-eql 32 (length (node-id-bytes id1)) "ID should be 32 bytes")))

(deftest test-make-dht-node-id
  "Test creating node ID from bytes."
  (let* ((bytes (make-array 32 :element-type '(unsigned-byte 8)
                               :initial-element 42))
         (id (make-dht-node-id bytes)))
    (assert-true (dht-node-id-p id))
    (assert-eql 42 (aref (node-id-bytes id) 0))))

(deftest test-node-id-from-key
  "Test deriving node ID from content key."
  (let ((id1 (node-id-from-key "hello"))
        (id2 (node-id-from-key "hello"))
        (id3 (node-id-from-key "world")))
    (assert-true (node-id= id1 id2) "Same key should produce same ID")
    (assert-false (node-id= id1 id3) "Different keys should produce different IDs")))

(deftest test-node-id-hex
  "Test hex string representation."
  (let* ((bytes (make-array 32 :element-type '(unsigned-byte 8)
                               :initial-element 0))
         (id (make-dht-node-id bytes))
         (hex (node-id-hex id)))
    (assert-eql 64 (length hex) "Hex string should be 64 chars")
    (assert-equal "0000000000000000000000000000000000000000000000000000000000000000" hex)))

(deftest test-node-id-comparison
  "Test node ID equality and ordering."
  (let* ((bytes1 (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0))
         (bytes2 (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0))
         (bytes3 (make-array 32 :element-type '(unsigned-byte 8) :initial-element 1)))
    (setf (aref bytes1 0) 1)
    (setf (aref bytes2 0) 1)
    (setf (aref bytes3 0) 2)
    (let ((id1 (make-dht-node-id bytes1))
          (id2 (make-dht-node-id bytes2))
          (id3 (make-dht-node-id bytes3)))
      (assert-true (node-id= id1 id2) "Equal IDs should be equal")
      (assert-false (node-id= id1 id3) "Different IDs should not be equal")
      (assert-true (node-id< id1 id3) "id1 < id3"))))

;;; ============================================================================
;;; XOR DISTANCE TESTS
;;; ============================================================================

(deftest test-xor-distance
  "Test XOR distance calculation."
  (let* ((bytes1 (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0))
         (bytes2 (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0)))
    (setf (aref bytes1 0) #xFF)
    (setf (aref bytes2 0) #x0F)
    (let ((id1 (make-dht-node-id bytes1))
          (id2 (make-dht-node-id bytes2))
          (dist (xor-distance (make-dht-node-id bytes1) (make-dht-node-id bytes2))))
      (assert-eql #xF0 (aref dist 0) "XOR of FF and 0F should be F0")
      ;; Self-distance should be zero
      (let ((self-dist (xor-distance id1 id1)))
        (assert-true (every #'zerop self-dist) "Self distance should be 0")))))

(deftest test-log-distance
  "Test log2 distance calculation."
  (let* ((bytes1 (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0))
         (bytes2 (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0)))
    ;; Test identical IDs
    (let ((id1 (make-dht-node-id bytes1))
          (id2 (make-dht-node-id bytes2)))
      (assert-eql -1 (log-distance id1 id2) "Identical IDs should have log-distance -1"))
    ;; Test different IDs
    (setf (aref bytes2 0) 1)
    (let ((id1 (make-dht-node-id bytes1))
          (id2 (make-dht-node-id bytes2)))
      (assert-eql 248 (log-distance id1 id2) "Single bit in first byte"))))

(deftest test-closer-to-p
  "Test distance comparison."
  (let* ((target-bytes (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0))
         (close-bytes (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0))
         (far-bytes (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0)))
    (setf (aref close-bytes 31) 1)
    (setf (aref far-bytes 31) 255)
    (let ((target (make-dht-node-id target-bytes))
          (close (make-dht-node-id close-bytes))
          (far (make-dht-node-id far-bytes)))
      (assert-true (closer-to-p close far target) "close should be closer than far")
      (assert-false (closer-to-p far close target) "far should not be closer than close"))))

;;; ============================================================================
;;; K-BUCKET TESTS
;;; ============================================================================

(deftest test-make-k-bucket
  "Test k-bucket creation."
  (let ((bucket (make-k-bucket 5)))
    (assert-true (k-bucket-p bucket))
    (assert-eql 5 (k-bucket-index bucket))
    (assert-eql +kademlia-k+ (k-bucket-capacity bucket))
    (assert-eql 0 (bucket-size bucket))))

(deftest test-bucket-add
  "Test adding nodes to bucket."
  (let ((bucket (make-k-bucket 0 :capacity 3))
        (node1 (make-dht-node :id (generate-node-id) :address "1.1.1.1" :port 1001))
        (node2 (make-dht-node :id (generate-node-id) :address "2.2.2.2" :port 1002))
        (node3 (make-dht-node :id (generate-node-id) :address "3.3.3.3" :port 1003))
        (node4 (make-dht-node :id (generate-node-id) :address "4.4.4.4" :port 1004)))
    (assert-eql :added (bucket-add bucket node1))
    (assert-eql :added (bucket-add bucket node2))
    (assert-eql :added (bucket-add bucket node3))
    (assert-eql 3 (bucket-size bucket))
    (assert-true (bucket-full-p bucket))
    ;; Fourth node goes to replacement cache
    (assert-eql :cached (bucket-add bucket node4))))

(deftest test-bucket-update-existing
  "Test updating existing node in bucket."
  (let* ((bucket (make-k-bucket 0))
         (id (generate-node-id))
         (node1 (make-dht-node :id id :address "1.1.1.1" :port 1001))
         (node2 (make-dht-node :id id :address "2.2.2.2" :port 2002)))
    (bucket-add bucket node1)
    (assert-eql :updated (bucket-add bucket node2))
    (assert-eql 1 (bucket-size bucket))
    (let ((found (bucket-get bucket id)))
      (assert-equal "2.2.2.2" (dht-node-address found)))))

(deftest test-bucket-remove
  "Test removing nodes from bucket."
  (let* ((bucket (make-k-bucket 0))
         (id (generate-node-id))
         (node (make-dht-node :id id)))
    (bucket-add bucket node)
    (assert-eql 1 (bucket-size bucket))
    (bucket-remove bucket id)
    (assert-eql 0 (bucket-size bucket))))

;;; ============================================================================
;;; ROUTING TABLE TESTS
;;; ============================================================================

(deftest test-make-routing-table
  "Test routing table creation."
  (let* ((local-id (generate-node-id))
         (table (make-routing-table local-id)))
    (assert-true (routing-table-p table))
    (assert-true (node-id= local-id (routing-table-local-id table)))
    (assert-eql 256 (length (routing-table-buckets table)))
    (assert-eql 0 (routing-table-size table))))

(deftest test-routing-table-add
  "Test adding nodes to routing table."
  (let* ((local-id (generate-node-id))
         (table (make-routing-table local-id))
         (node1 (make-dht-node :id (generate-node-id) :address "1.1.1.1"))
         (node2 (make-dht-node :id (generate-node-id) :address "2.2.2.2")))
    ;; Can't add self
    (assert-eql :self (routing-table-add table (make-dht-node :id local-id)))
    ;; Can add other nodes
    (assert-eql :added (routing-table-add table node1))
    (assert-eql :added (routing-table-add table node2))
    (assert-eql 2 (routing-table-size table))))

(deftest test-routing-table-closest
  "Test finding closest nodes."
  (let* ((local-id (generate-node-id))
         (table (make-routing-table local-id)))
    ;; Add some nodes
    (dotimes (i 50)
      (routing-table-add table (make-dht-node :id (generate-node-id))))
    (let ((target (generate-node-id))
          (closest (routing-table-closest table (generate-node-id) 10)))
      (assert-true (<= (length closest) 10)))))

(deftest test-routing-table-get
  "Test retrieving node by ID."
  (let* ((local-id (generate-node-id))
         (table (make-routing-table local-id))
         (node-id (generate-node-id))
         (node (make-dht-node :id node-id :address "test-address")))
    (routing-table-add table node)
    (let ((found (routing-table-get table node-id)))
      (assert-true (not (null found)))
      (assert-equal "test-address" (dht-node-address found)))))

;;; ============================================================================
;;; VALUE STORE TESTS
;;; ============================================================================

(deftest test-value-store-basic
  "Test basic value store operations."
  (let ((store (make-value-store))
        (key (generate-node-id))
        (value "test-value"))
    (assert-true (value-store-put store key value))
    (assert-equal value (value-store-get store key))
    (assert-true (value-store-contains-p store key))
    (assert-eql 1 (value-store-size store))
    (assert-true (value-store-delete store key))
    (assert-false (value-store-contains-p store key))))

(deftest test-value-store-ttl
  "Test value expiration."
  (let ((store (make-value-store))
        (key (generate-node-id)))
    ;; Store with very short TTL (already expired)
    (value-store-put store key "value" :ttl -1)
    (assert-false (value-store-get store key) "Expired value should return nil")))

;;; ============================================================================
;;; PROVIDER STORE TESTS
;;; ============================================================================

(deftest test-provider-store-basic
  "Test basic provider store operations."
  (let ((store (make-provider-store))
        (key (generate-node-id))
        (provider-id (generate-node-id)))
    (assert-true (provider-store-add store key provider-id '(("1.1.1.1" . 4001))))
    (let ((providers (provider-store-get store key)))
      (assert-eql 1 (length providers))
      (assert-true (node-id= provider-id (provider-record-provider-id (first providers)))))))

(deftest test-provider-store-multiple
  "Test multiple providers per key."
  (let ((store (make-provider-store :max-providers-per-key 5))
        (key (generate-node-id)))
    (dotimes (i 5)
      (provider-store-add store key (generate-node-id) '(("1.1.1.1" . 4001))))
    (let ((providers (provider-store-get store key)))
      (assert-eql 5 (length providers)))))

;;; ============================================================================
;;; DHT TESTS
;;; ============================================================================

(deftest test-make-dht
  "Test DHT creation."
  (let ((dht (make-dht)))
    (assert-true (dht-p dht))
    (assert-true (dht-node-id-p (dht-local-id dht)))
    (assert-true (routing-table-p (dht-routing-table dht)))
    (assert-true (value-store-p (dht-value-store dht)))
    (assert-true (provider-store-p (dht-provider-store dht)))))

(deftest test-dht-start-stop
  "Test DHT lifecycle."
  (let ((dht (make-dht)))
    (assert-false (dht-running-p dht))
    (dht-start dht)
    (assert-true (dht-running-p dht))
    (dht-stop dht)
    (assert-false (dht-running-p dht))))

(deftest test-dht-put-get
  "Test storing and retrieving values."
  (let ((dht (make-dht))
        (key (generate-node-id))
        (value "test-value"))
    (dht-start dht)
    (assert-true (dht-put dht key value))
    (assert-equal value (dht-get dht key))))

(deftest test-dht-providers
  "Test provider announcements."
  (let ((dht (make-dht))
        (key (generate-node-id)))
    (dht-start dht)
    (assert-true (dht-add-provider dht key))
    (let ((providers (dht-get-providers dht key)))
      (assert-eql 1 (length providers)))))

(deftest test-dht-stats
  "Test DHT statistics."
  (let ((dht (make-dht)))
    (dht-start dht)
    (let ((stats (dht-statistics dht)))
      (assert-true (getf stats :local-id))
      (assert-true (getf stats :running-p)))))

;;; ============================================================================
;;; LOOKUP TESTS
;;; ============================================================================

(deftest test-lookup-state
  "Test lookup state creation."
  (let* ((local-id (generate-node-id))
         (table (make-routing-table local-id))
         (target (generate-node-id))
         (state (make-lookup-state target table)))
    (assert-true (lookup-state-p state))
    (assert-true (node-id= target (lookup-state-target state)))))

(deftest test-iterative-find-node
  "Test iterative node lookup."
  (let ((dht (make-dht))
        (target (generate-node-id)))
    (dht-start dht)
    ;; Add some nodes
    (dotimes (i 20)
      (routing-table-add (dht-routing-table dht)
                         (make-dht-node :id (generate-node-id))))
    (multiple-value-bind (closest elapsed queries)
        (iterative-find-node dht target)
      (declare (ignore elapsed queries))
      ;; Should return up to k nodes
      (assert-true (<= (length closest) +kademlia-k+)))))

;;; ============================================================================
;;; TEST RUNNER
;;; ============================================================================

(defun run-tests ()
  "Run all tests and report results."
  (setf *test-count* 0
        *test-passed* 0
        *test-failed* 0)

  (format t "~%Running cl-kademlia tests...~%~%")

  ;; Node ID tests
  (format t "Node ID tests:~%")
  (test-generate-node-id)
  (test-make-dht-node-id)
  (test-node-id-from-key)
  (test-node-id-hex)
  (test-node-id-comparison)

  ;; XOR distance tests
  (format t "~%XOR distance tests:~%")
  (test-xor-distance)
  (test-log-distance)
  (test-closer-to-p)

  ;; K-bucket tests
  (format t "~%K-bucket tests:~%")
  (test-make-k-bucket)
  (test-bucket-add)
  (test-bucket-update-existing)
  (test-bucket-remove)

  ;; Routing table tests
  (format t "~%Routing table tests:~%")
  (test-make-routing-table)
  (test-routing-table-add)
  (test-routing-table-closest)
  (test-routing-table-get)

  ;; Value store tests
  (format t "~%Value store tests:~%")
  (test-value-store-basic)
  (test-value-store-ttl)

  ;; Provider store tests
  (format t "~%Provider store tests:~%")
  (test-provider-store-basic)
  (test-provider-store-multiple)

  ;; DHT tests
  (format t "~%DHT tests:~%")
  (test-make-dht)
  (test-dht-start-stop)
  (test-dht-put-get)
  (test-dht-providers)
  (test-dht-stats)

  ;; Lookup tests
  (format t "~%Lookup tests:~%")
  (test-lookup-state)
  (test-iterative-find-node)

  ;; Summary
  (format t "~%========================================~%")
  (format t "Tests: ~D  Passed: ~D  Failed: ~D~%"
          *test-count* *test-passed* *test-failed*)
  (format t "========================================~%")

  (zerop *test-failed*))
