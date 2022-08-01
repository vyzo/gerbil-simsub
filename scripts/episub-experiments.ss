#!/usr/bin/env gxi

(import :gerbil/gambit
        :std/format
        :std/iter
        :vyzo/simsub/scripts
        :vyzo/simsub/episub)

(def (run-simulations nodes sources messages)
  (def rng
    (let (rng (make-random-source))
      (random-source-randomize! rng)
      rng))
  (def rng-state
    (random-source-state-ref rng))
  (def default-source-state
    (random-source-state-ref default-random-source))
  (def (run-it what run)
    (printf "+++ ~a~n" what)
    (random-source-state-set! rng rng-state)
    (random-source-state-set! default-random-source default-source-state)
    (run))

  (printf ">>> Running simulations with nodes: ~a, sources: ~a, messages: ~a, rng-state: ~a, default-source-state: ~a~n" nodes sources messages rng-state default-source-state)
  (run-it 'gossipsub/v1.0
          (lambda ()
            (simple-gossipsub/v1.0-simulation
             nodes: nodes sources: sources messages: messages
             rng: rng
             trace: void)))
  (run-it 'gossipsub/v1.1
          (lambda ()
            (simple-gossipsub/v1.0-simulation
             nodes: nodes sources: sources messages: messages
             rng: rng
             trace: void)))
  (for (strategy '(order-avg order-median latency-avg latency-median latency-p90))
    (run-it (format "episub/~a" strategy)
            (lambda ()
              (simple-episub-simulation
               params: (make-overlay/v1.2 choke-strategy: strategy)
               nodes: nodes sources: sources messages: messages
               rng: rng
               trace: void)))))

(for* ((nodes '(100 250 500))
       (sources '(5 10 20))
       (messages '(60 120 300)))
  (run-simulations nodes sources messages))
