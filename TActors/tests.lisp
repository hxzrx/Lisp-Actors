
(in-package :ac)

(ac:make-remote-actor "echo@rincon.local"
                      :register :RECHO)

(ac:make-remote-actor "eval@rincon.local"
                      :register :REVAL)

(ac:make-remote-actor "eval@arroyo.local"
                      :register :REVAL)

(loop repeat 5 do
      (send :reval (ac:usti println) `(machine-instance)))

(let ((a (make-actor
          (lambda ()
            ;; (print args)
            (print :hello)))))
  (send a))
(get-actor-names println)
(find-actor println :reval)

;; --------------------------------------
;; Arg pattern convention has customer first, followed by message and
;; args

;; to break (+ a b) down into elementary particle Actors...
(send cust (+ a b))

(@bind (+)
    (send + @bind :eval)
  (@bind (a)
      (send a @bind :eval)
    (@bind (b)
        (send b @bind :eval)
      (send + cust :apply a b))))

(@bind ((+ a b))
    (send par @bind '(+ a b) :eval)
  (send + cust :apply a b))
          

(defun list-beh (lst)
  (um:dlambda
    (:eval (cust)
     (send (@bind vals
               (send par lst :eval

