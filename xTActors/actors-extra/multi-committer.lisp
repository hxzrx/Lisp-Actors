;; multi-committer.lisp
;;
;; DM/RAL  2022/11/08 06:34:36
;; ----------------------------------

(defpackage #:com.ral.actors.multi-committer
  (:use #:common-lisp #:ac #:kvdb)
  (:export
   #:multi-comitter
   ))

(in-package #:com.ral.actors.multi-committer)

;; ----------------------------------
;; In situations where more than one database is involved in a
;; coordinated mutation it becomes necessary to invoke a SERIALIZER
;; protocol. We need an ordered acqisition of SERIALERs to avoid
;; livelock.
;;
;; To that end, we ensure that all databases have a persistent,
;; orderable, ID. Then we serialize in sequence by those ID's.

(defvar *ordering-id-key*  #/uuid/{5caa85a4-5f7b-11ed-86c1-787b8acbe32e})

(deflex uuid-gen
  (create (lambda (cust key)
            (declare (ignore key))
            (send cust (uuid:make-v1-uuid)))
          ))

(defun ensure-orderable (cust kvdb)
  ;; We can't simply use kvdb :LOOKUP and :ADD because :ADD is
  ;; unconditional. It will keep retrying, if necessary, until the
  ;; stated addition has been committed.
  ;;
  ;; But if someone else manages to get there first, we don't want to
  ;; overwrite what has been chosen for the ID. We need to check
  ;; again, on retry, to see if there is already an ID.
  (send kvdb cust :find-or-add *ordering-id-key* uuid-gen))


(defun sort-kvdbs (cust &rest kvdbs)
  ;; we expect a list of alternating db-id and kvdb Actor, where the
  ;; Actors are associated with the user specified db-id's (keyword
  ;; symbols?).
  ;;
  ;; Once sorted, the user will need those tags in order to locate the
  ;; kvdb Actor in the sorted access list.
  (let ((sorter (create
                 (lambda (kvdbs &optional acc)
                   (if (endp kvdbs)
                       ;; return a PLIST of sorted kvdbs
                       (send cust (mapcan #'list
                                          (mapcar #'cdr
                                                  (sort acc #'uuid:uuid<
                                                        :key #'car))))
                     (let ((me  self)
                           (db-id  (car kvdbs))
                           (kvdb   (cadr kvdbs)))
                       (β (id)
                           (ensure-orderable β kvdb)
                         (send me (cdr kvdbs) (acons id (cons db-id kvdb) acc))
                         ))
                     ))
                 )))
    (send sorter kvdbs)))

;; The various kvdb's do not use a SERIALIZER gate, in order to permit
;; parallel queries with other ongong updates. But if you :REQ-EXCL,
;; that grants exclusive ownership for the purposes of :COMMIT. Once
;; you get ownership, you *must* either :COMMIT successfully, or else
;; :ABORT, to release ownership and allow others a chance to
;; proceed.
;;
;; Committing and giving-up, must both state the same customer as was
;; used when requesting exclusive commit ownership. Otherwise you will
;; be staged and wind up livelocking the database.
;;
;; During exclusive commit ownership, any other requests for exclusive
;; commit ownership, or attempts by others to commit, become staged
;; for later execution. All other activities are permitted to run in
;; parallel with you.
;;
;; For the purposes of commit and requesting exclusive ownership, the
;; effect is the same as going through a SERIALIZER gate. Ordered
;; access to kvdb's is required in order to prevent livelock.
;; ------------------------------------------------------------------------

(defun multi-commit-beh (ctrl-tag owner action open-dbs action-tag)
  ;; An exercise in Actors as an object capabilities security model:
  ;;
  ;; The only way to talk to an Actor is to know its identity in
  ;; memory. Knowledge of Actors comes from one or more of 3 routes:
  ;;
  ;;   1. An Actor always knows its own identity as SELF,
  ;;
  ;;   2. The creator of an Actor can know the identity of the created
  ;;   Actor,
  ;;
  ;;   3. Knowledge of Actor identities can be passed along to other
  ;;   Actors in messages, or as initialization parameters (closure
  ;;   args) of a newly created Actor.
  ;;
  ;; Having the identity of an Actor means you have permission to send
  ;; it messages, or to pass it along to other Actors.
  ;;
  ;; Nobody else could possibly guess a correct identity (memory
  ;; location) of any particular Actor. Even if you could scan all of
  ;; memory looking for Actor objects, you would not be able to
  ;; distinguish them as being the one you want.
  ;;
  ;; Furthermmore, just having the Actor identity is not enough. You
  ;; must also send it messages that it will respond to. All other
  ;; messages are silently ignored.
  ;;
  ;; If we wanted to extend this security model further, we could make
  ;; all access to our services go through a MEMBRANE, giving us the
  ;; possibility of going completely silent in the face of malicious
  ;; messages. But in this case, there are only two messages that we
  ;; will respond to from the outside world, and once we do, we go
  ;; deaf to all future messages.
  ;;
  ;; Ref: "Robust Composition: Towards a Unified Approach to Access
  ;; Control and Concurrency Control" by Mark Samuael Miller, May 2006
  ;; http://erights.org/talks/thesis/markm-thesis.pdf
  ;;
  ;; ----------------------------------------------------------------
  ;;
  ;; So even though we are hidden behind an orchestrator, we still
  ;; need to protect against malicious messages since we have to hand
  ;; a path leading back to us, to the ACTION Actor.
  ;;
  ;; That pathway, ACTION-TAG, will only permit :ABORT or :COMMIT
  ;; messages.
  ;;
  ;; We, and the orchestrator, are initially the only ones that know
  ;; the OWNER identity. But we do hand it out to the dbmgr on
  ;; :REQ-EXCL, :ABORT, and :COMMIT messages. That dbmgr could become
  ;; compromised. But OWNER is simply there for unique identification
  ;; of an exclusive commit. It offers no response to any messages.
  ;;
  ;; The only way to reach us for processing is to supply another tag,
  ;; CTRL-TAG, which remains known only to us and the orchestrator.
  ;; CTRL-TAG also serves as a channel back to orchestrator for when
  ;; we are finished processing.
  ;;
  ;; And the only way to add items to our sorted list of open kvdbs is
  ;; to supply ourself as a tag. Again, only we and orchestrator know
  ;; that Actor identity.
  ;;
  ;; Only someone who knows the ACTION-TAG can cause us to :ABORT or
  ;; :COMMIT. Initially we start with an Actor ID for ACTION-TAG that
  ;; nobody knows, including us and the orchestrator. Had we started
  ;; with a NIL tag, then someone outside could spoof their way in.
  ;;
  ;; Once we have a complete list of opened kvdbs, we generate the
  ;; real ACTION-TAG for use in communicating with the ACTION Actor.
  ;;
  ;; And once we either :COMMIT or :ABORT, we become deaf to all
  ;; further interaction.
  ;;
  (alambda
   ((atag :process kvdbs-plist) / (eq atag ctrl-tag)
    (let ((fwd  (label (label self self) :open-dbs)))
      (sort-kvdbs fwd kvdbs-plist)))

   ((atag :open-dbs ordered-kvdbs-plist) / (eq atag self)
    (cond ((endp ordered-kvdbs-plist)
           (let ((dbs (mapcan #'identity
                              (mapcar (lambda (pair)
                                        (list (car pair) (cdr pair)))
                                      open-dbs)))
                 (new-action-tag  (tag self)))
             (become (multi-commit-beh ctrl-tag owner action open-dbs new-action-tag))
             (send action new-action-tag dbs) ;; send act a plist of open dbs
             ))
          (t
           (let* ((me     self)
                  (db-id  (car ordered-kvdbs-plist))
                  (kvdb   (cadr ordered-kvdbs-plist))
                  (waiter (create (lambda (db)
                                    (β _
                                        (send me β :add-db me db-id db)
                                      (send me me :open-dbs (cddr ordered-kvdbs-plist))))
                                  )))
             (β (proxy)
                 (send kvdb β :req-proxy)
               (send proxy waiter :req-excl owner))))
          ))

   ((acust :add-db atag db-id db) / (eq atag self)
    (become (multi-commit-beh ctrl-tag owner action
                              (acons db-id db open-dbs)
                              action-tag))
    (send acust :ok))

   ((atag acust :commit upd-dbs-plist) / (eq atag action-tag)
    (labels ((commit-beh (lst)
               (lambda (reply)
                 (declare (ignore reply))
                 (cond ((endp open-dbs)
                        (send ctrl-tag :ok)
                        (send acust :ok)
                        (become-sink))
                       (t
                        (let* ((grp (car lst))
                               (db  (cdr grp)))
                          (send db self :commit)
                          (become (commit-beh (cdr lst)))
                          ))
                       ))))
      (send (create (commit-beh open-dbs)) nil)
      (become-sink)  ;; isolate us from further abuse
      ))

   ((atag acust :abort) / (eq atag action-tag)
    (labels ((release-beh (lst)
               (lambda (reply)
                 (declare (ignore reply))
                 (cond ((endp lst)
                        (send ctrl-tag :ok)
                        (send acust :ok)
                        (become-sink))
                       (t
                        (let* ((grp  (car lst))
                               (db   (cdr grp)))
                          (send db self :abort)
                          (become (release-beh (cdr lst)))
                          ))
                       ))))
      (send (create (release-beh open-dbs)) nil)
      (become-sink) ;; isolate us from further abuse
      ))
   ))

      
(defun multi-commit-orchestrator-beh (open-dbs pend)
  ;; Serves as a SERIALIZER gate for requests that overlap kvdb usage
  ;; with extant multi-committers. Otherwise, for mutually exclusive
  ;; use groups, they are launched into a fresh muti-committer in
  ;; parallel.
  (lambda (&rest msg)
    (match msg
      ((cust :process actionActor kvdbs-plist)
       (let ((req-kvdbs (mapcar #'cadr (um:group kvdbs-plist 2))))
         (cond ((some (lambda (grp)
                        (intersection req-kvdbs (third grp)))
                      open-dbs)
                ;; we have overlapping use, so enqueue this req for later
                (become (multi-commit-orchestrator-beh open-dbs (addq pend msg))))
               (t
                ;; no overlap - so launch him
                (let* ((tag-to-me (tag self))
                       (owner     (create)) ;; just a unique identity Actor
                       (handler   (create (multi-commit-beh tag-to-me owner
                                                            actionActor nil
                                                            (create) )))) ;; an Actor that nobody knows
                  (become (multi-commit-orchestrator-beh
                           (cons (list tag-to-me cust req-kvdbs)
                                 open-dbs)
                           pend))
                  (send handler tag-to-me :process kvdbs-plist)
                  ))
               )))

      ((atag . msg)
       (let* ((grp  (find atag open-dbs :key #'car))
              (cust (cadr grp)))
         (when cust
           (send* cust msg)
           (become (multi-commit-orchestrator-beh (remove grp open-dbs) +emptyq+))
           (do-queue (msg pend)
             (send* self msg))
           )))
      )))
      
(deflex multi-committer
  (create (multi-commit-orchestrator-beh nil +emptyq+)))

;; ---------------------------------------------------------------    
;; Protocol for use:
;;
;; Send a message to MULTI-COMMITTER:
;;
;;      (SEND MULTI-COMMITTER cust :PROCESS action-Actor pliist-of-kvdbs)
;;
;; MULTI-COMMITTER then opens all the kvdbs in consistent order, using
;; :REQ-EXCL, then sends a message to your action-Actor:
;;
;;      (SEND action-Actor handler plist-of-open-dbs)
;;
;; Action-Actor should do whatever processing it needs to do against
;; the open kvdb's and then send a response back to handler containing
;; either an :ABORT, or a :COMMIT with a plist of updated dbs. Any dbs
;; that have not been changed can be omitted from the plist in the
;; response.
;;
;;    (SEND handler acust :ABORT)
;;
;;     - or -
;;
;;    (SEND handler acust :COMMIT plist-of-updated-dbs)
;;
;; At the end, whether by :ABORT or :COMMIT, a message is sent to your
;; original cust argument from the :PROCESS message, as well as to the
;; acust specified in the :ABORT or :COMMIT message to the handler.
