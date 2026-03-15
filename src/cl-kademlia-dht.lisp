;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: Apache-2.0

(in-package :cl-kademlia)

;;; ============================================================================
;;; Kademlia DHT Core Implementation
;;; ============================================================================

(defstruct kademlia-node
  "Kademlia DHT node with k-buckets routing table."
  (node-id (gensym "KAD-NODE") :type symbol)
  (k-value 20 :type (integer 1 *))
  (alpha 3 :type (integer 1 *))
  (buckets (make-array 160 :initial-element nil) :type vector)
  (storage (make-hash-table :test 'equal) :type hash-table)
  (pending-operations (make-hash-table :test 'equal) :type hash-table)
  (lock (sb-thread:make-mutex) :type sb-thread:mutex)
  (lookup-count 0 :type (integer 0 *))
  (store-count 0 :type (integer 0 *))
  (find-count 0 :type (integer 0 *)))

(defstruct k-bucket-internal
  "K-bucket for organizing nodes by distance."
  (index 0 :type (integer 0 159))
  (nodes nil :type list)
  (last-updated (get-universal-time) :type integer))

(defstruct dht-node-entry
  "Entry in DHT for stored value."
  (key "" :type string)
  (value nil :type t)
  (publisher-id (gensym) :type symbol)
  (timestamp (get-universal-time) :type integer)
  (ttl 3600 :type (integer 0 *)))

;;; ============================================================================
;;; XOR Distance Metric
;;; ============================================================================

(defun xor-distance (id1 id2)
  "Compute XOR distance between two node IDs.
   Parameters:
     ID1, ID2 - Node ID symbols/hashes
   Returns: Distance as positive integer"
  (let ((h1 (sxhash id1))
        (h2 (sxhash id2)))
    (logxor (abs h1) (abs h2))))

(defun distance-bit-length (distance)
  "Get bit length of distance (log distance).
   Parameters:
     DISTANCE - XOR distance integer
   Returns: Bit position of highest bit"
  (if (zerop distance)
      0
      (integer-length distance)))

(defun closer-to-p (candidate target reference)
  "Check if CANDIDATE is closer to TARGET than REFERENCE.
   Parameters:
     CANDIDATE, TARGET, REFERENCE - Node IDs
   Returns: T if closer, NIL otherwise"
  (< (xor-distance candidate target)
     (xor-distance reference target)))

(defun bucket-index (local-id remote-id)
  "Compute k-bucket index for remote node from local perspective.
   Parameters:
     LOCAL-ID, REMOTE-ID - Node IDs
   Returns: Bucket index (0-159)"
  (min 159 (max 0 (distance-bit-length (xor-distance local-id remote-id)))))

;;; ============================================================================
;;; Node and Bucket Management
;;; ============================================================================

(defun make-kademlia (&optional (k-value 20) (alpha 3))
  "Create a new Kademlia DHT node.
   Parameters:
     K-VALUE - Number of nodes per bucket
     ALPHA - Parallel query parameter
   Returns: kademlia-node instance"
  (make-kademlia-node :k-value k-value :alpha alpha))

(defun add-node (node remote-node-id)
  "Add a discovered node to the routing table.
   Parameters:
     NODE - kademlia-node instance
     REMOTE-NODE-ID - Node ID to add
   Returns: T if added, NIL if bucket full"
  (sb-thread:with-mutex ((kademlia-node-lock node))
    (let* ((bucket-idx (bucket-index (kademlia-node-node-id node) remote-node-id))
           (bucket (aref (kademlia-node-buckets node) bucket-idx)))
      (when (null bucket)
        (setf bucket (make-k-bucket-internal :index bucket-idx))
        (setf (aref (kademlia-node-buckets node) bucket-idx) bucket))
      ;; Add if not present and bucket not full
      (unless (member remote-node-id (k-bucket-internal-nodes bucket))
        (if (< (length (k-bucket-internal-nodes bucket))
               (kademlia-node-k-value node))
            (progn
              (push remote-node-id (k-bucket-internal-nodes bucket))
              (setf (k-bucket-internal-last-updated bucket) (get-universal-time))
              t)
            nil)))))

(defun find-closest-nodes (node target-id &optional (count 20))
  "Find COUNT closest nodes to TARGET-ID.
   Parameters:
     NODE - kademlia-node instance
     TARGET-ID - Target node ID
     COUNT - Number to return (default 20)
   Returns: List of closest node IDs"
  (sb-thread:with-mutex ((kademlia-node-lock node))
    (let ((all-nodes nil))
      ;; Collect all nodes from all buckets
      (loop for bucket across (kademlia-node-buckets node)
            when bucket
            do (setf all-nodes (append (k-bucket-internal-nodes bucket) all-nodes)))
      ;; Sort by distance to target and return top COUNT
      (let ((sorted (sort (copy-list all-nodes)
                          (lambda (a b)
                            (< (xor-distance a target-id)
                               (xor-distance b target-id))))))
        (subseq sorted 0 (min count (length sorted)))))))

(defun node-count (node)
  "Count unique nodes in routing table.
   Parameters:
     NODE - kademlia-node instance
   Returns: Total number of nodes"
  (sb-thread:with-mutex ((kademlia-node-lock node))
    (let ((seen (make-hash-table :test 'eq)))
      (loop for bucket across (kademlia-node-buckets node)
            when bucket
            do (loop for n in (k-bucket-internal-nodes bucket)
                     do (setf (gethash n seen) t)))
      (hash-table-count seen))))

;;; ============================================================================
;;; Storage Operations
;;; ============================================================================

(defun store-value (node key value &key (ttl 3600) (publisher nil))
  "Store a key-value pair.
   Parameters:
     NODE - kademlia-node instance
     KEY - Storage key
     VALUE - Value to store
     TTL - Time to live in seconds
     PUBLISHER - Publisher ID
   Returns: T"
  (sb-thread:with-mutex ((kademlia-node-lock node))
    (let ((entry (make-dht-node-entry
                  :key key
                  :value value
                  :publisher-id (or publisher (kademlia-node-node-id node))
                  :ttl ttl)))
      (setf (gethash key (kademlia-node-storage node)) entry)
      (incf (kademlia-node-store-count node))
      t)))

(defun find-value (node key)
  "Retrieve a stored value.
   Parameters:
     NODE - kademlia-node instance
     KEY - Storage key
   Returns: (values value found-p)"
  (sb-thread:with-mutex ((kademlia-node-lock node))
    (let ((entry (gethash key (kademlia-node-storage node))))
      (if entry
          (values (dht-node-entry-value entry) t)
          (values nil nil)))))

(defun value-expired-p (entry)
  "Check if a DHT entry has expired.
   Parameters:
     ENTRY - dht-node-entry
   Returns: T if expired"
  (>= (- (get-universal-time) (dht-node-entry-timestamp entry))
      (dht-node-entry-ttl entry)))

(defun cleanup-expired (node)
  "Remove expired entries from storage.
   Parameters:
     NODE - kademlia-node instance
   Returns: Count of entries removed"
  (sb-thread:with-mutex ((kademlia-node-lock node))
    (let ((count 0))
      (loop for key being the hash-keys of (kademlia-node-storage node)
            for entry = (gethash key (kademlia-node-storage node))
            when (value-expired-p entry)
            do (remhash key (kademlia-node-storage node))
               (incf count))
      count)))

;;; ============================================================================
;;; Lookup Operations
;;; ============================================================================

(defun iterative-find-node (node target-id)
  "Perform iterative node lookup.
   Parameters:
     NODE - kademlia-node instance
     TARGET-ID - ID to find
   Returns: List of closest nodes found"
  (sb-thread:with-mutex ((kademlia-node-lock node))
    (incf (kademlia-node-lookup-count node))
    (find-closest-nodes node target-id)))

(defun iterative-find-value (node key)
  "Perform iterative value lookup.
   Parameters:
     NODE - kademlia-node instance
     KEY - Key to find
   Returns: (values value found-p nodes-checked)"
  (sb-thread:with-mutex ((kademlia-node-lock node))
    (incf (kademlia-node-find-count node))
    (multiple-value-bind (val found)
        (find-value node key)
      (if found
          (values val t 1)
          (values nil nil (node-count node))))))

;;; ============================================================================
;;; Statistics
;;; ============================================================================

(defun node-stats (node)
  "Get statistics for a Kademlia node.
   Parameters:
     NODE - kademlia-node instance
   Returns: Property list"
  (sb-thread:with-mutex ((kademlia-node-lock node))
    (list :node-id (kademlia-node-node-id node)
          :k-value (kademlia-node-k-value node)
          :alpha (kademlia-node-alpha node)
          :peer-count (node-count node)
          :storage-size (hash-table-count (kademlia-node-storage node))
          :lookups (kademlia-node-lookup-count node)
          :stores (kademlia-node-store-count node)
          :finds (kademlia-node-find-count node))))
