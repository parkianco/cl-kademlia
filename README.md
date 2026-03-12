# cl-kademlia

A pure Common Lisp implementation of the Kademlia Distributed Hash Table (DHT) protocol.

## Overview

cl-kademlia provides a complete implementation of the Kademlia DHT with:

- **XOR Distance Metric**: Symmetric, unidirectional distance calculation
- **K-Bucket Routing**: 256 buckets organized by logarithmic distance ranges
- **Iterative Lookup**: Alpha-concurrent parallel queries for O(log n) lookups
- **Value Storage**: Key-value store with TTL and republishing
- **Provider Records**: Content-addressable storage announcements

## Features

- **Zero Dependencies**: Pure Common Lisp, no external libraries required
- **Thread Safe**: All operations protected by fine-grained locking (SBCL)
- **Configurable**: Tunable k, alpha, timeouts, and intervals
- **Portable**: Works on SBCL (uses sb-thread for threading on SBCL, degrades gracefully elsewhere)

## Installation

```lisp
;; Load the system
(asdf:load-system "cl-kademlia")

;; Or in REPL
(load "cl-kademlia.asd")
(asdf:load-system "cl-kademlia")
```

## Quick Start

```lisp
(use-package :cl-kademlia)

;; Create a DHT instance
(defvar *dht* (make-dht :port 4001))

;; Start the DHT
(dht-start *dht*)

;; Store a value
(let ((key (node-id-from-key "my-content")))
  (dht-put *dht* key "Hello, DHT!"))

;; Retrieve a value
(let ((key (node-id-from-key "my-content")))
  (dht-get *dht* key))
;; => "Hello, DHT!"

;; Announce as a content provider
(let ((content-key (node-id-from-key "my-file.dat")))
  (dht-add-provider *dht* content-key))

;; Find content providers
(let ((content-key (node-id-from-key "my-file.dat")))
  (dht-get-providers *dht* content-key))

;; Get statistics
(dht-statistics *dht*)

;; Stop the DHT
(dht-stop *dht*)
```

## API Reference

### Configuration

```lisp
;; Create custom configuration
(make-dht-config :k 20              ; replication factor
                 :alpha 3           ; concurrency factor
                 :bucket-refresh-interval 3600
                 :republish-interval 3600
                 :record-ttl 86400
                 :request-timeout 10)
```

### Node IDs

```lisp
;; Generate random node ID
(generate-node-id)

;; Derive from content key
(node-id-from-key "content")

;; Derive from public key
(node-id-from-public-key #(1 2 3 4 ...))

;; XOR distance
(xor-distance id1 id2)

;; Log distance (bucket index)
(log-distance id1 id2)

;; Distance comparison
(closer-to-p candidate reference target)
```

### DHT Operations

```lisp
;; Create DHT
(make-dht :local-id node-id
          :address "0.0.0.0"
          :port 4001
          :config config)

;; Lifecycle
(dht-start dht)
(dht-stop dht)

;; Bootstrap from seed nodes
(dht-bootstrap dht '(("192.168.1.1" . 4001)
                     ("192.168.1.2" . 4001)))

;; Value operations
(dht-put dht key value)
(dht-get dht key)

;; Provider operations
(dht-add-provider dht content-key)
(dht-get-providers dht content-key)

;; Maintenance
(dht-refresh dht)
(dht-republish dht)

;; Statistics
(dht-statistics dht)
(dht-full-stats dht)
```

### Routing Table

```lisp
;; Create routing table
(make-routing-table local-id config)

;; Add/remove nodes
(routing-table-add table node)
(routing-table-remove table node-id)

;; Find closest nodes
(routing-table-closest table target-id k)

;; Maintenance
(routing-table-refresh table)
(routing-table-prune table)
```

### Iterative Lookups

```lisp
;; Find k closest nodes
(iterative-find-node dht target-id
                     :timeout 10
                     :on-query (lambda (node) ...)
                     :on-response (lambda (node nodes) ...))

;; Find value
(iterative-find-value dht key
                      :timeout 10
                      :on-query (lambda (node) ...)
                      :on-value (lambda (value node) ...))

;; Parallel lookups
(parallel-lookup dht targets :max-concurrent 16)
```

## Constants

| Constant | Default | Description |
|----------|---------|-------------|
| `+kademlia-k+` | 20 | Replication factor |
| `+kademlia-alpha+` | 3 | Concurrency factor |
| `+node-id-bits+` | 256 | Node ID size in bits |
| `+num-buckets+` | 256 | Number of k-buckets |
| `+bucket-refresh-interval+` | 3600 | Bucket refresh interval (seconds) |
| `+republish-interval+` | 3600 | Value republish interval (seconds) |
| `+record-expiration+` | 86400 | Default record TTL (seconds) |
| `+request-timeout+` | 10 | Request timeout (seconds) |

## Event Callbacks

```lisp
;; Set callbacks for events
(setf *on-node-discovered* (lambda (node) ...))
(setf *on-node-removed* (lambda (node-id) ...))
(setf *on-value-stored* (lambda (key value) ...))
(setf *on-value-retrieved* (lambda (key value) ...))
(setf *on-provider-added* (lambda (key provider-id) ...))
(setf *on-lookup-complete* (lambda (target closest-nodes) ...))
```

## Testing

```lisp
;; Run tests
(asdf:test-system "cl-kademlia")

;; Or directly
(cl-kademlia.test:run-tests)
```

## References

- [Kademlia: A Peer-to-Peer Information System Based on the XOR Metric](https://pdos.csail.mit.edu/~petar/papers/maymounkov-kademlia-lncs.pdf) - Maymounkov & Mazieres, IPTPS 2002
- [libp2p Kademlia DHT specification](https://github.com/libp2p/specs/tree/master/kad-dht)
- [IPFS DHT design documents](https://docs.ipfs.io/concepts/dht/)

## License

BSD 3-Clause License. See LICENSE file.

## Contributing

