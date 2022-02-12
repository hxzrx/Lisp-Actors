;; funcallable-beh.lisp -- What happens if we make Behavior functions into Funcallable Classes?
;;
;; A new style of message format, and a different way of building up
;; Actor behaviors that can be extensible and inheritable.
;;
;; DM/RAL 02/22
;; --------------------------------------------

(in-package :ac)

;; -----------------------------------------------------------

(defclass <behavior> ()
  ()
  (:metaclass clos:funcallable-standard-class))

(defmethod initialize-instance :after ((beh <behavior>) &key &allow-other-keys)
  (clos:set-funcallable-instance-function beh
                                          (lambda (fn &rest args)
                                            (apply fn beh args))
                                          ))

(defmacro defbeh (name supers &optional slots &rest options)
  `(defclass ,name
             ,(or supers
                  '(<behavior>))
     ,slots ,@options
     (:metaclass clos:funcallable-standard-class)))

#+:LISPWORKS
(editor:setup-indent "defbeh" 2)

;; -----------------------------------------------------------

(defbeh seq-beh ()
  ((hd  :reader seq-hd  :initarg :hd)
   (tl  :reader seq-tl  :initarg :tl)))

(defmethod shd ((beh seq-beh) cust)
  (send cust (seq-hd beh)))

(defmethod stl ((beh seq-beh) cust)
  (send (seq-tl beh) cust))

(defmethod spair ((beh seq-beh) cust)
  (let ((a  (seq-hd beh)))
    (β  (rb)
        (stl beh β)
      (send cust a rb)
      )))

(defmethod snth ((beh seq-beh) cust n)
  (cond ((zerop n)
         (send cust (seq-hd beh)))
        (t
         (β (next)
             (stl beh β)
           (send next 'snth cust (1- n))))
        ))

(defmethod snthtl ((beh seq-beh) cust n)
  (cond ((zerop n)
         (send cust self))
        (t
         (β (next)
             (stl beh β)
           (send next 'snthtl cust (1- n)))
         )))

(defun seq (a α-cust)
  (make-actor (make-instance 'seq-beh
                             :hd  a
                             :tl  (lazy α-cust))))

;; -----------------------------------------------

(deflex repeat
  (α (cust a f)
    (send cust (seq a (α (acust)
                        (β (fa)
                            (send f β a)
                          (send repeat acust fa f)))
                    ))))

(deflex order
  (α (cust seq)
    (β  (a rb)
        (send seq 'spair β)
      (β  (b rc)
          (send rb 'spair β)
        (β (c)
            (send rc 'shd β)
          (let ((ord (or (ignore-errors
                           (round (log (- (/ (- a c)
                                             (- b c))
                                          1 )
                                       2 )))
                         100)))
            (send cust ord)
            )))
      )))

(deflex within
  (α (cust eps s)
    (β  (a rb)
        (send s 'spair β)
      (β (b)
          (send rb 'shd β)
        (cond ((<= (abs (- a b)) eps)
               (send cust b))
              (t
               ;; (send order println s)
               (send within cust eps rb))
              )))))

(deflex ssqrt
  (α (cust a0 eps n)
    (β  (s)
        (send repeat β
              a0
              (α (cust x)
                (send cust (/ (+ x (/ n x)) 2))))
      (send within cust eps s))
    ))


#|
(send ssqrt println 1.5 1e-8 0.1)
(sqrt 2.0)
(β (s)
    (send repeat β 1.5 (lambda (x) (/ (+ x (/ 0.1 x)) 2)))
  (send stake println s 5))
|#
;; -----------------------------------------------

(deflex elimerror
  (α (cust n s)
    (β (a rb)
        (send s 'spair β)
      (β (b)
          (send rb 'shd β)
        (let ((2^n (expt 2 n)))
          (send cust (seq (/ (- (* b 2^n) a) (- 2^n 1))
                          (α (acust)
                            (send elimerror acust n rb))))
          )))))

(deflex improve
  (α (cust s)
    (β (ord)
        (send order β s)
      (send elimerror cust ord s))
    ))

(deflex fst
  (α (cust s)
    (send s 'shd cust)))

(deflex snd
  (α (cust s)
    (β (rb)
        (send s 'stl β)
      (send rb 'shd cust)
      )))

(deflex thd
  (α (cust s)
    (β  (rb)
        (send s 'stl β)
      (β  (rc)
          (send rb 'stl β)
        (send rc 'shd cust)
        ))))

(deflex smap
  (α (cust afn s)
    (β  (a rb)
        (send s 'spair β)
      (β  (ma)
          (send afn β a)
        (send cust (seq ma
                        (α (acust)
                          (send smap acust afn rb))
                        ))
        ))))

(deflex aitken
  (α (cust s)
  ;; Aitken's delta-squared process
  (β  (a rb)
      (send s 'spair β)
    (β  (b rc)
        (send rb 'spair β)
      (β (c)
          (send rc 'shd β)
        (let* ((epsilon 1d-16)
               (c-b (- c b))
               (den (- c-b (- b a)))
               (c-new (if (< (abs den) epsilon)
                          c
                        (- c (/ (* c-b c-b) den)))))
          (declare (real a b c c-b den c-new))
          (send cust (seq c-new
                          (α (acust)
                            (send aitken acust rb))))
          )))
    )))

(deflex accelerate
  (α (cust xform s)
    (β  (xs)
        (send repeat β s xform)
      (send smap cust snd xs)
      )))

(deflex fsecond
  (α (cust lst)
    (send cust (second lst))))

;; ----------------------------------------------------------------------
;; cfrac-iter -- an evaluator for continued fraction approximations,
;; expressed in the form
;;
;;  f(x) = x0
;;         -------
;;         y0 + x1
;;              -------
;;              y1 + x2
;;                   -------
;;                   y2 + x3 .....
;;
;; could also be written as:
;;
;; f(x) = x0/(y0 + x1/(y1 + x2/(y2 + ...
;;
;; Caller supplies a function fnxy that, when furnished with the index ix,
;; returns the next numerator x[ix] and denominator y[ix], for index ix = 1, 2, ...
;;
;; Also required are the starting values x[0] and y[0].
;;
;; We use accelerated iteration with Aitken's method.
;; Iteration ceases when two successive iterations produce the same answer.
;; That answer is supplied as the result.
;;
;; This is made easier by the use of lazy-streams.
;;
;; --------------------------------------------------------------------

(defun cfrac-term (fnxy)
  (α (cust args)
    (destructuring-bind (ix v p1 q1 p2 q2) args
      (declare (ignore v))
      (destructuring-bind (x0 y0) (funcall fnxy ix)
        (let ((p0 (+ (* y0 p1) (* x0 p2)))
              (q0 (+ (* y0 q1) (* x0 q2))))
          (assert (not (zerop q0)))
          (send cust (list (1+ ix) (/ p0 q0) p0 q0 p1 q1))
          )))))

(deflex erf-stream
  ;; cfrac is: x|1-2*x^2|3+4*x^2|5-6*x^2|7+ ...
  ;; use when x <= 1.7
  (α (cust x)
    (labels ((fnxy (ix)
                 (let ((sgn (- 1 (* 2 (logand ix 1)))))
                   (list (* sgn 2 ix x x) (+ 1 ix ix))
                   )))
      (β  (s)
          (send repeat β (list 1 x x 1 0 1) (cfrac-term #'fnxy))
        (send smap cust fsecond s)
        ))))

(deflex erfc-stream
  ;; cfrac is: 1|x+(1/2)|x+(2/2)|x+(3/2)|x+ ...
  ;; use when x > 1.7
  (α (cust x)
    (labels ((fnxy (ix)
               (list (/ ix 2) x)))
      (β  (s)
          (send repeat β (list 1 (/ x) 1 x 0 1) (cfrac-term #'fnxy))
        (send smap cust fsecond s)
        ))))

(deflex erf-raw
  ;; use when x <= 1.7
  (α (cust x eps)
    (β  (s)
        (send erf-stream β x)
      (β  (as)
          (send accelerate β aitken s)
        (β  (ans)
            (send within β eps as)
          (send cust (* ans
                        (/ 2.0d0 (sqrt pi) (exp (* x x)))))
          )))))

(deflex erfc-raw
  ;; use when x > 1.7
  (α (cust x eps)
    (β  (s)
        (send erfc-stream β x)
      (β  (as)
          (send accelerate β aitken s)
        (β  (ans)
            (send within β eps as)
          (send cust (* ans
                        (/ 1.0d0 (sqrt pi) (exp (* x x)))))
          )))))

;; -------------------------------------------------------------
;; User callable entry points
;;
;; These entry points determine which of the two raw definitions to call,
;; based on the magnitude of the argument x. When abs(x) = 1.7 both raw
;; definitions require about the same number of accelerated iterations for convergence.
;;
(deflex erfc
  ;; 2/Sqrt(Pi)*Integral(Exp(-t^2), {t, x, inf}) = 1 - erf(x)
  (α (cust x &optional (eps 1e-8))
    (let ((z  (abs (float x 1d0))))
      (cond ((> z 1.7d0)
             (β  (ans)
                 (send erfc-raw β z eps)
               (send cust (if (minusp x)
                              (- 2d0 ans)
                            ans))
               ))
            (t
             (β  (ans)
                 (send erf-raw β z eps)
               (let ((aans (- 1d0 ans)))
                 (send cust (if (minusp x)
                                (- 2d0 aans)
                              aans)))
               ))
            ))))

(deflex erf
  ;; 2/Sqrt(Pi)*Integral(Exp(-t^2), {t, 0, x}) = 1 - erfc(x)
  (α (cust x &optional (eps 1d-8))
    (let ((z  (abs (float x 1.0d0))))
      (cond ((> z 1.7d0)
             (β  (ans)
                 (send erfc-raw β z eps)
               (let ((aans (- 1d0 ans)))
                 (send cust (if (minusp x)
                                (- aans)
                              aans))
                 )))

            (t
             (β  (ans)
                 (send erf-raw β z eps)
               (send cust (if (minusp x)
                              (- ans)
                            ans))
               ))
            ))))

(defun fn-erfc (x &optional (eps 1e-12))
  (ask erfc x eps))

(defun fn-erf (x &optional (eps 1e-12))
  (ask erf x eps))

#| ;check it out...
(let ((domain '(-3.0d0 3.0d0)))
  (plt:fplot 1 domain #'fn-erfc
             :clear t
             :title "Erfc(x)")
  
  (plt:fplot 2 domain #'fn-erf
             :clear t
             :title "Erf(x)")
  
  (plt:fplot 3 domain (lambda (x)
                        (- (stocks::erfc x)
                           (fn-erfc x)))
             :clear t
             :title "Erfc Approximation Error"))

|#

        