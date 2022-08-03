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
        current-time-point)

(def (errorf template . args)
  (apply eprintf template args))

(defrules with-lock ()
  ((_ mx thunk)
   (dynamic-wind
       (cut mutex-lock! mx)
       thunk
       (cut real-mutex-unlock! mx))))

;; scheduler state
(def enabled #f)
(def now 0)
(def mx (make-mutex))
(def active 0)
(def thread-state (make-hash-table-eq))
(def joining (make-hash-table-eq))


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
    (set! thread-state (make-hash-table-eq))
    (set! joining (make-hash-table-eq))
    (set! completions (make-hash-table-eq))
    (set! active 0)
    (set! now 0)
    (set! enabled #t)))

(def (disable-virtual-time-scheduler!)
  (when enabled
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
        (set! now 0)
        (set! active 0)
        (set! thread-state (make-hash-table-eq))
        (set! joining (make-hash-table-eq))
        (set! completions (make-hash-table-eq))))))

(def (current-time-point)
  (if enabled now (##current-time-point)))

(def (vt-thread-start! thread)
  (sched-start! thread)
  thread)

(def (vt-thread-sleep! timeo)
  (let (c (make-completion 'thread-sleep!))
    (sched-sleep! (current-thread) timeo c)
    (completion-wait! c)))

(def (vt-thread-send thread obj)
  (sched-send! (current-thread) thread obj))

(def (vt-thread-mailbox-next (timeo absent-obj) (timeo-val absent-obj))
  (let (c (make-completion 'thread-mailbox-next))
    (sched-recv! (current-thread) timeo timeo-val c)
    (completion-wait! c)))

(def (vt-thread-join! thread)
  (let (c (make-completion 'thread-join!))
    (sched-join! (current-thread) thread c)
    (completion-wait! c)
    (real-thread-join! thread)))

(def (vt-mutex-unlock! mx (cv absent-obj) (timeo absent-obj))
  (if (condition-variable? cv)
    (begin
      ;; NOTE: this does not handle the timeout correctly, but it is not used by the simulator code.
      (sched-sync! (current-thread))
      (real-mutex-unlock! mx cv timeo)
      (sched-continue! (current-thread)))
    (real-mutex-unlock! mx)))

;;; scheduler implementation
(def (sched-start! thread)
  (with-lock mx
    (lambda ()
      (hash-put! thread-state thread '(running))
      (set! active (1+ active))
      (start-monitor! thread)
      (real-thread-start! thread))))

(def (sched-exit! thread)
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
            (completion-post! (caddr state) (void)))))

      (sched-advance!))))

(def (sched-join! thread target c)
  (with-lock mx
    (lambda ()
      (cond
       ((hash-get thread-state target)
        (set! active (1- active))
        (hash-put! thread-state thread ['join target c])
        (hash-update! joining target (cut cons thread <>) [])
        (sched-advance!))
       (else
        (completion-post! c (void)))))))

(def (sched-sleep! thread timeo c)
  (with-lock mx
    (lambda ()
      (set! active (1- active))
      (let (abstime (sched-timeout timeo))
        (hash-put! thread-state thread ['sleep abstime c]))
      (sched-advance!))))

(def (sched-send! thread dest obj)
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
        (real-thread-send dest obj))))))

(def (sched-recv! thread timeo timeo-val c)
  (with-lock mx
    (lambda ()
      (let* ((none '#(timeout))
             (msg (real-thread-mailbox-next 0 none)))
        (if (eq? msg none)
          (begin
            (set! active (1- active))
            (let (abstime (sched-timeout timeo))
              (hash-put! thread-state thread ['recv abstime timeo-val c]))
            (sched-advance!))
          (completion-post! c msg))))))

(def (sched-sync! thread)
  (with-lock mx
    (lambda ()
      (set! active (1- active))
      (hash-put! thread-state thread '(sync))
      (sched-advance!))))

(def (sched-continue! thread)
  (with-lock mx
    (lambda ()
      (set! active (1+ active))
      (hash-put! thread-state thread '(running)))))

;; caller holds the lock
(def (sched-advance!)
  (def time #f)
  (def thread #f)

  (thread-yield!)

  (when (zero? active)
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

        (set! active (1+ active))
        (hash-put! thread-state thread '(running))
        (case (car state)
          ((sleep)
           (completion-post! (caddr state) (void)))
          ((recv)
           (completion-post! (cadddr state) (caddr state))))))))

(def (sched-timeout timeo)
  (cond
   ((time? timeo) (time->seconds timeo))
   ((real? timeo) (+ now timeo))
   (else #f)))

(def (start-monitor! thread)
  (def (monitor)
    (with-catch void (cut real-thread-join! thread))
    (sched-exit! thread))

  (let (thr (make-thread monitor 'monitor))
    (real-thread-start! thr)))


;;; in-place implementation of completions
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
             (set! (&cmpl-ready? c) #f)
             (set! (&cmpl-value c) (void))
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
