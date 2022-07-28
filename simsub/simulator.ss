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
                        min-latency: (min-latency .010)
                        max-latency: (max-latency .150))
  (start-logger!)
  (spawn/group 'simulator simulator-main script nodes N-connect trace router params receive
               min-latency max-latency))

(def (stop-simulation! simd)
  (!!simulator.shutdown simd)
  (try
   (thread-join! simd)
   (finally
    (thread-group-kill! (thread-thread-group simd)))))

(def (simulator-main script nodes N-connect trace router params receive
                     min-latency max-latency)
  (def router-actor
    (let (thr (spawn/name 'router simulator-router min-latency max-latency))
      (spawn/name 'monitor simulator-monitor (current-thread) thr)
      thr))

  (def script-node
    (parameterize ((current-protocol-trace (current-thread))
                   (current-protocol-router router-actor))
      (let (thr (spawn/name 'driver simulator-driver script))
        (spawn/name 'monitor simulator-monitor (current-thread) thr)
        (thread-specific-set! thr 0)
        thr)))

  (def peer-nodes
    (parameterize ((current-protocol-trace (current-thread))
                   (current-protocol-router router-actor))
      (map (lambda (id)
             (let (thr (spawn/name 'peer simulator-node router params receive))
               (spawn/name 'monitor simulator-monitor (current-thread) thr)
               (thread-specific-set! thr id)
               thr))
           (iota nodes 1))))

  (def (run)
    (for (peer peer-nodes)
      (let* ((peers (shuffle (remq peer peer-nodes)))
             (peers (if (> (length peers) N-connect)
                      (take peers N-connect)
                      peers)))
        (!!simulator.start peer peers)))
    (!!simulator.start script-node peer-nodes)
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

(def (simulator-router min-latency max-latency)
  (def send-message #f)
  (def mqueue (make-pqueue (lambda (m) (time->seconds (car m)))))
  (def latencies (make-hash-table))

  (def (latency src dest)
    (let (key1 (cons src dest))
      (cond
       ((hash-get latencies key1)
        => values)
       (else
        (let ((key2 (cons dest src))
              (dt (+ min-latency (* (random-real) (- max-latency min-latency)))))
          (hash-put! latencies key1 dt)
          (hash-put! latencies key2 dt)
          dt)))))

  (def (push! dt msg)
    (let (timeo (make-timeout dt))
      (pqueue-push! mqueue (cons timeo msg))
      (when (or (not send-message) (time< timeo send-message))
        (set! send-message timeo))))

  (def (pop!)
    (let (now (current-time))
      (let lp ()
        (unless (pqueue-empty? mqueue)
          (with ([timeo . msg] (pqueue-peek mqueue))
            (when (time< timeo now)
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

(def (simulator-driver script)
  (def (run peers)
    (try
     (script peers)
     (catch (e)
       (errorf "unhandled exception: ~a" e)
       (raise e))))

  (<- ((!simulator.start peers)
       (run peers))))

(def (simulator-node router params receive)
  (def (run peers)
    (try
     (router params receive peers)
     (catch (e)
       (errorf "unhandled exception: ~a" e)
       (raise e))))

  (<- ((!simulator.start peers)
       (run peers))))

(def (simulator-monitor notifiee thread)
  (with-catch void (cut thread-join! thread))
  (!!simulator.join notifiee thread))
