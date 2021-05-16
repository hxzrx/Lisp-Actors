;; prim-actors.lisp - A collection of useful primitive Actors
;;
;; DM/RAL 05/21
;; ------------------------------------------------------
(in-package :actors/base)
;; ------------------------------------------------------
;; There are, broadly, two conventions followed for Actor messages:
;;
;;  1. When an Actor expects a customer argument, it is always in
;;  first position.
;;
;;  2. When an Actor uses DCASE, it expects the dispatch token in
;;  second position when a customer arg is present.
;;
;; --------------------------------------
;; Sink Behaviors

(defun make-sink-beh ()
  #'lw:do-nothing)

(defun sink ()
  (make-actor (make-sink-beh)))

;; --------------------------------------

(setf (symbol-value 'println)
      (make-actor
       (ensure-par-safe-behavior
        (lambda* msg
          (format t "~&~{~A~^ ~}~%" msg))
        )))

;; -------------------------------------
;; Non-Sink Behaviors

(defun make-const-beh (&rest msg)
  (lambda (cust)
    (send* cust msg)))

(defun const (&rest msg)
  (make-actor (apply #'make-const-beh msg)))

;; ---------------------

(defun make-once-beh (cust)
  (lambda (&rest msg)
    (send* cust msg)
    (become (make-sink-beh))))

(defun once (cust)
  (make-actor (make-once-beh cust)))

;; ---------------------

(defun send-to-all (actors &rest msg)
  (dolist (actor actors)
    (send* actor msg)))

;; ---------------------

(defun make-race-beh (&rest actors)
  (lambda (cust &rest msg)
    (let ((gate (once cust)))
      (apply #'send-to-all actors gate msg))))

(defun race (&rest actors)
  (make-actor (apply #'make-race-beh actors)))

;; ---------------------

(defun make-fwd-beh (actor)
  (lambda (&rest msg)
    (send* actor msg)))

(defun fwd (actor)
  (make-actor (make-fwd-beh actor)))

;; ---------------------

(defun make-label-beh (cust lbl)
  (lambda (&rest msg)
    (send* cust lbl msg)))

(defun label (cust lbl)
  (make-actor (make-label-beh cust lbl)))

;; ---------------------

(defun make-tag-beh (cust)
  (lambda (&rest msg)
    (send* cust self msg)))

(defun tag (cust)
  (make-actor (make-tag-beh cust)))

;; -------------------------------------------------

(defun make-future-wait-beh (tag custs)
  (lambda (cust &rest msg)
    (cond ((eq cust tag)
           (become (apply #'make-const-beh msg))
           (apply #'send-to-all custs msg))
          (t
           (become (make-future-wait-beh tag (cons cust custs))))
          )))

(defun future (actor &rest msg)
  ;; Return an Actor that represents the future value. Send that value
  ;; (when it arrives) to cust with (SEND (FUTURE actor ...) CUST)
  (actors ((fut (make-future-wait-beh tag nil))
           (tag (make-tag-beh fut)))
    (send* actor tag msg)
    fut))

;; -----------------------------------------

(defun lazy (actor &rest msg)
  ;; Like FUTURE, but delays evaluation of the Actor with message
  ;; until someone demands it. (SEND (LAZY actor ... ) CUST)
  (α (cust)
    (let ((tag (tag self)))
      (become (make-future-wait-beh tag (list cust)))
      (send* actor tag msg))
    ))

;; --------------------------------------
;; SER - make an Actor that evaluates a series of blocks sequentially
;; - i.e., without concurrency between them.  Each block is fed the
;; same initial message, and the results from each block are sent as
;; an ordered collection to cust.

(setf (symbol-value 'ser)
      (make-actor
       (lambda (cust lst &rest msg)
         (if (null lst)
             (send cust)
           (let ((me self))
             (β msg-hd (send* (car lst) β msg)
               (β msg-tl (send* me β (cdr lst) msg)
                 (send-combined-msg cust msg-hd msg-tl)))
         )))
       ))

(defun send-combined-msg (cust msg1 msg2)
  (multiple-value-call #'send cust (values-list msg1) (values-list msg2)))

;; -----------------------------------
;; PAR - make an Actor that evaluates a series of blocks concurrently.
;; Each block is fed the same initial message, and the results from
;; each block are sent as an ordered collection to cust.

(defun make-join-beh (cust lbl1 lbl2)
  (declare (ignore lbl2))
  (lambda (lbl &rest msg)
    (cond ((eq lbl lbl1)
           (become (lambda (_ &rest msg2)
                     (declare (ignore _)) ;; _ = lbl arg
                     (send-combined-msg cust msg msg2))
                   ))
          (t ;; (eq lbl lbl2)
           (become (lambda (_ &rest msg1)
                     (declare (ignore _)) ;; _ = lbl arg
                     (send-combined-msg cust msg1 msg))
                   ))
          )))

(setf (symbol-value 'par)
      (make-actor
       (lambda (cust lst &rest msg)
         (if (null lst)
             (send cust)
           (actors ((join (make-join-beh cust lbl1 lbl2))
                    (lbl1 (make-tag-beh join))
                    (lbl2 (make-tag-beh join)))
             (send* (car lst) lbl1 msg)
             (send* self lbl2 (cdr lst) msg)))
         )))

;; ---------------------------------------------------------
#|
(send ser println
      (list
       (blk ()
         :blk1)
       (blk ()
         :blk2)
       (blk ()
         :blk3)))
               
(send par println
      (list
       (blk ()
         :blk1)
       (blk ()
         :blk2)))

(let* ((actor (make-actor (lambda (cust) (sleep 2) (send cust :ok))))
       (fut   (future actor)))
  (send fut println)
  (send fut println))
 |#
;; -----------------------------------------
;; Delayed Trigger

(defun make-scheduled-message-beh (cust dt &rest msg)
  (let ((timer (apply #'mp:make-timer #'send cust msg)))
    (lambda* _
      (mp:schedule-timer-relative timer dt)
      (become (make-sink-beh)))))

(defun scheduled-message (cust dt &rest msg)
  (make-actor (apply #'make-scheduled-message-beh cust dt msg)))

;; -----------------------------------------
;; Serializer Gateway
;;
;; This kind of Actor widget is not needed in our 1-Core-per-Actor
;; system. Every Actor already has a message queue that serializes
;; requests for service.
;;
;; It would be useful in a single-threaded implementation which must
;; continue to dispatch messages to remain lively.
;;
;; We default to shared par-safe behavior because SERIALIZERs are
;; frequently used for shared access to a resource. And since we use
;; BECOME, we have to make the SERIALIZER have par-safe behavior.

(defun make-serializer-beh (service)
  ;; initial empty state
  (ensure-par-safe-behavior
   (lambda (cust &rest msg)
     (let ((tag  (tag self)))
       (send* service tag msg)
       (become (make-enqueued-serializer-beh
                service tag cust nil))
       ))))

(defun make-enqueued-serializer-beh (service tag in-cust queue)
  (ensure-par-safe-behavior
   (lambda (cust &rest msg)
     (cond ((eq cust tag)
            (send* in-cust msg)
            (if queue
                (multiple-value-bind (next-req new-queue)
                    (finger-tree:popq queue)
                  (destructuring-bind (next-cust . next-msg) next-req
                    (send* service tag next-msg)
                    (become (make-enqueued-serializer-beh
                             service tag next-cust new-queue))
                    ))
              ;; else
              (become (make-serializer-beh service))))
           (t
            (become (make-enqueued-serializer-beh
                     service tag in-cust (finger-tree:addq queue (cons cust msg)))))
           ))))
  
(defun serializer (service)
  (make-actor (make-serializer-beh service)))

;; --------------------------------------
#|
(defun make-rw-serializer-beh (service)
  ;; initial empty state
  (ensure-par-safe-behavior
   ;; because we use BECOME
   (lambda (cust &rest msg)
     (um:dcase msg
       (:read (&rest msg)
        (let ((tag (tag self)))
          (send* service tag msg)
          (become (make-busy-rd-serializer-beh
                   service
                   (acons tag cust nil)
                   nil))
          ))
       (:write (&rest msg)
        (let ((tag (tag self)))
          (send* service tag msg)
          (become (make-busy-wr-serializer-beh
                   service tag cust nil nil))
          ))
       ))))

(defun rw-serializer (service)
  (make-actor (make-rw-serializer-beh service)))

(defun make-busy-rd-serializer-beh (service tags pend-wr)
  (ensure-par-safe-behavior
   ;; because we use BECOME
   (lambda (cust &rest msg)
     (um:dcase msg
       (:read (&rest msg)
        (let ((tag (tag self)))
          (send* service tag msg)
          (become (make-busy-rd-serializer-beh
                   service
                   (acons tag cust tags)
                   pend-wr))))
       (:write (&rest msg)
        (become (make-busy-rd-serializer-beh
                 service
                 tags
                 (finger-tree:addq pend-wr (cons cust msg))
                 )))
       (t _
          (let ((pair (assoc cust tags)))
            (when pair
              (send* (cdr pair) msg)
              (let ((new-tags (remove pair tags)))
                (cond (new-tags
                       (become (make-busy-rd-serializer-beh service new-tags pend-wr)))
                      
                      (pend-wr
                       (let ((tag (tag self)))
                         (multiple-value-bind (pair new-queue)
                             (finger-tree:popq pend-wr)
                           (send* service tag (cdr pair))
                           (become (make-busy-wr-serializer-beh service tag (car pair) new-queue nil))
                           )))
                     (t
                      (become (make-rw-serializer-beh service)))
                     )))))
       ))))

(defun make-busy-wr-serializer-beh (service tag in-cust pend-wr pend-rd)
  (ensure-par-safe-behavior
   ;; because we use BECOME
   (lambda (cust &rest msg)
     (um:dcase msg
       (:read (&rest msg)
        (become (make-busy-wr-serializer-beh
                 service tag cust pend-wr
                 (cons (cons cust msg) pend-rd))))
       (:write (&rest msg)
        (become (make-busy-wr-serializer-beh
                 service tag cust
                 (finger-tree:addq pend-wr (cons cust msg))
                 pend-rd)))
       (t _
          (when (eq cust tag)
            (send* in-cust msg)
            (cond (pend-wr
                   (multiple-value-bind (ent new-queue)
                       (finger-tree:popq pend-wr)
                     (let ((tag (tag self)))
                       (send* service tag (cdr ent))
                       (become (make-busy-wr-serializer-beh service tag (car ent) new-queue pend-rd))
                       )))
                  (pend-rd
                   (let ((tags nil))
                     (dolist (ent pend-rd)
                       (let ((tag (tag self)))
                         (um:aconsf tags tag (car ent))
                         (send* service tag (cdr ent))
                         ))
                     (become (make-busy-rd-serializer-beh service tags nil))
                     ))
                  (t
                   (become (make-rw-serializer-beh service)))
                  )))
       ))))
|#
;; --------------------------------------

(defun make-timing-beh (dut)
  (lambda (cust &rest msg)
    (let ((start (usec:get-time-usec)))
      (β _ (send* dut β msg)
        (send cust (- (usec:get-time-usec) start)))
      )))

(defun timing (dut)
  (make-actor (make-timing-beh dut)))

#|
(let* ((dut (α (cust nsec)
             (sleep nsec)
             (send cust)))
      (timer (timing dut)))
  (send timer println 1))
|#
(defun sponsor-switch (spons)
  ;; Switch to other Sponsor for rest of processing
  (α msg
    (sendx* spons msg)))

(defun io (svc)
  (α (cust &rest msg)
    (let ((spons *current-sponsor*))
      (sendx* *slow-sponsor*
              svc
              (α ans
                (sendx* spons cust ans))
              msg)
      )))
      
;; -----------------------------------------------

