#lang racket/base

(require json net/rfc6455 net/url racket/match racket/bool gregor libuuid) 


(provide grapevine-version grapevine-supports grapevine-channels grapevine-channel?
         grapevine-broadcast! grapevine-connect! grapevine-connected? grapevine-status grapevine-subscribe! grapevine-unsubscribe!
         grapevine-players/sign-in! grapevine-players/sign-out!)


#||||       Constants      ||||#

(define grapevine-version "2.3.0")
(define grapevine-url (string->url "wss://grapevine.haus/socket"))
(define grapevine-supports '("channels" "players" "tells"))
(define grapevine-channels '())

; (connection-payload id secret) constructs the payload object for the given id and secret.
;    - uses the above global variables for supports, default channels, and grapevine version

; connection-payload : string? string? -> jsexpr?

(define (connection-payload id secret user-agent)
  (hasheq 'client_id id
          'client_secret secret
          'user_agent user-agent
          'supports grapevine-supports
          'channels grapevine-channels
          'version grapevine-version))


#|||| State Variables.  🤮 ||||#

(define grapevine-connection #f)
(define grapevine-status 'disconnected)
(define grapevine-players-cb void)
(define grapevine-broadcast-cb void)
(define grapevine-tell-cb void)
(define grapevine-response-cb void)
(define grapevine-error-cb void)
(define grapevine-restart #f)
(define grapevine-thread #f)
(define grapevine-connect-msg #f)
(define grapevine-sema (make-semaphore 1))

(define pending-tells (make-hash))
(define pending-subscribes (make-hash))
(define pending-unsubscribes (make-hash))

(define (make-grapevine-message event #:payload [payload #f] #:ref [ref #f] #:error [error #f] #:status [status #f])
  (define msg/json (make-hasheq (list (cons 'event event))))
  (when payload (hash-set! msg/json 'payload payload))
  (when ref (hash-set! msg/json 'ref ref))
  (when error (hash-set! msg/json 'error error))
  (when status (hash-set! msg/json 'status status))
  (jsexpr->string msg/json))


(define (json-bytes->string maybe-bytes)
  (if (string? maybe-bytes) maybe-bytes
      (bytes->string/utf-8 (list->bytes maybe-bytes))))
 

(define (grapevine-thunk)
  (define msg (ws-recv grapevine-connection))
  (define connected? (not (eof-object? msg)))

  (unless connected?
    (when (and grapevine-restart (symbol=? grapevine-status 'restarting))
      (sleep grapevine-restart)
      (let loop ([success? (grapevine-reconnect)])
        (unless success?
          (set! grapevine-restart (* 2 grapevine-restart))
          (sleep grapevine-restart)
          (loop (grapevine-reconnect))))))

  (when connected?
    (let* ([msg/json (string->jsexpr msg)]
           [event (string->symbol (hash-ref msg/json 'event))]
           [payload (hash-ref msg/json 'payload #hasheq())]
           [ref (hash-ref msg/json 'ref #f)]
           [error (hash-ref msg/json 'error #f)]
           [status (hash-ref msg/json 'status #f)])
      (case event
        [(authenticate)
         (if (string=? status "success")
             (begin
               (unless (string=? grapevine-version (json-bytes->string (hash-ref payload 'version "")))
                 (grapevine-error-cb 'new-version (json-bytes->string (hash-ref payload 'version ""))))
               (grapevine-response-cb 'connected)
               (set! grapevine-restart #f)
               (set! grapevine-status 'connected))
             (begin
               (ws-close! grapevine-connection #:reason "authentication failed")
               (set! grapevine-connection #f)
               (grapevine-error-cb 'authentication-failed (format "status=~a payload=~a" status payload))
               (kill-thread (current-thread))
               ))]
        [(heartbeat)
         (ws-send! grapevine-connection (make-grapevine-message "heartbeat" #:payload (hasheq 'players (grapevine-players-cb))))]
        [(channels/broadcast)
         (grapevine-broadcast-cb
          (hash-ref payload 'channel)
          (hash-ref payload 'game)
          (hash-ref payload 'name)
          (hash-ref payload 'message))]
        [(tells/receive)
         (grapevine-tell-cb
          (hash-ref payload 'from_game)
          (hash-ref payload 'from_name)
          (hash-ref payload 'to_name)
          (hash-ref payload 'sent_at)
          (hash-ref payload 'message)
          ref)]
        [(restart)
         (set! grapevine-status 'restarting)
         (set! grapevine-restart (hash-ref payload 'downtime))]
        [(channels/subscribe)
         (let ([channel (hash-ref pending-subscribes ref (λ () (grapevine-error-cb 'channels/subscribe (format "invalid ref: ~a" ref))))])
           (when (or (not status)
                     (string=? status "success"))
             (set! grapevine-channels (cons channel grapevine-channels)))
           (when (and (string? status)
                      (string=? status "failure"))
             (grapevine-error-cb 'subscribe/failure channel))
           (hash-remove! pending-subscribes ref))]
        [(channels/unsubscribe)
         (let ([channel (hash-ref pending-unsubscribes ref (λ () (grapevine-error-cb 'channels/unsubscribe (format "invalid ref: ~a" ref))))])
           (when (or (not status)
                     (string=? status "success"))
             (set! grapevine-channels (remove channel grapevine-channels)))
           (when (and (string? status)
                      (string=? status "failure"))
             (grapevine-error-cb 'unsubscribe/failure channel))
           (hash-remove! pending-unsubscribes ref))]
        [(channels/send)
         (grapevine-response-cb msg/json)]
        [(players/sign-in players/sign-out)
         (grapevine-response-cb msg/json)]
        [else
         (grapevine-error-cb 'unknown-message (format "event=~v payload=~v ref=~v error=~v status=~v" event payload ref error status))] ; eventually this should never trigger
        
        ;; TODO: uuid based responses: do something with them???
        )))
  (grapevine-thunk))


(define (grapevine-channel? v)
  (and (string? v) (regexp-match-exact? #px"[a-zA-Z_\\-]{3,15}" v)))


(define (grapevine-broadcast! channel name message)
  (unless (member channel grapevine-channels)
    (raise-argument-error 'grapevine-broadcast "subscribed-channel?" channel))
  (when (symbol=? grapevine-status 'connected)
    (ws-send! grapevine-connection (make-grapevine-message "channels/send" #:ref (uuid-generate) #:payload (hasheq 'channel channel 'name name 'message message))))
  (grapevine-broadcast-cb channel name "local" message))
      

                
(define (grapevine-subscribe! channel)
  (unless (grapevine-channel? channel)
    (raise-argument-error 'grapevine-subscribe "grapevine-channel?" channel))
  (when (and (not (member channel grapevine-channels))
             (symbol=? grapevine-status 'connected))
    (let ([ref (uuid-generate)])
      (hash-set! pending-subscribes ref channel)
      (ws-send! grapevine-connection (make-grapevine-message "channels/subscribe" #:ref ref #:payload (hasheq 'channel channel))))))
    
(define (grapevine-unsubscribe! channel)
  (unless (grapevine-channel? channel)
    (raise-argument-error 'grapevine-subscribe "grapevine-channel?" channel))
  (when (and (member channel grapevine-channels)
             (symbol=? grapevine-status 'connected))
    (let ([ref (uuid-generate)])
      (hash-set! pending-unsubscribes ref channel)
      (ws-send! grapevine-connection (make-grapevine-message "channels/unsubscribe" #:ref ref #:payload (hasheq 'channel channel))))))

(define (grapevine-players/sign-in! name)
  (when (symbol=? grapevine-status 'connected)
    (ws-send! grapevine-connection (make-grapevine-message "players/sign-in" #:payload (hasheq 'name name)))))

(define (grapevine-players/sign-out! name)
  (when (symbol=? grapevine-status 'connected)
    (ws-send! grapevine-connection (make-grapevine-message "players/sign-out" #:payload (hasheq 'name name)))))


(define (grapevine-reconnect)
  (when (and (ws-conn? grapevine-connection)
             (not (ws-conn-closed? grapevine-connection)))
    (ws-close! grapevine-connection #:reason "reconnect called"))
  (unless grapevine-connect-msg
    (error 'grapevine-reconnect "reconnect attempted before connect call.  (I thought that was impossible???)"))
  ;  (when grapevine-thread
  ;    (kill-thread grapevine-thread))
  (set! grapevine-connection (ws-connect grapevine-url))
  (if (ws-conn-closed? grapevine-connection)
      #f
      (begin0
        #t
        (ws-send! grapevine-connection grapevine-connect-msg)
        (set! grapevine-status 'authenticating)
        (unless grapevine-thread
          (set! grapevine-thread (thread grapevine-thunk)))
        )))
  
  
; should never happen(?)

; grapevine-connect!: string string string ( -> (listof String)) (String String String String -> Void) (String String String Gregor String) (Symbol String -> Void) -> Bool
(define (grapevine-connect! id secret user-agent players-callback broadcast-callback tell-callback response-callback error-callback)
  (if (not (symbol=? grapevine-status 'disconnected)) #f
      (begin
        (set! grapevine-connect-msg (make-grapevine-message "authenticate" #:payload (connection-payload id secret user-agent)))
        ;; todo: contract checks
        (set! grapevine-players-cb players-callback)
        (set! grapevine-broadcast-cb broadcast-callback)
        (set! grapevine-tell-cb tell-callback)
        (set! grapevine-response-cb response-callback)
        (set! grapevine-error-cb error-callback)
        (grapevine-reconnect))))


(define (grapevine-connected?)
  (and (ws-conn? grapevine-connection)
       (not (ws-conn-closed? grapevine-connection))))

#|
(define (players-stub)
  '("Zared"))

(define (broadcast-stub chan game name msg)
  (printf "[~a] ~a@~a: ~a\n" chan name game msg))

(define (tell-stub from_game from_name to_name time msg)
  (printf "[~a] ~a@~a >> ~a: ~a\n" time from_name from_game to_name msg))

(define (error-stub reason msg)
  (eprintf "~a: ~a\n" reason msg))

|#
