;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: Apache-2.0

;;;; package.lisp - Package definitions for cl-kademlia
;;;;
;;;; Kademlia Distributed Hash Table Protocol Implementation
;;;; Pure Common Lisp - no external dependencies

(defpackage #:cl-kademlia
  (:use #:cl)
  (:nicknames #:kademlia)
  (:documentation "Kademlia Distributed Hash Table Protocol Implementation

This package implements a full Kademlia DHT with:

1. ROUTING TABLE:
   - 256 k-buckets organized by XOR distance
   - Replacement cache for bucket overflow
   - Periodic bucket refresh and node liveness checks
   - Distance-based node organization

2. NODE LOOKUP:
   - Iterative lookup with alpha concurrency
   - Closest-nodes set maintenance
   - Parallel query optimization
   - Timeout and retry handling

3. VALUE STORAGE:
   - Key-value store with TTL support
   - Value republishing protocol
   - Replication to k closest nodes
   - Expiration and garbage collection

4. PROVIDER RECORDS:
   - Content provider announcements
   - Provider discovery by content key
   - Provider record TTL and refresh
   - Multiple providers per key

5. NETWORK PROTOCOL:
   - PING/PONG liveness checks
   - FIND_NODE for routing
   - FIND_VALUE for retrieval
   - STORE for publication
   - ADD_PROVIDER/GET_PROVIDERS for content addressing")

  ;; Configuration
  (:export
   #:+kademlia-k+
   #:+kademlia-alpha+
   #:+kademlia-beta+
   #:+node-id-bits+
   #:+node-id-bytes+
   #:+num-buckets+
   #:+bucket-refresh-interval+
   #:+republish-interval+
   #:+record-expiration+
   #:+provider-record-ttl+
   #:+request-timeout+
   #:+ping-interval+
   #:+max-value-size+
   #:+max-providers-per-key+
   #:+replacement-cache-size+
   #:+max-concurrent-queries+
   #:*dht-config*
   #:make-dht-config
   #:dht-config
   #:dht-config-k
   #:dht-config-alpha
   #:dht-config-bucket-refresh
   #:dht-config-republish-interval
   #:dht-config-record-ttl)

  ;; Node Identity
  (:export
   #:dht-node-id
   #:dht-node-id-p
   #:make-dht-node-id
   #:node-id-bytes
   #:node-id-hex
   #:generate-node-id
   #:node-id-from-key
   #:node-id-from-public-key
   #:xor-distance
   #:log-distance
   #:common-prefix-length
   #:closer-to-p
   #:bucket-index-for-distance
   #:node-id=
   #:node-id<)

  ;; DHT Node
  (:export
   #:dht-node
   #:dht-node-p
   #:make-dht-node
   #:dht-node-id
   #:dht-node-address
   #:dht-node-port
   #:dht-node-last-seen
   #:dht-node-latency
   #:dht-node-failed-requests)

  ;; K-bucket
  (:export
   #:k-bucket
   #:k-bucket-p
   #:make-k-bucket
   #:k-bucket-index
   #:k-bucket-nodes
   #:k-bucket-replacements
   #:k-bucket-capacity
   #:k-bucket-last-refresh
   #:bucket-add
   #:bucket-remove
   #:bucket-get
   #:bucket-contains-p
   #:bucket-size
   #:bucket-full-p
   #:bucket-needs-refresh-p
   #:bucket-stale-nodes)

  ;; Routing Table
  (:export
   #:routing-table
   #:routing-table-p
   #:make-routing-table
   #:routing-table-local-id
   #:routing-table-buckets
   #:routing-table-size
   #:routing-table-add
   #:routing-table-remove
   #:routing-table-update
   #:routing-table-get
   #:routing-table-contains-p
   #:routing-table-closest
   #:routing-table-random-nodes
   #:routing-table-all-nodes
   #:routing-table-refresh
   #:routing-table-prune)

  ;; Iterative Lookup
  (:export
   #:lookup-state
   #:lookup-state-p
   #:make-lookup-state
   #:lookup-state-target
   #:lookup-state-closest
   #:lookup-state-queried
   #:lookup-state-pending
   #:lookup-state-complete-p
   #:iterative-find-node
   #:iterative-find-value
   #:parallel-lookup
   #:advance-lookup
   #:finalize-lookup)

  ;; Value Store
  (:export
   #:dht-record
   #:dht-record-p
   #:make-dht-record
   #:dht-record-key
   #:dht-record-value
   #:dht-record-timestamp
   #:dht-record-expiration
   #:dht-record-publisher
   #:value-store
   #:value-store-p
   #:make-value-store
   #:value-store-get
   #:value-store-put
   #:value-store-delete
   #:value-store-contains-p
   #:value-store-size
   #:value-store-prune
   #:schedule-republish
   #:republish-values
   #:get-republish-candidates)

  ;; Provider Records
  (:export
   #:provider-record
   #:provider-record-p
   #:make-provider-record
   #:provider-record-key
   #:provider-record-provider-id
   #:provider-record-addresses
   #:provider-record-timestamp
   #:provider-record-expiration
   #:provider-store
   #:provider-store-p
   #:make-provider-store
   #:provider-store-add
   #:provider-store-get
   #:provider-store-remove
   #:provider-store-prune
   #:announce-provider
   #:find-providers
   #:refresh-provider-records)

  ;; DHT Service
  (:export
   #:dht
   #:dht-p
   #:make-dht
   #:dht-local-id
   #:dht-routing-table
   #:dht-value-store
   #:dht-provider-store
   #:dht-config
   #:dht-start
   #:dht-stop
   #:dht-bootstrap
   #:dht-get
   #:dht-put
   #:dht-add-provider
   #:dht-get-providers
   #:dht-find-node
   #:dht-refresh
   #:dht-republish
   #:dht-running-p
   #:dht-stats
   #:dht-statistics
   #:dht-full-stats)

  ;; Events and Callbacks
  (:export
   #:*on-node-discovered*
   #:*on-node-removed*
   #:*on-value-stored*
   #:*on-value-retrieved*
   #:*on-provider-added*
   #:*on-lookup-complete*))

(defpackage #:cl-kademlia.test
  (:use #:cl #:cl-kademlia)
  (:export
   #:run-tests))
