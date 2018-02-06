;; -*- Gerbil -*-
;; © vyzo
;; simple simulation scripts

(import :gerbil/gambit
        :std/iter
        :std/misc/shuffle
        (only-in :std/srfi/1 take)
        :vyzo/simsub/env
        :vyzo/simsub/gossip
        :vyzo/simsub/simulator)
(export #t)

(def (simple-gossipsub-simulation nodes: (nodes 100)
                                  fanout: (fanout 5)
                                  messages: (messages 10)
                                  duration: (duration 30)
                                  trace: (trace displayln))
  (def (my-script peers)
    (let (peers (shuffle peers))
      (let lp ((i 0))
        (when (< i messages)
          (thread-sleep! 1)
          (let (dest (take (shuffle peers) fanout))
            (for (peer dest)
              (let (msg (cons 'msg i))
                (trace-publish! i msg)
                (!!pubsub.publish peer i msg))))
          (lp (1+ i))))
      (thread-sleep! duration)))

  (let (simulator (start-simulation! script: my-script
                                     router: gossipsub-router
                                     nodes: nodes
                                     trace: trace))
    (thread-join! simulator)))
