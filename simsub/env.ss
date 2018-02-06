;; -*- Gerbil -*-
;; © vyzo
;; simulation environment

(import :gerbil/gambit
        :std/actor)
(export #t)

(def current-protocol-trace
  (make-parameter #f))

(defproto protocol
  event:
  (trace ts msg))

(defrules trace! ()
  ((_ (message peer arg ...))
   (begin
     (trace-send! peer ['message arg ...])
     (message peer arg ...))))

(def (trace-send! peer msg)
  (cond
   ((current-protocol-trace)
    => (lambda (actor)
         (let ((src (trace-id (current-thread)))
               (dest (trace-id peer)))
         (!!protocol.trace actor (trace-ts) [src dest msg]))))))

(def (trace-id thread)
  (or (thread-specific thread)
      thread))

(def (trace-ts)
  (##current-time-point))

(def (make-timeout dt)
  (seconds->time (+ (##current-time-point) dt)))
