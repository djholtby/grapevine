#lang scribble/manual


@(require scribble/manual
	  (for-label racket
		     net/url
		     net/rfc6455
		     uuid
		     grapevine))

@title{Grapevine}

@author[(author+email "Daniel Holtby" "djholtby@gmail.com")]

@local-table-of-contents[]

@section{Introduction}

This package, @tt{grapevine}, provides
@link["https://grapevine.haus/docs"]{Grapevine} integration for Racket,
using @racket[net/rfc6455] for WebSockets.

@section{API}


; grapevine-connect!: string string string ( -> (listof String)) (String String String String -> Void) (String String String Gregor String) (Symbol String -> Void) -> Bool
;(define (grapevine-connect! id secret user-agent players-callback broadcast-callback tell-callback response-callback error-callback #:url [url grapevine-url/default] #:channels [chan '()])

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

;(define (grapevine-broadcast! gv channel name message)

@defproc[(grapevine-broadcast!
          [gv grapevine?]
          [channel grapevine-channel?]
          [name string?]
          [message string?]) boolean?]{Sends a msesage from name to the given channel.

                                       Precondition: Grapevine object gv must be substribed to channel, and must be connected.}


                                       
