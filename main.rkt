#lang racket/base

(require json net/rfc6455 net/url racket/match racket/bool gregor libuuid racket/set (for-syntax racket/base)) 


(provide grapevine?
         grapevine-status
         grapevine-channels
         grapevine-version grapevine-supports grapevine-channels grapevine-channel? grapevine-subscribed-channel?
         grapevine-broadcast! grapevine-tell!
         grapevine-connect! grapevine-connected? grapevine-status grapevine-subscribe! grapevine-unsubscribe!
         grapevine-players/sign-in! grapevine-players/sign-out!)


#||||       Constants      ||||#

(define grapevine-version "2.3.0")
(define grapevine-url/default (string->url "wss://grapevine.haus/socket"))
(define grapevine-supports '("channels" "players" "tells"))

(define (make-grapevine-connect-msg gv)
  (make-grapevine-message "authenticate"
                          #:payload
                          (hasheq 'client_id (grapevine-id gv)
                                  'client_secret (grapevine-secret gv)
                                  'user_agent (grapevine-user-agent gv)
                                  'supports grapevine-supports
                                  'channels (set->list (grapevine-channels gv))
                                  'version grapevine-version)))

(struct grapevine
  ([connection #:mutable]
   url
   [status #:mutable]
   get-players on-broadcast on-tell on-error on-event-response
   [restart #:mutable]
   [thread #:mutable]
   sema
   channels
   games
   pending-tells pending-subscribes pending-unsubscribes id secret user-agent))

(define (lock! gv)
  (semaphore-wait (grapevine-sema gv)))

(define (unlock! gv)
  (semaphore-post (grapevine-sema gv)))

(define-syntax (critical! stx)
  (syntax-case stx ()
    [(_ gv body ...)
     (syntax/loc stx
       (call-with-semaphore (grapevine-sema gv)
                            (lambda () body ...)))]))

(define (get-players gv)
  ((grapevine-get-players gv)))

(define (on-broadcast gv chan game name msg)
  ((grapevine-on-broadcast gv) chan game name msg))

(define (on-tell gv from_game from_name to sent msg)
  ((grapevine-on-tell gv) from_game from_name to sent msg))

(define (on-error gv level module msg)
  ((grapevine-on-error gv) level module msg))

(define (on-event-response gv response)
  ((grapevine-on-event-response gv) response))

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
 

(define (make-grapevine-thunk gv)
  (letrec ([grapevine-thunk
            (lambda ()
              (define msg (ws-recv (grapevine-connection gv)))
              (define connected? (not (eof-object? msg)))

              (unless connected?
                (when (and (grapevine-restart gv)
                           (symbol=? (grapevine-status gv) 'restarting))
                  (sleep (grapevine-restart gv))
                  (let loop ([success? (grapevine-reconnect gv)])
                    (unless success?
                      (set-grapevine-restart! gv (* 2 (grapevine-restart gv)))
                      (sleep (grapevine-restart gv))
                      (loop (grapevine-reconnect gv))))))

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
                             (on-error gv 'info 'new-version (json-bytes->string (hash-ref payload 'version ""))))
                           (critical! gv
                                      (set-grapevine-restart! gv #f)
                                      (set-grapevine-status! gv 'connected))
                           (on-event-response gv 'connected)
                           )
                         (begin
                           (ws-close! (grapevine-connection gv) #:reason "authentication failed")
                           (critical! gv
                                      (set-grapevine-connection! gv #f)
                                      (set-grapevine-status! gv 'disconnected))
                           (on-error gv 'error 'authentication-failed (format "status=~a payload=~a" status payload))
                           (critical! gv (set-grapevine-thread! gv #f))
                           (kill-thread (current-thread))))]
               
                    [(heartbeat)
                     (ws-send! (grapevine-connection gv)
                               (make-grapevine-message "heartbeat" #:payload (hasheq 'players (get-players gv))))]
                    [(channels/broadcast)
                     (on-broadcast
                      gv
                      (hash-ref payload 'channel)
                      (hash-ref payload 'game)
                      (hash-ref payload 'name)
                      (hash-ref payload 'message))]
                    [(tells/receive)
                     (on-tell
                      gv
                      (hash-ref payload 'from_game)
                      (hash-ref payload 'from_name)
                      (hash-ref payload 'to_name)
                      (hash-ref payload 'sent_at)
                      (hash-ref payload 'message)
                      ref)]
                    [(restart)
                     (critical! gv
                                (set-grapevine-status! gv 'restarting))
                     (set-grapevine-restart! gv (hash-ref payload 'downtime))]
                    [(channels/subscribe)
                     (let ([channel (hash-ref (grapevine-pending-subscribes gv) ref
                                              (λ () (on-error gv 'warning 'channels/subscribe (format "invalid ref: ~a" ref))))])
                       (when (or (not status)
                                 (string=? status "success"))
                         (on-event-response gv `(channels/subscribe ,channel success))
                         (critical! gv
                                    (set-add! (grapevine-channels gv) channel)))
                       (when (and (string? status)
                                  (string=? status "failure"))
                         (on-event-response gv `(channels/subscribe ,channel failure))

                         (on-error gv 'error 'channels/subscribe channel))
                       (critical! gv (hash-remove! (grapevine-pending-subscribes gv) ref)))]
                    [(channels/unsubscribe)
                     (let ([channel (hash-ref (grapevine-pending-unsubscribes gv) ref
                                              (λ () (on-error gv 'warning 'channels/unsubscribe (format "invalid ref: ~a" ref))))])
                       (when (or (not status)
                                 (string=? status "success"))
                         (critical! gv  (set-remove! (grapevine-channels gv channel))))
                       (when (and (string? status)
                                  (string=? status "failure"))
                         (on-error gv 'error 'channels/unsubscribe channel))
                       (critical! gv (hash-remove! (grapevine-pending-unsubscribes gv) ref)))]
                    [(channels/send)
                     (on-event-response gv msg/json)]
                    [(players/sign-in players/sign-out)
                     (on-event-response gv msg/json)]
                    [else
                     (on-error gv 'warning 'unknown-message (format "event=~v payload=~v ref=~v error=~v status=~v" event payload ref error status))] ; eventually this should never trigger
        ;; TODO: uuid based responses: do something with them???
                    )))
              (grapevine-thunk))])
    grapevine-thunk))


(define (grapevine-channel? v)
  (and (string? v) (regexp-match-exact? #px"[a-zA-Z_\\-]{3,15}" v)))

(define (grapevine-subscribed-channel? gv v)
  (critical! gv (set-member? (grapevine-channels gv) v)))

(define (grapevine-broadcast! gv channel name message)
  (critical! gv
             (unless (set-member? (grapevine-channels gv) channel)
               (raise-argument-error 'grapevine-broadcast "grapevine-subscribed-channel?" channel))
             (and (symbol=? (grapevine-status gv) 'connected)
                  (ws-send! (grapevine-connection gv)
                            (make-grapevine-message "channels/send" #:ref (uuid-generate) #:payload (hasheq 'channel channel 'name name 'message message)))
                  #t)))

(define (grapevine-tell! gv sender to-game to-name message)
  (critical! gv
             (and (grapevine-connected? gv)
                  (let ([ref (uuid-generate)])
                    (hash-set! (grapevine-pending-tells gv) ref (list (now/moment/utc) sender to-game to-name message))
                    (ws-send! (grapevine-connection gv)
                              (make-grapevine-message "tells/send" #:ref ref #:payload (hasheq 'from_name sender
                                                                                               'to_game to-game
                                                                                               'to_name to-name
                                                                                               'message message
                                                                                               'sent_at (moment->iso8601 (now/moment/utc))))))
                  #t)))
  

(define (grapevine-subscribe! gv channel)
  (critical! gv
             (unless (grapevine-channel? channel)
               (raise-argument-error 'grapevine-subscribe "grapevine-channel?" channel))
             (when (and (not (set-member? (grapevine-channels gv) channel))
                        (symbol=? (grapevine-status gv) 'connected))
               (let ([ref (uuid-generate)])
                 (hash-set! (grapevine-pending-subscribes gv) ref channel)
                 (ws-send! (grapevine-connection gv)
                           (make-grapevine-message "channels/subscribe" #:ref ref #:payload (hasheq 'channel channel)))))))
    
(define (grapevine-unsubscribe! gv channel)
  (critical! gv
             (unless (grapevine-channel? channel)
               (raise-argument-error 'grapevine-subscribe "grapevine-channel?" channel))
             (when (and (set-member? (grapevine-channels gv) channel)
                        (symbol=? (grapevine-status gv) 'connected))
               (let ([ref (uuid-generate)])
                 (hash-set! (grapevine-pending-unsubscribes gv) ref channel)
                 (ws-send! (grapevine-connection gv)
                           (make-grapevine-message "channels/unsubscribe" #:ref ref #:payload (hasheq 'channel channel)))))))

(define (grapevine-players/sign-in! gv name)
  (critical! gv
             (when (symbol=? (grapevine-status gv) 'connected)
               (ws-send! (grapevine-connection gv)
                         (make-grapevine-message "players/sign-in" #:payload (hasheq 'name name))))))

(define (grapevine-players/sign-out! gv name)
  (critical! gv
             (when (symbol=? (grapevine-status gv) 'connected)
               (ws-send! (grapevine-connection gv)
                         (make-grapevine-message "players/sign-out" #:payload (hasheq 'name name))))))
  
(define (grapevine-reconnect gv)
  (when (and (ws-conn? (grapevine-connection gv))
             (not (ws-conn-closed? (grapevine-connection gv))))
    (ws-close! (grapevine-connection gv) #:reason "reconnect called"))
  (set-grapevine-connection! gv (ws-connect (grapevine-url gv)))
  (if (ws-conn-closed? (grapevine-connection gv))
      #f
      (begin0
        #t
        (ws-send! (grapevine-connection gv)
                  (make-grapevine-connect-msg gv))
        (set-grapevine-status! gv 'authenticating)
        (unless (grapevine-thread gv)
          (set-grapevine-thread! gv (thread (make-grapevine-thunk gv)))))))

#|
  ([connnection #:mutable]
   url
   [status #:mutable]
   get-players on-broadcast on-tell on-error on-event-response
   [restart #:mutable]
   [thread #:mutable]
   sema
   channels
   pending-tells pending-subscribes pending-unsubscribes id secret))
|#

; grapevine-connect!: string string string ( -> (listof String)) (String String String String -> Void) (String String String Gregor String) (Symbol String -> Void) -> Bool
(define (grapevine-connect! id secret user-agent players-callback broadcast-callback tell-callback response-callback error-callback #:url [url grapevine-url/default] #:channels [chan '()])
  (define gv
    (grapevine
     #f
     url
     'disconnected
     players-callback broadcast-callback tell-callback error-callback response-callback
     #f
     #f
     (make-semaphore 1)
     (apply mutable-set chan)
     (make-hash)
     (make-hash)
     (make-hash)
     (make-hash)
     id
     secret
     user-agent))
  (grapevine-reconnect gv)
  gv)

(define (grapevine-connected? gv)
  (critical! gv
             (and
              (symbol=? 'connected (grapevine-status gv))
              (ws-conn? (grapevine-connection gv))
              (not (ws-conn-closed? (grapevine-connection gv))))))

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
