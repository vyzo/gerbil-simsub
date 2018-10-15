#!/usr/bin/env gxi

(import :std/build-script)

(defbuild-script
  '("simsub/env"
    "simsub/proto"
    "simsub/flood"
    "simsub/gossip"
    "simsub/simulator"
    "simsub/scripts"))
