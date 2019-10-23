#lang info

(define pkg-name "grapevine")
(define collection "grapevine")
(define pkg-desc "Connect to the Grapevine intermud network")
(define version "1.0")
(define pkg-authors '(djholtby))

(define deps '("base" "gregor" "rfc6455" "libuuid"))
(define build-deps '("racket-doc"
                     "scribble-lib"))

(define scribblings '(("scribblings/grapevine.scrbl" ())))
