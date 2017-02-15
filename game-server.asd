;;;; game-server.asd

(asdf:defsystem #:game-server
  :description "Describe game-server here"
  :author "Your Name <your.name@example.com>"
  :license "Specify license here"
  :serial t
  :depends-on (#:sqlite #:usocket #:diff-match-patch)
  :components ((:file "package")
               (:file "game-server")))
