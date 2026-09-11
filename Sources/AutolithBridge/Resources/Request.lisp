;; Evaluated as one lexical form through Autolith's authenticated management RPC.
;; No definitions or observer hooks are installed in the active image.
(let* ((request (json-decode __REQUEST_JSON__))
       (configuration (localgroup--client-configuration))
       (application *active-application*))
  (labels
      ((required (key)
         (let ((value (json-get request key)))
           (unless (non-empty-string-p value)
             (error 'configuration-error :message (format nil "Missing string ~A." key)))
           value))
       (application-session-id ()
         (getf (rest (localgroup-status-snapshot (application-localgroup-session application))) :session-id))
       (current-application ()
         (unless (and application
                      (string= (required "id") (application-session-id)))
           (error 'configuration-error :message "This management endpoint belongs to another session."))
         application)
       (status-json (status)
         (let ((fields (rest status)))
           (json-object "id" (getf fields :session-id)
                        "pid" (getf fields :pid)
                        "title" (or (getf fields :conversation-title) "New session")
                        "state" (string-downcase (symbol-name (getf fields :state)))
                        "workspace" (getf fields :cwd)
                        "model" (or (getf fields :model) "")
                        "effort" (getf fields :reasoning-effort)
                        "supportedEfforts"
                        (coerce (configuration--reasoning-efforts-for
                                 (or (getf fields :model) "")) 'vector)
                        "permissions" (string-downcase (symbol-name (getf fields :permission-mode)))
                        "queued" (getf fields :queued-input-count)
                        "jobs" (getf fields :task-live-count))))
       (event-json (record)
         (let* ((fields (rest record))
                (kind (or (getf fields :role) (first record)))
                (content (or (when (eq (first record) ':user-operation)
                               (format nil "~A~%~A" (getf fields :source) (getf fields :result)))
                             (getf fields :content) (getf fields :output)
                             (getf fields :arguments) (getf fields :message) "")))
           (json-object "id" (princ-to-string (getf fields :seq))
                        "timestamp" (let ((time (getf fields :time)))
                                      (when (typep time 'timestamp) (- time 2208988800)))
                        "role" (string-downcase (symbol-name kind))
                        "tool" (princ-to-string (or (getf fields :tool) ""))
                        "text" (if (stringp content) content
                                   (with-standard-io-syntax
                                     (let ((*print-readably* nil)) (prin1-to-string content)))))))
       (context-events (records)
         (loop for record in records for index from 0
               for event = (event-json record)
               do (setf (gethash "id" event) (format nil "local-~D" index))
               collect event))
       (sessions ()
         (let* ((live (mapcar #'status-json (localgroup-statuses configuration)))
                (identifiers (mapcar (lambda (status) (json-get status "id")) live))
                (saved nil))
           (dolist (pathname (conversation-list configuration))
             (unless (member (pathname-name pathname) identifiers :test #'string=)
               (let ((conversation (conversation-replay-load configuration (pathname-name pathname))))
                 (push (json-object "id" (conversation-identifier conversation)
                                    "title" (or (conversation-title conversation) "Saved session")
                                    "state" "stopped"
                                    "workspace" (or (conversation-origin-directory conversation) "")
                                    "model" (or (conversation-model conversation) "")
                                    "permissions" "ask" "queued" 0 "jobs" 0)
                       saved))))
           (let ((sessions (append live (nreverse saved))))
             (dolist (session sessions)
               (let* ((pathname (conversation-pathname-for-id configuration (json-get session "id")))
                      (active (conversation-storage-active-pathname pathname)))
                 (setf (gethash "updatedAt" session) (if active (or (file-write-date active) 0) 0))))
             (coerce sessions 'vector))))
       (transcript ()
         (when (json-get request "requireCurrent") (current-application))
         (let* ((identifier (required "id"))
                (after (json-get request "after" 0))
                (events nil)
                (live (and application
                           (string= identifier (application-session-id))
                           (application-conversation application)))
                (pathname (conversation-pathname-for-id
                           configuration (if live (conversation-identifier live) identifier)))
                (conversation (if (conversation-storage-active-pathname pathname)
                                  (conversation-replay-load configuration (pathname-name pathname)) live))
                (context (and conversation (zerop after)
                              (conversation-user-operation-snapshot (or live conversation)))))
           (unless (typep after '(integer 0))
             (error 'configuration-error :message "after must be a nonnegative integer."))
           (when conversation
             (conversation-replay--map-records
              conversation
              (lambda (record)
                (when (eq (first record) ':user-operation)
                  (setf context (remove record context :test #'equal)))
                (when (> (or (getf (rest record) :seq) 0) after)
                  (let ((projected (conversation-replay--project-record record)))
                    (when projected (push (event-json projected) events)))))))
           (json-object "events" (coerce (append (context-events context) (nreverse events)) 'vector)
                        "replaceEvents" (if (zerop after) t *json-decoded-false*))))
       (catalog ()
         ;; Unmanaged older sessions share the gateway's configured catalog.
         ;; A dedicated endpoint uses that session's live registrations.
         (when (json-get request "requireCurrent") (current-application))
         (unless application
           (error 'configuration-error :message "The management endpoint has no active application."))
         (json-object
          "models" (coerce (mapcar (lambda (item)
                                     (json-object "id" (getf item :name)
                                                  "provider" (getf item :group)
                                                  "description" (getf item :description)))
                                   (application--model-items application)) 'vector)
          "completions"
          (coerce (mapcar (lambda (item)
                            (json-object "name" (getf item :name)
                                         "hint" (or (getf item :argument) "")
                                         "description" (getf item :description)))
                          (append (application-operation-completion-entries application)
                                  (let ((entries nil))
                                    (do-external-symbols (symbol (find-package '#:cl) entries)
                                      (when (fboundp symbol)
                                        (push (list :name (format nil "(~(~A~)" symbol)
                                                    :argument "" :description "Common Lisp") entries))))))
                  'vector)))
       (spawn-session (resume-p)
         (let* ((directory (uiop:ensure-directory-pathname (required "workspace")))
                (mode (json-get request "permissions" "ask"))
                (permission-mode (cdr (assoc mode '(("ask" . :ask) ("auto" . :auto)
                                                    ("full" . :full-access)) :test #'equal)))
                (configuration (configuration-create :working-directory directory))
                (socket (required "managementSocket"))
                (token (namestring (configuration-management-repl-token-file-path
                                   (application-configuration application)))))
           (unless (uiop:directory-exists-p directory)
             (error 'configuration-error :message "Workspace directory does not exist."))
           (unless permission-mode
             (error 'configuration-error :message "Invalid permission mode."))
           (flet ((launch-managed (configuration launch-id handoff-path permission immutable-p)
                    ;; Use the existing launch hook and handoff format. The
                    ;; ordinary watchdog already supports explicit detachment.
                    (let ((record
                            (with-open-file (stream handoff-path)
                              (with-standard-io-syntax
                                (let ((*read-eval* nil)) (read stream))))))
                      (setf (getf (rest record) :attach-expected-p) nil)
                      (localgroup-handoff--write-record handoff-path record))
                    (let ((log (localgroup-handoff-log-pathname configuration launch-id)))
                      (ensure-directories-exist log)
                      (with-open-file (output log :direction ':output :if-exists ':append
                                                  :if-does-not-exist ':create :external-format ':utf-8)
                        (uiop:run-program (list "/bin/chmod" "600" (namestring log)))
                        (localgroup-handoff--launch-supervised
                         :arguments
                         (append (list "/usr/bin/env" "AUTOLITH_MANAGEMENT_REPL=on"
                                       "AUTOLITH_MANAGEMENT_REPL_TRANSPORT=unix"
                                       (concatenate 'string "AUTOLITH_MANAGEMENT_REPL_UNIX_SOCKET=" socket)
                                       (concatenate 'string "AUTOLITH_MANAGEMENT_REPL_TOKEN_FILE=" token)
                                       (namestring (localgroup-handoff--launcher-pathname configuration))
                                       "--permissions" permission)
                                 (when immutable-p (list "--immutable"))
                                 (list "--localgroup-handoff" (namestring handoff-path)))
                         :handoff-pathname handoff-path
                         :directory directory :output output)))))
             (let ((*localgroup-fresh-launch-function* #'launch-managed))
               (json-object "id" (localgroup-handoff-spawn-fresh
                                  configuration :permission-mode permission-mode
                                  :conversation-id (when resume-p (required "id")))))))))
    (json-encode
     (let ((operation (required "operation")))
       (cond
         ((string= operation "identity")
          (json-object "id" (application-session-id)))
         ((string= operation "list") (json-object "sessions" (sessions)))
         ((string= operation "transcript") (transcript))
         ((string= operation "catalog") (catalog))
         ((string= operation "create") (spawn-session nil))
         ((string= operation "resume") (spawn-session t))
         ((string= operation "delete")
          (conversation-delete configuration (required "id")) (json-object "ok" t))
         ((member operation '("tell" "pause" "kill") :test #'string=)
          (let* ((entry (localgroup--find-record configuration (required "id")))
                 (command (cond ((string= operation "tell") ':tell)
                                ((string= operation "pause") ':pause) (t ':kill))))
            (localgroup-query-record
             entry command
             (when (eq command ':tell)
               (let ((message (required "message")))
                 (when (and (terminal-ui--lisp-draft-p message)
                            (application-lisp-input-incomplete-p message))
                   (error 'configuration-error :message "The Lisp form is incomplete."))
                 (list :message message))))
          (json-object "ok" t)))
         (t (error 'configuration-error :message "Unsupported companion operation.")))))))
