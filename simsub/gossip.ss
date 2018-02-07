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
  (link)
  (unlink)
  (graft)
  (prune))

;; overlay parameters
(def N-in 6)                     ; target inbound degree
(def N-in-low 4)                 ; low water mark for inbound degree
(def N-in-high 9)                ; high water mark for inbound degree
(def N-out 6)                    ; target outbound degree
(def N-out-low 4)                ; low water mark for outbound degree
(def N-out-high 12)              ; high water mark for outbound degree

(def history-gossip 3)           ; length of gossip history
(def history-length 30)          ; length of total message history

;; receive: lambda (msg-id msg-data)
;; initial-peers: list of peers to connect
(def (gossipsub-router receive initial-peers)
  (def messages (make-hash-table-eqv))  ; message-id -> data
  (def window [])                       ; [message-id ...]
  (def history [])                      ; [window ...]
  (def peers [])                        ; connected peers
  (def D-in [])                         ; inbound peers in the mesh
  (def D-out [])                        ; outbound peer in the mesh
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
    (def d-in (length D-in))
    (def d-out (length D-out))

    ;; overlay management
    (when (< d-in N-in-low)
      ;; we need some inbound links, send LINK to some peers
      (let* ((i-need (- N-in d-in))
             (candidates (filter (lambda (peer) (not (memq peer D-in)))
                                 peers))
             (candidates (shuffle candidates))
             (candidates (if (> (length candidates) i-need)
                           (take candidates i-need)
                           candidates)))
        (for (peer candidates)
          (send! (!!gossipsub.link peer)))))

    (when (> d-in N-in-high)
      ;; we have too many inbound links, send UNLINK to some peers
      (let* ((to-drop (- d-in N-in))
             (candidates (shuffle D-in))
             (candidates (take candidates to-drop)))
        (for (peer candidates)
          (send! (!!gossipsub.unlink peer)))))

    (when (< d-out N-out-low)
      ;; we have too few outbound links, add some peers and send GRAFT
      (let* ((i-need (- N-out d-out))
             (candidates (filter (lambda (peer) (not (memq peer D-out)))
                                 peers))
             (candidates (shuffle candidates))
             (candidates (if (> (length candidates) i-need)
                           (take candidates i-need)
                           candidates)))
        (set! D-out (foldl cons D-out candidates))
        (for (peer candidates)
          (send! (!!gossipsub.graft peer)))))

    (when (> d-out N-out-high)
      ;; we have too many outbound links, drop some peers and send PRUNE
      (let* ((to-drop (- d-out N-out))
             (candidates (shuffle D-out))
             (candidates (take candidates to-drop)))
        (for (peer candidates)
          (set! D-out (remq peer D-out))
          (send! (!!gossipsub.prune peer)))))

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
               (peers (if (> (length peers) N-out)
                        (take peers N-out)
                        peers)))
          (for (peer peers)
            (send! (!!gossipsub.ihave peer ids))))))

    (set! heartbeat (make-timeout 1)))

  (def (loop)
    (<- ((!pubsub.connect)
         (unless (memq @source peers)
           (set! peers (cons @source peers))))

        ((!pubsub.publish id msg)
         (unless (hash-get messages id) ; seen?
           (hash-put! messages id msg)
           (set! window (cons id window))
           ;; deliver
           (receive id msg)
           ;; and forward
           (for (peer (remq @source D-out))
             (send! (!!pubsub.publish peer id msg)))))

        ((!gossipsub.ihave ids)
         (let (iwant (filter (lambda (id) (not (hash-get messages id)))
                             ids))
           (unless (null? iwant)
             (send! (!!gossipsub.iwant @source iwant)))))

        ((!gossipsub.iwant ids)
         (for (id ids)
           (alet (msg (hash-get messages id))
             (send! (!!pubsub.publish @source id msg)))))

        ((!gossipsub.link)
         (unless (memq @source D-out)
           (set! D-out (cons @source D-out))
           (send! (!!gossipsub.graft @source))))

        ((!gossipsub.unlink)
         (when (memq @source D-out)
           (set! D-out (remq @source D-out))
           (send! (!!gossipsub.prune @source))))

        ((!gossipsub.graft)
         (unless (memq @source D-in)
           (set! D-in (cons @source D-in))))

        ((!gossipsub.prune)
         (when (memq @source D-in)
           (set! D-in (remq @source D-in))))

        (! heartbeat (heartbeat!)))
    (loop))

  (try
   (connect initial-peers)
   (loop)
   (catch (e)
     (log-error "unhandled exception" e))))
