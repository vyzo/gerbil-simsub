;; -*- Gerbil -*-
;; © vyzo
;; simulation environment

(import :gerbil/gambit
        :std/iter
        :std/actor
        :std/sort
        :std/logger
        :std/misc/shuffle
        :vyzo/simsub/scheduler)
(export #t)

(deflogger simsub)

;; start it here to avoid capturing the thread in the vt scheduler.
(start-logger!)

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
  (current-time-point))

(def (current-time)
  (seconds->time (current-time-point)))

(def (make-timeout dt)
  (seconds->time (+ (current-time-point) dt)))

(def (time<= t1 t2)
  (<= (time->seconds t1)
      (time->seconds t2)))

(def (make-rng)
  (let (new-rng (make-random-source))
    (random-source-randomize! new-rng)
    new-rng))

(def (make-subrng rng i j)
  (let (new-rng (make-random-source))
    (random-source-state-set! new-rng (random-source-state-ref rng))
    (random-source-pseudo-randomize! new-rng i j)
    new-rng))

(def (normalize lst (peer-id thread-specific))
  (sort lst (lambda (x y) (< (peer-id x) (peer-id y)))))

(def (shuffle/normalize lst rng (peer-id thread-specific))
  (shuffle (normalize lst peer-id) rng))

;; compatibility shims so that things work with gerbil 0.17
(cond-expand
  ((not (defined keyword-rest))
   (def (keyword-rest kwt . drop)
     (for-each (lambda (kw) (hash-remove! kwt kw)) drop)
     (hash-fold (lambda (k v r) (cons* k v r)) [] kwt))

   ;; we also need the rng version of shuffle
   (def (shuffle lst (rng default-random-source))
     (vector->list
      (vector-shuffle!
       (list->vector lst)
       rng)))

   (def (vector-shuffle vec (rng default-random-source))
     (vector-shuffle! (vector-copy vec) rng))

   (def (vector-shuffle! vec (rng default-random-source))
     (def random-integer
       (random-source-make-integers rng))
     (let (len (vector-length vec))
       (do ((i 0 (##fx+ i 1)))
           ((##fx= i len) vec)
         (let* ((j (##fx+ i (random-integer (##fx- len i))))
                (iv (##vector-ref vec i)))
           (##vector-set! vec i (##vector-ref vec j))
           (##vector-set! vec j iv))))))
  (else
   (export shuffle)))
