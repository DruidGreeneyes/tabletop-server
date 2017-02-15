;;;; game-server.lisp

(in-package #:game-server)

(defpackage #:server
  (:use #:cl #:sqlite #:usocket #:diff-match-patch))

;;; "game-server" goes here. Hacks and glory await!

;;; game needs a board
;;; board is defined by the game type, but follows some general rules:
;;; board is either a positive dag
;;;    (point A <--> point B <--> point C, entities may only move between points that have connecting edges)
;;; or a negative dag
;;;    (point A <-\-> point C, entities may move freely between points only if those points don't have connecting edges)
;;; in either case, edges define/modify movement between their respective points. Using Chutes and Ladders as an example:
;;;    (point C -Forced-> point A [representing a chute]
;;;     point A --> point B
;;;     point B --> point C
;;;     point B -Optional-> point D [representing a ladder])


;;; all of the work is done client-site; server just maintains a central event log.
;;; client A does some stuff and passes a time-stamped result to the server
;;;      (move player-a new-location)
;;; server appends this to the event log and sense the two most recent events out to all clients
;;; whenever a client recieves a pair of events, it checks to make sure its most recent event matches
;;; the second-most-recent of the pair. If not, it asks the server for a longer backlog, and continues asking until it
;;; sees events it recognizes, at which point it rebuilts its own local event log from the provided server data.

;;; server and clients each maintain local copies of game information (board, rules, state).
;;; Connecting clients either start a new game (for which they supply a game type or rules file)
;;; or supply the name of a saved game. In the case of conflicts between client saves server saves,
;;; the server always takes priority.

;;; upon loading or starting a game session, the server generates a random unique session id and hands it out to clients,
;;; which provide the session id as a prefix to any command or data passed to the server in regard to the session.

;;; this enables the game server to maintain several sessions at once, and means that without the sesson id, the server
;;; cannot know against which session to make changes it is passed.

;;; server should also supply rng.

;;; sqlite db, columns: client-id | session-id | game-id | ruleset-hash

(defparameter *server* nil)

(defparameter *id-bound* (expt 2 8192))

(defparameter *db-path* "db")

(defun get-session-info (session-id open-session-db) 
  (sqlite:execute-one-row-m-v open-session-db "select (game_id, ruleset_hash) from session_data where session_id = ?" session-id))

(defun get-session-id (game-id open-session-db)
  (sqlite:execute-single open-session-id "select session_id from sessions where game_id = ?" game-id))

(defun find-item-in-session-list (target column-name session-db)
  (sqlite:execute-single session-db "select ?1 from session_data where ?1 = ?2" column-name target))

(defun find-db-in-folder (target folder)
  (car (directory (pathname (format nil "~A/~A/~A.sqlite.db" *db-path* folder target)))))

(defun generate-id ()
  (random *id-bound*))

(defun generate-new-id (predicate)
  (let ((id (generate-id)))
    (if (apply predicate id)
        (generate-new-id predicate)
        id)))

(defun generate-new-session-id (open-session-db)
  (generate-new-id #'(lambda (id) (find-item-in-db id "session_id" open-session-db))))

(defun generate-new-game-id ()
  (generate-new-id #'(lambda (id) (find-db-in-folder id "games"))))

(defun add-client! (open-session-db client-id session-id game-id ruleset-hash)
  (sqlite:execute-non-query open-session-db
                            "insert into session_data (client_id, session_id, game_id, ruleset_hash) values (?, ?, ?, ?)"
                            client-id session-id game-id ruleset-hash))

(defun disconnect-client! (client-id)
  "Stop the client-agent and allow the client socket connection to close."
  nil)

(defun close-session! (session-id open-session-db)
  (close-game (get-session-info session-id open-session-db))
  (sqlite:execute-non-query open-session-db "delete from session_data where session_id = ?" session-id))

(defun ruleset-path (hash)
  (car (directory (pathname (format nil "~A/rulesets/~A" *db-path* hash)))))

(defun load-ruleset (hash)
  (let ((path (ruleset-path hash)))
    (when path
      (with-open-file (stream path)
        (let ((ruleset (make-string (file-length stream))))
          (read-sequence ruleset stream)
          ruleset)))))

(defun push-ruleset (out-stream ruleset-hash)
  (let ((ruleset (load-ruleset ruleset-hash)))
    (broadcast out-stream (list :ruleset ruleset-hash ruleset))))

(defun push-ruleset-update! (out-stream game-id old-ruleset-hash new-ruleset-hash)
  (let ((patch (dmp:make-patch (load-ruleset old-ruleset-hash)
                               (load-ruleset new-ruleset-hash))))
    (broadcast out-stream (list :ruleset-patch game-id old-ruleset-hash new-ruleset-hash patch))))

(defun open-event-log (game-id)
  (let ((event-log (sqlite:connect (format nil "~A/games/~A.sqlite.db" *db-path* game-id))))
    (execute-non-query event-log "create table log (timestamp integer primary-key, event text) without rowid")
    event-log))

(defun open-session-db () 
  (let ((db (sqlite:connect "~A/game-sessions.sqlite.db" *db-path*)))
    (execute-non-query db "create table session-data (client-id integer primary-key, session-id integer, game-id integer, ruleset-hash integer) without rowid")
    db))

(defun request-ruleset! (client-stream ruleset-hash)
  (write (list :request-ruleset ruleset-hash) :stream client-stream))

(defun log-event! (event-log event)
  (sqlite:execute-non-query event-log "insert into log (timestamp, event) values (?, ?)" (car event) (cdr event)))

(defun broadcast! (stream-list message)
  (let ((*print-readably* t))
    (loop for stream in stream-list
       do (write message :stream stream))))

(defun save-ruleset! (ruleset-hash ruleset)
  (with-open-file (strm (ruleset-path ruleset-hash) :direction :output :if-exists :error :if-does-not-exist :create)
    (write ruleset :stream strm)))

(defun patch-ruleset (ruleset-hash patch)
  (with-open-file (in (ruleset-path ruleset-hash))
    (let ((patched-ruleset (dmp:apply-patch patch (read in))))
      (let ((p-hash (sxhash patched-ruleset)))
        (save-ruleset! p-hash patched-ruleset)
        p-hash))))

(defun dispatch-input! (input)
  (case (first input)
    (:request-log (broadcast! (list stream) (most-recent-events (second input))))
    (:request-ruleset (push-ruleset! (list stream) (second input)))
    (:ruleset (apply #'save-ruleset! (rest input)))
    (:ruleset-patch (apply #'patch-ruleset! (rest input)))
    (otherwise (progn
                 (log-event! event-log input)
                 (broadcast! (get-all-clients session-id)
                             (cons :log (most-recent-events 10))))))))

(defun client-event-loop! (stream event-log session-id)
  (loop
     (handler-bind ((end-of-file #'loop-finish))
       (dispatch-input! (read stream)))))

(defun handle-ruleset-conflict! (client-stream game-id client-ruleset-hash ruleset-hash)
  (let ((client-timestamp (get-ruleset-timestamp client-ruleset-hash))
        (local-timestamp (get-ruleset-timestamp ruleset-hash)))
    (if (> client-timestamp local-timestamp)
        (request-ruleset! client-stream client-ruleset-hash)
        (push-ruleset! client-stream ruleset-hash))))

(defun handle-connection! (client-stream client-socket)
  (let ((open-session-db (open-session-db))) 
    (destructuring-bind (client-id game-id client-ruleset-hash)
        (read client-stream)
      (multiple-value-bind (session-id ruleset-hash)
          (get-session-info game-id open-session-db)
        (let ((ruleset-hash (or ruleset-hash (request-ruleset! client-stream ruleset-hash))))
          (unless (string= client-ruleset-hash ruleset-hash)
            (resolve-ruleset-conflict! client-stream game-id client-ruleset-hash ruleset-hash))
          (add-client! client-id session-id game-id ruleset-hash)
          (let ((event-log (get-event-log game-id)))
            (client-event-loop! stream event-log session-id)))))))

(defun start-server (host port)
  (usocket:socket-server host port #'handle-connection! :multi-threading t))

(defun stop-server (server)
  (usocket:socket-close server))
