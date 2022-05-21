
(in-package :com.ral.actors.base)

(defun stsend (actor &rest msg)
  #F
  ;; Single-threaded SEND - runs entirely in the thread of the caller.
  ;;
  ;; We still need to abide by the single-thread-only exclusive
  ;; execution of Actors. There might be several other instances of
  ;; this running, or else some of the multithreaded versions.
  ;;
  ;; SENDs are optimistically committed in the event queue. In case of
  ;; error these are rolled back.
  (let (qhd qtl qsav evt pend-beh)
    (macrolet ((qreset ()
                 `(if (setf qtl qsav)              ;; unroll committed SENDs
                      (setf (msg-link (the msg qtl)) nil)
                    (setf qhd nil))))
      (flet ((%send (actor &rest msg)
               (cond (evt
                      ;; reuse last message frame if possible
                      (setf (msg-actor (the msg evt)) (the actor actor)
                            (msg-args  (the msg evt)) msg
                            (msg-link  (the msg evt)) nil))
                     (t
                      (setf evt (msg (the actor actor) msg))) )
               (setf qtl
                     (if qhd
                         (setf (msg-link (the msg qtl)) evt)
                       (setf qhd evt))
                     evt nil))
             
             (%become (new-beh)
               (setf pend-beh new-beh)))
        
        (declare (dynamic-extent #'%send #'%become))
        
        (let ((*current-actor*    nil)
              (*whole-message*    nil)
              (*current-behavior* nil)
              (*send*             #'%send)
              (*become*           #'%become))
          (declare (list *whole-message*))
          
          (send* actor msg)
          (loop
             while qhd
             do
               (with-simple-restart (abort "Handle next event")
                 (handler-bind
                     ((error (lambda (c)
                               (declare (ignore c))
                               (qreset))
                             ))
                   (loop
                      ;; keep going until there are no more messages
                      while (when (setf evt qhd)
                              (setf qhd (msg-link (the msg evt)))
                              evt)
                      do
                        (setf self     (msg-actor (the msg evt))
                              self-msg (msg-args (the msg evt))
                              qsav     (and qhd qtl))
                        (tagbody
                         again
                         (setf pend-beh (actor-beh (the actor self))
                               self-beh pend-beh)
                         (apply (the function pend-beh) self-msg)
                         (cond ((or (eq pend-beh self-beh)
                                    (sys:compare-and-swap (actor-beh (the actor self)) self-beh pend-beh)))
                               
                               (t
                                ;; Actor was in use, try again
                                (setf evt (or evt qtl))
                                (qreset)
                                (go again))
                               )))
                   )))
          )))))

(defmacro with-single-thread (&body body)
  `(let ((*send* 'stsend))
     ,@body))

(defun call-actor (ac &rest args)
  ;; Invoking an Actor from procedural code.  Assumes Actor, ac, takes
  ;; a customer argument, which we supply internally.
  ;;
  ;; Actor may spawn logical threads that will run in our process. The
  ;; dispatch loop returns after all spawned Actor activity has
  ;; ceased.
  ;;
  ;; Careful! This can only be assured safe in single-threaded
  ;; environments.  Otherwise, use ASK.
  ;;
  (let* ((ans   nil)
         (cust  (create
                 (lambda (&rest ans-args)
                   (setf ans ans-args)))))
    (with-single-thread
      (send* ac cust args))
    (values-list ans)))

(defun wrap-fn (fn)
  ;; The converse - wrap any function as an Actor expecting a customer
  ;; and args.
  (create
   (lambda (cust &rest args)
     (send* cust (multiple-value-list (apply fn args)))
     )))
