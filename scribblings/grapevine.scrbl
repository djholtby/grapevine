#lang scribble/manual


@(require scribble/example
	  (for-label racket
		     grapevine))

@title{Grapevine}

@author[(author+email "Daniel Holtby" "djholtby@gmail.com")]

@defmodule[grapevine]

@local-table-of-contents[]

@section{Introduction}

This package, @tt{grapevine}, provides
@link["https://grapevine.haus/docs"]{Grapevine} integration for Racket,
using @racket[net/rfc6455] for WebSockets.

@section{API}

@(define make-gv-eval
   (make-eval-factory '(grapevine)))

@defproc[(grapevine-connect!
	[id string?]
	[secret string?]
	[user-agent string?]
	[players-callback (-> (listof string?))]
	[broadcast-callback (-> string? string? string? string? void?)]
        [tell-callback (-> string? string? string? moment? string? void?)]
        [response-callback (-> any/c void?)]
        [error-callback (-> log-level/c symbol? string? void?)]
        [#:url url (or/c ws-url? wss-url?)]
        [#:channels chan (listof grapevine-channel?)])
         grapevine?]{ Produces a grapevine connection object.  

                                                    }

@defproc[(grapevine? [v any/c]) boolean?]{Predicate to check if a value is a Grapevine object}
@defproc[(grapevine-channel? [s string]) boolean?]{Predicate to check if a string is a legal name for a Grapevine channel.

@examples[
          #:eval (make-gv-eval)
          (grapevine-channel? "gossip")
          (grapevine-channel? "no spaces")
]}



;(define (grapevine-broadcast! gv channel name message)

@defproc[(grapevine-broadcast!
          [gv grapevine?]
          [channel grapevine-channel?]
          [name string?]
          [message string?]) boolean?]{Sends a msesage from name to the given channel.

                                       Precondition: Grapevine object gv must be substribed to channel, and must be connected.}


                                       
