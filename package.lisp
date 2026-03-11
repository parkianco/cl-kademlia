;;;; package.lisp - Package definitions for cl-kademlia
;;;;
;;;; BSD 3-Clause License
;;;; Copyright (c) 2024-2025, CLPIC Contributors

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

  ;; ============================================================================
  ;; CONSTANTS AND CONFIGURATION
  ;; ============================================================================
  (:export
   ;; Kademlia parameters
   #:+kademlia-k+                       ; Replication factor (20)
   #:+kademlia-alpha+                   ; Parallelism factor (3)
   #:+kademlia-beta+                    ; Disjoint paths for queries (3)
   #:+node-id-bits+                     ; Node ID size in bits (256)
   #:+node-id-bytes+                    ; Node ID size in bytes (32)
   #:+num-buckets+                      ; Number of k-buckets (256)

   ;; Timing constants
   #:+bucket-refresh-interval+          ; Bucket refresh interval (3600s)
   #:+republish-interval+               ; Value republish interval (3600s)
   #:+record-expiration+                ; Record expiration time (86400s)
   #:+provider-record-ttl+              ; Provider record TTL (86400s)
   #:+request-timeout+                  ; Request timeout (10s)
   #:+ping-interval+                    ; Ping interval for liveness (300s)

   ;; Limits
   #:+max-value-size+                   ; Maximum stored value size (65536)
   #:+max-providers-per-key+            ; Maximum providers per key (20)
   #:+replacement-cache-size+           ; Replacement cache per bucket (8)
   #:+max-concurrent-queries+           ; Maximum concurrent queries (16)

   ;; Configuration
   #:*dht-config*                       ; Global DHT configuration
   #:make-dht-config                    ; Create configuration
   #:dht-config                         ; Configuration structure
   #:dht-config-k                       ; Replication parameter
   #:dht-config-alpha                   ; Concurrency parameter
   #:dht-config-bucket-refresh          ; Refresh interval
   #:dht-config-republish-interval      ; Republish interval
   #:dht-config-record-ttl)             ; Record TTL

  ;; ============================================================================
  ;; NODE IDENTITY
  ;; ============================================================================
  (:export
   ;; Node ID type
   #:dht-node-id                        ; 256-bit node identifier
   #:dht-node-id-p                      ; Type predicate
   #:make-dht-node-id                   ; Constructor from bytes
   #:node-id-bytes                      ; Get raw 32 bytes
   #:node-id-hex                        ; Get hex string representation

   ;; Node ID generation
   #:generate-node-id                   ; Generate random node ID
   #:node-id-from-key                   ; Derive from content key
   #:node-id-from-public-key            ; Derive from public key

   ;; Distance calculations
   #:xor-distance                       ; XOR distance between two IDs
   #:log-distance                       ; Log2 of XOR distance (bucket index)
   #:common-prefix-length               ; Common prefix in bits
   #:closer-to-p                        ; Check if A is closer than B to target
   #:bucket-index-for-distance          ; Get bucket index for distance

   ;; Comparison
   #:node-id=                           ; Equality comparison
   #:node-id<)                          ; Ordering for sorted collections

  ;; ============================================================================
  ;; DHT NODE
  ;; ============================================================================
  (:export
   ;; Node structure
   #:dht-node                           ; DHT node information
   #:dht-node-p                         ; Type predicate
   #:make-dht-node                      ; Constructor
   #:dht-node-id                        ; Node's ID
   #:dht-node-address                   ; Network address
   #:dht-node-port                      ; Network port
   #:dht-node-last-seen                 ; Last contact timestamp
   #:dht-node-latency                   ; Round-trip latency
   #:dht-node-failed-requests)          ; Consecutive failures

  ;; ============================================================================
  ;; K-BUCKET
  ;; ============================================================================
  (:export
   ;; K-bucket structure
   #:k-bucket                           ; Single k-bucket
   #:k-bucket-p                         ; Type predicate
   #:make-k-bucket                      ; Constructor
   #:k-bucket-index                     ; Bucket index (0-255)
   #:k-bucket-nodes                     ; Nodes in bucket
   #:k-bucket-replacements              ; Replacement cache
   #:k-bucket-capacity                  ; Maximum capacity (k)
   #:k-bucket-last-refresh              ; Last refresh time

   ;; Bucket operations
   #:bucket-add                         ; Add node to bucket
   #:bucket-remove                      ; Remove node from bucket
   #:bucket-get                         ; Get node by ID
   #:bucket-contains-p                  ; Check if bucket contains node
   #:bucket-size                        ; Current node count
   #:bucket-full-p                      ; Is bucket at capacity?
   #:bucket-needs-refresh-p             ; Does bucket need refresh?
   #:bucket-stale-nodes)                ; Get stale nodes

  ;; ============================================================================
  ;; ROUTING TABLE
  ;; ============================================================================
  (:export
   ;; Routing table structure
   #:routing-table                      ; Kademlia routing table
   #:routing-table-p                    ; Type predicate
   #:make-routing-table                 ; Constructor
   #:routing-table-local-id             ; Local node's ID
   #:routing-table-buckets              ; All k-buckets
   #:routing-table-size                 ; Total nodes in table

   ;; Core operations
   #:routing-table-add                  ; Add node to table
   #:routing-table-remove               ; Remove node from table
   #:routing-table-update               ; Update node's info
   #:routing-table-get                  ; Get node by ID
   #:routing-table-contains-p           ; Check if contains node

   ;; Lookups
   #:routing-table-closest              ; Find k closest to target
   #:routing-table-random-nodes         ; Get random nodes
   #:routing-table-all-nodes            ; Get all nodes

   ;; Maintenance
   #:routing-table-refresh              ; Refresh stale buckets
   #:routing-table-prune)               ; Remove dead nodes

  ;; ============================================================================
  ;; ITERATIVE LOOKUP
  ;; ============================================================================
  (:export
   ;; Lookup state
   #:lookup-state                       ; Iterative lookup state
   #:lookup-state-p                     ; Type predicate
   #:make-lookup-state                  ; Constructor
   #:lookup-state-target                ; Target ID
   #:lookup-state-closest               ; K closest found
   #:lookup-state-queried               ; Already queried nodes
   #:lookup-state-pending               ; Pending queries
   #:lookup-state-complete-p            ; Is lookup complete?

   ;; Lookup operations
   #:iterative-find-node                ; Find k closest nodes
   #:iterative-find-value               ; Find value or k closest
   #:parallel-lookup                    ; Lookup with alpha concurrency
   #:advance-lookup                     ; Process response, advance
   #:finalize-lookup)                   ; Complete lookup

  ;; ============================================================================
  ;; VALUE STORE
  ;; ============================================================================
  (:export
   ;; Value record
   #:dht-record                         ; Stored value record
   #:dht-record-p                       ; Type predicate
   #:make-dht-record                    ; Constructor
   #:dht-record-key                     ; Record key
   #:dht-record-value                   ; Record value
   #:dht-record-timestamp               ; Storage timestamp
   #:dht-record-expiration              ; Expiration time
   #:dht-record-publisher               ; Publisher node ID

   ;; Value store
   #:value-store                        ; Local value storage
   #:value-store-p                      ; Type predicate
   #:make-value-store                   ; Constructor
   #:value-store-get                    ; Get value by key
   #:value-store-put                    ; Store value
   #:value-store-delete                 ; Delete value
   #:value-store-contains-p             ; Check if key exists
   #:value-store-size                   ; Number of stored values
   #:value-store-prune                  ; Remove expired values

   ;; Republishing
   #:schedule-republish                 ; Schedule value republish
   #:republish-values                   ; Republish all values
   #:get-republish-candidates)          ; Get values needing republish

  ;; ============================================================================
  ;; PROVIDER RECORDS
  ;; ============================================================================
  (:export
   ;; Provider record
   #:provider-record                    ; Content provider record
   #:provider-record-p                  ; Type predicate
   #:make-provider-record               ; Constructor
   #:provider-record-key                ; Content key
   #:provider-record-provider-id        ; Provider node ID
   #:provider-record-addresses          ; Provider addresses
   #:provider-record-timestamp          ; Record timestamp
   #:provider-record-expiration         ; Expiration time

   ;; Provider store
   #:provider-store                     ; Provider record storage
   #:provider-store-p                   ; Type predicate
   #:make-provider-store                ; Constructor
   #:provider-store-add                 ; Add provider for key
   #:provider-store-get                 ; Get providers for key
   #:provider-store-remove              ; Remove provider
   #:provider-store-prune               ; Remove expired providers

   ;; Provider operations
   #:announce-provider                  ; Announce as provider
   #:find-providers                     ; Find providers for key
   #:refresh-provider-records)          ; Refresh provider records

  ;; ============================================================================
  ;; DHT SERVICE
  ;; ============================================================================
  (:export
   ;; DHT structure
   #:dht                                ; Main DHT instance
   #:dht-p                              ; Type predicate
   #:make-dht                           ; Constructor
   #:dht-local-id                       ; Local node ID
   #:dht-routing-table                  ; Routing table
   #:dht-value-store                    ; Value store
   #:dht-provider-store                 ; Provider store
   #:dht-config                         ; Configuration

   ;; Lifecycle
   #:dht-start                          ; Start DHT service
   #:dht-stop                           ; Stop DHT service
   #:dht-bootstrap                      ; Bootstrap from seed nodes

   ;; High-level operations
   #:dht-get                            ; Get value by key
   #:dht-put                            ; Store value
   #:dht-add-provider                   ; Add provider record
   #:dht-get-providers                  ; Get providers for key
   #:dht-find-node                      ; Find node by ID

   ;; Maintenance
   #:dht-refresh                        ; Refresh routing table
   #:dht-republish                      ; Republish values
   #:dht-stats                          ; Get DHT statistics
   #:dht-full-stats)                    ; Get comprehensive statistics

  ;; ============================================================================
  ;; EVENTS AND CALLBACKS
  ;; ============================================================================
  (:export
   #:*on-node-discovered*               ; Called when node discovered
   #:*on-node-removed*                  ; Called when node removed
   #:*on-value-stored*                  ; Called when value stored
   #:*on-value-retrieved*               ; Called when value retrieved
   #:*on-provider-added*                ; Called when provider added
   #:*on-lookup-complete*))             ; Called when lookup completes

(defpackage #:cl-kademlia.test
  (:use #:cl #:cl-kademlia)
  (:export #:run-tests))
