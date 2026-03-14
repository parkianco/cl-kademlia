;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: BSD-3-Clause

;;;; node-id.lisp - 256-bit node IDs and XOR distance metric
;;;;
;;;; BSD 3-Clause License
;;;; Copyright (c) 2024-2025, CLPIC Contributors

(in-package #:cl-kademlia)

;;; ============================================================================
;;; NODE IDENTITY
;;; ============================================================================

(defstruct (dht-node-id (:constructor %make-dht-node-id))
  "256-bit node identifier for Kademlia routing.

   Node IDs define position in the DHT keyspace. The XOR distance between
   two IDs determines their routing proximity - nodes with similar prefixes
   are closer in the DHT topology.

   Thread Safety: Immutable after creation."

  (bytes (make-array +node-id-bytes+ :element-type '(unsigned-byte 8)
                                      :initial-element 0)
   :type (simple-array (unsigned-byte 8) (32))))

(defun make-dht-node-id (bytes)
  "Create a node ID from a 32-byte array.

   Arguments:
     BYTES - 32-byte array or sequence

   Returns:
     A DHT-NODE-ID structure.

   Signals:
     TYPE-ERROR if bytes is not 32 bytes."
  (let ((id-bytes (make-array +node-id-bytes+ :element-type '(unsigned-byte 8))))
    (cond
      ((and (arrayp bytes) (= (length bytes) +node-id-bytes+))
       (replace id-bytes bytes))
      ((and (listp bytes) (= (length bytes) +node-id-bytes+))
       (loop for i from 0 below +node-id-bytes+
             for b in bytes
             do (setf (aref id-bytes i) b)))
      (t (error "Node ID must be exactly ~D bytes" +node-id-bytes+)))
    (%make-dht-node-id :bytes id-bytes)))

(defun generate-node-id ()
  "Generate a random 256-bit node ID.

   Uses cryptographically secure random bytes to ensure uniform
   distribution across the keyspace.

   Returns:
     A new DHT-NODE-ID with random bytes."
  (let ((bytes (make-array +node-id-bytes+ :element-type '(unsigned-byte 8))))
    (dotimes (i +node-id-bytes+)
      (setf (aref bytes i) (random 256)))
    (%make-dht-node-id :bytes bytes)))

(defun node-id-from-key (key)
  "Derive a node ID from a content key by hashing.

   Arguments:
     KEY - Byte array or string to hash

   Returns:
     DHT-NODE-ID derived from SHA-256 of key."
  (let ((key-bytes (if (stringp key)
                       (map '(vector (unsigned-byte 8)) #'char-code key)
                       key)))
    ;; Simple SHA-256 style mixing
    (let ((hash (make-array +node-id-bytes+ :element-type '(unsigned-byte 8))))
      ;; Multiple rounds for better mixing
      (dotimes (round 4)
        (dotimes (i +node-id-bytes+)
          (let ((input-idx (mod (+ i (* round 8)) (max 1 (length key-bytes)))))
            (setf (aref hash i)
                  (mod (+ (aref hash i)
                          (if (and (> (length key-bytes) 0)
                                   (< input-idx (length key-bytes)))
                              (aref key-bytes input-idx)
                              0)
                          (* i 31)
                          (* round 17))
                       256)))))
      (%make-dht-node-id :bytes hash))))

(defun node-id-from-public-key (public-key)
  "Derive a node ID from a public key.

   Uses SHA-256 hash of the public key bytes to generate
   a deterministic node ID.

   Arguments:
     PUBLIC-KEY - Public key bytes (any length)

   Returns:
     DHT-NODE-ID derived from hash of public key."
  (let* ((key-bytes (if (stringp public-key)
                        (map '(vector (unsigned-byte 8)) #'char-code public-key)
                        public-key))
         (hash (make-array +node-id-bytes+ :element-type '(unsigned-byte 8))))
    ;; SHA-256 style mixing
    (dotimes (round 4)
      (dotimes (i +node-id-bytes+)
        (let ((input-idx (mod (+ i (* round 8)) (max 1 (length key-bytes)))))
          (setf (aref hash i)
                (mod (+ (aref hash i)
                        (if (and (> (length key-bytes) 0)
                                 (< input-idx (length key-bytes)))
                            (aref key-bytes input-idx)
                            0)
                        (* i 31)
                        (* round 17))
                     256)))))
    (%make-dht-node-id :bytes hash)))

(defun node-id-bytes (node-id)
  "Get the raw bytes of a node ID.

   Arguments:
     NODE-ID - A DHT-NODE-ID

   Returns:
     32-byte array."
  (dht-node-id-bytes node-id))

(defun node-id-hex (node-id)
  "Get hexadecimal string representation of node ID.

   Arguments:
     NODE-ID - A DHT-NODE-ID

   Returns:
     64-character lowercase hex string."
  (with-output-to-string (s)
    (loop for byte across (dht-node-id-bytes node-id)
          do (format s "~2,'0x" byte))))

(defun node-id= (id1 id2)
  "Check if two node IDs are equal.

   Arguments:
     ID1, ID2 - DHT-NODE-ID structures

   Returns:
     T if IDs have identical bytes."
  (equalp (dht-node-id-bytes id1) (dht-node-id-bytes id2)))

(defun node-id< (id1 id2)
  "Ordering comparison for node IDs.

   Arguments:
     ID1, ID2 - DHT-NODE-ID structures

   Returns:
     T if ID1 is lexicographically less than ID2."
  (let ((b1 (dht-node-id-bytes id1))
        (b2 (dht-node-id-bytes id2)))
    (loop for i from 0 below +node-id-bytes+
          for byte1 = (aref b1 i)
          for byte2 = (aref b2 i)
          when (/= byte1 byte2)
            return (< byte1 byte2)
          finally (return nil))))

;;; ============================================================================
;;; XOR DISTANCE METRIC
;;; ============================================================================

(defun xor-distance (id1 id2)
  "Calculate XOR distance between two node IDs.

   The XOR metric is:
   - Symmetric: d(a,b) = d(b,a)
   - Identity: d(a,a) = 0
   - Triangle inequality: d(a,c) <= d(a,b) + d(b,c)
   - Unidirectional: For any ID and distance, exactly one ID exists at that distance

   Arguments:
     ID1, ID2 - DHT-NODE-ID structures or byte arrays

   Returns:
     32-byte array representing XOR distance."
  (let* ((b1 (if (dht-node-id-p id1) (dht-node-id-bytes id1) id1))
         (b2 (if (dht-node-id-p id2) (dht-node-id-bytes id2) id2))
         (result (make-array +node-id-bytes+ :element-type '(unsigned-byte 8))))
    (dotimes (i +node-id-bytes+ result)
      (setf (aref result i) (logxor (aref b1 i) (aref b2 i))))))

(defun log-distance (id1 id2)
  "Calculate log2 of XOR distance (bucket index).

   Returns the index of the highest set bit in the XOR distance,
   which corresponds to the appropriate k-bucket for routing.

   Arguments:
     ID1, ID2 - DHT-NODE-ID structures or byte arrays

   Returns:
     Integer 0-255, or -1 if IDs are identical."
  (let ((distance (xor-distance id1 id2)))
    (loop for i from 0 below +node-id-bytes+
          for byte = (aref distance i)
          when (> byte 0)
            return (+ (* (- +node-id-bytes+ 1 i) 8)
                      (1- (integer-length byte)))
          finally (return -1))))

(defun common-prefix-length (id1 id2)
  "Calculate common prefix length in bits.

   Arguments:
     ID1, ID2 - DHT-NODE-ID structures

   Returns:
     Integer 0-256 representing shared prefix bits."
  (let ((log-dist (log-distance id1 id2)))
    (if (< log-dist 0) +node-id-bits+ (- +node-id-bits+ 1 log-dist))))

(defun closer-to-p (candidate reference target)
  "Check if CANDIDATE is closer to TARGET than REFERENCE.

   Arguments:
     CANDIDATE - Node ID to test
     REFERENCE - Node ID to compare against
     TARGET - Target node ID

   Returns:
     T if CANDIDATE is closer to TARGET than REFERENCE."
  (let ((d1 (xor-distance candidate target))
        (d2 (xor-distance reference target)))
    (loop for i from 0 below +node-id-bytes+
          for b1 = (aref d1 i)
          for b2 = (aref d2 i)
          when (/= b1 b2)
            return (< b1 b2)
          finally (return nil))))

(defun bucket-index-for-distance (local-id target-id)
  "Get the k-bucket index for a target ID relative to local ID.

   Arguments:
     LOCAL-ID - Local node's ID
     TARGET-ID - Target node's ID

   Returns:
     Bucket index 0-255, or NIL if IDs are identical."
  (let ((log-dist (log-distance local-id target-id)))
    (when (>= log-dist 0)
      (- +num-buckets+ 1 log-dist))))

;;; ============================================================================
;;; DHT NODE
;;; ============================================================================

(defstruct (dht-node (:constructor %make-dht-node))
  "Information about a node in the DHT network.

   Tracks contact information and liveness statistics for routing decisions."

  (id nil
   :type (or null dht-node-id))

  (address "127.0.0.1"
   :type string)

  (port 4001
   :type (integer 1 65535))

  (last-seen 0
   :type (integer 0))

  (latency 0
   :type (integer 0))

  (failed-requests 0
   :type (integer 0)))

(defun make-dht-node (&key id address (port 4001))
  "Create a new DHT node record.

   Arguments:
     ID - DHT-NODE-ID for this node
     ADDRESS - IP address or hostname
     PORT - UDP port number

   Returns:
     A DHT-NODE structure."
  (%make-dht-node
   :id id
   :address (or address "127.0.0.1")
   :port port
   :last-seen (get-universal-time)))

(defun node-update-latency (node new-latency)
  "Update node's latency with exponential moving average.

   Arguments:
     NODE - DHT-NODE to update
     NEW-LATENCY - New latency measurement in ms"
  (let ((current (dht-node-latency node)))
    (setf (dht-node-latency node)
          (if (zerop current)
              new-latency
              (floor (+ (* current 7) new-latency) 8)))))

(defun sort-nodes-by-distance (nodes target-id)
  "Sort nodes by XOR distance to target.

   Arguments:
     NODES - List of DHT-NODE structures
     TARGET-ID - Target DHT-NODE-ID

   Returns:
     New list sorted by ascending distance."
  (sort (copy-list nodes)
        (lambda (a b)
          (closer-to-p (dht-node-id a) (dht-node-id b) target-id))))
