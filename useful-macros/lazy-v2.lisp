
(in-package :um.lazy)

(defmacro deferred (&body body)
  `(lambda ()
     ,@body))

(defstruct lazy
  cell)

(defmacro lazy (expr)
  `(make-lazy
    :cell (cons
           (lambda ()
             ,expr)
           :uneval)))

(defgeneric force (obj)
  (:method ((obj lazy))
   (um:recover-ans-or-exn
    (um:nlet iter ()
      (let ((cell (lazy-cell obj)))
        (cond
         ((eq (cdr cell) :eval)
          (car cell))
         ((sys:compare-and-swap (cdr cell) :uneval :in-proc)
          (let ((val (um:call-capturing-ans-or-exn (car cell))))
            (setf (lazy-cell obj) (cons val :eval))
            val))
         (t
          (mp:process-allow-scheduling)
          (go-iter))
         )))))
  (:method ((obj function))
   (funcall obj))
  (:method (obj)
   obj))
  
