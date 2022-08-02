;; © vyzo
;; floodsub

(import :std/actor
        :std/sugar
        :std/iter
        :vyzo/simsub/proto
        :vyzo/simsub/env)
(export #t)

(def (floodsub _ receive initial-peers rng ready! go!)
  (def messages (make-hash-table-eqv))
  (def peers [])

  (def (connect new-peers)
    (let (new-peers (filter (lambda (peer) (not (memq peer peers)))
                            new-peers))
      (for (peer new-peers)
        (send! (!!pubsub.connect peer)))
      (set! peers
        (foldl cons peers new-peers))))

  (def (connect-complete)
    (let lp ()
      (<- ((!pubsub.connect)
           (unless (memq @source peers)
             (set! peers (cons @source peers)))
           (lp))
          (else (void)))))

  (def (loop)
    (<- ((!pubsub.connect)
         (unless (memq @source peers)
           (set! peers (cons @source peers))))

        ((!pubsub.publish id msg)
         (hash-put! messages id msg)
         ;; deliver
         (receive id msg)
         ;; and forward
         (for (peer (shuffle/normalize peers rng))
           (send! (!!pubsub.message peer id msg))))

        ((!pubsub.message id msg)
         (unless (hash-get messages id) ; seen?
           (hash-put! messages id msg)
           ;; deliver
           (receive id msg)
           ;; and forward
           (for (peer (shuffle/normalize peers rng))
             (unless (eq? @source peer)
               (send! (!!pubsub.message peer id msg)))))))
    (loop))

  (try
   (connect initial-peers)
   (ready!)
   (connect-complete)
   (go!)
   (loop)
   (catch (e)
     (errorf "unhandled exception: ~a" e))))
