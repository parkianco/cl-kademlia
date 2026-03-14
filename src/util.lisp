;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: BSD-3-Clause

;;;; util.lisp - Utility functions and helpers
;;;;
;;;; BSD 3-Clause License
;;;; Copyright (c) 2024-2025, CLPIC Contributors

(in-package #:cl-kademlia)

;;; ============================================================================
;;; CONSTANTS
;;; ============================================================================

(defconstant +kademlia-k+ 20
  "Kademlia replication parameter. Number of nodes stored per bucket and
   returned in queries. Higher values increase redundancy and lookup success
   rate but consume more bandwidth and memory.")

(defconstant +kademlia-alpha+ 3
  "Kademlia concurrency parameter. Number of parallel queries during iterative
   lookups. Higher values speed up lookups but increase network load.")

(defconstant +kademlia-beta+ 3
  "Disjoint lookup paths for improved resilience against eclipse attacks.")

(defconstant +node-id-bits+ 256
  "Node ID size in bits. 256-bit IDs provide 2^256 keyspace.")

(defconstant +node-id-bytes+ 32
  "Node ID size in bytes (256 bits / 8).")

(defconstant +num-buckets+ 256
  "Number of k-buckets in routing table. One bucket per bit of node ID.")

(defconstant +bucket-refresh-interval+ 3600
  "Bucket refresh interval in seconds. Buckets with no activity are refreshed
   by performing a lookup for a random ID in their range.")

(defconstant +republish-interval+ 3600
  "Value republishing interval in seconds. Stored values are periodically
   republished to ensure they remain available.")

(defconstant +record-expiration+ 86400
  "Default record expiration time in seconds (24 hours).")

(defconstant +provider-record-ttl+ 86400
  "Provider record time-to-live in seconds (24 hours).")

(defconstant +request-timeout+ 10
  "Request timeout in seconds for individual RPC calls.")

(defconstant +ping-interval+ 300
  "Interval between liveness pings in seconds (5 minutes).")

(defconstant +max-value-size+ 65536
  "Maximum stored value size in bytes (64 KB).")

(defconstant +max-providers-per-key+ 20
  "Maximum number of provider records per content key.")

(defconstant +replacement-cache-size+ 8
  "Size of replacement cache per k-bucket.")

(defconstant +max-concurrent-queries+ 16
  "Maximum concurrent queries in flight.")

;;; ============================================================================
;;; CONFIGURATION
;;; ============================================================================

(defstruct (dht-config (:constructor %make-dht-config))
  "Configuration settings for the Kademlia DHT.

   All timing values are in seconds. The default values are suitable for
   most deployments but can be tuned for specific network conditions."

  (k +kademlia-k+
   :type (integer 1 256))

  (alpha +kademlia-alpha+
   :type (integer 1 16))

  (bucket-refresh-interval +bucket-refresh-interval+
   :type (integer 60))

  (republish-interval +republish-interval+
   :type (integer 60))

  (record-ttl +record-expiration+
   :type (integer 60))

  (provider-ttl +provider-record-ttl+
   :type (integer 60))

  (request-timeout +request-timeout+
   :type (integer 1 300))

  (max-value-size +max-value-size+
   :type (integer 1)))

(defun make-dht-config (&key (k +kademlia-k+)
                              (alpha +kademlia-alpha+)
                              (bucket-refresh-interval +bucket-refresh-interval+)
                              (republish-interval +republish-interval+)
                              (record-ttl +record-expiration+)
                              (provider-ttl +provider-record-ttl+)
                              (request-timeout +request-timeout+)
                              (max-value-size +max-value-size+))
  "Create a new DHT configuration with optional customization.

   Arguments:
     K - Replication factor (default 20)
     ALPHA - Concurrency factor (default 3)
     BUCKET-REFRESH-INTERVAL - Bucket refresh period (default 3600s)
     REPUBLISH-INTERVAL - Value republish period (default 3600s)
     RECORD-TTL - Record expiration time (default 86400s)
     PROVIDER-TTL - Provider record TTL (default 86400s)
     REQUEST-TIMEOUT - Request timeout (default 10s)
     MAX-VALUE-SIZE - Maximum value size (default 65536)

   Returns:
     A DHT-CONFIG structure."
  (%make-dht-config
   :k k
   :alpha alpha
   :bucket-refresh-interval bucket-refresh-interval
   :republish-interval republish-interval
   :record-ttl record-ttl
   :provider-ttl provider-ttl
   :request-timeout request-timeout
   :max-value-size max-value-size))

;;; Global configuration
(defvar *dht-config* nil
  "Global DHT configuration.")

;;; ============================================================================
;;; EVENT CALLBACKS
;;; ============================================================================

(defvar *on-node-discovered* nil
  "Callback when a node is discovered. Called with (node).")

(defvar *on-node-removed* nil
  "Callback when a node is removed. Called with (node-id).")

(defvar *on-value-stored* nil
  "Callback when a value is stored. Called with (key value).")

(defvar *on-value-retrieved* nil
  "Callback when a value is retrieved. Called with (key value).")

(defvar *on-provider-added* nil
  "Callback when a provider is added. Called with (key provider-id).")

(defvar *on-lookup-complete* nil
  "Callback when a lookup completes. Called with (target closest-nodes).")
