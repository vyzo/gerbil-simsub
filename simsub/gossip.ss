;; -*- Gerbil -*-
;; © vyzo
;; gossipsub aka meshsub/1

(import :gerbil/gambit
        :std/actor
        :std/logger
        :std/iter
        :std/sugar
        :std/misc/shuffle
        (only-in :std/srfi/1 take drop-right)
        :vyzo/simsub/env)
(export #t)

(defproto pubsub
  event:
  (connect)
  (publish id data))

(defproto gossipsub
  extend: pubsub
  event:
  (ihave ids)
  (iwant ids)
  (graft)
  (prune))

;; overlay parameters
(def N 6)                            ; target mesh degree
(def N-low 4)                        ; low water mark for mesh degree
(def N-high 12)                      ; high water mark for mesh degree

(def history-gossip 3)               ; length of gossip history
(def history-length 120)             ; length of total message history

(def epidemic-graft .5)              ; probability of epidemic grafting from gossip

;; receive: lambda (msg-id msg-data)
;; initial-peers: list of peers to connect
(def (gossipsub-router receive initial-peers)
  (def messages (make-hash-table-eqv))  ; message-id -> data
  (def window [])                       ; [message-id ...]
  (def history [])                      ; [window ...]
  (def peers [])                        ; connected peers
  (def D [])                            ; mesh peers
  (def heartbeat                        ; next heartbeat time
    (make-timeout (1+ (random-real))))

  (def (connect new-peers)
    (let (new-peers (filter (lambda (peer) (not (memq peer peers)))
                            new-peers))
      (for (peer new-peers)
        (send! (!!pubsub.connect peer)))
      (set! peers
        (foldl cons peers new-peers))))

  (def (heartbeat!)
    (def d (length D))

    ;; overlay management
    (when (< d N-low)
      ;; we need some links, add some peers and send GRAFT
      (let* ((i-need (- N d))
             (candidates (filter (lambda (peer) (not (memq peer D)))
                                 peers))
             (candidates (shuffle candidates))
             (new-peers (if (> (length candidates) i-need)
                          (take candidates i-need)
                          candidates)))
        (for (peer new-peers)
          (send! (!!gossipsub.graft peer)))
        (set! D (append D new-peers))))

    (when (> d N-high)
      ;; we have too many links, drop some peers and send PRUNE
      (let* ((to-drop (- d N))
             (candidates (shuffle D))
             (pruned-peers (take candidates to-drop)))
        (for (peer pruned-peers)
          (send! (!!gossipsub.prune peer)))
        (set! D (filter (lambda (peer) (not (memq peer pruned-peers)))
                        D))))

    ;; message history management
    (set! history (cons window history))
    (set! window [])
    (when (> (length history) history-length)
      (let (ids (last history))
        (set! history
          (drop-right history 1))
        (for (id ids)
          (hash-remove! messages id))))

    ;; gossip about messages in our history (if any)
    (let (ids (foldl (lambda (window r) (foldl cons r window))
                     []
                     (if (> (length history) history-gossip)
                       (take history history-gossip)
                       history)))
      (unless (null? ids)
        (let* ((peers (shuffle peers))
               (peers (if (> (length peers) N)
                        (take peers N)
                        peers)))
          (for (peer peers)
            (send! (!!gossipsub.ihave peer ids))))))

    (set! heartbeat (make-timeout 1)))

  (def (loop)
    (<- ((!pubsub.connect)
         (unless (memq @source peers)
           (set! peers (cons @source peers))))

        ((!pubsub.publish id msg)
         (if (hash-get messages id)     ; seen message?
           (when (and (memq @source D) (> (length D) N))
             ;; PRUNE link
             (send! (!!gossipsub.prune @source))
             (set! D (remq @source D)))
           (begin
             (hash-put! messages id msg)
             (set! window (cons id window))
             ;; deliver
             (receive id msg)
             ;; and forward
             (for (peer (remq @source D))
               (send! (!!pubsub.publish peer id msg))))))

        ((!gossipsub.ihave ids)
         (let (iwant (filter (lambda (id) (not (hash-get messages id)))
                             ids))
           (unless (null? iwant)
             (send! (!!gossipsub.iwant @source iwant))
             (when (and (not (memq @source D))
                        (or (< (length D) N)
                            (< (random-real) epidemic-graft)))
               ;; GRAFT a new link
               (send! (!!gossipsub.graft @source))
               (set! D (cons @source D))))))

        ((!gossipsub.iwant ids)
         (for (id ids)
           (alet (msg (hash-get messages id))
             (send! (!!pubsub.publish @source id msg)))))

        ((!gossipsub.graft)
         (unless (memq @source D)
           (set! D (cons @source D))))

        ((!gossipsub.prune)
         (when (memq @source D)
           (set! D (remq @source D))))

        (! heartbeat (heartbeat!)))
    (loop))

  (try
   (connect initial-peers)
   (loop)
   (catch (e)
     (log-error "unhandled exception" e))))
