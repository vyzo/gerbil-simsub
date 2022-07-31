;;; -*- Gerbil -*-
;;; © vyzo
;;; gossipsub v1.1 protocol

(import :gerbil/gambit/random
        :std/iter
        :std/misc/shuffle
        (only-in :std/srfi/1 take)
        :vyzo/simsub/proto
        :vyzo/simsub/env
        :vyzo/simsub/gossipsub-base
        :vyzo/simsub/gossipsub-v1_0)
(export #t)

;; gossipsub/v1.1 overlay parameters
;; gossip-factor: probability of gossiping to a node
;; flood-publish: enables flood publishing when #t
;; px: (max) peers to exchange in prune; 0 disables px.
(defstruct (overlay/v1.1 overlay/v1.0) (gossip-factor flood-publish px)
  constructor: :init!)

(defmethod {:init! overlay/v1.1}
  (lambda (#!key kws self
            gossip-factor: (gossip-factor .25)
            flood-publish: (flood-publish #t)
            px: (px 16))
    (set! (overlay/v1.1-gossip-factor self) gossip-factor)
    (set! (overlay/v1.1-flood-publish self) flood-publish)
    (set! (overlay/v1.1-px self) px)
    (apply overlay/v1.0:::init! self (keyword-rest kws gossip-factor: flood-publish: px:))))

;; gossipsub v1.1 implementation
;; Note: the score function is not implemented here, as we are interested in the performance
;;       properties of the protocol. Nonetheless, should you wish to study its properties, it
;;       should be straightforward to implement.
(defgossipsub gossipsub/v1.1
  (params peers mesh mcache)
  (publish! forward! void gossip! void shuffle prune! void)
  (def (publish! id msg)
    (forward-message! #f id msg (if (overlay/v1.1-flood-publish params) peers mesh)))
  (def (forward! source id msg)
    (forward-message! source id msg mesh))
  (def (prune! peer)
    (let* ((px (overlay/v1.1-px params))
           (peers
            (cond
             ((zero? px) [])
             ((> (length peers) px)
              (take (remq peer peers) px))
             (else
              (remq peer peers)))))
      (send! (!!gossipsub.prune peer peers))))
  (def (gossip!)
    (let (mids (mcache-gossip mcache (overlay-gossip-window params)))
      (unless (null? mids)
        (let* ((candidates (filter (lambda (p) (not (memq p mesh))) (shuffle peers)))
               (gossip-peers
                (for/fold (r []) (peer candidates)
                  (if (< (random-real) (overlay/v1.1-gossip-factor params))
                    (cons peer r)
                    r)))
               (gossip-peers
                (if (< (length gossip-peers) (overlay/v1.0-D-gossip params))
                  (let ((to-add (- (overlay/v1.0-D-gossip params) (length gossip-peers)))
                        (candidates (filter (lambda (p) (not (memq p gossip-peers))) candidates)))
                    (append (take candidates to-add) gossip-peers))
                  gossip-peers)))
          (for (peer gossip-peers)
            (send! (!!gossipsub.ihave peer mids))))))))
