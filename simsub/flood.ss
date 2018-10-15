;; © vyzo
;; floodsub

(import :std/actor
        :std/sugar
        :std/logger
        :std/iter
        :vyzo/simsub/proto
        :vyzo/simsub/env)
(export #t)

(def (floodsub-router receive initial-peers)
  (def messages (make-hash-table-eqv))
  (def peers [])

  (def (connect new-peers)
    (let (new-peers (filter (lambda (peer) (not (memq peer peers)))
                            new-peers))
      (for (peer new-peers)
        (send! (!!pubsub.connect peer)))
      (set! peers
        (foldl cons peers new-peers))))

  (def (loop)
    (<- ((!pubsub.connect)
         (unless (memq @source peers)
           (set! peers (cons @source peers))))

        ((!pubsub.publish id msg)
         (unless (hash-get messages id) ; seen?
           (hash-put! messages id msg)
           ;; deliver
           (receive id msg)
           ;; and forward
           (for (peer peers)
             (unless (eq? @source peer)
               (send! (!!pubsub.publish peer id msg)))))))
    (loop))

  (try
   (connect initial-peers)
   (loop)
   (catch (e)
     (log-error "unhandled exception" e))))
