;; © vyzo
;; pubsub protocols

(import :std/actor)
(export #t)

(defproto pubsub
  event:
  (connect)
  (publish id msg)
  (message id msg))

(defproto gossipsub
  extend: pubsub
  event:
  (ihave ids)
  (iwant ids)
  (graft)
  (prune px))

(defproto episub
  extend: gossipsub
  event:
  (choke)
  (unchoke))
