;; secure-connection.lisp -- communication between client and server
;; via secure channel
;;
;; Uses ECDH secret key exchange for encryption. All ECC points are
;; relayed as integers representing compressed points. All messages
;; and replies are encrypted and authenticatd with Schnorr signatures.
;; Encryption keying is roving for each message/reply interchange.
;;
;; After initial connection is established between client and server,
;; each of them knows the other's public key and mutal encryption key.
;; No need to send along public key info for signatures. It is assumed
;; that the public key that requested the connection is the one
;; performing signature generation.
;;
;; It is presumed that the server has a well known public key, and its
;; gateway Actor is known to the outside world. That is the only
;; information the outside world needs to know. Clients can perfom
;; only a limited list of services, as provided by a menu of
;; offerings. The verbs for the services can be obtained by sending
;; verb :available-services.
;;
;; The client and server connection portals are also controlled by an
;; admin-tag to provide for immediate shutdown, and for
;; augmenting/trimming the list of available services at the server.
;;
;; This code is the working guts for a secure comm system. No
;; provision here for comm channels, e.g., sockets. It is assumed that
;; there are proxy Actors resident in the machine to which the Actors
;; send messages. Outboard communications is a separate layer. With
;; the exception of symbolic verbs representing server services, all
;; sends are between Actors.
;;
;; DM/RAL 11/21
;; --------------------------------------------------------------------------

(in-package :com.ral.actors.secure-comm)

;; ------------------------------------------------------

(defun actors-skey ()
  (read-from-string (lw:environment-variable "ActorsNode")))

(defun actors-pkey ()
  (ed-compress-pt (ed-nth-pt (actors-skey))))

(defconstant +server-connect-id+  #/uuid/{66895052-c57f-123a-9571-0a2cb67da316})

;; ----------------------------------------------------------------
;; Group Membership Verification
;;
;; A collection of public keys that are permitted to use our services.
;; Anyone of the group can serve as a Server and as a Client.

(defvar *allowed-members*
  (let ((s (sets:empty)))
    (dolist (pkey '(#xBA9666CEAE92CAC6D2B9400B6FC329BB9F701BFAC50D94E0989E664426F3369
                    #x3BA58949841180E96B1E4EF619CECD73B112F7C563FD8620142C1487484D5D6
                    #x645C7DC72A2C5BD07785C978FE69DFCFECBA00F2DFBF005929A1F2A95BB5D42))
      (sets:addf s pkey))
    s))

#|
(let ((lst nil))
  (dolist (skey '())
    (push (int (ed-compress-pt (ed-nth-pt skey))) lst))
  (with-standard-io-syntax
    (let ((*print-base* 16.))
      (print lst))))
|#

;; ----------------------------------------------------------------
;; Self-organizing list of services for Server and connection Actors

(defun service-list-beh (lst)
  (alambda
   ((cust :available-services)
    (send cust (mapcar #'car lst)))

   ((cust :add-service name handler)
    ;; replace or add
    (become (service-list-beh (acons name handler
                                     (remove (assoc name lst) lst))))
    (send cust :ok))

   ((cust :get-service name)
    (send cust (cdr (assoc name lst))))

   ((cust :remove-service name)
    (become (service-list-beh (remove (assoc name lst) lst)))
    (send cust :ok))

   ((rem-cust :send verb . msg)
    (let ((pair (assoc verb lst)))
      (when pair
        (send* (cdr pair) rem-cust msg))
      ))
   ))

;; -----------------------------------------------
;; Simple Services

(defun make-echo ()
  (α (cust msg)
    (send cust msg)))

(defun cmpfn (&rest args)
  (compile nil `(lambda ()
                  ,@args)))

(defun make-eval ()
  (α (cust form)
    (send cust (funcall (cmpfn form)))))

;; -----------------------------------------------

(defactor global-services
    (service-list-beh
     `((:echo . ,(make-echo))
       (:eval . ,(make-eval)))
     ))

;; ------------------------------------------------------------
;; When the socket connection (server or client side) receives an
;; incoming message, the cust field of the message will contain a
;; symbolic reference to a customer on the other side of the socket
;; connection.
;;
;; We need to manufacture a local proxy for that customer and pass it
;; along as the cust field of the message being sent to a local
;; service. That service will use the proxy for any replies.
;;
;; We want to avoid inventing subtypes of Actors for this. Instead, we
;; manufacture stand-in Actors.

(defun remote-actor-proxy (actor-id socket)
  ;; Used to setup a target proxy for sending information across the
  ;; socket to them.
  (when actor-id
    (α (&rest msg)
      ;; (send println (format nil "s/reply: ~S" msg))
      (send* socket actor-id :send msg))))

;; Similarly, on the sending side, we can't just send along a cust
;; field of a message because it is an Actor, and contains a
;; non-marshalable functional closure.
;;
;; We need to manufacture a symbolic name for sending across, and give
;; us a way to translate back to an Actor for any messages sent back
;; to us on its behalf.
;;
;; Unlike the previous case, this situation more resembles a service
;; since it may become the direct target of a send. But unlike server
;; services, each of these local services survives only for one
;; message send. And in case that never happens, they are given a
;; time-to-live, after which they become purged from the list of local
;; ephemeral services.

(defvar *dbg* nil)

(defmacro dbg (&body body)
  `(when *dbg*
     ,@body))

(defvar *default-ephemeral-ttl*  10)

(defstruct (local-service
            (:constructor local-service (handler)))
  handler)

(defstruct (ephem-service
            (:include local-service)
            (:constructor ephem-service (handler)))
  )

(defun local-services-beh (svcs)
  (alambda
   ((cust :add-service-with-id id actor)
    ;; insert ahead of any with same id
    (become (local-services-beh (acons id (local-service actor) svcs) ))
    (send cust id))

   ((cust :add-service actor)
    ;; used for connection handlers
    (let ((id  (uuid:make-v1-uuid)))
      (become (local-services-beh (acons id (local-service actor) svcs) ))
      (send cust id)
      ))
   
   ((cust :add-ephemeral-client actor ttl)
    ;; used for transient customer proxies
    (let ((id   (uuid:make-v1-uuid)))
      (become (local-services-beh (acons id (ephem-service actor) svcs) ))
      (send cust id)
      (when ttl
        (send-after ttl self sink :remove-service id))
      ))
    
   ((cust :remove-service id)
    (become (local-services-beh (remove (assoc id svcs :test #'uuid:uuid=) svcs :count 1)))
    (send cust :ok))

   ((client-id :send . msg)
    (let ((pair (assoc client-id svcs :test #'uuid:uuid=)))
      (when pair
        ;; Server replies are directed here via the client proxy id, to
        ;; find the actual client channel. Once a reply is received, this
        ;; proxy is destroyed. It is also removed after a timeout and no
        ;; reply forthcoming.
        (send* (local-service-handler (cdr pair)) msg)
        (when (ephem-service-p (cdr pair))
          (become (local-services-beh (remove pair svcs))))
        )))
   ))

(defun make-local-services ()
  (create (local-services-beh nil)))


(defun create-ephemeral-client-proxy (cust local-services svc &key (ttl *default-ephemeral-ttl*))
  ;; used by client side
  (send local-services cust :add-ephemeral-client svc ttl))

(defun create-service-proxy (cust local-services svc)
  ;; used by server side
  (send local-services cust :add-service svc))

;; ---------------------------------------------------
;; Composite Actor pipes

(defun secure-sender (ekey)
  (pipe (marshal-encoder)
        (marshal-compressor)
        (chunker :max-size 65000)
        (marshal-encoder)
        (encryptor ekey)
        (authentication ekey)
        ))

(defun secure-reader (ekey)
  (pipe (check-authentication ekey)
        (decryptor ekey)
        (fail-silent-marshal-decoder)
        (dechunker)
        (fail-silent-marshal-decompressor)
        (fail-silent-marshal-decoder)))

