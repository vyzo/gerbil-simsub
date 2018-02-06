;; -*- Gerbil -*-
;; © vyzo
;; simulation environment

(import :gerbil/gambit
        :std/actor)
(export #t)

(def current-protocol-trace
  (make-parameter #f))

(def current-protocol-router
  (make-parameter #f))

(defproto protocol
  event:
  (trace ts msg)
  (publish ts msg)
  (deliver ts msg))

(defsyntax (send! stx)
  (syntax-case stx ()
    ((_ (message peer arg ...))
     (with-syntax ((event
                    (let* ((str (symbol->string (stx-e #'message)))
                           (str (substring str 2 (string-length str)))
                           (sym (string->symbol str)))
                      (stx-identifier #'message sym))))
       #'(cond
          ((current-protocol-router)
           => (lambda (actor)
                (trace-send! peer ['message arg ...])
                (send actor (make-message (!event (event arg ...)) (current-thread) peer #f))))
          (else
           (trace-send! peer ['message arg ...])
           (message peer arg ...)))))))

(defrules trace! ()
  ((_ (message peer arg ...))
   (begin
     (trace-send! peer ['message arg ...])
     (message peer arg ...))))

(defrules with-protocol-trace ()
  ((_ actor body ...)
   (cond
    ((current-protocol-trace)
     => (lambda (actor) body ...)))))

(def (trace-send! peer msg)
  (with-protocol-trace actor
    (let ((src (trace-id (current-thread)))
          (dest (trace-id peer)))
      (!!protocol.trace actor (trace-ts) [src dest msg]))))

(def (trace-publish! id data)
  (with-protocol-trace actor
    (let (src (trace-id (current-thread)))
      (!!protocol.publish actor (trace-ts) [src #f [id data]]))))

(def (trace-deliver! id data)
  (with-protocol-trace actor
    (let (src (trace-id (current-thread)))
      (!!protocol.deliver actor (trace-ts) [src #f [id data]]))))

(def (trace-id thread)
  (or (thread-specific thread)
      thread))

(def (trace-ts)
  (##current-time-point))

(def (make-timeout dt)
  (seconds->time (+ (##current-time-point) dt)))

(def (time< t1 t2)
  (< (time->seconds t1)
     (time->seconds t2)))
