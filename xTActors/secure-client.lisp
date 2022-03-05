;; secure-connection.lisp -- communication between client and server
;; via secure channel
;;

(in-package :com.ral.actors.secure-comm)

;; --------------------------------------------------------------------
;; Client side

(defun negotiate-secure-channel-beh (client-skey)
  ;; Diffie-Hellman key exchange
  (λ (cust socket local-services)
    (let* ((arand       (int (ctr-drbg 256)))
           (apt         (ed-nth-pt arand))
           (client-pkey (ed-nth-pt client-skey))
           (srv-pkey    (server-pkey))
           ;; (socket      (show-client-outbound socket)) ;; ***
           (responder
            (α (server-id bpt)
              (let* ((ekey  (hash/256 (ed-mul (ed-decompress-pt bpt) arand)))
                     (chan  (client-channel
                             :local-services  local-services
                             :encryptor       (sink-pipe
                                               (secure-sender ekey)
                                               (remote-actor-proxy server-id socket))
                             :decryptor       (secure-reader ekey)
                             )))
                (send connections cust :set-channel socket chan)
                ))))
      (β (client-id)
          (create-ephemeral-client-proxy β local-services responder)
        (send (remote-actor-proxy +server-connect-id+ socket)
              client-id srv-pkey (int client-pkey) (int apt))
        ))
    ))

(defun client-connect-beh (handshake)
  (λ (cust host-ip-addr)
    (send client-connector cust handshake host-ip-addr)))

(defactor client-gateway
  ;; This is the main local client service used to initiate
  ;; connections with foreign servers. We develop a DHE shared secret
  ;; encryption key for use across a private connection portal with
  ;; the server.
  ;;
  ;; A Connection consists of a Socket and a Channel. A Socket merely
  ;; supports the tranport of data across a network. It does not
  ;; specify any data protocol. It may marshal objects and compress
  ;; the resulting byte stream before sending. A Channel is an
  ;; encryptor/decryptor married to a Socket.
  (λ _
    (let* ((skey      (make-deterministic-keys (uuid:make-v1-uuid)))
           (handshake (create (negotiate-secure-channel-beh skey))))
      (become (client-connect-beh handshake))
      (repeat-send self))
    ))

;; ---------------------------------------------------

(defun client-channel (&key
                       local-services
                       encryptor
                       decryptor)
  ;; One of these serves as a client-local private portal with an
  ;; established connection to a server. It encrypts and signs a
  ;; request message for a server service. It also instantiates a
  ;; private decryptor for any returning replies being sent back to
  ;; the customer on this client.
  ;;
  ;; Every request to the server sent from here carries an
  ;; incrementing sequence number to ensure a change of encryption
  ;; keying for every new message.
  (α (cust verb &rest msg)
    ;; (send println (format nil "trying to send: ~S" self-msg))
    (if (is-pure-sink? cust)
        (send* encryptor nil verb msg)
      (β (cust-id)
          (create-ephemeral-client-proxy β local-services (sink-pipe decryptor cust))
        (send* encryptor cust-id verb msg))
      )))

;; ------------------------------------------------------------------
;; User side of Client Interface

(defun remote-service (name host-ip-addr)
  ;; An Actor and send target. Connection to remote service
  ;; established on demand.
  (α (cust &rest msg)
    (β (chan)
        (send client-gateway β host-ip-addr)
      (send* chan cust name msg))))

;; ------------------------------------------------------------
#|
(defun tst (host)
  (let ((recho (remote-service :echo host)))
    (β (ans)
        (send recho β :hello)
      (send println (format nil "(send recho println ~S) sez: ~S" :hello ans)))))
(tst "localhost")
(tst "arroyo.local")
(tst "rincon.local")
(tst "rambo.local")
(install-atrace)
(atrace)
(atrace nil)

(defun tst (host)
  (let ((recho (remote-service :echo host))
        (txt   (hcl:file-string "./xTActors/encoding.lisp")))
    (β (ans)
        (send recho β txt)
      (send println (string= txt ans)))))

(defun tst (host)
  (let ((reval (remote-service :eval host)))
    (β (ans)
        (send reval β '(list (get-universal-time) (machine-instance)))
      #|
        (send reval β '(um:capture-ans-or-exn
                            (error "test-error")))
        |#
      (send println (format nil "reval sez: ~S" (um:recover-ans-or-exn ans))))
    ))
(tst "localhost")
(tst "arroyo.local")
(tst "rincon.local")
(tst "rambo.local")
(tst "dachshund.local")
(tst "honeypot.local")
(tst "david-pc.local")
(tst "umbra.local")
(tst "zircon.local")
|#
