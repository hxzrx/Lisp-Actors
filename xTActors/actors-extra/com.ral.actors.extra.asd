
;; Select one or the other...
(pushnew :KVDB-USE-FPLHT *features*) ;; using FPL Hashtables
;; (pushnew :KVDB-USE-MAPS *features*)  ;; using FPL RB-Trees

(asdf:defsystem "com.ral.actors.extra"
  :description "Everything is an Actor..."
  :version     "3.0"
  :author      "D.McClain <dbm@refined-audiometrics.com>"
  :license     "Copyright (c) 2021-2022 by Refined Audiometrics Laboratory. MIT License terms apply."
  :components  (#-:ALLEGRO (:file "debugging")
                #-:ALLEGRO (:file "kvdb")
                #-:ALLEGRO (:file "multi-commit")
                (:file "reactive")
                (:file "resource")
                ;; (:file "sponsors")
                )
  :SERIAL T
  :depends-on   ("com.ral.actors"
                 "com.ral.rb-trees"              ;; maps for transactional db
                 "com.ral.lisp-object-encoder"   ;; encoding for transactional db
                 "mini-core-crypto"
                 ))

#|
(asdf :doctools)
(doctools:gen-docs
 :asdf-system-name :com.ral.actors.extra
 :package-name     :com.ral.actors
 :directory        (translate-logical-pathname "PROJECTS:LISP;xTActors;actors-extra")
 :subtitle         "Extra Goodies for Hewitt Actors in Lisp")
|#
