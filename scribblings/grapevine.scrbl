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
                     If @racket[url] is specified, it will connect to that URL, otherwise it will connected to the default Grapevine server.
                     If @racket[chan] is specified, it will automatically subscribe to the given channels, otherwise it will not subscribe to
                     any.  @racket[id] and @racket[secret] are your server's ID and secret (obtain from the
                                                               grapevine site).

                     @racket[user-agent] is the user agent that will be reported from the server.
                                                               
                     The grapevine object has its own thread for handling the websock connection.  Server to client interactions occur through
                     the use of callbacks.

                     @racket[(players-callback)] is called periodically by the grapevine heartbeat
 to report the list of currently logged-in players.

 @racket[(broadcast-callback chan game name msg)] is called when a broadcast message (@racket[msg]) on channel @racket[chan] is received
 from player @racket[name] on server @racket[game].
                     
 @racket[(tell-callback from-game from-name to sent msg)] is called when a tell message (@racket[msg]) intended for local player @racket[to]
 is received from player @racket[from-name] on server @racket[from-game] at @racket[sent] UTC.  (Note that since sent is a @racket[moment]
 it's easy to interpret as a local time).

 @racket[(response-callback response)] is called for all other events.  Response is @racket['connected] when the connection is established and
 authenticated.  Otherwise, @racket[response] is a @racket[jsexpr] as shown in the Grapevine documentation.
 
 
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


                                       
