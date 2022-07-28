;;; -*- Gerbil -*-
;;; © vyzo
;;; generic gossipsub framework

(import :gerbil/gambit
        :std/sugar
        :std/iter
        :std/actor
        :std/misc/shuffle
        (only-in :std/srfi/1 take drop-right)
        :vyzo/simsub/proto
        :vyzo/simsub/env)
(export #t)

;; overlay parameters
;; D: mesh degree
;; D-low: mesh low watermark
;; D-hi: mesh high water mark
;; heartbeat: heartbeat period in seconds
;; history: mcache history length
;; gossip-window: mcache gossip window
(defstruct overlay (D D-low D-high heartbeat history gossip-window)
  constructor: :init!)

(defmethod {:init! overlay}
  (lambda (self D: (D 6) D-low: (D-low 4) D-high: (D-high 12)
           heartbeat: (heartbeat 1)
           history: (history 120)
           gossip-window: (gossip-window 3))
    (struct-instance-init! self D D-low D-high heartbeat history gossip-window)))

;; message cache
;; window: messages in the current heartbeat window
(defstruct mcache (window history))

;; gossipsub actor definition
(defrules defgossipsub ()
  ;; params: the overlay parameters
  ;; peers: the local identifier of currently connected peers
  ;; mesh: the local identifier of current mesh peers
  ;; on-heartbeat!: function to call on heartbeat, implementing gossip and advanced functionality
  ;; handle-message: protocol specific message handler
  ;; locals: local definition(s)
  ((_ proto (params peers mesh mcache on-heartbeat! handle-message) local-defs ...)
   ;; receive: lambda (msg-id msg-data) -- delivers received messages
   ;; initial-peers: list of peers to connect at start up
   (def (proto params receive initial-peers)
     ;; seen messages: message-id -> data
     (def messages (make-hash-table-eqv))
     ;; message window/history management
     (def mcache (make-mcache [] []))
     ;; connected peers
     (def peers [])
     ;; mesh peers
     (def mesh [])
     ;; heartbeat: next heartbeat (abs time)
     (def heartbeat
       (make-timeout (1+ (* (random-real) (overlay-heartbeat params)))))

     ;; splice protocol-specific local defs
     local-defs ...

     ;; base functionality
     (def (connect new-peers)
       (let (new-peers (filter (lambda (peer) (not (memq peer peers)))
                               new-peers))
         (for (peer new-peers)
           (send! (!!pubsub.connect peer)))
         (set! peers
           (foldl cons peers new-peers))))

     (def (heartbeat!)
       (def d (length mesh))

       (with ((overlay D D-low D-high) params)
         ;; overlay management
         (when (< d D-low)
           ;; we need some links, add some peers and send GRAFT
           (let* ((i-need (- D d))
                  (candidates (filter (lambda (peer) (not (memq peer mesh)))
                                      peers))
                  (candidates (shuffle candidates))
                  (new-peers (if (> (length candidates) i-need)
                               (take candidates i-need)
                               candidates)))
             (for (peer new-peers)
               (send! (!!gossipsub.graft peer)))
             (set! mesh (append mesh new-peers))))

         (when (> d D-high)
           ;; we have too many links, drop some peers and send PRUNE
           (let* ((to-drop (- d D))
                  (candidates (shuffle mesh))
                  (pruned-peers (take candidates to-drop)))
             (for (peer pruned-peers)
               (send! (!!gossipsub.prune peer)))
             (set! mesh (filter (lambda (peer) (not (memq peer pruned-peers)))
                                mesh)))))

       ;; shift the mcache, drop older messages
       (let (expired (mcache-shift! mcache (overlay-history params)))
         (for (mid expired)
           (hash-remove! messages mid)))

       ;; protocol specific heartbeat
       (on-heartbeat!)

       (set! heartbeat (make-timeout (overlay-heartbeat params))))

     ;; actor main lopp
     (def (loop)
       (<- ((!pubsub.connect)
            (unless (memq @source peers)
              (set! peers (cons @source peers))))

           ((!pubsub.publish id msg)
            (unless (hash-get messages id) ; seen?
              (hash-put! messages id msg)
              (mcache-push! mcache id)
              ;; deliver
              (receive id msg)
              ;; and forward
              (for (peer mesh)
                (unless (eq? @source peer)
                  (send! (!!pubsub.publish peer id msg))))))

           ((!gossipsub.ihave ids)
            (let (iwant (filter (lambda (id) (not (hash-get messages id)))
                                ids))
              (unless (null? iwant)
                (send! (!!gossipsub.iwant @source iwant)))))

           ((!gossipsub.iwant ids)
            (for (id ids)
              (alet (msg (hash-get messages id))
                (send! (!!pubsub.publish @source id msg)))))

           ((!gossipsub.graft)
            (unless (memq @source mesh)
              (set! mesh (cons @source mesh))))

           ((!gossipsub.prune)
            (when (memq @source mesh)
              (set! mesh (remq @source mesh))))

           ;; protocol specific messages
           (msg (handle-message msg))

           ;; heartbeat timer
           (! heartbeat (heartbeat!)))
       (loop))

     (try
      (connect initial-peers)
      (loop)
      (catch (e)
        (errorf "unhandled exception: ~a" e))))))

;; mcache implementation
(def (mcache-shift! mc history-length)
  (with ((mcache window history) mc)
    (let (history-length (1- history-length))
      (if (> (length history) history-length)
        (let (expired (last history))
          (set! history
            (cons window (drop-right history 1)))
          (set! window [])
          expired)
        []))))

(def (mcache-push! mc mid)
  (set! (mcache-window mc)
    (cons mid (mcache-window mc))))

(def (mcache-gossip mc gossip-window)
  (with ((mcache window history) mc)
    (foldl (lambda (window r) (foldl cons r window))
           []
           (let (gossip-old (1- gossip-window))
             (if (> (length history) gossip-old)
               (take history gossip-old)
               history)))))
