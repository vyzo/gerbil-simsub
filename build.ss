#!/usr/bin/env gxi

(import :std/build-script
        :std/make)

(defbuild-script
  `((gxc: "simsub/scheduler" ,@(include-gambit-sharp))
    "simsub/env"
    "simsub/proto"
    "simsub/floodsub"
    "simsub/gossipsub-base"
    "simsub/gossipsub-v1_0"
    "simsub/gossipsub-v1_1"
    "simsub/episub"
    "simsub/simulator"
    "simsub/scripts"))
