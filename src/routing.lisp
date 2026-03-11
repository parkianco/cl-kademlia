;;;; routing.lisp - K-buckets and routing table
;;;;
;;;; BSD 3-Clause License
;;;; Copyright (c) 2024-2025, CLPIC Contributors

(in-package #:cl-kademlia)

;;; ============================================================================
;;; K-BUCKET
;;; ============================================================================

(defstruct (k-bucket (:constructor %make-k-bucket))
  "Single k-bucket in the Kademlia routing table.

   Each bucket stores nodes at a specific XOR distance range from the local node.
   Bucket i contains nodes where log2(distance) = 255 - i.

   Nodes are ordered by last-seen time (most recent first). When a bucket is
   full and a new node is discovered, it goes to the replacement cache.

   Thread Safety: Protected by internal mutex."

  (index 0
   :type (integer 0 255))

  (nodes nil
   :type list)

  (replacements nil
   :type list)

  (capacity +kademlia-k+
   :type (integer 1 256))

  (replacement-capacity +replacement-cache-size+
   :type (integer 0 64))

  (last-refresh 0
   :type (integer 0))

  (lock nil
   :type (or null #+sbcl sb-thread:mutex #-sbcl t)))

(defun make-k-bucket (index &key (capacity +kademlia-k+)
                                  (replacement-capacity +replacement-cache-size+))
  "Create a new k-bucket.

   Arguments:
     INDEX - Bucket index (0-255)
     CAPACITY - Maximum nodes (default k=20)
     REPLACEMENT-CAPACITY - Replacement cache size (default 8)

   Returns:
     A K-BUCKET structure."
  (%make-k-bucket
   :index index
   :capacity capacity
   :replacement-capacity replacement-capacity
   :last-refresh (get-universal-time)
   :lock #+sbcl (sb-thread:make-mutex :name (format nil "k-bucket-~D" index))
         #-sbcl t))

(defmacro with-bucket-lock ((bucket) &body body)
  "Execute body with bucket lock held.

   Arguments:
     BUCKET - K-bucket to lock

   Returns:
     Result of body execution."
  #+sbcl
  `(sb-thread:with-mutex ((k-bucket-lock ,bucket))
     ,@body)
  #-sbcl
  `(progn ,@body))

(defun bucket-size (bucket)
  "Get current number of nodes in bucket.

   Arguments:
     BUCKET - A k-bucket

   Returns:
     Integer node count."
  (with-bucket-lock (bucket)
    (length (k-bucket-nodes bucket))))

(defun bucket-full-p (bucket)
  "Check if bucket is at capacity.

   Arguments:
     BUCKET - A k-bucket

   Returns:
     T if bucket has k nodes."
  (with-bucket-lock (bucket)
    (>= (length (k-bucket-nodes bucket))
        (k-bucket-capacity bucket))))

(defun bucket-contains-p (bucket node-id)
  "Check if bucket contains a node with given ID.

   Arguments:
     BUCKET - A k-bucket
     NODE-ID - Node ID to search for

   Returns:
     T if node is in bucket."
  (with-bucket-lock (bucket)
    (find-if (lambda (node)
               (node-id= (dht-node-id node) node-id))
             (k-bucket-nodes bucket))))

(defun bucket-get (bucket node-id)
  "Get a node from bucket by ID.

   Arguments:
     BUCKET - A k-bucket
     NODE-ID - Node ID to find

   Returns:
     DHT-NODE if found, NIL otherwise."
  (with-bucket-lock (bucket)
    (find-if (lambda (node)
               (node-id= (dht-node-id node) node-id))
             (k-bucket-nodes bucket))))

(defun bucket-add (bucket node)
  "Add a node to the bucket.

   If bucket is full, node goes to replacement cache.
   If node exists, it's moved to front (most recent).

   Arguments:
     BUCKET - A k-bucket
     NODE - DHT-NODE to add

   Returns:
     :ADDED - Node added to bucket
     :UPDATED - Existing node updated
     :CACHED - Node added to replacement cache
     :DROPPED - All caches full"
  (with-bucket-lock (bucket)
    (let* ((node-id (dht-node-id node))
           (existing (find-if (lambda (n) (node-id= (dht-node-id n) node-id))
                              (k-bucket-nodes bucket))))
      (cond
        ;; Node exists - update and move to front
        (existing
         (setf (dht-node-last-seen existing) (get-universal-time))
         (setf (dht-node-address existing) (dht-node-address node))
         (setf (dht-node-port existing) (dht-node-port node))
         (setf (dht-node-failed-requests existing) 0)
         (setf (k-bucket-nodes bucket)
               (cons existing (remove existing (k-bucket-nodes bucket))))
         :updated)
        ;; Bucket has space - add to front
        ((< (length (k-bucket-nodes bucket)) (k-bucket-capacity bucket))
         (push node (k-bucket-nodes bucket))
         :added)
        ;; Bucket full - try replacement cache
        ((< (length (k-bucket-replacements bucket))
            (k-bucket-replacement-capacity bucket))
         (push node (k-bucket-replacements bucket))
         :cached)
        ;; Everything full
        (t :dropped)))))

(defun bucket-remove (bucket node-id)
  "Remove a node from bucket.

   If a replacement is available, it's promoted to fill the slot.

   Arguments:
     BUCKET - A k-bucket
     NODE-ID - ID of node to remove

   Returns:
     Removed node, or NIL if not found."
  (with-bucket-lock (bucket)
    (let ((node (find-if (lambda (n) (node-id= (dht-node-id n) node-id))
                         (k-bucket-nodes bucket))))
      (when node
        (setf (k-bucket-nodes bucket)
              (remove node (k-bucket-nodes bucket)))
        ;; Promote replacement if available
        (when (k-bucket-replacements bucket)
          (push (pop (k-bucket-replacements bucket))
                (k-bucket-nodes bucket))))
      node)))

(defun bucket-needs-refresh-p (bucket &optional (interval +bucket-refresh-interval+))
  "Check if bucket needs refresh.

   Arguments:
     BUCKET - A k-bucket
     INTERVAL - Refresh interval in seconds

   Returns:
     T if bucket should be refreshed."
  (> (- (get-universal-time) (k-bucket-last-refresh bucket)) interval))

(defun bucket-mark-refreshed (bucket)
  "Mark bucket as just refreshed.

   Arguments:
     BUCKET - A k-bucket"
  (setf (k-bucket-last-refresh bucket) (get-universal-time)))

(defun bucket-stale-nodes (bucket &optional (max-failures 3) (max-age +ping-interval+))
  "Get list of stale nodes needing liveness check.

   Arguments:
     BUCKET - A k-bucket
     MAX-FAILURES - Failure threshold
     MAX-AGE - Age threshold in seconds

   Returns:
     List of stale nodes."
  (let ((now (get-universal-time)))
    (with-bucket-lock (bucket)
      (remove-if-not
       (lambda (node)
         (or (>= (dht-node-failed-requests node) max-failures)
             (> (- now (dht-node-last-seen node)) max-age)))
       (k-bucket-nodes bucket)))))

;;; ============================================================================
;;; ROUTING TABLE
;;; ============================================================================

(defstruct (routing-table (:constructor %make-routing-table))
  "Kademlia routing table with 256 k-buckets.

   Organizes known nodes by XOR distance from local node, enabling
   efficient O(log n) lookups in networks of n nodes.

   Thread Safety: Operations are thread-safe via per-bucket locking."

  (local-id nil
   :type (or null dht-node-id))

  (buckets nil
   :type (or null (simple-vector 256)))

  (config nil
   :type (or null dht-config))

  (stats-lock nil
   :type (or null #+sbcl sb-thread:mutex #-sbcl t))

  (total-added 0
   :type (integer 0))

  (total-removed 0
   :type (integer 0)))

(defun make-routing-table (local-id &optional config)
  "Create a new routing table.

   Arguments:
     LOCAL-ID - Local node's DHT-NODE-ID
     CONFIG - Optional DHT configuration

   Returns:
     A ROUTING-TABLE structure."
  (let* ((cfg (or config (make-dht-config)))
         (k (dht-config-k cfg))
         (buckets (make-array +num-buckets+)))
    (loop for i below +num-buckets+
          do (setf (aref buckets i)
                   (make-k-bucket i :capacity k)))
    (%make-routing-table
     :local-id local-id
     :buckets buckets
     :config cfg
     :stats-lock #+sbcl (sb-thread:make-mutex :name "routing-table-stats")
                 #-sbcl t)))

(defun routing-table-bucket (table node-id)
  "Get the bucket for a given node ID.

   Arguments:
     TABLE - A routing table
     NODE-ID - Target node ID

   Returns:
     The k-bucket for this ID."
  (let ((index (bucket-index-for-distance
                (routing-table-local-id table) node-id)))
    (when index
      (aref (routing-table-buckets table) index))))

(defmacro with-stats-lock ((table) &body body)
  "Execute body with routing table stats lock held."
  #+sbcl
  `(sb-thread:with-mutex ((routing-table-stats-lock ,table))
     ,@body)
  #-sbcl
  `(progn ,@body))

(defun routing-table-add (table node)
  "Add a node to the routing table.

   Arguments:
     TABLE - A routing table
     NODE - DHT-NODE to add

   Returns:
     :ADDED, :UPDATED, :CACHED, :DROPPED, or :SELF."
  (let ((node-id (dht-node-id node)))
    ;; Don't add ourselves
    (when (node-id= node-id (routing-table-local-id table))
      (return-from routing-table-add :self))
    (let* ((bucket (routing-table-bucket table node-id))
           (result (when bucket (bucket-add bucket node))))
      (when (eq result :added)
        (with-stats-lock (table)
          (incf (routing-table-total-added table))))
      result)))

(defun routing-table-remove (table node-id)
  "Remove a node from the routing table.

   Arguments:
     TABLE - A routing table
     NODE-ID - ID of node to remove

   Returns:
     Removed node, or NIL."
  (let* ((bucket (routing-table-bucket table node-id))
         (removed (when bucket (bucket-remove bucket node-id))))
    (when removed
      (with-stats-lock (table)
        (incf (routing-table-total-removed table))))
    removed))

(defun routing-table-get (table node-id)
  "Get a node from routing table by ID.

   Arguments:
     TABLE - A routing table
     NODE-ID - ID to find

   Returns:
     DHT-NODE if found, NIL otherwise."
  (let ((bucket (routing-table-bucket table node-id)))
    (when bucket (bucket-get bucket node-id))))

(defun routing-table-contains-p (table node-id)
  "Check if routing table contains a node.

   Arguments:
     TABLE - A routing table
     NODE-ID - ID to check

   Returns:
     T if node is in table."
  (let ((bucket (routing-table-bucket table node-id)))
    (when bucket (bucket-contains-p bucket node-id))))

(defun routing-table-size (table)
  "Get total number of nodes in routing table.

   Arguments:
     TABLE - A routing table

   Returns:
     Total node count."
  (loop for bucket across (routing-table-buckets table)
        sum (bucket-size bucket)))

(defun routing-table-closest (table target &optional (count +kademlia-k+))
  "Find the k closest nodes to a target ID.

   Uses iterative bucket search starting from target's bucket,
   expanding outward until k nodes are collected.

   Arguments:
     TABLE - A routing table
     TARGET - Target DHT-NODE-ID
     COUNT - Maximum nodes to return (default k)

   Returns:
     List of up to COUNT closest nodes, sorted by distance."
  (let* ((local-id (routing-table-local-id table))
         (target-bucket-idx (or (bucket-index-for-distance local-id target)
                                (1- +num-buckets+)))
         (candidates nil))
    ;; Collect from target bucket and neighbors
    (loop for offset from 0 below +num-buckets+
          for up = (+ target-bucket-idx offset)
          for down = (- target-bucket-idx offset)
          while (< (length candidates) (* 2 count))
          do (when (< up +num-buckets+)
               (let ((bucket (aref (routing-table-buckets table) up)))
                 (with-bucket-lock (bucket)
                   (dolist (node (k-bucket-nodes bucket))
                     (push node candidates)))))
             (when (and (>= down 0) (/= down up))
               (let ((bucket (aref (routing-table-buckets table) down)))
                 (with-bucket-lock (bucket)
                   (dolist (node (k-bucket-nodes bucket))
                     (push node candidates))))))
    ;; Sort by distance and take top count
    (let ((sorted (sort-nodes-by-distance candidates target)))
      (if (> (length sorted) count)
          (subseq sorted 0 count)
          sorted))))

(defun routing-table-random-nodes (table count)
  "Get random nodes from routing table.

   Arguments:
     TABLE - A routing table
     COUNT - Number of nodes to return

   Returns:
     List of randomly selected nodes."
  (let ((all-nodes (routing-table-all-nodes table)))
    (if (<= (length all-nodes) count)
        all-nodes
        (let ((shuffled (copy-seq all-nodes)))
          (loop for i from (1- (length shuffled)) downto 1
                for j = (random (1+ i))
                do (rotatef (elt shuffled i) (elt shuffled j)))
          (subseq shuffled 0 count)))))

(defun routing-table-all-nodes (table)
  "Get all nodes in the routing table.

   Arguments:
     TABLE - A routing table

   Returns:
     List of all nodes."
  (loop for bucket across (routing-table-buckets table)
        nconc (with-bucket-lock (bucket)
                (copy-list (k-bucket-nodes bucket)))))

(defun routing-table-refresh (table)
  "Refresh all stale buckets.

   Identifies buckets needing refresh and returns random IDs
   in their ranges for lookup.

   Arguments:
     TABLE - A routing table

   Returns:
     List of (bucket-index . random-id) for refresh lookups."
  (loop for bucket across (routing-table-buckets table)
        when (bucket-needs-refresh-p bucket)
          collect (let ((idx (k-bucket-index bucket)))
                    (bucket-mark-refreshed bucket)
                    (cons idx (random-id-in-bucket
                               (routing-table-local-id table) idx)))))

(defun routing-table-prune (table &optional (max-failures 3))
  "Remove nodes with too many failures.

   Arguments:
     TABLE - A routing table
     MAX-FAILURES - Failure threshold

   Returns:
     Number of nodes removed."
  (let ((removed 0))
    (loop for bucket across (routing-table-buckets table)
          do (dolist (stale (bucket-stale-nodes bucket max-failures))
               (when (bucket-remove bucket (dht-node-id stale))
                 (incf removed))))
    removed))

(defun random-id-in-bucket (local-id bucket-index)
  "Generate a random ID that falls in the specified bucket.

   Arguments:
     LOCAL-ID - Local node's ID
     BUCKET-INDEX - Target bucket index

   Returns:
     DHT-NODE-ID in the bucket's distance range."
  (let ((bytes (make-array +node-id-bytes+ :element-type '(unsigned-byte 8)))
        (local-bytes (dht-node-id-bytes local-id))
        (bit-index (- +node-id-bits+ 1 bucket-index)))
    ;; Copy local ID
    (replace bytes local-bytes)
    ;; Flip bit at the appropriate position to land in bucket
    (let ((byte-index (floor bit-index 8))
          (bit-offset (mod bit-index 8)))
      (setf (aref bytes byte-index)
            (logxor (aref bytes byte-index)
                    (ash 1 (- 7 bit-offset)))))
    ;; Randomize remaining bits
    (loop for i from (1+ (floor bit-index 8)) below +node-id-bytes+
          do (setf (aref bytes i) (random 256)))
    (%make-dht-node-id :bytes bytes)))

(defun routing-table-update (table node)
  "Update an existing node's information in the routing table.

   If node exists, updates its address, port, and marks as recently seen.
   If node doesn't exist, adds it.

   Arguments:
     TABLE - A routing table
     NODE - DHT-NODE with updated information

   Returns:
     :UPDATED if node existed and was updated
     :ADDED if node was newly added
     :CACHED/:DROPPED as per bucket-add
     :SELF if trying to update self"
  (let ((node-id (dht-node-id node)))
    ;; Don't add ourselves
    (when (node-id= node-id (routing-table-local-id table))
      (return-from routing-table-update :self))
    (let ((bucket (routing-table-bucket table node-id)))
      (when bucket
        (with-bucket-lock (bucket)
          (let ((existing (find-if (lambda (n) (node-id= (dht-node-id n) node-id))
                                   (k-bucket-nodes bucket))))
            (if existing
                (progn
                  (setf (dht-node-last-seen existing) (get-universal-time))
                  (setf (dht-node-address existing) (dht-node-address node))
                  (setf (dht-node-port existing) (dht-node-port node))
                  (setf (dht-node-failed-requests existing) 0)
                  ;; Move to front (most recently seen)
                  (setf (k-bucket-nodes bucket)
                        (cons existing (remove existing (k-bucket-nodes bucket))))
                  :updated)
                ;; Node doesn't exist, add it
                (bucket-add bucket node))))))))

(defun routing-table-node-seen (table node-id)
  "Mark a node as recently seen (successful communication).

   Arguments:
     TABLE - A routing table
     NODE-ID - ID of node that was seen

   Returns:
     T if node was found and updated, NIL otherwise."
  (let ((bucket (routing-table-bucket table node-id)))
    (when bucket
      (with-bucket-lock (bucket)
        (let ((node (find-if (lambda (n) (node-id= (dht-node-id n) node-id))
                             (k-bucket-nodes bucket))))
          (when node
            (setf (dht-node-last-seen node) (get-universal-time))
            (setf (dht-node-failed-requests node) 0)
            ;; Move to front
            (setf (k-bucket-nodes bucket)
                  (cons node (remove node (k-bucket-nodes bucket))))
            t))))))

(defun routing-table-node-failed (table node-id)
  "Mark a node as having failed a request.

   Increments failure count. Node may be removed if threshold exceeded.

   Arguments:
     TABLE - A routing table
     NODE-ID - ID of node that failed

   Returns:
     :INCREMENTED - Failure count incremented
     :REMOVED - Node removed due to too many failures
     NIL - Node not found"
  (let ((bucket (routing-table-bucket table node-id)))
    (when bucket
      (with-bucket-lock (bucket)
        (let ((node (find-if (lambda (n) (node-id= (dht-node-id n) node-id))
                             (k-bucket-nodes bucket))))
          (when node
            (incf (dht-node-failed-requests node))
            (if (>= (dht-node-failed-requests node) 3)
                (progn
                  (bucket-remove bucket node-id)
                  :removed)
                :incremented)))))))

(defun routing-table-bucket-by-index (table index)
  "Get a bucket by its index.

   Arguments:
     TABLE - A routing table
     INDEX - Bucket index (0-255)

   Returns:
     The k-bucket at that index."
  (when (and (>= index 0) (< index +num-buckets+))
    (aref (routing-table-buckets table) index)))
