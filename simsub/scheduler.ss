;; -*- Gerbil -*-
;; © vyzo
;; virtual time scheduler

(import :gerbil/gambit
        :std/sugar
        :std/iter
        :std/format)
(export enable-virtual-time-scheduler!
        disable-virtual-time-scheduler!
        virtual-time-scheduler-reset!
        current-time-point
        current-time)

(def (errorf template . args)
  (apply eprintf template args))

(defrules with-lock ()
  ((_ mx thunk)
   (dynamic-wind
       (cut mutex-lock! mx)
       thunk
       (cut real-mutex-unlock! mx))))

;; state
(def enabled #f)
(def now 0)
(def thread-state (make-hash-table-eq))
(def scheduler #f)
(def mx (make-mutex))

;; real thread scheduler calls
(def real-thread-start!       (values thread-start!))
(def real-thread-sleep!       (values thread-sleep!))
(def real-thread-send         (values ##thread-send))
(def real-thread-mailbox-next (values thread-mailbox-next))
(def real-thread-join!        (values thread-join!))
(def real-mutex-unlock!       (values mutex-unlock!))

(def (enable-virtual-time-scheduler!)
  (unless enabled
    (set! thread-start!       vt-thread-start!)
    (set! thread-sleep!       vt-thread-sleep!)
    (set! ##thread-send       vt-thread-send) ; actors use the low level primitive
    (set! thread-mailbox-next vt-thread-mailbox-next)
    (set! thread-join!        vt-thread-join!)
    (set! mutex-unlock!       vt-mutex-unlock!)
    (set! now 0)
    (set! thread-state (make-hash-table-eq))
    (start-scheduler!)
    (set! enabled #t)))

(def (disable-virtual-time-scheduler!)
  (when enabled
    (virtual-time-scheduler-stop!)
    (set! thread-start!       real-thread-start!)
    (set! thread-sleep!       real-thread-sleep!)
    (set! ##thread-send       real-thread-send)
    (set! thread-mailbox-next real-thread-mailbox-next)
    (set! thread-join!        real-thread-join!)
    (set! mutex-unlock!       real-mutex-unlock!)
    (set! enabled #f)))

(def (virtual-time-scheduler-reset!)
  (when enabled
    (with-lock mx
      (lambda ()
        (thread-terminate! scheduler)
        (for ((values thr _) thread-state)
          (thread-terminate! thr))
        (set! now 0)
        (set! thread-state (make-hash-table-eq))
        (start-scheduler!)))))

(def (virtual-time-scheduler-stop!)
  (when enabled
    (with-lock mx
      (lambda ()
        (thread-terminate! scheduler)
        (for ((values thr _) thread-state)
          (thread-terminate! thr))))))

(def (current-time-point)
  (if enabled now (##current-time-point)))

(def (current-time)
  (seconds->time (current-time-point)))

(def (vt-thread-start! thread)
  (let (c (make-completion 'thread-start!))
    (real-thread-send scheduler ['start thread c])
    (completion-wait! c)
    thread))

(def (vt-thread-sleep! timeo)
  (let (c (make-completion 'thread-sleep!))
    (real-thread-send scheduler ['sleep (current-thread) timeo c])
    (completion-wait! c)))

(def (vt-thread-send thread obj)
  (let (c (make-completion 'thread-send))
    (real-thread-send scheduler ['send (current-thread) thread obj c])
    (completion-wait! c)))

(def (vt-thread-mailbox-next (timeo absent-obj) (timeo-val absent-obj))
  (let (c (make-completion 'thread-mailbox-next))
    (real-thread-send scheduler ['recv (current-thread) timeo timeo-val c])
    (completion-wait! c)))

(def (vt-thread-join! thread)
  (let (c (make-completion 'thread-join!))
    (real-thread-send scheduler ['join (current-thread) thread c])
    (completion-wait! c)
    (real-thread-join! thread)))

(def (vt-mutex-unlock! mx (cv absent-obj) (timeo absent-obj))
  (if (condition-variable? cv)
    (let (c (make-completion 'mutex-unlock!))
      ;; NOTE: this does not handle the timeout correctly, but it is not used by the simulator code.
      (real-thread-send scheduler ['sync (current-thread)])
      (real-mutex-unlock! mx cv timeo)
      (real-thread-send scheduler ['continue (current-thread) c])
      (completion-wait! c))
    (real-mutex-unlock! mx)))

(def (start-scheduler!)
  (let (thr (make-thread vt-scheduler 'scheduler))
    (set! scheduler thr)
    (real-thread-start! thr)))

;; used by scheduler
(extern namespace: #f
  macro-mailbox-cursor
  macro-mailbox-cursor-set!
  macro-fifo-next
  macro-mailbox-fifo
  macro-fifo-elem)

(def (vt-scheduler)
  (def active 0)
  (def joining (make-hash-table-eq))
  (def (timeout timeo)
    (cond
     ((time? timeo) (time->seconds timeo))
     ((real? timeo) (+ now timeo))
     (else #f)))

  (def (loop)
    (match (thread-receive)
      (['start thread c]
       (with-lock mx
         (lambda ()
           (hash-put! thread-state thread '(running))
           (set! active (1+ active))
           (start-monitor! thread)
           (real-thread-start! thread)
           (completion-post! c (void)))))

      (['exit thread]
       (with-lock mx
         (lambda ()
           (alet (state (hash-get thread-state thread))
             (hash-remove! thread-state thread)
             (when (eq? (car state) 'running)
               (set! active (1- active))))
           (alet (waiting (hash-get joining thread))
             (hash-remove! joining thread)
             (for (thread waiting)
               (let (state (hash-ref thread-state thread))
                 (set! active (1+ active))
                 (hash-put! thread-state thread '(running))
                 (completion-post! (caddr state) (void))))))))

      (['join thread target c]
       (with-lock mx
         (lambda ()
           (cond
            ((hash-get thread-state target)
             (set! active (1- active))
             (hash-put! thread-state thread ['join target c])
             (hash-update! joining target (cut cons thread <>) []))
            (else
             (completion-post! c (void)))))))

      (['sleep thread timeo c]
       (with-lock mx
         (lambda ()
           (set! active (1- active))
           (let (abstime (timeout timeo))
             (hash-put! thread-state thread ['sleep abstime c])))))

      (['send thread dest obj c]
       (with-lock mx
         (lambda ()
           (cond
            ((hash-get thread-state dest)
             => (lambda (state)
                  (if (eq? (car state) 'recv)
                    (begin
                      (set! active (1+ active))
                      (hash-put! thread-state dest '(running))
                      (completion-post! (cadddr state) obj))
                    (real-thread-send dest obj))))
            (else
             (real-thread-send dest obj)))
           (completion-post! c (void)))))

      (['recv thread timeo timeo-val c]
       (with-lock mx
         (lambda ()
           (let* ((mb (##thread-mailbox-get! thread))
                  (cursor (macro-mailbox-cursor mb))
                  (next (if cursor
                          (macro-fifo-next cursor)
                          (macro-mailbox-fifo mb)))
                  (next2 (macro-fifo-next next)))
             (if (pair? next2)
               (let (result (macro-fifo-elem next2))
                 (macro-mailbox-cursor-set! mb next)
                 (completion-post! c result))
               (begin
                 (set! active (1- active))
                 (let (abstime (timeout timeo))
                   (hash-put! thread-state thread ['recv abstime timeo-val c]))))))))

      (['sync thread]
       (with-lock mx
         (lambda ()
           (set! active (1- active))
           (hash-put! thread-state thread '(sync)))))

      (['continue thread c]
       (with-lock mx
         (lambda ()
           (set! active (1+ active))
           (hash-put! thread-state thread '(running))
           (completion-post! c (void))))))

    (if (zero? active)
      (advance!)
      (loop)))

  (def (advance!)
    (with-lock mx
      (lambda ()
        (def time #f)
        (def thread #f)

        (for ((values thr state) thread-state)
          (case (car state)
            ((sleep recv)
             (let (t (cadr state))
               (when (and t (or (not time) (< t time)))
                 (set! time t)
                 (set! thread thr))))))

        (when time
          (let (state (hash-get thread-state thread))
            (when (> time now)
              (set! now time))

            (displayln "ADVANCE " now)

            (set! active (1+ active))
            (hash-put! thread-state thread '(running))
            (case (car state)
              ((sleep)
               (completion-post! (caddr state) (void)))
              ((recv)
               (completion-post! (cadddr state) (caddr state))))))))

    (loop))

  (try
   (loop)
   (catch (e)
     (errorf "scheduler error: ~a" e))))

(def (start-monitor! thread)
  (def (monitor)
    (with-catch void (cut real-thread-join! thread))
    (real-thread-send scheduler ['exit thread]))

  (let (thr (make-thread monitor 'monitor))
    (real-thread-start! thr)))

;; in-place implementtation of completions
;; ideally we would just use :std/misc/completion, but recursion, see recursion...
(defstruct cmpl (mx cv ready? value)
  final: #t unchecked: #t)

(def completions (make-hash-table-eq))
(def completions-mx (make-mutex))

(extern namespace: #f
  macro-mutex-name-set!
  macro-condvar-name-set!)

(def (make-completion name)
  (with-lock completions-mx
    (lambda ()
      (cond
       ((hash-get completions (current-thread))
        => (lambda (c)
             (macro-mutex-name-set! (&cmpl-mx c) name)
             (macro-condvar-name-set! (&cmpl-cv c) name)
             c))
       (else
        (let (c (make-cmpl (make-mutex name) (make-condition-variable name) #f (void)))
          (hash-put! completions (current-thread) c)
          c))))))

(def (completion-wait! c)
  (with ((cmpl mx cv) c)
    (let lp ()
      (mutex-lock! mx)
      (if (&cmpl-ready? c)
        (begin
          (real-mutex-unlock! mx)
          (&cmpl-value c))
        (begin
          (real-mutex-unlock! mx cv)
          (lp))))))

(def (completion-post! c val)
  (with ((cmpl mx cv) c)
     (mutex-lock! mx)
     (set! (&cmpl-value c) val)
     (set! (&cmpl-ready? c) #t)
     (real-mutex-unlock! mx)
     (condition-variable-broadcast! cv)
     (void)))
