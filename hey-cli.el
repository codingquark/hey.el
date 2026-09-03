;;; hey-cli.el --- Closed HEY CLI transport  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 codingquark
;; SPDX-License-Identifier: MIT

;; Author: Dhavan Vaidya <456712+codingquark@users.noreply.github.com>
;; Assisted-by: Codex:gpt-5
;; Keywords: mail
;; URL: https://github.com/codingquark/hey.el

;;; Commentary:

;; Exact, read-only command builders and the asynchronous process boundary for
;; the HEY reader.  This library intentionally has no generic public command
;; runner: only the named operations at the end of this file can start a
;; subprocess.  In posting responses, only a literal JSON true `seen' value
;; means read; false, null, a missing field, or any other value means unread.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'hey-model)

(defgroup hey nil
  "Read HEY mail in Emacs through the official CLI."
  :group 'applications
  :prefix "hey-")

(defcustom hey-executable nil
  "Absolute path to the official HEY executable.

When nil, resolve `hey' lazily through `executable-find'.  A non-nil
override must be an absolute, local executable path; an invalid override is
never replaced by an executable found elsewhere."
  :type '(choice (const :tag "Find hey in exec-path" nil) file)
  :group 'hey)

(defcustom hey-working-directory
  (file-name-as-directory
   (expand-file-name
    (cond
     ((and (getenv "XDG_STATE_HOME")
           (not (string-empty-p (getenv "XDG_STATE_HOME"))))
      "emacs/hey")
     ((eq system-type 'darwin)
      "Library/Application Support/Emacs/hey")
     (t ".local/state/emacs/hey"))
    (if (and (getenv "XDG_STATE_HOME")
             (not (string-empty-p (getenv "XDG_STATE_HOME"))))
        (getenv "XDG_STATE_HOME")
      (expand-file-name "~/"))))
  "Private local directory from which HEY subprocesses run.

The transport rejects a remote directory, a directory inside a Git worktree,
or a directory below an ancestor containing `.hey/config.json'."
  :type 'directory
  :group 'hey)

(defcustom hey-timeout-seconds 30
  "Seconds before a HEY subprocess is terminated."
  :type 'number
  :group 'hey)

(defcustom hey-max-output-bytes (* 4 1024 1024)
  "Maximum combined stdout and stderr bytes retained per request."
  :type 'integer
  :group 'hey)

(defconst hey-cli-minimum-version "1.4.0"
  "Oldest official HEY CLI version supported by this package.

The version preflight and discovery guidance both name this baseline.")

(defconst hey-cli--official-origin "https://app.hey.com"
  "The only server origin allowed by the v1 reader.")

(defconst hey-cli--removed-environment-variables
  '("HEY_TOKEN" "HEY_BASE_URL" "HEY_ACCOUNT_ID" "HEY_DEBUG" "HEY_THEME"
    "HEY_CABLE_URL" "HEY_SETUP_AGENT")
  "Inherited HEY variables that must not affect reader requests.")

(defvar hey-cli--process-counter 0)

(cl-defstruct (hey-cli--request (:constructor hey-cli--make-request))
  process
  stderr-process
  stdout-buffer
  stderr-buffer
  owner
  source-key
  generation
  success
  failure
  timer
  kill-hook
  operation
  started-at
  bytes
  completed
  canceled
  timed-out
  output-too-large)

(defun hey-cli--data-string (value description)
  "Return VALUE after validating it as a DESCRIPTION data string."
  (unless (and (stringp value)
               (not (string-empty-p value))
               (not (string-match-p "[\0-\x1f\x7f]" value)))
    (user-error "%s must be a non-empty string without control characters"
                description))
  value)

(defun hey-cli--positional-string (value description)
  "Return VALUE after validating it as positional DESCRIPTION data.

Closed builders never allow a server-provided identifier to be reinterpreted
as a Cobra flag.  Search text is the sole exception because it follows an
explicit `--' delimiter."
  (setq value (hey-cli--data-string value description))
  (when (string-prefix-p "-" value)
    (user-error "%s must not begin with a dash" description))
  value)

(defun hey-cli--search-page (page)
  "Return PAGE as a positive decimal string, or nil."
  (when page
    (unless (and (integerp page) (> page 0))
      (user-error "Search page must be a positive integer"))
    (number-to-string page)))

(defun hey-cli--base-argv ()
  "Return the fixed global argv prefix."
  (list "--base-url" hey-cli--official-origin))

(defun hey-cli--account-argv (account-id)
  "Return the fixed global argv prefix scoped to ACCOUNT-ID."
  (append (hey-cli--base-argv)
          (list "--account" (hey-cli--data-string account-id "Account ID"))))

(defun hey-cli--finish-argv (argv)
  "Append the sole supported output selector to ARGV."
  (append argv '("--json")))

;;; Pure closed command builders

(defun hey-cli-build-version ()
  "Build argv for the HEY version read."
  (hey-cli--finish-argv
   (append (hey-cli--base-argv) '("version"))))

(defun hey-cli-build-auth-status ()
  "Build argv for the HEY authentication status read."
  (hey-cli--finish-argv
   (append (hey-cli--base-argv) '("auth" "status"))))

(defun hey-cli-build-account-list ()
  "Build argv for listing linked HEY accounts."
  (hey-cli--finish-argv
   (append (hey-cli--base-argv) '("account" "list"))))

(defun hey-cli-build-box-list (account-id)
  "Build argv for listing boxes in ACCOUNT-ID."
  (hey-cli--finish-argv
   (append (hey-cli--account-argv account-id) '("box" "list"))))

(defun hey-cli-build-box-view (account-id box &optional page)
  "Build argv for reading BOX in ACCOUNT-ID, optionally at PAGE cursor."
  (hey-cli--finish-argv
   (append (hey-cli--account-argv account-id)
           (list "box" "view" (hey-cli--positional-string box "Box"))
           (when page
             (list "--page" (hey-cli--data-string page "Page cursor"))))))

(defun hey-cli-build-bundle-view (account-id posting-id &optional page)
  "Build argv for reading bundle POSTING-ID in ACCOUNT-ID at PAGE cursor."
  (hey-cli--finish-argv
   (append (hey-cli--account-argv account-id)
           (list "bundle" "view"
                 (hey-cli--positional-string posting-id "Posting ID"))
           (when page
             (list "--page" (hey-cli--data-string page "Page cursor"))))))

(defun hey-cli-build-search (account-id query &optional page)
  "Build argv for searching ACCOUNT-ID for QUERY, optionally at PAGE.

Every option precedes the literal `--', so a QUERY beginning with a dash is
always positional data."
  (let ((page-string (hey-cli--search-page page)))
    (append (hey-cli--account-argv account-id)
            '("search")
            (when page-string (list "--page" page-string))
            '("--json" "--")
            (list (hey-cli--data-string query "Search query")))))

(defun hey-cli-build-thread-read (account-id topic-id)
  "Build argv for reading TOPIC-ID in ACCOUNT-ID without marking it seen."
  (hey-cli--finish-argv
   (append (hey-cli--account-argv account-id)
           (list "thread" "read"
                 (hey-cli--positional-string topic-id "Topic ID")
                 "--allow-partial"))))

(defun hey-cli-build-label-list (account-id)
  "Build argv for listing labels in ACCOUNT-ID."
  (hey-cli--finish-argv
   (append (hey-cli--account-argv account-id) '("label" "list"))))

(defun hey-cli-build-label-view (account-id label-id &optional page)
  "Build argv for reading LABEL-ID in ACCOUNT-ID at optional PAGE cursor."
  (hey-cli--finish-argv
   (append (hey-cli--account-argv account-id)
           (list "label" "view"
                 (hey-cli--positional-string label-id "Label ID"))
           (when page
             (list "--page" (hey-cli--data-string page "Page cursor"))))))

(defun hey-cli-build-collection-list (account-id)
  "Build argv for listing collections in ACCOUNT-ID."
  (hey-cli--finish-argv
   (append (hey-cli--account-argv account-id) '("collection" "list"))))

(defun hey-cli-build-collection-view (account-id collection-id &optional page)
  "Build argv for reading COLLECTION-ID in ACCOUNT-ID at PAGE cursor."
  (hey-cli--finish-argv
   (append (hey-cli--account-argv account-id)
           (list "collection" "view"
                 (hey-cli--positional-string collection-id "Collection ID"))
           (when page
             (list "--page" (hey-cli--data-string page "Page cursor"))))))

;;; Process setup

(defun hey-cli--sanitized-environment ()
  "Return a safe per-request environment for noninteractive HEY access."
  (let ((process-environment (copy-sequence process-environment)))
    (dolist (name hey-cli--removed-environment-variables)
      (setenv name nil))
    ;; Deliberately do not remove HEY_NO_KEYRING: it selects the user's stored
    ;; credential backend rather than injecting credentials or an endpoint.
    (setenv "HEY_NONINTERACTIVE" "1")
    process-environment))

(defun hey-cli--unsafe-working-ancestor (directory)
  "Return an unsafe ancestor of DIRECTORY, or nil.

Git worktrees and repository-local HEY configuration are both excluded."
  (let ((current (file-name-as-directory (expand-file-name directory)))
        parent
        found)
    (while (and current (not found))
      (when (or (file-exists-p (expand-file-name ".git" current))
                (file-exists-p (expand-file-name ".hey/config.json" current)))
        (setq found current))
      (setq parent (file-name-directory (directory-file-name current)))
      (setq current (unless (or found (equal current parent)) parent)))
    found))

(defun hey-cli--working-directory-ancestors (directory)
  "Return DIRECTORY and its ancestors, ordered from root to leaf."
  (let ((current (file-name-as-directory (expand-file-name directory)))
        ancestors
        parent)
    (while current
      (push current ancestors)
      (setq parent (file-name-directory (directory-file-name current)))
      (setq current (unless (equal current parent) parent)))
    ancestors))

(defun hey-cli--verify-working-ancestor (directory)
  "Reject DIRECTORY unless it is a trusted, non-writable local directory.

Directories owned by the current user or root are trusted.  Group- or
world-writable directories are rejected, except for root-owned sticky
directories such as `/tmp'."
  (when (or (file-remote-p directory) (file-symlink-p directory))
    (error "HEY working directory has an unsafe symlink or remote ancestor"))
  (let* ((attributes (file-attributes directory 'integer))
         (owner (and attributes (file-attribute-user-id attributes)))
         (modes (and attributes (file-modes directory)))
         (current-owner (user-uid)))
    (unless (and attributes
                 (eq (file-attribute-type attributes) t)
                 (integerp modes))
      (error "HEY working directory ancestor is not a local directory"))
    (unless (or (equal owner current-owner) (equal owner 0))
      (error "HEY working directory has an untrusted owner"))
    (unless (or (zerop (logand modes #o022))
                (and (equal owner 0)
                     (not (zerop (logand modes #o1000)))))
      (error "HEY working directory has a writable shared ancestor"))))

(defun hey-cli--verify-working-tree (directory)
  "Verify every canonical ancestor of DIRECTORY."
  (dolist (ancestor (hey-cli--working-directory-ancestors directory))
    (hey-cli--verify-working-ancestor ancestor)))

(defun hey-cli--working-directory-base (directory)
  "Return canonical existing base and missing components for DIRECTORY.

The result is a cons whose car is the nearest existing ancestor's truename
and whose cdr lists the components that still need to be created."
  (let ((probe (directory-file-name directory))
        missing
        parent)
    (while (not (file-exists-p probe))
      (when (file-symlink-p probe)
        (error "HEY working directory contains a dangling symlink"))
      (push (file-name-nondirectory probe) missing)
      (setq parent (file-name-directory probe))
      (when (or (null parent)
                (equal (directory-file-name parent) probe))
        (error "HEY working directory has no usable local ancestor"))
      (setq probe (directory-file-name parent)))
    (unless (file-directory-p probe)
      (error "HEY working directory ancestor is not a directory"))
    (cons (file-name-as-directory (file-truename probe)) missing)))

(defun hey-cli--prepare-working-directory ()
  "Validate, create, and return the neutral HEY working directory."
  (unless (and (stringp hey-working-directory)
               (file-name-absolute-p hey-working-directory)
               (not (file-remote-p hey-working-directory)))
    (error "HEY working directory must be an absolute local path"))
  (let ((expanded (file-name-as-directory
                   (expand-file-name hey-working-directory))))
    ;; Never chmod or otherwise follow a caller-supplied final symlink.
    (when (file-symlink-p (directory-file-name expanded))
      (error "HEY working directory must not be a symlink"))
    (pcase-let* ((`(,base . ,missing)
                  (hey-cli--working-directory-base expanded))
                 (directory base))
      ;; Resolve conventional, trusted system aliases (for example macOS
      ;; /var) once, then operate only on the canonical path.  Security checks
      ;; below prevent traversal through mutable shared or foreign-owned
      ;; ancestors.
      (hey-cli--verify-working-tree directory)
      (dolist (component missing)
        (setq directory
              (file-name-as-directory (expand-file-name component directory)))
        (when (file-symlink-p (directory-file-name directory))
          (error "HEY working directory contains a symlink"))
        (if (file-exists-p directory)
            (hey-cli--verify-working-ancestor directory)
          (make-directory directory)
          (set-file-modes directory #o700)
          (hey-cli--verify-working-ancestor directory)))
      (setq directory (file-name-as-directory (file-truename directory)))
      (when (or (file-remote-p directory)
                (hey-cli--unsafe-working-ancestor directory))
        (error "HEY working directory resolves to an unsafe location"))
      (hey-cli--verify-working-tree directory)
      (let* ((attributes (file-attributes directory 'integer))
             (owner (and attributes (file-attribute-user-id attributes))))
        (unless (equal owner (user-uid))
          (error "HEY working directory must be owned by the current user")))
      (set-file-modes directory #o700)
      ;; Re-stat after chmod.  This both verifies the intended privacy mode and
      ;; catches a replacement of the leaf during preparation.  Trusted,
      ;; non-writable ancestors make a later replacement impractical for a
      ;; different local user before `make-process' opens the directory.
      (unless (and (not (file-symlink-p (directory-file-name directory)))
                   (equal (file-attribute-user-id
                           (file-attributes directory 'integer))
                          (user-uid))
                   (zerop (logand (file-modes directory) #o077)))
        (error "HEY working directory changed during secure preparation"))
      directory)))

;; Executable messages are package-owned prose: they name the option to change
;; and the action to take, never a candidate path or operating-system error.

(define-error
  'hey-cli-executable-missing
  (format "HEY CLI was not found in `exec-path'. Install HEY CLI %s or newer \
and restart Emacs, or set `hey-executable'." hey-cli-minimum-version)
  'error)

(define-error
  'hey-cli-executable-configured
  "Configured `hey-executable' is not a local executable file. Set an absolute \
path, or nil to search `exec-path'; no fallback is taken."
  'error)

(defconst hey-cli--vanished-message
  "The HEY executable became unavailable as the request started. Reinstall it, \
or set `hey-executable'."
  "Failure when a validated executable disappears before startup.")

(defconst hey-cli--start-message
  "HEY process could not be started."
  "Generic failure for any other subprocess startup error.")

(defun hey-cli--executable-available-p (candidate)
  "Return non-nil when absolute local CANDIDATE is a regular executable file."
  (condition-case nil
      (and (stringp candidate)
           (file-name-absolute-p candidate)
           (not (file-remote-p candidate))
           (file-regular-p candidate)
           (file-executable-p candidate))
    (error nil)))

(defun hey-cli--resolve-executable ()
  "Return a validated absolute path to the HEY executable.

With nil `hey-executable' discover `hey' through option `exec-path'; a
configured override is never replaced by a discovered program.  An unusable
candidate signals `hey-cli-executable-missing' or
`hey-cli-executable-configured'."
  (let ((candidate
         (if hey-executable
             (and (stringp hey-executable) hey-executable)
           (executable-find "hey"))))
    (unless (hey-cli--executable-available-p candidate)
      (signal (if hey-executable
                  'hey-cli-executable-configured
                'hey-cli-executable-missing)
              nil))
    (file-truename candidate)))

(defun hey-cli--owner-default-directory-local-p (owner)
  "Return non-nil when OWNER has a local `default-directory'."
  (and (buffer-live-p owner)
       (let ((directory (buffer-local-value 'default-directory owner)))
         (and (stringp directory) (not (file-remote-p directory))))))

(defun hey-cli--make-error (category message &optional code hint exit-status)
  "Create a sanitized `hey-error' from CATEGORY, MESSAGE, CODE, and HINT.

Record EXIT-STATUS when a subprocess supplied one."
  (make-hey-error
   :category category
   :message (hey-model-sanitize-metadata message)
   :code (and (stringp code) (hey-model-sanitize-metadata code))
   :hint (and (stringp hint) (hey-model-sanitize-metadata hint))
   :exit-status exit-status))

(defun hey-cli--log (operation exit-status category duration &optional stderr-p)
  "Append one redacted diagnostic for OPERATION.

EXIT-STATUS, CATEGORY, DURATION, and STDERR-P contain no command arguments or
server data."
  (let ((buffer (get-buffer-create "*hey-log*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode)
        (buffer-disable-undo))
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "operation=%s duration=%.3fs exit=%s category=%s%s\n"
                        operation duration
                        (if (numberp exit-status) exit-status "none")
                        category
                        (if stderr-p " stderr=yes" "")))))))

(defun hey-cli--buffer-string (buffer)
  "Return BUFFER contents without text properties."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer
        (buffer-substring-no-properties (point-min) (point-max)))
    ""))

(defun hey-cli--json-to-alists (value)
  "Convert hash-table JSON VALUE recursively to string-keyed alists."
  (cond
   ((hash-table-p value)
    (let (result)
      (maphash (lambda (key item)
                 (push (cons key (hey-cli--json-to-alists item)) result))
               value)
      (nreverse result)))
   ((listp value) (mapcar #'hey-cli--json-to-alists value))
   (t value)))

(defun hey-cli--parse-json (string)
  "Parse STRING into the frozen HEY JSON representation."
  (hey-cli--json-to-alists
   (json-parse-string string
                      :object-type 'hash-table
                      :array-type 'list
                      :null-object nil
                      :false-object 'hey-json-false)))

(defun hey-cli--field (name object)
  "Return string-keyed NAME from alist OBJECT."
  (cdr (assoc name object)))

(defun hey-cli--success-envelope-p (value)
  "Return non-nil when VALUE is one successful HEY envelope."
  (and (listp value) (eq (hey-cli--field "ok" value) t)))

(defun hey-cli--error-envelope-p (value)
  "Return non-nil when VALUE is one structured HEY error envelope."
  (and (listp value)
       (eq (hey-cli--field "ok" value) 'hey-json-false)
       (stringp (hey-cli--field "error" value))
       (stringp (hey-cli--field "code" value))))

(defun hey-cli--exit-category (status)
  "Return the documented error category for exit STATUS."
  (alist-get status '((1 . usage) (2 . not-found) (3 . auth)
                      (4 . forbidden) (5 . rate-limit) (6 . network)
                      (7 . api) (8 . ambiguous))
            'cli-exit))

(defun hey-cli--delete-request-buffers (request)
  "Delete REQUEST's private processes and capture buffers."
  (dolist (process (list (hey-cli--request-process request)
                         (hey-cli--request-stderr-process request)))
    (when (processp process)
      (ignore-errors (delete-process process))))
  (dolist (buffer (list (hey-cli--request-stdout-buffer request)
                        (hey-cli--request-stderr-buffer request)))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun hey-cli--remove-kill-hook (request)
  "Remove REQUEST's owner-buffer kill hook."
  (let ((owner (hey-cli--request-owner request))
        (hook (hey-cli--request-kill-hook request)))
    (when (and hook (buffer-live-p owner))
      (with-current-buffer owner
        (remove-hook 'kill-buffer-hook hook t)))))

(defun hey-cli--deliver (request success value category exit-status stderr-p)
  "Complete REQUEST once, delivering VALUE according to SUCCESS.

CATEGORY and EXIT-STATUS are used only for redacted diagnostics."
  (unless (hey-cli--request-completed request)
    (setf (hey-cli--request-completed request) t)
    (when (timerp (hey-cli--request-timer request))
      (cancel-timer (hey-cli--request-timer request)))
    (hey-cli--remove-kill-hook request)
    (hey-cli--log
     (hey-cli--request-operation request) exit-status category
     (- (float-time) (hey-cli--request-started-at request)) stderr-p)
    (unwind-protect
        (let ((owner (hey-cli--request-owner request))
              (callback (if success
                            (hey-cli--request-success request)
                          (hey-cli--request-failure request))))
          (when (and (buffer-live-p owner) (functionp callback))
            (condition-case nil
                (funcall callback value)
              (error
               (hey-cli--log (hey-cli--request-operation request) exit-status
                             'callback-error 0 nil)))))
      ;; Callback `quit', `throw', and other nonlocal exits must never retain
      ;; raw stdout or stderr in the private capture buffers.
      (hey-cli--delete-request-buffers request))))

(defun hey-cli--abort-request-setup (request process stderr-process)
  "Clean up REQUEST after setup aborts using PROCESS and STDERR-PROCESS."
  ;; Mark completion before deleting either process: deletion can run the
  ;; sentinel synchronously, and an incompletely installed request must not
  ;; call application callbacks.
  (setf (hey-cli--request-completed request) t)
  (when (processp process)
    (setf (hey-cli--request-process request) process))
  (when (processp stderr-process)
    (setf (hey-cli--request-stderr-process request) stderr-process))
  (when (timerp (hey-cli--request-timer request))
    (cancel-timer (hey-cli--request-timer request)))
  (hey-cli--remove-kill-hook request)
  (hey-cli--delete-request-buffers request))

(defun hey-cli--capture (request buffer chunk)
  "Capture CHUNK for REQUEST in BUFFER without crossing the byte limit."
  (unless (hey-cli--request-completed request)
    (let ((total (+ (or (hey-cli--request-bytes request) 0)
                    (string-bytes chunk))))
      (setf (hey-cli--request-bytes request) total)
      (if (> total hey-max-output-bytes)
          (progn
            (setf (hey-cli--request-output-too-large request) t)
            (let ((process (hey-cli--request-process request)))
              (when (process-live-p process)
                (delete-process process))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert chunk)))))))

(defun hey-cli--structured-cli-error (stderr status)
  "Return a `hey-error' from structured STDERR for exit STATUS, or nil."
  (condition-case nil
      (let ((envelope (hey-cli--parse-json stderr)))
        (when (hey-cli--error-envelope-p envelope)
          (hey-cli--make-error
           (hey-cli--exit-category status)
           (hey-cli--field "error" envelope)
           (hey-cli--field "code" envelope)
           (hey-cli--field "hint" envelope)
           status)))
    (error nil)))

(defun hey-cli--sentinel (request process _event)
  "Complete REQUEST when PROCESS reaches a terminal state."
  (when (memq (process-status process) '(exit signal))
    (condition-case nil
        (let* ((status (process-exit-status process))
               (stdout (hey-cli--buffer-string
                        (hey-cli--request-stdout-buffer request)))
               (stderr (hey-cli--buffer-string
                        (hey-cli--request-stderr-buffer request)))
               (stderr-p (not (string-empty-p stderr))))
          (cond
           ((hey-cli--request-output-too-large request)
            (hey-cli--deliver
             request nil
             (hey-cli--make-error 'output-limit
                                  "HEY output exceeded the configured limit."
                                  nil nil status)
             'output-limit status stderr-p))
           ((hey-cli--request-timed-out request)
            (hey-cli--deliver
             request nil
             (hey-cli--make-error 'timeout "HEY request timed out."
                                  nil nil status)
             'timeout status stderr-p))
           ((hey-cli--request-canceled request)
            (hey-cli--deliver
             request nil
             (hey-cli--make-error 'canceled "HEY request was canceled."
                                  nil nil status)
             'canceled status stderr-p))
           ((eq (process-status process) 'signal)
            (hey-cli--deliver
             request nil
             (hey-cli--make-error 'signal "HEY process ended after a signal."
                                  nil nil status)
             'signal status stderr-p))
           ((zerop status)
            (condition-case nil
                (let ((envelope (hey-cli--parse-json stdout)))
                  (if (hey-cli--success-envelope-p envelope)
                      (hey-cli--deliver request t envelope 'success status stderr-p)
                    (hey-cli--deliver
                     request nil
                     (hey-cli--make-error
                      'protocol "HEY returned an unsuccessful success envelope."
                      nil nil status)
                     'protocol status stderr-p)))
              (error
               (hey-cli--deliver
                request nil
                (hey-cli--make-error 'malformed-json
                                     "HEY returned malformed JSON."
                                     nil nil status)
                'malformed-json status stderr-p))))
           ((not (string-empty-p (string-trim stdout)))
            (hey-cli--deliver
             request nil
             (hey-cli--make-error 'cli-exit
                                  "HEY failed with unexpected standard output."
                                  nil nil status)
             'cli-exit status stderr-p))
           (t
            (let ((error (hey-cli--structured-cli-error stderr status)))
              (if error
                  (hey-cli--deliver request nil error
                                    (hey-error-category error) status stderr-p)
                (hey-cli--deliver
                 request nil
                 (hey-cli--make-error 'cli-exit
                                      "HEY failed without a valid error envelope."
                                      nil nil status)
                 'cli-exit status stderr-p))))))
      (error
       (hey-cli--deliver
        request nil
        (hey-cli--make-error 'process "HEY process completion failed safely.")
        'process nil nil)))))

(defun hey-cli--timeout (request)
  "Terminate REQUEST and classify its eventual completion as a timeout."
  (unless (hey-cli--request-completed request)
    (let ((process (hey-cli--request-process request)))
      (when (process-live-p process)
        (setf (hey-cli--request-timed-out request) t)
        (delete-process process)))))

(defun hey-cli-cancel-request (request)
  "Cancel an asynchronous HEY REQUEST.

Its failure callback receives a `hey-error' in the `canceled' category if the
owner buffer is still live.  UI source and generation checks remain the final
guard against stale state updates."
  (when (and (hey-cli--request-p request)
             (not (hey-cli--request-completed request)))
    (setf (hey-cli--request-canceled request) t)
    (let ((process (hey-cli--request-process request)))
      (when (process-live-p process)
        (delete-process process))))
  nil)

(defun hey-cli--configuration-failure (operation owner failure message)
  "Report configuration MESSAGE for OPERATION to OWNER through FAILURE."
  (hey-cli--log operation nil 'configuration 0 nil)
  (when (and (buffer-live-p owner) (functionp failure))
    (funcall failure (hey-cli--make-error 'configuration message))))

(defun hey-cli--start-failure-message (err executable)
  "Return package-owned prose for setup error ERR and resolved EXECUTABLE.

Only a `file-missing' whose EXECUTABLE no longer validates counts as vanished:
the operating system may otherwise be naming the working directory."
  (if (and (eq (car-safe err) 'file-missing)
           (not (hey-cli--executable-available-p executable)))
      hey-cli--vanished-message
    hey-cli--start-message))

(defun hey-cli--start-process
    (operation argv owner source-key generation success failure)
  "Start one closed read OPERATION with ARGV for OWNER.

SOURCE-KEY and GENERATION are retained with the request so the UI can pair the
returned request with its immutable session state.  SUCCESS receives a parsed
success envelope.  FAILURE receives a `hey-error'."
  (cond
   ((not (buffer-live-p owner)) nil)
   ((not (hey-cli--owner-default-directory-local-p owner))
    (hey-cli--configuration-failure
     operation owner failure "HEY requests cannot originate in remote buffers.")
    nil)
   (t
    (condition-case err
        (let* ((executable (hey-cli--resolve-executable))
               (working-directory (hey-cli--prepare-working-directory))
               (name (format "hey-%s-%d" operation
                             (cl-incf hey-cli--process-counter)))
               (stdout-buffer (generate-new-buffer (format " *%s-out*" name)))
               (stderr-buffer (generate-new-buffer (format " *%s-err*" name)))
               (request (hey-cli--make-request
                         :stdout-buffer stdout-buffer
                         :stderr-buffer stderr-buffer
                         :owner owner
                         :source-key source-key
                         :generation generation
                         :success success
                         :failure failure
                         :operation operation
                         :started-at (float-time)
                         :bytes 0))
               stderr-process process kill-hook setup-complete)
          (unwind-protect
              (condition-case err
                  (let ((default-directory working-directory)
                        (process-environment (hey-cli--sanitized-environment)))
                    (setq stderr-process
                          (make-pipe-process
                           :name (concat name "-stderr")
                           :buffer nil
                           :coding 'utf-8-unix
                           :noquery t
                           :filter (lambda (_process chunk)
                                     (hey-cli--capture request stderr-buffer chunk))))
                    (setf (hey-cli--request-stderr-process request) stderr-process)
                    (setq process
                          (make-process
                           :name name
                           :buffer nil
                           :command (cons executable argv)
                           :coding 'utf-8-unix
                           :connection-type 'pipe
                           :noquery t
                           :stderr stderr-process
                           :filter (lambda (_process chunk)
                                     (hey-cli--capture request stdout-buffer chunk))
                           :sentinel (lambda (finished-process event)
                                       (hey-cli--sentinel request finished-process
                                                          event))))
                    (setf (hey-cli--request-process request) process)
                    (setq kill-hook
                          (lambda ()
                            ;; A process sentinel can run before `kill-buffer'
                            ;; finishes.  Clear the owner first so that completion
                            ;; still cannot call into a dying buffer.
                            (setf (hey-cli--request-owner request) nil)
                            (hey-cli-cancel-request request)))
                    (setf (hey-cli--request-kill-hook request) kill-hook)
                    (with-current-buffer owner
                      (add-hook 'kill-buffer-hook kill-hook nil t))
                    (setf (hey-cli--request-timer request)
                          (run-at-time hey-timeout-seconds nil
                                       #'hey-cli--timeout request))
                    (setq setup-complete t)
                    request)
                (error
                 (hey-cli--abort-request-setup request process stderr-process)
                 (hey-cli--configuration-failure
                  operation owner failure
                  (hey-cli--start-failure-message err executable))
                 nil))
            ;; Also covers `quit' and a caller's nonlocal exit while setup is
            ;; in progress; neither can leave the just-created CLI orphaned.
            (unless setup-complete
              (hey-cli--abort-request-setup request process stderr-process))))
      ((hey-cli-executable-missing hey-cli-executable-configured)
       (hey-cli--configuration-failure
        operation owner failure (get (car err) 'error-message))
       nil)
      (error
       (hey-cli--configuration-failure
        operation owner failure "HEY transport configuration is invalid.")
       nil)))))

;;; Named asynchronous operations

(defun hey-cli-version (owner source-key generation success failure)
  "Read HEY version for OWNER, tagged SOURCE-KEY and GENERATION.

Deliver the result through SUCCESS or FAILURE."
  (hey-cli--start-process 'version (hey-cli-build-version)
                          owner source-key generation success failure))

(defun hey-cli-auth-status (owner source-key generation success failure)
  "Read authentication status for OWNER, tagged SOURCE-KEY and GENERATION.

Deliver the result through SUCCESS or FAILURE."
  (hey-cli--start-process 'auth-status (hey-cli-build-auth-status)
                          owner source-key generation success failure))

(defun hey-cli-account-list (owner source-key generation success failure)
  "List accounts for OWNER, tagged SOURCE-KEY and GENERATION.

Deliver the result through SUCCESS or FAILURE."
  (hey-cli--start-process 'account-list (hey-cli-build-account-list)
                          owner source-key generation success failure))

(defun hey-cli-box-list
    (account-id owner source-key generation success failure)
  "List boxes for ACCOUNT-ID and OWNER, tagged SOURCE-KEY and GENERATION.

Deliver the result through SUCCESS or FAILURE."
  (hey-cli--start-process 'box-list (hey-cli-build-box-list account-id)
                          owner source-key generation success failure))

(defun hey-cli-box-view
    (account-id box page owner source-key generation success failure)
  "Read BOX and PAGE in ACCOUNT-ID for OWNER, tagged SOURCE-KEY and GENERATION.

PAGE may be nil.  Deliver the result through SUCCESS or FAILURE."
  (hey-cli--start-process 'box-view
                          (hey-cli-build-box-view account-id box page)
                          owner source-key generation success failure))

(defun hey-cli-bundle-view
    (account-id posting-id page owner source-key generation success failure)
  "Read POSTING-ID and PAGE in ACCOUNT-ID for OWNER.

PAGE may be nil.  Tag the request with SOURCE-KEY and GENERATION, and deliver
the result through SUCCESS or FAILURE."
  (hey-cli--start-process 'bundle-view
                          (hey-cli-build-bundle-view account-id posting-id page)
                          owner source-key generation success failure))

(defun hey-cli-search
    (account-id query page owner source-key generation success failure)
  "Search ACCOUNT-ID for QUERY at PAGE for OWNER.

PAGE may be nil.  Tag the request with SOURCE-KEY and GENERATION, and deliver
the result through SUCCESS or FAILURE."
  (hey-cli--start-process 'search
                          (hey-cli-build-search account-id query page)
                          owner source-key generation success failure))

(defun hey-cli-thread-read
    (account-id topic-id owner source-key generation success failure)
  "Read TOPIC-ID in ACCOUNT-ID for OWNER, tagged SOURCE-KEY and GENERATION.

Deliver the result through SUCCESS or FAILURE."
  (hey-cli--start-process 'thread-read
                          (hey-cli-build-thread-read account-id topic-id)
                          owner source-key generation success failure))

(defun hey-cli-label-list
    (account-id owner source-key generation success failure)
  "List labels in ACCOUNT-ID for OWNER, tagged SOURCE-KEY and GENERATION.

Deliver the result through SUCCESS or FAILURE."
  (hey-cli--start-process 'label-list (hey-cli-build-label-list account-id)
                          owner source-key generation success failure))

(defun hey-cli-label-view
    (account-id label-id page owner source-key generation success failure)
  "Read LABEL-ID and PAGE in ACCOUNT-ID for OWNER.

PAGE may be nil.  Tag the request with SOURCE-KEY and GENERATION, and deliver
the result through SUCCESS or FAILURE."
  (hey-cli--start-process 'label-view
                          (hey-cli-build-label-view account-id label-id page)
                          owner source-key generation success failure))

(defun hey-cli-collection-list
    (account-id owner source-key generation success failure)
  "List collections in ACCOUNT-ID for OWNER, tagged SOURCE-KEY and GENERATION.

Deliver the result through SUCCESS or FAILURE."
  (hey-cli--start-process
   'collection-list (hey-cli-build-collection-list account-id)
   owner source-key generation success failure))

(defun hey-cli-collection-view
    (account-id collection-id page owner source-key generation success failure)
  "Read COLLECTION-ID and PAGE in ACCOUNT-ID for OWNER.

PAGE may be nil.  Tag the request with SOURCE-KEY and GENERATION, and deliver
the result through SUCCESS or FAILURE."
  (hey-cli--start-process
   'collection-view
   (hey-cli-build-collection-view account-id collection-id page)
   owner source-key generation success failure))

(provide 'hey-cli)
;;; hey-cli.el ends here
