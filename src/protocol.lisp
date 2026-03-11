;;;; protocol.lisp - DHT service, value store, provider records
;;;;
;;;; BSD 3-Clause License
;;;; Copyright (c) 2024-2025, CLPIC Contributors

(in-package #:cl-kademlia)

;;; ============================================================================
;;; VALUE STORE
;;; ============================================================================

(defstruct (dht-record (:constructor %make-dht-record))
  "Stored value record in the DHT.

   Records have a TTL and are periodically republished to maintain
   availability in the network."

  (key nil
   :type (or null dht-node-id))

  (value nil)

  (timestamp 0
   :type (integer 0))

  (expiration 0
   :type (integer 0))

  (publisher nil
   :type (or null dht-node-id))

  (republished-at 0
   :type (integer 0)))

(defun make-dht-record (key value &key publisher (ttl +record-expiration+))
  "Create a new DHT record.

   Arguments:
     KEY - Record key (DHT-NODE-ID)
     VALUE - Value to store
     PUBLISHER - Publisher's node ID
     TTL - Time-to-live in seconds

   Returns:
     A DHT-RECORD structure."
  (let ((now (get-universal-time)))
    (%make-dht-record
     :key key
     :value value
     :timestamp now
     :expiration (+ now ttl)
     :publisher publisher
     :republished-at now)))

(defstruct (value-store (:constructor %make-value-store))
  "Local storage for DHT values.

   Thread Safety: Protected by internal mutex."

  (records (make-hash-table :test 'equalp)
   :type hash-table)

  (max-records 10000
   :type (integer 1))

  (max-value-size +max-value-size+
   :type (integer 1))

  (lock nil
   :type (or null #+sbcl sb-thread:mutex #-sbcl t)))

(defun make-value-store (&key (max-records 10000)
                               (max-value-size +max-value-size+))
  "Create a new value store.

   Arguments:
     MAX-RECORDS - Maximum records to store
     MAX-VALUE-SIZE - Maximum value size in bytes

   Returns:
     A VALUE-STORE structure."
  (%make-value-store
   :max-records max-records
   :max-value-size max-value-size
   :lock #+sbcl (sb-thread:make-mutex :name "value-store")
         #-sbcl t))

(defmacro with-store-lock ((store) &body body)
  "Execute body with store lock held."
  #+sbcl
  `(sb-thread:with-mutex ((value-store-lock ,store))
     ,@body)
  #-sbcl
  `(progn ,@body))

(defun value-store-get (store key)
  "Get a value from the store.

   Arguments:
     STORE - Value store
     KEY - DHT-NODE-ID key

   Returns:
     Value if found and not expired, NIL otherwise."
  (with-store-lock (store)
    (let* ((key-bytes (dht-node-id-bytes key))
           (record (gethash key-bytes (value-store-records store))))
      (when (and record (> (dht-record-expiration record) (get-universal-time)))
        (dht-record-value record)))))

(defun value-store-put (store key value &key publisher (ttl +record-expiration+))
  "Store a value.

   Arguments:
     STORE - Value store
     KEY - DHT-NODE-ID key
     VALUE - Value to store
     PUBLISHER - Publisher's node ID
     TTL - Time-to-live in seconds

   Returns:
     T on success, NIL if value too large or store full."
  (let ((value-size (if (arrayp value) (length value) 1)))
    (when (> value-size (value-store-max-value-size store))
      (return-from value-store-put nil))
    (with-store-lock (store)
      (let ((records (value-store-records store)))
        (when (and (>= (hash-table-count records)
                       (value-store-max-records store))
                   (not (gethash (dht-node-id-bytes key) records)))
          (return-from value-store-put nil))
        (setf (gethash (dht-node-id-bytes key) records)
              (make-dht-record key value :publisher publisher :ttl ttl))
        t))))

(defun value-store-delete (store key)
  "Delete a value from the store.

   Arguments:
     STORE - Value store
     KEY - DHT-NODE-ID key

   Returns:
     T if deleted, NIL if not found."
  (with-store-lock (store)
    (remhash (dht-node-id-bytes key) (value-store-records store))))

(defun value-store-contains-p (store key)
  "Check if store contains a key.

   Arguments:
     STORE - Value store
     KEY - DHT-NODE-ID key

   Returns:
     T if key exists and not expired."
  (not (null (value-store-get store key))))

(defun value-store-size (store)
  "Get number of stored values.

   Arguments:
     STORE - Value store

   Returns:
     Record count."
  (with-store-lock (store)
    (hash-table-count (value-store-records store))))

(defun value-store-prune (store)
  "Remove expired values.

   Arguments:
     STORE - Value store

   Returns:
     Number of records removed."
  (let ((now (get-universal-time))
        (removed 0))
    (with-store-lock (store)
      (maphash (lambda (key record)
                 (when (<= (dht-record-expiration record) now)
                   (remhash key (value-store-records store))
                   (incf removed)))
               (value-store-records store)))
    removed))

(defun get-republish-candidates (store &optional (interval +republish-interval+))
  "Get records needing republishing.

   Arguments:
     STORE - Value store
     INTERVAL - Republish interval in seconds

   Returns:
     List of DHT-RECORD needing republish."
  (let ((threshold (- (get-universal-time) interval))
        (candidates nil))
    (with-store-lock (store)
      (maphash (lambda (key record)
                 (declare (ignore key))
                 (when (< (dht-record-republished-at record) threshold)
                   (push record candidates)))
               (value-store-records store)))
    candidates))

;;; ============================================================================
;;; REPUBLISHING
;;; ============================================================================

(defstruct (republish-task (:constructor %make-republish-task))
  "Scheduled republishing task for a stored value."

  (key nil
   :type (or null dht-node-id))

  (next-run 0
   :type (integer 0))

  (interval +republish-interval+
   :type (integer 1))

  (retries 0
   :type (integer 0)))

(defvar *republish-queue* nil
  "Queue of pending republish tasks.")

(defvar *republish-queue-lock*
  #+sbcl (sb-thread:make-mutex :name "republish-queue")
  #-sbcl t
  "Lock for republish queue.")

(defmacro with-republish-lock (() &body body)
  #+sbcl
  `(sb-thread:with-mutex (*republish-queue-lock*)
     ,@body)
  #-sbcl
  `(progn ,@body))

(defun schedule-republish (key &key (delay +republish-interval+)
                                      (interval +republish-interval+))
  "Schedule a value for republishing.

   Arguments:
     KEY - DHT key to republish
     DELAY - Initial delay before first republish
     INTERVAL - Republish interval

   Returns:
     T if scheduled successfully."
  (let ((task (%make-republish-task
               :key key
               :next-run (+ (get-universal-time) delay)
               :interval interval)))
    (with-republish-lock ()
      (push task *republish-queue*))
    t))

(defun cancel-republish (key)
  "Cancel scheduled republishing for a key.

   Arguments:
     KEY - DHT key to cancel

   Returns:
     T if task was found and cancelled."
  (with-republish-lock ()
    (let ((original-length (length *republish-queue*)))
      (setf *republish-queue*
            (remove-if (lambda (task)
                         (node-id= (republish-task-key task) key))
                       *republish-queue*))
      (/= (length *republish-queue*) original-length))))

(defun get-due-republish-tasks ()
  "Get all republish tasks that are due.

   Returns:
     List of REPUBLISH-TASK that should run now."
  (let ((now (get-universal-time))
        (due nil))
    (with-republish-lock ()
      (dolist (task *republish-queue*)
        (when (<= (republish-task-next-run task) now)
          (push task due)
          ;; Reschedule for next interval
          (setf (republish-task-next-run task)
                (+ now (republish-task-interval task))))))
    due))

(defun republish-values (dht &key (force nil))
  "Republish all stored values that are due.

   Values are republished to the k closest nodes to ensure
   availability as nodes join and leave the network.

   Arguments:
     DHT - DHT instance
     FORCE - If T, republish all values regardless of schedule

   Returns:
     Number of values republished."
  (let ((value-store (dht-value-store dht))
        (routing-table (dht-routing-table dht))
        (k (dht-config-k (dht-config dht)))
        (republished 0))

    (if force
        ;; Force republish all
        (let ((candidates (get-republish-candidates value-store 0)))
          (dolist (record candidates)
            (let* ((key (dht-record-key record))
                   (value (dht-record-value record))
                   (closest (routing-table-closest routing-table key k)))
              ;; In real implementation, send STORE to each closest node
              (declare (ignore value closest))
              (setf (dht-record-republished-at record) (get-universal-time))
              (incf republished))))

        ;; Normal scheduled republish
        (let ((tasks (get-due-republish-tasks)))
          (dolist (task tasks)
            (let* ((key (republish-task-key task))
                   (record (with-store-lock (value-store)
                             (gethash (dht-node-id-bytes key)
                                      (value-store-records value-store)))))
              (when record
                (let* ((value (dht-record-value record))
                       (closest (routing-table-closest routing-table key k)))
                  (declare (ignore value closest))
                  ;; In real implementation, send STORE to closest
                  (setf (dht-record-republished-at record) (get-universal-time))
                  (incf republished)))))))
    republished))

;;; ============================================================================
;;; PROVIDER RECORDS
;;; ============================================================================

(defstruct (provider-record (:constructor %make-provider-record))
  "Content provider record.

   Announces that a node can provide specific content,
   enabling content-addressable storage."

  (key nil
   :type (or null dht-node-id))

  (provider-id nil
   :type (or null dht-node-id))

  (addresses nil
   :type list)

  (timestamp 0
   :type (integer 0))

  (expiration 0
   :type (integer 0)))

(defun make-provider-record (key provider-id addresses &key (ttl +provider-record-ttl+))
  "Create a new provider record.

   Arguments:
     KEY - Content key (DHT-NODE-ID)
     PROVIDER-ID - Provider's node ID
     ADDRESSES - List of (address . port) pairs
     TTL - Time-to-live in seconds

   Returns:
     A PROVIDER-RECORD structure."
  (let ((now (get-universal-time)))
    (%make-provider-record
     :key key
     :provider-id provider-id
     :addresses addresses
     :timestamp now
     :expiration (+ now ttl))))

(defstruct (provider-store (:constructor %make-provider-store))
  "Storage for provider records.

   Thread Safety: Protected by internal mutex."

  (records (make-hash-table :test 'equalp)
   :type hash-table)

  (max-providers-per-key +max-providers-per-key+
   :type (integer 1))

  (lock nil
   :type (or null #+sbcl sb-thread:mutex #-sbcl t)))

(defun make-provider-store (&key (max-providers-per-key +max-providers-per-key+))
  "Create a new provider store.

   Arguments:
     MAX-PROVIDERS-PER-KEY - Maximum providers per key

   Returns:
     A PROVIDER-STORE structure."
  (%make-provider-store
   :max-providers-per-key max-providers-per-key
   :lock #+sbcl (sb-thread:make-mutex :name "provider-store")
         #-sbcl t))

(defmacro with-provider-lock ((store) &body body)
  #+sbcl
  `(sb-thread:with-mutex ((provider-store-lock ,store))
     ,@body)
  #-sbcl
  `(progn ,@body))

(defun provider-store-add (store key provider-id addresses &key (ttl +provider-record-ttl+))
  "Add a provider record.

   Arguments:
     STORE - Provider store
     KEY - Content key
     PROVIDER-ID - Provider's node ID
     ADDRESSES - Provider's addresses
     TTL - Time-to-live

   Returns:
     T on success."
  (let ((record (make-provider-record key provider-id addresses :ttl ttl)))
    (with-provider-lock (store)
      (let* ((key-bytes (dht-node-id-bytes key))
             (existing (gethash key-bytes (provider-store-records store)))
             ;; Remove duplicate provider
             (filtered (remove-if (lambda (r)
                                    (node-id= (provider-record-provider-id r)
                                              provider-id))
                                  existing))
             (new-list (cons record filtered)))
        ;; Limit to max providers
        (when (> (length new-list) (provider-store-max-providers-per-key store))
          (setf new-list (subseq new-list 0 (provider-store-max-providers-per-key store))))
        (setf (gethash key-bytes (provider-store-records store)) new-list)
        t))))

(defun provider-store-get (store key)
  "Get providers for a content key.

   Arguments:
     STORE - Provider store
     KEY - Content key

   Returns:
     List of active PROVIDER-RECORD."
  (let ((now (get-universal-time)))
    (with-provider-lock (store)
      (let ((records (gethash (dht-node-id-bytes key)
                              (provider-store-records store))))
        (remove-if (lambda (r) (<= (provider-record-expiration r) now))
                   records)))))

(defun provider-store-remove (store key provider-id)
  "Remove a specific provider for a key.

   Arguments:
     STORE - Provider store
     KEY - Content key
     PROVIDER-ID - Provider's node ID to remove

   Returns:
     T if provider was found and removed."
  (with-provider-lock (store)
    (let* ((key-bytes (dht-node-id-bytes key))
           (existing (gethash key-bytes (provider-store-records store))))
      (when existing
        (let ((filtered (remove-if (lambda (r)
                                     (node-id= (provider-record-provider-id r)
                                               provider-id))
                                   existing)))
          (if filtered
              (setf (gethash key-bytes (provider-store-records store)) filtered)
              (remhash key-bytes (provider-store-records store)))
          (< (length filtered) (length existing)))))))

(defun provider-store-prune (store)
  "Remove expired provider records.

   Arguments:
     STORE - Provider store

   Returns:
     Number of records removed."
  (let ((now (get-universal-time))
        (removed 0))
    (with-provider-lock (store)
      (maphash (lambda (key records)
                 (let ((active (remove-if (lambda (r)
                                            (when (<= (provider-record-expiration r) now)
                                              (incf removed)
                                              t))
                                          records)))
                   (if active
                       (setf (gethash key (provider-store-records store)) active)
                       (remhash key (provider-store-records store)))))
               (provider-store-records store)))
    removed))

;;; ============================================================================
;;; DHT SERVICE
;;; ============================================================================

(defstruct (dht (:constructor %make-dht))
  "Main Kademlia DHT instance.

   Coordinates routing table, value store, provider records,
   and maintenance tasks."

  (local-id nil
   :type (or null dht-node-id))

  (local-address "0.0.0.0"
   :type string)

  (local-port 4001
   :type (integer 1 65535))

  (routing-table nil
   :type (or null routing-table))

  (value-store nil
   :type (or null value-store))

  (provider-store nil
   :type (or null provider-store))

  (config nil
   :type (or null dht-config))

  (running-p nil
   :type boolean)

  (stats nil
   :type list))

(defun make-dht (&key local-id (address "0.0.0.0") (port 4001) config)
  "Create a new DHT instance.

   Arguments:
     LOCAL-ID - Local node ID (generated if not provided)
     ADDRESS - Local bind address
     PORT - Local UDP port
     CONFIG - DHT configuration

   Returns:
     A DHT structure."
  (let* ((id (or local-id (generate-node-id)))
         (cfg (or config (make-dht-config))))
    (%make-dht
     :local-id id
     :local-address address
     :local-port port
     :routing-table (make-routing-table id cfg)
     :value-store (make-value-store)
     :provider-store (make-provider-store)
     :config cfg
     :running-p nil
     :stats nil)))

(defun dht-start (dht)
  "Start the DHT service.

   Arguments:
     DHT - DHT instance

   Returns:
     T on success."
  (setf (dht-running-p dht) t)
  (setf (dht-stats dht)
        (list :started-at (get-universal-time)
              :lookups 0
              :stores 0
              :finds 0))
  t)

(defun dht-stop (dht)
  "Stop the DHT service.

   Arguments:
     DHT - DHT instance

   Returns:
     T on success."
  (setf (dht-running-p dht) nil)
  t)

(defun dht-bootstrap (dht seed-nodes)
  "Bootstrap DHT from seed nodes.

   Performs initial lookups to populate routing table.

   Arguments:
     DHT - DHT instance
     SEED-NODES - List of (address . port) pairs

   Returns:
     Number of nodes discovered."
  (let ((discovered 0))
    ;; Add seed nodes to routing table
    (dolist (seed seed-nodes)
      (let ((node (make-dht-node
                   :id (generate-node-id)  ; Will be updated on contact
                   :address (car seed)
                   :port (cdr seed))))
        (when (eq :added (routing-table-add (dht-routing-table dht) node))
          (incf discovered))))
    ;; Perform self-lookup to populate nearby buckets
    (routing-table-closest (dht-routing-table dht)
                           (dht-local-id dht)
                           (dht-config-k (dht-config dht)))
    discovered))

(defun dht-get (dht key)
  "Get a value from the DHT.

   Performs iterative FIND_VALUE lookup.

   Arguments:
     DHT - DHT instance
     KEY - DHT-NODE-ID key

   Returns:
     Value if found, NIL otherwise."
  ;; Check local store first
  (let ((local (value-store-get (dht-value-store dht) key)))
    (when local
      (return-from dht-get local)))
  ;; Would perform network lookup here
  nil)

(defun dht-put (dht key value)
  "Store a value in the DHT.

   Stores locally and would replicate to k closest nodes.

   Arguments:
     DHT - DHT instance
     KEY - DHT-NODE-ID key
     VALUE - Value to store

   Returns:
     T on success."
  (value-store-put (dht-value-store dht) key value
                   :publisher (dht-local-id dht)
                   :ttl (dht-config-record-ttl (dht-config dht))))

(defun dht-add-provider (dht key)
  "Announce as provider for content.

   Arguments:
     DHT - DHT instance
     KEY - Content key

   Returns:
     T on success."
  (provider-store-add (dht-provider-store dht)
                      key
                      (dht-local-id dht)
                      (list (cons (dht-local-address dht)
                                  (dht-local-port dht)))
                      :ttl (dht-config-provider-ttl (dht-config dht))))

(defun dht-get-providers (dht key)
  "Get providers for content.

   Arguments:
     DHT - DHT instance
     KEY - Content key

   Returns:
     List of PROVIDER-RECORD."
  (provider-store-get (dht-provider-store dht) key))

(defun dht-find-node (dht target-id)
  "Find a node by ID.

   Arguments:
     DHT - DHT instance
     TARGET-ID - Node ID to find

   Returns:
     DHT-NODE if found, NIL otherwise."
  (routing-table-get (dht-routing-table dht) target-id))

(defun dht-refresh (dht)
  "Refresh stale buckets in routing table.

   Arguments:
     DHT - DHT instance

   Returns:
     Number of buckets refreshed."
  (length (routing-table-refresh (dht-routing-table dht))))

(defun dht-republish (dht)
  "Republish stored values.

   Arguments:
     DHT - DHT instance

   Returns:
     Number of values republished."
  (let ((candidates (get-republish-candidates
                     (dht-value-store dht)
                     (dht-config-republish-interval (dht-config dht)))))
    (dolist (record candidates)
      (setf (dht-record-republished-at record) (get-universal-time)))
    (length candidates)))

(defun dht-statistics (dht)
  "Get DHT statistics.

   Arguments:
     DHT - DHT instance

   Returns:
     Property list with statistics."
  (list :local-id (node-id-hex (dht-local-id dht))
        :running-p (dht-running-p dht)
        :routing-table-size (routing-table-size (dht-routing-table dht))
        :value-store-size (value-store-size (dht-value-store dht))
        :uptime (when (getf (dht-stats dht) :started-at)
                  (- (get-universal-time)
                     (getf (dht-stats dht) :started-at)))))

(defun dht-full-stats (dht)
  "Get comprehensive DHT statistics.

   Arguments:
     DHT - DHT instance

   Returns:
     Plist with detailed statistics."
  (let* ((routing-table (dht-routing-table dht))
         (value-store (dht-value-store dht))
         (provider-store (dht-provider-store dht))
         (buckets (routing-table-buckets routing-table))
         (bucket-sizes (loop for bucket across buckets
                             collect (bucket-size bucket)))
         (non-empty-buckets (count-if #'plusp bucket-sizes)))

    (list :local-id (node-id-hex (dht-local-id dht))
          :running-p (dht-running-p dht)
          :routing-table
          (list :total-nodes (routing-table-size routing-table)
                :total-added (routing-table-total-added routing-table)
                :total-removed (routing-table-total-removed routing-table)
                :non-empty-buckets non-empty-buckets
                :bucket-fill-rates bucket-sizes)
          :value-store
          (list :size (value-store-size value-store)
                :max-size (value-store-max-records value-store))
          :provider-store
          (list :keys (with-provider-lock (provider-store)
                        (hash-table-count (provider-store-records provider-store))))
          :config
          (list :k (dht-config-k (dht-config dht))
                :alpha (dht-config-alpha (dht-config dht))
                :bucket-refresh (dht-config-bucket-refresh-interval (dht-config dht))
                :republish-interval (dht-config-republish-interval (dht-config dht))))))

;;; ============================================================================
;;; PROVIDER OPERATIONS
;;; ============================================================================

(defun announce-provider (dht key &key (addresses nil))
  "Announce self as provider for content.

   Stores provider record locally and would propagate to
   k closest nodes in a real implementation.

   Arguments:
     DHT - DHT instance
     KEY - Content key (DHT-NODE-ID)
     ADDRESSES - Optional list of (address . port), defaults to local

   Returns:
     (VALUES success-p nodes-notified)
     SUCCESS-P - T if provider record was created
     NODES-NOTIFIED - Number of nodes notified (in production)"
  (let* ((local-id (dht-local-id dht))
         (addrs (or addresses
                    (list (cons (dht-local-address dht)
                                (dht-local-port dht)))))
         (config (dht-config dht))
         (routing-table (dht-routing-table dht))
         (k (dht-config-k config))
         (provider-store (dht-provider-store dht)))

    ;; Store locally
    (provider-store-add provider-store key local-id addrs
                        :ttl (dht-config-provider-ttl config))

    ;; Get k closest nodes for propagation
    (let ((closest (routing-table-closest routing-table key k)))
      ;; In real implementation, send ADD_PROVIDER to each
      (when *on-provider-added*
        (funcall *on-provider-added* key local-id))
      (values t (length closest)))))

(defun find-providers (dht key &key (count +max-providers-per-key+)
                                     (timeout +request-timeout+))
  "Find providers for content.

   Searches local store and queries network for providers.

   Arguments:
     DHT - DHT instance
     KEY - Content key
     COUNT - Maximum providers to return
     TIMEOUT - Query timeout

   Returns:
     (VALUES providers queried-nodes)
     PROVIDERS - List of PROVIDER-RECORD
     QUERIED-NODES - Nodes that were queried"
  (declare (ignore timeout))
  (let* ((provider-store (dht-provider-store dht))
         (routing-table (dht-routing-table dht))
         (k (dht-config-k (dht-config dht)))
         ;; Get local providers first
         (local-providers (provider-store-get provider-store key))
         (queried-nodes nil))

    ;; If we have enough providers locally, return them
    (when (>= (length local-providers) count)
      (return-from find-providers
        (values (subseq local-providers 0 count) nil)))

    ;; Query closest nodes for more providers
    (let ((closest (routing-table-closest routing-table key k)))
      ;; In real implementation, send GET_PROVIDERS to each
      (setf queried-nodes closest)

      ;; For now, return local providers
      (values local-providers queried-nodes))))

(defun refresh-provider-records (dht)
  "Refresh all provider records that are due.

   Re-announces as provider for all content where we are
   the original provider.

   Arguments:
     DHT - DHT instance

   Returns:
     Number of provider records refreshed."
  (let* ((provider-store (dht-provider-store dht))
         (local-id (dht-local-id dht))
         (refreshed 0)
         (now (get-universal-time))
         (refresh-threshold (* +provider-record-ttl+ 3/4)))  ; Refresh at 75% TTL

    (with-provider-lock (provider-store)
      (maphash (lambda (key-bytes records)
                 (declare (ignore key-bytes))
                 (dolist (record records)
                   ;; Only refresh our own provider records
                   (when (and (node-id= (provider-record-provider-id record) local-id)
                              (< (- (provider-record-expiration record) now)
                                 refresh-threshold))
                     ;; Re-announce
                     (let ((key (provider-record-key record))
                           (addrs (provider-record-addresses record)))
                       (provider-store-add provider-store key local-id addrs
                                           :ttl +provider-record-ttl+)
                       (incf refreshed)))))
               (provider-store-records provider-store)))
    refreshed))
