;; transactional-db.lisp -- transactional database processing in Actors
;;
;; DM/RAL 12/21
;; ----------------------------------------------------------------------
;; Using an FPL-pure RB-tree as the database. Hence the database
;; serves as its own transaction ID. Lock-free design.

(in-package com.ral.actors.kv-database)
  
(defun trans-gate-beh (tag-commit tag-rollback saver db)
  (flet ((try (cust target args)
           (send* target db tag-commit tag-rollback cust target args)))
    (alambda
     ((cust :req target . args)
      ;; general entry for external clients
      (try cust target args))
     
     ((a-tag db-old db-new cust retry-target . args) when (eql a-tag tag-commit)
      ;; client called the commit portal
      (with-sponsor base-sponsor
        (cond ((eql db-old db) ;; commit consistency?
               (unless (eql db-old db-new) ;; anything changed?
                 (let ((versioned-db (maps:add db-new 'version (uuid:make-v1-uuid))))
                   ;; version key = 'com.ral.actors.kv-database::version
                   (become (trans-gate-beh tag-commit tag-rollback saver versioned-db))
                   (send-after 10 self saver versioned-db)))
               (send cust :ok))
              
              (t
               (try cust retry-target args))
              )))
     
     ((a-tag cust retry-target . args) when (eql a-tag tag-rollback)
      ;; client called the rollback portal
      (try cust retry-target args))
     
     ((a-tag a-db) when (and (eql a-tag saver)
                             (eql a-db  db))
      ;; We are the only one that knows the identity of saver, so this
      ;; can't be forged by malicious clients. Also, a-db will only
      ;; eql db if there have been no updates within the last 10 sec.
      (send saver db))
     )))

(defun nascent-database-beh (custs saver)
  (alambda
   ((a-tag db) when (eql a-tag saver)
    ;; We are the only one that knows the identity of saver. So this
    ;; message could not have come from anywhere except saver itself.
    (with-sponsor base-sponsor
      (let ((tag-commit (tag self))
            (tag-retry  (tag self)))
        (become (trans-gate-beh tag-commit tag-retry saver db))
        ;; now open for business, resubmit pending client requests
        (dolist (cust custs)
          (send* self cust))
        )))
   
   (msg
    (with-sponsor base-sponsor
      ;; accumulate client requests until we open for business
      (become (nascent-database-beh (cons msg custs) saver))))
   ))

;; -----------------------------------------------------------

(defconstant +db-id+  #/uuid/{6f896744-6472-11ec-8ecb-24f67702cdaa})

(defun save-database-beh (path last-db)
  (alambda
   ((new-db) when (not (eql new-db last-db))
    ;; The db gateway is the only one that knows saver's identity.
    ;; Don't bother doing anything unless the db has changed.
    (with-sponsor slow-sponsor
      (ensure-directories-exist path)
      (let ((trimmed (remove-unstorable new-db)))
        (with-open-file (f path
                           :direction         :output
                           :if-exists         :rename
                           :if-does-not-exist :create
                           :element-type      '(unsigned-byte 8))
          (write-sequence (uuid:uuid-to-byte-array +db-id+) f)
          (loenc:serialize trimmed f)
          (become (save-database-beh path new-db))))))
   ))

(defun unopened-database-beh (trans-gate)
  (alambda
   ((db-path)
    ;; message from kick-off starter routine
    (with-sponsor slow-sponsor
      (let ((db (maps:empty)))
        (ignore-errors
          (with-open-file (f db-path
                             :direction         :input
                             :if-does-not-exist :error
                             :element-type      '(unsigned-byte 8))
            (let* ((sig  (uuid:uuid-to-byte-array +db-id+))
                   (id   (make-array (length sig)
                                     :element-type '(unsigned-byte 8)
                                     :initial-element 0)))
              (read-sequence id f)
              (when (equalp id sig)
                (setf db (loenc:deserialize f)))
              )))
        (become (save-database-beh db-path db))
        (send trans-gate self db))))
   ))

(defun remove-unstorable (map)
  (maps:fold map (lambda (key val accu)
                   (handler-case
                       (progn
                         (loenc:encode (list key val))
                         (maps:add accu key val))
                     (error ()
                       accu)))
             (maps:empty)))

(defun deep-copy (obj)
  (loenc:decode (loenc:encode obj)))

;; -----------------------------------------------------------

(defvar *db-path*  (merge-pathnames "LispActors/Actors Transactional Database.dat"
                                    (sys:get-folder-path :appdata)))

(def-singleton-actor db ()
  (actors ((trans  (nascent-database-beh nil saver))
           (saver  (unopened-database-beh trans)))
    (send saver *db-path*)
    trans))

;; -----------------------------------------------------------

(defun add-rec (cust key val)
  (send (db) cust :req
        (actor (db commit rollback &rest retry-info)
          (declare (ignore rollback))
          (send* commit db (maps:add db key val) retry-info))
        ))

(defun remove-rec (cust key)
  (send (db) cust :req
        (actor (db commit rollback &rest retry-info)
          (declare (ignore rollback))
          (send* commit db (maps:remove db key) retry-info))
        ))

(defun lookup (cust key &optional default)
  (send (db) cust :req
        (actor (db &rest ignored)
          (declare (ignore ignored))
          (send cust (maps:find db key default)))
        ))

(defun show-db ()
  (send (db) nil :req
        (actor (db &rest ignored)
          (declare (ignore ignored))
          (sets:view-set db))))

;; ------------------------------------------------------------------
;; more usable public face - can use ASK against this

(deflex kvdb
        (make-actor
         (alambda
          ((cust :lookup key . default)
           (apply 'lookup cust key default))
          
          ((cust :add key val)
           (add-rec cust key val))
          
          ((cust :remove key)
           (remove-rec cust key))
          
          ((cust :req action-actor)
           (repeat-send (db)))
          )))

;; -----------------------------------------------------------
#|
(ask kvdb :lookup :dave)
(uuid:when-created (ask kvdb :lookup 'version))

(dotimes (ix 5)
  (add-rec println ix ix))
(add-rec println :dave :chara)
(add-rec println :cat "dog")
(lookup writeln :cat)
(show-db)
(dotimes (ix 10)
  (remove-rec println ix))
(add-rec println :tst (lambda (&rest args)
                        (declare (ignore args))
                        ))
(lookup writeln :tst)

(let ((m (maps:empty)))
  (setf m (maps:add m :dave :dog))
  (eql m (maps:add m :dave :dog)))
(let ((m (sets:empty)))
  (setf m (sets:add m :dave))
  (eql m (sets:add m :dave)))

(send (db) nil :req
      (actor (db . _)
        (maps:iter db (lambda (k v)
                        (send writeln (list k v))))))
|#               
