;; -*- Gerbil -*-
;; © vyzo
;; pubsub simulator

(import :gerbil/gambit
        :std/actor
        :std/sugar
        :std/iter
        :std/misc/threads
        :std/misc/shuffle
        :std/misc/pqueue
        :std/misc/barrier
        :std/misc/completion
        (only-in :std/srfi/1 take)
        :vyzo/simsub/env)
(export start-simulation! stop-simulation!)

(defproto simulator
  event:
  (start peers)
  (shutdown)
  (join actor))

(def (start-simulation! script: script
                        router: router
                        params: params
                        trace: trace
                        nodes: nodes
                        N-connect: (N-connect 10)
                        receive: (receive trace-deliver!)
                        rng: (rng (make-rng))
                        min-latency: (min-latency .010)
                        max-latency: (max-latency .150)
                        jitter: (jitter .1))
  (spawn/group 'simulator simulator-main script nodes N-connect trace router params receive
               rng min-latency max-latency jitter))

(def (stop-simulation! simd)
  (!!simulator.shutdown simd)
  (try
   (thread-join! simd)
   (finally
    (thread-group-kill! (thread-thread-group simd)))))

(def (simulator-main script nodes N-connect trace router params receive
                     rng min-latency max-latency jitter)
  (def router-rng
    (make-subrng rng 5 7))
  (def main-rng
    (make-subrng rng 7 11))
  (def node-rng-base
    (make-subrng rng 11 13))
  (def (make-node-rng i)
    (make-subrng node-rng-base (+ 13 i) (* 17 i)))

  (def barrier1 (make-barrier nodes))
  (def completion1 (make-completion))
  (def (ready!)
    ;; wait for all the initial connect events to be ready to be popped
    (thread-sleep! (* (1+ jitter) max-latency 2))
    (barrier-post! barrier1)
    (completion-wait! completion1))

  (def barrier2 (make-barrier (1+ nodes)))
  (def completion2 (make-completion))
  (def (go!)
    (barrier-post! barrier2)
    (completion-wait! completion2))

  (def router-actor
    (let (thr (spawn/name 'router simulator-router router-rng min-latency max-latency jitter))
      (spawn/name 'monitor simulator-monitor (current-thread) thr)
      thr))

  (def script-node
    (parameterize ((current-protocol-trace (current-thread))
                   (current-protocol-router router-actor))
      (let (thr (spawn/name 'driver simulator-driver script go!))
        (spawn/name 'monitor simulator-monitor (current-thread) thr)
        (thread-specific-set! thr 0)
        thr)))

  (def peer-nodes
    (parameterize ((current-protocol-trace (current-thread))
                   (current-protocol-router router-actor))
      (map (lambda (id)
             (let (thr (spawn/name 'peer simulator-node router params receive
                                   (make-node-rng id) ready! go!))
               (spawn/name 'monitor simulator-monitor (current-thread) thr)
               (thread-specific-set! thr id)
               thr))
           (iota nodes 1))))

  (def (run)
    (for (peer peer-nodes)
      (let* ((peers (shuffle (remq peer peer-nodes) main-rng))
             (peers (if (> (length peers) N-connect)
                      (take peers N-connect)
                      peers)))
        (!!simulator.start peer peers)))
    (!!simulator.start script-node peer-nodes)
    ;; ready!
    (barrier-wait! barrier1)
    (completion-post! completion1 (void))
    ;; go!
    (barrier-wait! barrier2)
    (completion-post! completion2 (void))
    ;; loop
    (loop))

  (def (loop)
    (<- ((!simulator.shutdown)
         (shutdown!))
        ((!simulator.join actor)
         (unless (eq? actor script-node)
           (warnf "actor exited unexpectedly ~a" actor))
         (when (eq? actor script-node)
           (shutdown!)))
        ((!protocol.trace ts msg)
         (trace (cons* 'trace ts msg)))
        ((!protocol.publish ts msg)
         (trace (cons* 'publish ts msg)))
        ((!protocol.deliver ts msg)
         (trace (cons* 'deliver ts msg))))
    (loop))

  (def (shutdown!)
    (for-each thread-terminate! peer-nodes)
    (thread-terminate! script-node)
    (thread-terminate! router-actor)
    (raise 'shutdown))

  (try
   (run)
   (catch (e)
     (unless (eq? 'shutdown e)
       (errorf "unhandled exception: ~a" e)
       (raise e)))))

(def (simulator-router rng min-latency max-latency jitter)
  (def send-message #f)
  (def mqueue (make-pqueue (lambda (m) (time->seconds (car m)))))
  (def rands (make-hash-table))
  (def latencies (make-hash-table))

  (def (get-rand key)
    (cond
     ((hash-get rands key) => values)
     (else
      (with ([src . dest] key)
        (let* ((key2 (cons dest src))
               (i (min (thread-specific src) (thread-specific dest)))
               (j (max (thread-specific src) (thread-specific dest)))
               (rand (random-source-make-reals (make-subrng rng i j))))
          (hash-put! rands key rand)
          (hash-put! rands key2 rand)
          rand)))))

  (def (with-jitter key dt)
    (+ dt (* ((get-rand key)) jitter dt)))

  (def (latency src dest)
    (let (key (cons src dest))
      (cond
       ((hash-get latencies key)
        => (cut with-jitter key <>))
       (else
        (let* ((key2 (cons dest src))
               (rand (get-rand key))
               (dt (+ min-latency (* (rand) (- max-latency min-latency)))))
          (hash-put! latencies key dt)
          (hash-put! latencies key2 dt)
          (with-jitter key dt))))))

  (def (push! dt msg)
    (let (timeo (make-timeout dt))
      (pqueue-push! mqueue (cons timeo msg))
      (when (or (not send-message) (time<= timeo send-message))
        (set! send-message timeo))))

  (def (pop!)
    (let (now (current-time))
      (let lp ()
        (unless (pqueue-empty? mqueue)
          (with ([timeo . msg] (pqueue-peek mqueue))
            (when (time<= timeo now)
              (send (message-dest msg) msg)
              (pqueue-pop! mqueue)
              (lp)))))
      (set! send-message
        (if (pqueue-empty? mqueue)
          #f
          (car (pqueue-peek mqueue))))))

  (def (loop)
    (<< ((? message? msg)
         (pop!)
         (with ((message _ src dest) msg)
           (let (dt (latency src dest))
             (push! dt msg))))
        (! send-message (pop!)))
    (loop))

  (try
   (loop)
   (catch (e)
     (errorf "unhandled exception: ~a" e)
     (raise e))))

(def (simulator-driver script go!)
  (def (run peers)
    (try
     (script peers)
     (catch (e)
       (errorf "unhandled exception: ~a" e)
       (raise e))))

  (go!)
  (<- ((!simulator.start peers)
       (run peers))))

(def (simulator-node router params receive rng ready! go!)
  (def (run peers)
    (try
     (router params receive peers rng ready! go!)
     (catch (e)
       (errorf "unhandled exception: ~a" e)
       (raise e))))

  (<- ((!simulator.start peers)
       (run peers))))

(def (simulator-monitor notifiee thread)
  (with-catch void (cut thread-join! thread))
  (!!simulator.join notifiee thread))
