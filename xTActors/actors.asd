#|
MIT License Terms:

Copyright (c) 2017, Refined Audiometrics Laboratory, LLC

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
|#

(asdf:defsystem "actors"
  :description "Everything is an Actor..."
  :version     "3.0"
  :author      "D.McClain <dbm@refined-audiometrics.com>"
  :license     "Copyright (c) 2021 by Refined Audiometrics Laboratory. MIT License terms apply."
  :components  ((:file "packages")
                #-:lispworks (:file "ansi-timer")
                (:file "macros")
                (:file "actors-mstr")
                (:file "prim-actors")
                (:file "debugging")
                (:file "encoding")
                (:file "transactional-db")
                (:file "reactive")
                (:file "resource")
                (:file "st-send")
                (:file "sponsors"))
  :SERIAL T
  :depends-on   ("data-objects"
                 "trivia"
		 "mpcompat"
                 "cps"
                 "lisp-object-encoder"
                 "core-crypto"
                 "snappy"
                 ))

