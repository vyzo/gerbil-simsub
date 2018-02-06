;; -*- Gerbil -*-
;; © vyzo
;; pubsub simulator

(import :gerbil/gambit
        :std/actor
        :std/logger
        :std/sugar
        :std/iter
        :std/misc/threads
        :std/misc/shuffle
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
                        trace: trace
                        nodes: nodes
                        N-connect: (N-connect 10)
                        receive: (receive trace-deliver!))
  (start-logger!)
  (spawn/group 'simulator simulator-main script nodes N-connect trace router receive))

(def (stop-simulation! simd)
  (!!simulator.shutdown simd)
  (try
   (thread-join! simd)
   (finally
    (thread-group-kill! (thread-thread-group simd)))))

(def (simulator-main script nodes N-connect trace router receive)
  (def script-node
    (parameterize ((current-protocol-trace (current-thread)))
      (let (thr (spawn/name 'driver simulator-driver script))
        (thread-specific-set! thr 0)
        thr)))

  (def peer-nodes
    (parameterize ((current-protocol-trace (current-thread)))
      (map (lambda (id)
             (let (thr (spawn/name 'peer simulator-node router receive))
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
    (spawn/name 'monitor simulator-monitor (current-thread) script-node)
    (loop))

  (def (loop)
    (<- ((!simulator.shutdown)
         (shutdown!))
        ((!simulator.join actor)
         (unless (eq? actor script-node)
           (warning "actor exited unexpectedly ~a" actor))
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
    (raise 'shutdown))

  (try
   (run)
   (catch (e)
     (unless (eq? 'shutdown e)
       (log-error "unhandled exception" e)
       (raise e)))))

(def (simulator-driver script)
  (def (run peers)
    (try
     (script peers)
     (catch (e)
       (log-error "unhandled exception" e)
       (raise e))))

  (<- ((!simulator.start peers)
       (run peers))))

(def (simulator-node router receive)
  (def (run peers)
    (try
     (router receive peers)
     (catch (e)
       (log-error "unhandled exception" e)
       (raise e))))

  (<- ((!simulator.start peers)
       (run peers))))

(def (simulator-monitor notifiee thread)
  (with-catch void (cut thread-join! thread))
  (!!simulator.join notifiee thread))
