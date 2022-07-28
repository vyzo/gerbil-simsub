;;; -*- Gerbil -*-
;;; © vyzo
;;; baseline gossipsub v1.0 protocol

(import :std/iter
        :std/misc/shuffle
        (only-in :std/srfi/1 take)
        :vyzo/simsub/proto
        :vyzo/simsub/env
        :vyzo/simsub/gossipsub-base.ss)
(export #t)

;; gossipsub/v1.0 overlay parameters
;; D-gossip: the gossip degree (fixed)
(defstruct (overlay/v1.0 overlay) (D-gossip)
  constructor: :init!)

(defmethod {:init! overlay/v1.0}
  (lambda (#!key kws self D-gossip: (D-gossip 6))
    (set! (overlay/v1.0-D-gossip self) D-gossip)
    (apply overlay:::init! self (keyword-rest kws D-gossip:))))

(defgossipsub gossipsub/v1.0 (params peers mesh mcache send-gossip! void)
  (def (send-gossip!)
    (let (mids (mcache-gossip mcache (overlay-gossip-window params)))
      (unless (null? mids)
        (let* ((all-peers (shuffle peers))
               (gossip-peers (filter (lambda (p) (not (memq p mesh))) all-peers))
               (gossip-peers
                (let (D-gossip (overlay/v1.0-D-gossip params))
                  (if (> (length gossip-peers) )
                    (take gossip-peers D-gossip)
                    gossip-peers))))
          (for (peer peers)
            (send! (!!gossipsub.ihave peer mids))))))))
