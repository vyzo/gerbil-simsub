;;; -*- Gerbil -*-
;;; © vyzo
;;; episub (gossipsub/v1.2) experiments

(import :gerbil/gambit/random
        :std/actor
        :std/iter
        :std/sort
        :std/misc/shuffle
        (only-in :std/srfi/1 take)
        :vyzo/simsub/proto
        :vyzo/simsub/env
        :vyzo/simsub/gossipsub-base
        :vyzo/simsub/gossipsub-v1_0
        :vyzo/simsub/gossipsub-v1_1)
(export #t)

;; episub overlay parameters
;; D-choke: minimum acceptable mesh degree excluding choked peers
;; choke-strategy: the strategy to use for making choking decisions
;;  'order-avg:      use delivery order average
;;  'latency-avg:    use delivery latency average
;;  'latency-median: use delivery latency median
;;  'latency-p90:    use delivery latency 90th percentale
;; choke-threshold: number of heartbeats before choking is activated
;; choke-frequency: number of heartbeats before a new choking decision is made
;; choke-min-samples: minimum number of samples for considering a peer in a choking decision
(defstruct (overlay/v1.2 overlay/v1.1) (D-choke choke-strategy choke-threshold choke-frequency choke-min-samples)
  constructor: :init!)

(defmethod {:init! overlay/v1.2}
  (lambda (#!key kws self
            D-choke: (D-choke 3)
            choke-strategy: (choke-strategy 'order-avg)
            choke-threshold: (choke-threshold 30)
            choke-frequency: (choke-frequency 15)
            choke-min-samples: (choke-min-samples 3))
    (set! (overlay/v1.2-D-choke self) D-choke)
    (set! (overlay/v1.2-choke-strategy self) choke-strategy)
    (set! (overlay/v1.2-choke-threshold self) choke-threshold)
    (set! (overlay/v1.2-choke-frequency self) choke-frequency)
    (set! (overlay/v1.2-choke-min-samples self) choke-min-samples)
    (apply overlay/v1.1:::init! self
           (keyword-rest kws D-choke: choke-strategy: choke-threshold: choke-frequency: choke-min-samples:))))

;; episub experimental implementation
(defgossipsub gossipsub/v1.2
  (params peers mesh mcache)
  (publish! deliver! duplicate! on-heartbeat! handle-message prune-candidates prune! pruned!)
  ;; peers we have choked
  (def choke-in [])
  ;; peers that have choked us
  (def choke-out [])
  ;; delivered/duplicate message timestamps
  (def deliveries (make-hash-table-eqv))
  ;; delivery mcache (for managing delivery table)
  (def deliveries-mcache (make-mcache [] []))
  ;; choking strategy
  (def choke-strategy
    (case (overlay/v1.2-choke-strategy params)
      ((order-avg)      choke-strategy-order-avg)
      ((latency-avg)    choke-strategy-latency-avg)
      ((latency-median) choke-strategy-latency-median)
      ((latency-p90)    choke-strategy-latency-p90)
      (else
       (error "unknown choking strategy" (overlay/v1.2-choke-strategy params)))))
  ;; current heartbeat
  (def heartbeat 0)
  ;; implementation
  (def (publish! id msg)
    (forward-message! #f id msg (if (overlay/v1.1-flood-publish params) peers mesh)))
  (def (deliver! source id msg)
    (mcache-push! deliveries-mcache id)
    (hash-put! deliveries id [(cons source (trace-ts))])
    (forward-message! source id msg mesh choke-out))
  (def (duplicate! source id)
    (hash-update! deliveries id (cut cons (cons source (trace-ts)) <>) []))
  (def (on-heartbeat!)
    (set! heartbeat (1+ heartbeat))
    ;; choking/unchoking logic
    (when (> heartbeat (overlay/v1.2-choke-threshold params))
      (when (zero? (modulo heartbeat (overlay/v1.2-choke-frequency params)))
        (let ((values choke unchoke)
              (choke/strategy choke-strategy deliveries mesh choke-in
                              (overlay/v1.2-choke-min-samples params)
                              (overlay/v1.2-D-choke params)))
          ;; we only try to choke when we are over D-choke in effective mesh degree
          (when choke
            (set! choke-in (cons choke choke-in))
            (send! (!!episub.choke choke)))
          (when unchoke
            (set! choke-in (remq unchoke choke-in))
            (send! (!!episub.unchoke unchoke))))))
    ;; deliveries table maintenance
    (let (expired (mcache-shift! deliveries-mcache (overlay/v1.2-choke-frequency params)))
      (for (mid expired)
        (hash-remove! deliveries mid)))
    ;; send gossip
    (let (mids (mcache-gossip mcache (overlay-gossip-window params)))
      (gossip/adaptive! params mids peers mesh choke-out)))
  (def (handle-message source m)
    (match m
      ((!event (episub.choke))
       (set! choke-out (cons source choke-out)))
      ((!event (episub.unchoke))
       (set! choke-out (remq source choke-out)))))
  (def (prune-candidates mesh)
    (append (shuffle choke-in)
            (filter (lambda (peer) (not (memq peer choke-in)))
                    (shuffle mesh))))
  (def (prune! peer)
    (when (memq peer choke-in)
      (set! choke-in (remq peer choke-in)))
    (when (memq peer choke-out)
      (set! choke-out (remq peer choke-out)))
    (prune/px! params peer peers))
  (def (pruned! peer)
    (when (memq peer choke-in)
      (set! choke-in (remq peer choke-in))
      ;; if we got pruned and have too few non-choked peers, we need to unchoke someone
      (when (< (- (length mesh) (length choke-in)) (overlay/v1.2-D-choke params))
        (unless (null? choke-in)
          (let (peer (car (shuffle choke-in)))
            (set! choke-in (remq peer choke-in))
            (send! (!!episub.unchoke peer))))))
    (when (memq peer choke-out)
      (set! choke-out (remq peer choke-out)))))

;; choking/unchoking logic
(def (choke/strategy choke-strategy deliveries mesh choked min-samples D-choke)
  (def (count f lst)
    (let lp ((rest lst) (cnt 0))
      (match rest
        ([x . rest]
         (lp rest (if (f x) (1+ cnt) cnt)))
        (else cnt))))
  (let* ((stat (choke-strategy deliveries mesh min-samples))
         (stat (sort stat (lambda (x y) (< (cdr x) (cdr y)))))
         (rstat (reverse stat)))
    (values
      ;; choke slowest peer not already choked
      (let lp ((rest rstat))
        (match rest
          ([[peer . _] . rest]
           (cond
            ((memq peer choked)
             (lp rest))
            ((< (count (lambda (x) (not (memq (car x) choked))) rest) D-choke)
             #f)
            (else peer)))
          (else #f)))
      ;; unchoke the fastest choked peer that is faster than any unchoked one
      (let lp ((rest stat) (unchoked []))
        (match rest
          ([[peer . _] . rest]
           (if (memq peer choked)
             (if (find (lambda (x) (not (memq (car x) choked))) rest)
               peer
               #f)
             (lp rest (cons peer unchoked))))
          (else #f))))))

;; choking strategies
(def (choke-strategy-order-avg deliveries mesh min-samples)
  (let (stat (stat-delivery-order deliveries mesh))
    (stat-collect stat stat-average min-samples)))

(def (choke-strategy-latency-avg deliveries mesh min-samples)
  (let (stat (stat-delivery-latency deliveries mesh))
    (stat-collect stat stat-average min-samples)))

(def (choke-strategy-latency-median deliveries mesh min-samples)
  (let (stat (stat-delivery-latency deliveries mesh))
    (stat-collect stat stat-median min-samples)))

(def (choke-strategy-latency-p90 deliveries mesh min-samples)
  (let (stat (stat-delivery-latency deliveries mesh))
    (stat-collect stat stat-p90 min-samples)))

(def (stat-delivery-order deliveries mesh)
  (let (result (make-hash-table-eq))
    (for ((values _ samples) deliveries)
      (let lp ((rest (reverse samples)) (order 0))
        (match rest
          ([[peer . _] . rest]
           (when (memq peer mesh)
             (hash-update! result peer (cut cons order <>) []))
           (lp rest (1+ order)))
          (else (void)))))
    result))

(def (stat-delivery-latency deliveries mesh)
  (let (result (make-hash-table-eq))
    (for ((values _ samples) deliveries)
      (let* ((samples (reverse samples))
             (start (cdar samples)))
        (let lp ((rest samples))
          (match rest
            ([[peer . ts] . rest]
             (when (memq peer mesh)
               (hash-update! result peer (cut cons (- ts start) <>) []))
             (lp rest))
            (else (void))))))
    result))

(def (stat-collect stat aggregate min-samples)
  (hash-fold
     (lambda (peer samples r)
       (if (< (length samples) min-samples)
         r
         (cons (cons peer (aggregate samples)) r)))
     [] stat))

(def (stat-average stat)
  (let ((N (length stat))
        (sum (foldl + 0 stat)))
    (exact->inexact (/ sum N))))

(def (stat-median stat)
  (let* ((N (length stat))
         (median (inexact->exact (floor (/ N 2))))
         (stat (sort stat <)))
    (list-ref stat median)))

(def (stat-p90 stat)
  (let* ((N (length stat))
         (p90 (inexact->exact (floor (* N .9))))
         (stat (sort stat <)))
    (list-ref stat p90)))
