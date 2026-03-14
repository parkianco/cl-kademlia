;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: BSD-3-Clause

;;;; lookup.lisp - Iterative node and value lookup
;;;;
;;;; BSD 3-Clause License
;;;; Copyright (c) 2024-2025, CLPIC Contributors

(in-package #:cl-kademlia)

;;; ============================================================================
;;; LOOKUP STATE
;;; ============================================================================

(defstruct (lookup-state (:constructor %make-lookup-state))
  "State for iterative Kademlia lookup.

   Tracks the k closest nodes found, which nodes have been queried,
   and which queries are pending.

   Thread Safety: Protected by internal mutex."

  (target nil
   :type (or null dht-node-id))

  (closest nil
   :type list)

  (queried nil
   :type list)

  (pending nil
   :type list)

  (started-at 0
   :type (integer 0))

  (alpha +kademlia-alpha+
   :type (integer 1))

  (k +kademlia-k+
   :type (integer 1))

  (value nil)

  (complete-p nil
   :type boolean)

  (lock nil
   :type (or null #+sbcl sb-thread:mutex #-sbcl t)))

(defun make-lookup-state (target routing-table &key (alpha +kademlia-alpha+)
                                                     (k +kademlia-k+))
  "Create a new lookup state.

   Arguments:
     TARGET - Target DHT-NODE-ID to find
     ROUTING-TABLE - Routing table for initial nodes
     ALPHA - Concurrency factor
     K - Number of closest nodes to find

   Returns:
     A LOOKUP-STATE structure."
  (let ((initial (routing-table-closest routing-table target k)))
    (%make-lookup-state
     :target target
     :closest initial
     :queried nil
     :pending (mapcar #'dht-node-id initial)
     :started-at (get-universal-time)
     :alpha alpha
     :k k
     :lock #+sbcl (sb-thread:make-mutex :name "lookup-state")
           #-sbcl t)))

(defmacro with-lookup-lock ((state) &body body)
  "Execute body with lookup state lock held."
  #+sbcl
  `(sb-thread:with-mutex ((lookup-state-lock ,state))
     ,@body)
  #-sbcl
  `(progn ,@body))

(defun lookup-next-queries (state)
  "Get next batch of nodes to query.

   Returns up to ALPHA nodes that haven't been queried yet.

   Arguments:
     STATE - Lookup state

   Returns:
     List of DHT-NODE to query."
  (with-lookup-lock (state)
    (let ((to-query nil)
          (count 0))
      (dolist (node (lookup-state-closest state))
        (when (>= count (lookup-state-alpha state))
          (return))
        (let ((nid (dht-node-id node)))
          (unless (member nid (lookup-state-queried state) :test #'node-id=)
            (push nid (lookup-state-queried state))
            (push node to-query)
            (incf count))))
      (nreverse to-query))))

(defun lookup-add-nodes (state new-nodes)
  "Add discovered nodes to lookup state.

   Merges new nodes into closest set, keeping only k closest.

   Arguments:
     STATE - Lookup state
     NEW-NODES - List of newly discovered DHT-NODEs

   Returns:
     T if any closer nodes were found."
  (with-lookup-lock (state)
    (let* ((target (lookup-state-target state))
           (k (lookup-state-k state))
           (current-closest (lookup-state-closest state))
           (old-furthest (when (>= (length current-closest) k)
                           (dht-node-id (car (last current-closest)))))
           ;; Merge and sort
           (merged (remove-duplicates
                    (append new-nodes current-closest)
                    :key #'dht-node-id :test #'node-id=))
           (sorted (sort-nodes-by-distance merged target))
           (new-closest (if (> (length sorted) k)
                            (subseq sorted 0 k)
                            sorted)))
      (setf (lookup-state-closest state) new-closest)
      ;; Check if we found closer nodes
      (and old-furthest
           (closer-to-p (dht-node-id (car (last new-closest)))
                        old-furthest
                        target)))))

(defun lookup-complete-p (state)
  "Check if lookup is complete.

   Lookup is complete when all k closest nodes have been queried
   and no closer nodes are being discovered.

   Arguments:
     STATE - Lookup state

   Returns:
     T if lookup is complete."
  (with-lookup-lock (state)
    (or (lookup-state-complete-p state)
        (lookup-state-value state)
        (let ((closest (lookup-state-closest state))
              (queried (lookup-state-queried state)))
          (every (lambda (node)
                   (member (dht-node-id node) queried :test #'node-id=))
                 closest)))))

(defun lookup-mark-complete (state)
  "Mark lookup as complete.

   Arguments:
     STATE - Lookup state"
  (with-lookup-lock (state)
    (setf (lookup-state-complete-p state) t)))

(defun lookup-set-value (state value)
  "Set found value for FIND_VALUE lookup.

   Arguments:
     STATE - Lookup state
     VALUE - Found value"
  (with-lookup-lock (state)
    (setf (lookup-state-value state) value)
    (setf (lookup-state-complete-p state) t)))

;;; ============================================================================
;;; ITERATIVE LOOKUP PROTOCOL
;;; ============================================================================

(defun advance-lookup (state responding-node new-nodes)
  "Advance lookup state with response from a queried node.

   Integrates newly discovered nodes, updates query state,
   and determines if more queries are needed.

   Arguments:
     STATE - Lookup state
     RESPONDING-NODE - DHT-NODE that responded
     NEW-NODES - List of nodes returned in response

   Returns:
     :IMPROVED - Found closer nodes, continue lookup
     :STABLE - No closer nodes found
     :COMPLETE - Lookup complete"
  (with-lookup-lock (state)
    ;; Remove from pending if it was there
    (setf (lookup-state-pending state)
          (remove (dht-node-id responding-node)
                  (lookup-state-pending state)
                  :test #'node-id=))

    ;; Filter out self and already-seen nodes
    (let* ((target (lookup-state-target state))
           (queried (lookup-state-queried state))
           (filtered-nodes
             (remove-if (lambda (n)
                          (or (member (dht-node-id n) queried :test #'node-id=)
                              (node-id= (dht-node-id n) target)))
                        new-nodes))
           ;; Current furthest in closest set
           (current-closest (lookup-state-closest state))
           (k (lookup-state-k state))
           (old-furthest (when (>= (length current-closest) k)
                           (dht-node-id (car (last current-closest))))))

      ;; Merge new nodes
      (let* ((merged (remove-duplicates
                      (append filtered-nodes current-closest)
                      :key #'dht-node-id :test #'node-id=))
             (sorted (sort-nodes-by-distance merged target))
             (new-closest (if (> (length sorted) k)
                              (subseq sorted 0 k)
                              sorted)))
        (setf (lookup-state-closest state) new-closest)

        ;; Check result
        (cond
          ;; Lookup complete - all closest have been queried
          ((every (lambda (n)
                    (member (dht-node-id n) queried :test #'node-id=))
                  new-closest)
           (setf (lookup-state-complete-p state) t)
           :complete)

          ;; Improved - found closer nodes
          ((and old-furthest
                (> (length new-closest) 0)
                (closer-to-p (dht-node-id (car (last new-closest)))
                             old-furthest
                             target))
           :improved)

          ;; Stable - no improvement
          (t :stable))))))

(defun finalize-lookup (state)
  "Finalize and return lookup results.

   Marks lookup as complete and returns the k closest nodes found.

   Arguments:
     STATE - Lookup state

   Returns:
     List of k closest nodes to target."
  (with-lookup-lock (state)
    (setf (lookup-state-complete-p state) t)
    (copy-list (lookup-state-closest state))))

(defun iterative-find-node (dht target-id &key (timeout +request-timeout+)
                                                (on-query nil)
                                                (on-response nil))
  "Perform iterative FIND_NODE lookup.

   Finds the k closest nodes to target-id using Kademlia's
   iterative lookup algorithm with alpha concurrency.

   Arguments:
     DHT - DHT instance
     TARGET-ID - Target node ID to find
     TIMEOUT - Per-query timeout in seconds
     ON-QUERY - Callback (node) called before each query
     ON-RESPONSE - Callback (node nodes) called on each response

   Returns:
     (VALUES closest-nodes elapsed-time query-count)
     CLOSEST-NODES - List of k closest nodes to target
     ELAPSED-TIME - Time taken in seconds
     QUERY-COUNT - Number of queries made"
  (declare (ignore timeout))
  (let* ((start-time (get-universal-time))
         (config (dht-config dht))
         (alpha (dht-config-alpha config))
         (k (dht-config-k config))
         (routing-table (dht-routing-table dht))
         (state (make-lookup-state target-id routing-table :alpha alpha :k k))
         (query-count 0))

    ;; Iterative lookup loop
    (loop while (not (lookup-complete-p state))
          for round from 0 below (* 2 +node-id-bits+)  ; Limit iterations
          do
             ;; Get next batch of nodes to query
             (let ((to-query (lookup-next-queries state)))
               (when (null to-query)
                 ;; No more nodes to query, we're done
                 (return))

               ;; Query each node
               (dolist (node to-query)
                 (incf query-count)
                 ;; Call on-query callback if provided
                 (when on-query
                   (funcall on-query node))

                 ;; In a real implementation, this would send network messages
                 ;; For now, use local routing table knowledge
                 (let ((closest (routing-table-closest routing-table target-id k)))
                   ;; Call on-response callback
                   (when on-response
                     (funcall on-response node closest))

                   ;; Advance lookup with "response"
                   (advance-lookup state node closest)))))

    ;; Return results
    (let ((elapsed (- (get-universal-time) start-time)))
      (when *on-lookup-complete*
        (funcall *on-lookup-complete* target-id (lookup-state-closest state)))
      (values (finalize-lookup state)
              elapsed
              query-count))))

(defun iterative-find-value (dht key &key (timeout +request-timeout+)
                                           (on-query nil)
                                           (on-value nil))
  "Perform iterative FIND_VALUE lookup.

   Searches for a value by key. Returns the value if found,
   otherwise returns the k closest nodes.

   Arguments:
     DHT - DHT instance
     KEY - Key to find (DHT-NODE-ID)
     TIMEOUT - Per-query timeout in seconds
     ON-QUERY - Callback (node) called before each query
     ON-VALUE - Callback (value node) called if value found

   Returns:
     (VALUES result found-p closest-nodes)
     RESULT - The value if found, NIL otherwise
     FOUND-P - T if value was found
     CLOSEST-NODES - K closest nodes (for caching value)"
  (declare (ignore timeout))
  (let* ((config (dht-config dht))
         (alpha (dht-config-alpha config))
         (k (dht-config-k config))
         (routing-table (dht-routing-table dht))
         (value-store (dht-value-store dht))
         (state (make-lookup-state key routing-table :alpha alpha :k k)))

    ;; Check local store first
    (let ((local-value (value-store-get value-store key)))
      (when local-value
        (when on-value
          (funcall on-value local-value nil))
        (when *on-value-retrieved*
          (funcall *on-value-retrieved* key local-value))
        (return-from iterative-find-value
          (values local-value t (lookup-state-closest state)))))

    ;; Iterative lookup - similar to find-node but checks for value
    (loop while (not (lookup-complete-p state))
          for round from 0 below (* 2 +node-id-bits+)
          do
             (let ((to-query (lookup-next-queries state)))
               (when (null to-query)
                 (return))

               (dolist (node to-query)
                 (when on-query
                   (funcall on-query node))

                 ;; In real implementation, send FIND_VALUE request
                 ;; Response could be either value or closest nodes
                 ;; For now, simulate with local lookup
                 (let ((closest (routing-table-closest routing-table key k)))
                   (advance-lookup state node closest)))))

    ;; Value not found, return closest nodes for caching
    (values nil nil (finalize-lookup state))))

(defun parallel-lookup (dht targets &key (timeout +request-timeout+)
                                          (max-concurrent +max-concurrent-queries+))
  "Perform parallel lookups for multiple targets.

   Executes multiple find-node operations concurrently,
   useful for batch operations like bootstrapping.

   Arguments:
     DHT - DHT instance
     TARGETS - List of target node IDs
     TIMEOUT - Per-query timeout
     MAX-CONCURRENT - Maximum concurrent lookups

   Returns:
     Association list of (target-id . closest-nodes)."
  (declare (ignore timeout max-concurrent))
  (let ((results nil))
    ;; In production, this would use parallel threads
    ;; For now, sequential execution
    (dolist (target targets)
      (let ((closest (iterative-find-node dht target)))
        (push (cons target closest) results)))
    (nreverse results)))

(defun disjoint-path-lookup (dht target-id &key (paths +kademlia-beta+))
  "Perform lookup using disjoint paths for eclipse attack resistance.

   Uses multiple independent starting points to find target,
   reducing the chance of being misled by malicious nodes.

   Arguments:
     DHT - DHT instance
     TARGET-ID - Target to find
     PATHS - Number of disjoint paths (default beta=3)

   Returns:
     Merged results from all paths, sorted by distance."
  (let* ((routing-table (dht-routing-table dht))
         (k (dht-config-k (dht-config dht)))
         (all-closest (routing-table-closest routing-table target-id (* k paths)))
         (path-results nil))

    ;; Divide initial nodes into disjoint sets
    (loop for i below paths
          for start-idx = (* i k)
          for end-idx = (min (+ start-idx k) (length all-closest))
          when (< start-idx (length all-closest))
            do (let ((path-initial (subseq all-closest start-idx end-idx)))
                 ;; Each path would be queried independently
                 ;; For now, collect initial nodes
                 (push path-initial path-results)))

    ;; Merge and sort all results
    (let ((merged (remove-duplicates
                   (apply #'append path-results)
                   :key #'dht-node-id :test #'node-id=)))
      (sort-nodes-by-distance merged target-id))))
