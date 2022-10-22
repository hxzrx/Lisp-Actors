;; par-xlate.lisp -- Conversion of Call/Return into Parallel Actors
;;
;; DM/RAL  2022/10/22 05:51:07
;; ----------------------------------

(defpackage #:com.ral.actors.par-xlate
  (:use #:common-lisp #:actors))

(in-package #:com.ral.actors.par-xlate)

;; ----------------------------------
;; General translations of imperative Call/Return code into Actors
;; Parallel code.
;;
;; We make use of SERVICE and β forms. A SERVICE Actor is an Actor
;; that expects only a customer in a message, performs its service,
;; and sends its result onward to that customer. The result should
;; be a single value. β-forms allow for destructuring args.
;;
;; Anything can be converted into a Service. For existing Actors which
;; expect a customer in their messages, simply state their name and
;; message form, eliding the customer argument:
;;
;;   If the send form is:
;;     (SEND Actor cust e1 e2 ...)
;;
;;   then their service form is:
;;     (SERVICE Actor e1 e2 ...) ;; note elided cust
;;
;; The convention with Actors is that the cust arg is always in first
;; position in any message.
;;
;;
;;  For functions whose call form is:
;;     (fn e1 e2 ...)
;;
;;  their service form is:
;;     (SERVICE #'fn e1 e2 ...)
;;
;;
;;  And for general value forms:
;;     expr
;;
;;  their service form is:
;;     (SERVICE expr)
;; 
;; ---------------------------
;; A β form is an Actor-continuation style, where the syntax of the β
;; form mimics the syntax of a DESTRUCTURING-BIND form:
;;
;;   (DESTRUCTURING-BIND (n1 n2 ...)
;;      (funcall fn e1 e2 ...)
;;    body)
;; =>
;;   (β (n1 n2 ...)
;;      (SEND Actor cust e1 e2 ...)
;;     body)
;;
;; Note that arg lists can be general trees, just like for
;; DESTRUCTURING-BIND.
;;
;; The dynamics of the β form are that you are in execution #1 into
;; the SEND, and in execution #2 (the continuation) in the body, with
;; the bindings (n1 n2 ...) having been established on resumption of
;; the continuation for the body form.
;;
;; The β form is just a convenient representation for the equivalent
;; form:
;;
;;  (let ((β  (CREATE (LAMBDA (n1 n2 ...) body))))
;;     (SEND Actor β e1 e2 ...)
;;
;; Just be on guard - while you can refer to SELF in the outer parts
;; of Execution #1, the value of SELF later refers to the anonymous
;; continuation Actor inside the body form of the continuation. So if
;; you need to send to the outer SELF Actor, be sure to capture it in
;; a lexical binding:
;;
;;   (let ((ME SELF))
;;     (β  (...)
;;        (SEND Actor β .. SELF ...)
;;       (body-form ... ME ...)))
;;       
;; ---------------------------------------------
;; Imperative Conversions to Parallel Forms:
;;
;; Just be advised - since Lisp does not offer CALL/RETURN
;; Continuations, as with CALL/CC, you cannot peform β conversions in
;; mid-arguments stream. You must perform them prior to use of thier
;; resulting bindings.
;;
;;  That is, you cannot hope to do something like:
;;
;;    (funcall e1 e2 (β-form e3) e4 e5)
;;
;;  Doing that would require that the Lisp compiler convert the
;;  expression to CALL/RETURN CPS-style, moving the funcall to after
;;  the argument eval with the β-form. Lisp cannot do this.
;;
;;   So, instead, you must do:
;;
;;     (β-form (n3)
;;            (SEND e3 β)
;;        (funcall e1 e2 n3 e4 e5))
;;
;; ---------------------------------------------------
;; (funcall fn e1 e2 ...)
;; =>
;; (β (v1 v2 ...)
;;     (send (fork (service ,@e1)
;;                 (service ,@e2)
;;                 ...)
;;           β)
;;   (send fn cust v1 v2 ...))

;; -----------------

;; (begin
;;  e1
;;  e2
;;  ...
;;  en)
;; =>
;; (β (_ _ ... vn)
;;     (send (fork (service ,@e1)
;;                 (service ,@e2)
;;                 ...
;;                 (service ,@en))
;;           β)
;;   (send cust vn))

;; ---------------

;; (if e1
;;     e2
;;   e3)
;; =>
;; (β (v1)
;;     (send (service ,@e1) β)
;;   (if v1
;;       (send (service ,@e2) cust)
;;     (send (service ,@e3) cust)))
;; ---------------------------

;; (lambda args . body)
;; => ;; for Services
;; (create (lambda (cust ,@args)
;;           ,@body))
;; => ;; for Sinks
;; (create (lambda ,args ,@body))

;; ----------------------------

;; (and e1 e2 .. en)
;; =>
;; (send (and-gate
;;        (service ,@e1)
;;        (service ,@e2)
;;        ...
;;        (service ,@en))
;;       cust)

;; ----------------------------

;; (or e1 e2 .. en)
;; =>
;; (send (or-gate
;;        (service ,@e1)
;;        (service ,@e2)
;;        ...
;;        (service ,@en))
;;       cust)
;; ------------------------------
;; (let ((n1 e1)
;;       (n2 e2)
;;       ..
;;       (nn en))
;;   eb1
;;   eb2
;;   ...
;;   ebn)
;; =>
;; (β  (n1 n2 .. nn)
;;     (send (fork (service ,@e1)
;;                 (service ,@e2)
;;                 ...
;;                 (service ,@en))
;;           β)
;;   (β (_ _ .. vbn)
;;       (send (fork (service ,@eb1)
;;                   (service ,@eb2)
;;                   ...
;;                   (service ,@ebn))
;;             β)
;;     (send cust vbn)))
;; ------------------------------
;; (let* ((n1 e1)
;;        (n2 e2)
;;        ..
;;        (nn en))
;;   eb1
;;   eb2
;;   ...
;;   ebn)
;; =>
;; (β  (n1)
;;     (send (service ,@e1) β)
;;   (β (n2)
;;       (send (service ,@e2) β)
;;     ...
;;     (β (nn)
;;         (send (service ,@en) β)
;;       (β (_ _ .. vbn)
;;           (send (fork (service ,eb1)
;;                       (service ,eb2)
;;                       ...
;;                       (service ,@ebn))
;;                 β)
;;         (send cust vbn)))))
;;
;; -----------------------------------------------

(defun const-beh (&rest msg)
  (lambda (cust)
    (send* cust msg)))

(defun const (&rest msg)
  (create (apply #'const-beh msg)))

;; ---------------------------------------------------
;; Service -- offer up a parameterized service once the customer is
;; known

(defun service-beh (server &rest args)
  (lambda (cust)
    (send* server cust args)))

(defun service (server &rest args)
  (cond ((actor-p server)
         (create (apply #'service-beh server args)))
        ((functionp server)
         (create
          (lambda (cust)
            (send cust (apply server args)))))
        (t
         (const server))
        ))

(deflex null-service
  (create (lambda (cust)
            (send cust))))

;; ---------------------------------------------------
;; Fork/Join against an arbitrary number of services

(defun join2-beh (cust tag1)
  (alambda
   ((tag . ans) when (eql tag tag1)
    (become (lambda (tag &rest ans2)
              (declare (ignore tag))
              (send* cust (append ans ans2)))))
   ((_ . ans)
    (become (lambda (tag &rest ans1)
              (declare (ignore tag))
              (send* cust (append ans1 ans)))))
   ))

(defun fork2-beh (service1 service2)
  ;; Produce a single services which fires both in parallel and sends
  ;; their results in the same order to eventual customer.
  (lambda (cust)
    (actors ((tag1   (tag joiner))
             (tag2   (tag joiner))
             (joiner (create (join2-beh cust tag1))))
      (send service1 tag1)
      (send service2 tag2)
      )))

(defun fork2 (service1 service2)
  (create (fork2-beh service1 service2)))

(defun fork (&rest services)
  ;; Produces a single service from a collection of them. Will exec
  ;; each in parallel, returning all of their results to eventual
  ;; customer, in the same order as stated in the service list.
  (or (reduce (lambda (svc tail)
                (fork2 svc tail))
              (butlast services)
              :initial-value (car (last services))
              :from-end t)
      null-service))
;;
;; We get for (FORK A B C):
;;
;;                    +---+
;;                    | A |
;;                    +---+     +---+
;;         +------+  /          | B |
;;      -->| FORK |/            +---+
;;         +------+\           /
;;                   \+------+/
;;                    | FORK |
;;                    +------+\
;;                             \
;;                              +---+
;;                              | C |
;;                              +---+
;;
;; -----------------------------------------------

(defmacro let-β (bindings &body body)
  ;; bindings should be to services as in:
  ;; 
  ;;   (let-β ((n1 (service ,@e1))
  ;;           (n2 (service ,@e2))
  ;;           ... )
  ;;      ,@body)
  ;;
  ;; FORK works properly for zero or more services.
  ;;
  `(β ,(mapcar #'car bindings)
       (send (fork ,@(mapcar #'cadr bindings)) β)
     ,@body))

#+:LISPWORKS
(progn
  (editor:setup-indent "let-β"  1)
  (editor:setup-indent "let-β*" 1))

(defmacro let-β* (bindings &body body)
  ;; bindings should be to services
  (if bindings
      `(let-β (,(car bindings))
         (let-β* ,(cdr bindings) ,@body))
    `(progn
       ,@body)))

;; -----------------------------------------------

(defmacro prog1-β (first-val services &body body)
  (um:with-unique-names (ns)
    `(β ,ns
         (send (fork ,@services) β)
       (let ((,first-val (car ,ns)))
         ,@body))))

(defmacro progn-β (final-val services &body body)
  (um:with-unique-names (ns)
    `(β ,ns
         (send (fork ,@services) β)
       (let ((,final-val (car (last ,ns))))
         ,@body))))

;; -----------------------------------------------

(deflex true  (const t))
(deflex false (const nil))

(defun or2-gate-beh (service1 service2)
  (lambda (cust)
    (β (ans)
        (send service1 β)
      (if ans
          (send cust ans)
        (send service2 cust)))))

(defun or2-gate (service1 service2)
  (create (or2-gate-beh service1 service2)))

(defun or-gate (&rest services)
  (if services
      (reduce (lambda (head svc)
                (or2-gate head svc))
              services)
    false))
        
;;
;; We get for (OR-GATE A B C):
;;
;;                          +---+
;;                          | A |
;;                          +---+
;;               +------+  /
;;               |  OR  |/
;;               +------+\ 
;;                  /      \+---+
;;                 /        | B |
;;                /         +---+
;;      +------+ /
;;   -->|  OR  |/
;;      +------+\
;;               \+---+
;;                | C |
;;                +---+
;;
;; -----------------------------------------------

(defun and2-gate-beh (service1 service2)
  (lambda (cust)
    (β (ans)
        (send service1 β)
      (if ans
          (send service2 cust)
        (send cust nil)))))

(defun and2-gate (service1 service2)
  (create (and2-gate-beh service1 service2)))

(defun and-gate (&rest services)
  (if services
      (reduce (lambda (head svc)
                (and2-gate head svc))
              services)
    true))

;;
;; We get for (AND-GATE A B C):
;;
;;                          +---+
;;                          | A |
;;                          +---+
;;               +------+  /
;;               |  AND |/
;;               +------+\ 
;;                  /      \+---+
;;                 /        | B |
;;                /         +---+
;;      +------+ /
;;   -->|  AND |/
;;      +------+\
;;               \+---+
;;                | C |
;;                +---+
;;
;; -----------------------------------------------

(defmacro with-β-and ((ans &rest clauses) &body body)
  `(β (,ans)
       (send (and-gate ,@clauses) β)
     ,@body))

(defmacro with-β-or ((ans &rest clauses) &body body)
  `(β (,ans)
       (send (or-gate ,@clauses) β)
     ,@body))

;; -----------------------------------------------

(defmacro if-β (test iftrue &optional iffalse)
  (lw:with-unique-names (ans)
    `(with-β-and (,ans ,test)
       (if ,ans
           ,iftrue
         ,iffalse))
    ))

(defmacro when-β (test &body body)
  (lw:with-unique-names (ans)
    `(with-β-and (,ans ,test)
       (when ,ans
         ,@body))))

(defmacro unless-β (test &body body)
  (lw:with-unique-names (ans)
    `(with-β-and (,ans ,test)
       (unless ,ans
         ,@body))))

;; -----------------------------------------------

(defmacro if-β-and ((&rest clauses) iftrue &optional iffalse)
  (lw:with-unique-names (ans)
    `(with-β-and (,ans ,@clauses)
       (if ,ans
           ,iftrue
         ,iffalse))
    ))

(defmacro if-β-or ((&rest clauses) iftrue &optional iffalse)
  (lw:with-unique-names (ans)
    `(with-β-or (,ans ,@clauses)
       (if ,ans
           ,iftrue
         ,iffalse))
    ))

(defmacro when-β-and ((ans &rest clauses) &body body)
  `(if-β-and (,ans ,@clauses) (progn ,@body)))

(defmacro when-β-or ((ans &rest clauses) &body body)
  `(if-β-or (,ans ,@clauses) (progn ,@body)))

(defmacro unless-β-and ((ans &rest clauses) &body body)
  `(if-β-and (,ans ,@clauses) 'nil (progn ,@body)))

(defmacro unless-β-or ((ans &rest clauses) &body body)
  `(if-β-or (,ans ,@clauses) 'nil (progn ,@body)))

#+:LISPWORKS
(progn
  (editor:setup-indent "with-β-and" 1)
  (editor:setup-indent "with-β-or"  1)
  (editor:indent-like 'if-β     'if)
  (editor:indent-like 'if-β-and 'if)
  (editor:indent-like 'if-β-or  'if))

;; -----------------------------------------------

