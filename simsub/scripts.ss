;; -*- Gerbil -*-
;; © vyzo
;; simple simulation scripts

(import :gerbil/gambit
        :std/iter
        :std/format
        :std/sort
        :std/misc/shuffle
        (only-in :std/srfi/1 take)
        :vyzo/simsub/env
        :vyzo/simsub/proto
        :vyzo/simsub/floodsub
        :vyzo/simsub/gossipsub-base
        :vyzo/simsub/gossipsub-v1_0
        :vyzo/simsub/gossipsub-v1_1
        :vyzo/simsub/episub
        :vyzo/simsub/simulator)
(export #t)

(def (simple-gossipsub/v1.0-simulation #!key kws params: (params #f))
  (apply simple-simulation
    router: gossipsub/v1.0
    params: (or params (make-overlay/v1.0))
    (keyword-rest kws router: params:)))

(def (simple-gossipsub/v1.1-simulation #!key kws params: (params #f))
  (apply simple-simulation
    router: gossipsub/v1.1
    params: (or params (make-overlay/v1.1))
    (keyword-rest kws router: params:)))

(def (simple-episub-simulation #!key kws params: (params #f))
  (apply simple-simulation
    router: gossipsub/v1.2
    params: (or params (make-overlay/v1.2))
    (keyword-rest kws router: params:)))

(def (simple-floodsub-simulation #!key kws)
  (apply simple-simulation
    router: floodsub
    params: #f
    (keyword-rest kws router: params:)))

(def (simple-simulation #!key kws
                        nodes: (nodes 100)
                        sources: (nsources 5)
                        messages: (messages 10)
                        message-delay: (message-delay 1)
                        connect-delay: (connect-delay 5)
                        connect: (connect 20)
                        linger: (linger 10)
                        trace: (trace displayln)
                        transcript: (transcript void)
                        rng: (rng default-random-source)
                        router: router
                        params: params)
  (def traces (box []))
  (def random-integer (random-source-make-integers rng))

  (def (my-trace evt)
    (set! (box traces)
      (cons evt (unbox traces)))
    (trace evt))

  (def (my-script peers)
    (thread-sleep! connect-delay)
    (let (sources (take (shuffle peers rng) nsources))
      (let lp ((i 0))
        (when (< i messages)
          (let (source (list-ref sources (random-integer nsources)))
            (let (msg (cons 'msg i))
              (trace-publish! i msg)
              (send! (!!pubsub.publish source i msg))))
          (thread-sleep! message-delay)
          (lp (1+ i)))))
    (thread-sleep! linger))

  (def (display-summary!)
    (def publish 0)
    (def deliver 0)
    (def send (make-hash-table-eq))
    (def deliveries (make-hash-table-eqv))

    (for (evt (unbox traces))
      (match evt
        (['trace ts src dest [what . _]]
         (hash-update! send what 1+ 0))
        (['publish . _]
         (set! publish (1+ publish)))
        (['deliver ts _ _ msg]
         (set! deliver (1+ deliver))
         (hash-update! deliveries (car msg) (cut cons ts <>) []))))

    (displayln "=== simulation summary ===")
    (displayln "nodes: " nodes)
    (displayln "messages: " messages)
    (displayln "sources: " nsources)
    (displayln "publish: " publish)
    (displayln "deliver: " deliver)
    (for ((values msg count) send)
      (displayln msg ": " count))

    (displayln "=== delivery latency histogram ===")
    (display-histogram deliveries))

  (let (simulator (apply start-simulation!
                    script: my-script
                    trace: my-trace
                    nodes: nodes
                    N-connect: connect
                    (keyword-rest kws
                                  nodes:
                                  sources:
                                  messages:
                                  message-delay:
                                  connect-delay:
                                  connect:
                                  linger:
                                  trace:
                                  transcript:)))
    (thread-join! simulator)
    (display-summary!)
    (transcript (unbox traces))))

(def (save-transcript-to-file file)
  (lambda (trace)
    (let (trace (reverse trace))
      (call-with-output-file file
        (lambda (port)
          (parameterize ((current-output-port port))
            (for-each displayln trace)))))))

(def (display-histogram deliveries)
  (def buckets (vector))
  (def samples 0)
  (def (bucket-stars i)
    (let* ((delta (inexact->exact (ceiling (/ samples 100))))
           (count (vector-ref buckets i))
           (stars (inexact->exact (floor (/ count delta)))))
      (make-string stars #\*)))
  (def (pad str n)
    (let (strlen (string-length str))
      (if (< strlen n)
        (string-append (make-string (- n strlen) #\space) str)
        str)))
  (for ((values _ timestamps) deliveries)
    (let* ((timestamps (sort timestamps <))
           (publish (car timestamps))
           (deliver (cdr timestamps)))
      (for (ts deliver)
        (set! samples (1+ samples))
        (let* ((delta (- ts publish))
               (bucket (inexact->exact (floor (/ delta .1))))) ; 100ms buckets
          (unless (< bucket (vector-length buckets))
            (let (new-buckets (make-vector (1+ bucket) 0))
              (subvector-move! buckets 0 (vector-length buckets) new-buckets 0)
              (set! buckets new-buckets)))
          (vector-set! buckets bucket (1+ (vector-ref buckets bucket)))))))
  (for (i (in-range (vector-length buckets)))
    (printf "~a\t~a\t~a\n"
            (pad (format "~a-~ams" (* i 100) (* (1+ i) 100)) 12)
            (pad (format "~a" (vector-ref buckets i)) 6)
            (bucket-stars i))))
