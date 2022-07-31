#!/usr/bin/env gxi

(import :std/build-script)

(defbuild-script
  '("simsub/env"
    "simsub/proto"
    "simsub/floodsub"
    "simsub/gossipsub-base"
    "simsub/gossipsub-v1_0"
    "simsub/gossipsub-v1_1"
    "simsub/episub"
    "simsub/simulator"
    "simsub/scripts"))
