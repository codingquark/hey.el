;;; hey-cli-test.el --- Tests for the closed HEY CLI lane  -*- lexical-binding: t; -*-

;;; Commentary:

;; Builder and process tests.  No test resolves or executes an installed HEY
;; binary; every successful spawn goes through `hey-test-fake-executable'.

;;; Code:

(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'hey-cli)
(require 'hey-test-helper)

(defconst hey-cli-test--origin-prefix
  '("--base-url" "https://app.hey.com")
  "Expected immutable origin prefix in every builder test.")

(ert-deftest hey-cli-builds-exact-unscoped-read-argv ()
  (should (equal (hey-cli-build-version)
                 '("--base-url" "https://app.hey.com" "version" "--json")))
  (should (equal (hey-cli-build-auth-status)
                 '("--base-url" "https://app.hey.com"
                   "auth" "status" "--json")))
  (should (equal (hey-cli-build-account-list)
                 '("--base-url" "https://app.hey.com"
                   "account" "list" "--json"))))

(ert-deftest hey-cli-builds-exact-account-scoped-read-argv ()
  (let ((prefix '("--base-url" "https://app.hey.com"
                  "--account" "account-17")))
    (should (equal (hey-cli-build-box-list "account-17")
                   (append prefix '("box" "list" "--json"))))
    (should (equal (hey-cli-build-box-view "account-17" "imbox")
                   (append prefix '("box" "view" "imbox" "--json"))))
    (should (equal (hey-cli-build-box-view "account-17" "feedbox" "opaque-2")
                   (append prefix '("box" "view" "feedbox"
                                    "--page" "opaque-2" "--json"))))
    (should (equal (hey-cli-build-bundle-view "account-17" "posting-3")
                   (append prefix '("bundle" "view" "posting-3" "--json"))))
    (should (equal
             (hey-cli-build-bundle-view "account-17" "posting-3" "cursor/4?x=y")
             (append prefix '("bundle" "view" "posting-3"
                              "--page" "cursor/4?x=y" "--json"))))
    (should (equal
             (hey-cli-build-contact-threads
              "account-17" "contact-4" "cursor/5?x=y")
             (append prefix '("contact" "threads" "contact-4"
                              "--page" "cursor/5?x=y" "--json"))))
    (should (equal (hey-cli-build-thread-read "account-17" "topic-5")
                   (append prefix '("thread" "read" "topic-5"
                                    "--allow-partial" "--json"))))
    (should (equal (hey-cli-build-label-list "account-17")
                   (append prefix '("label" "list" "--json"))))
    (should (equal (hey-cli-build-label-view "account-17" "label-6" "next-7")
                   (append prefix '("label" "view" "label-6"
                                    "--page" "next-7" "--json"))))
    (should (equal (hey-cli-build-collection-list "account-17")
                   (append prefix '("collection" "list" "--json"))))
    (should (equal
             (hey-cli-build-collection-view
              "account-17" "collection-8" "next-9")
             (append prefix '("collection" "view" "collection-8"
                              "--page" "next-9" "--json"))))))

(ert-deftest hey-cli-search-protects-leading-dash-and-unicode-query ()
  (should
   (equal (hey-cli-build-search "all" "--from Café ☕" 3)
          '("--base-url" "https://app.hey.com" "--account" "all"
            "search" "--page" "3" "--json" "--" "--from Café ☕"))))

(ert-deftest hey-cli-builders-reject-invalid-data ()
  (dolist (value '(nil "" "line\nbreak" "nul\0byte"))
    (should-error (hey-cli-build-box-list value))
    (should-error (hey-cli-build-box-view "account-17" value))
    (should-error (hey-cli-build-contact-threads "account-17" value))
    (should-error (hey-cli-build-thread-read "account-17" value)))
  (should-error (hey-cli-build-box-view "account-17" "imbox" ""))
  (dolist (value '("--help" "-1"))
    (should-error (hey-cli-build-box-view "account-17" value))
    (should-error (hey-cli-build-bundle-view "account-17" value))
    (should-error (hey-cli-build-contact-threads "account-17" value))
    (should-error (hey-cli-build-thread-read "account-17" value))
    (should-error (hey-cli-build-label-view "account-17" value))
    (should-error (hey-cli-build-collection-view "account-17" value)))
  (should-error (hey-cli-build-search "account-17" "query" 0))
  (should-error (hey-cli-build-search "account-17" "query" "2")))

(ert-deftest hey-cli-builders-expose-no-write-operation ()
  (let ((builders
         (seq-filter
          (lambda (symbol)
            (string-prefix-p "hey-cli-build-" (symbol-name symbol)))
          (apropos-internal "^hey-cli-build-" #'fboundp)))
        (forbidden '("compose" "reply" "forward" "draft" "seen" "unseen"
                     "move" "bubble" "trash" "spam" "ignore" "share"
                     "unshare" "approve" "deny" "add" "create" "update"
                     "delete" "remove" "send")))
    (should (= (length builders) 13))
    (dolist (builder builders)
      (let ((name (symbol-name builder)))
        (dolist (verb forbidden)
          (should-not (string-match-p (concat "-" verb "\\(?:-\\|$\\)") name)))))))

(defun hey-cli-test--start-version (owner success failure)
  "Start a version request for OWNER with SUCCESS and FAILURE callbacks."
  (hey-cli-version owner '(test-source) 1 success failure))

(defun hey-cli-test--live-processes ()
  "Return live HEY transport processes, which no completed test may leave."
  (cl-loop for process in (process-list)
           when (and (process-live-p process)
                     (string-match-p "\\`hey-" (process-name process)))
           collect process))

(defun hey-cli-test--transport-buffers ()
  "Return private HEY capture buffers, which no completed test may leave."
  (cl-loop for buffer in (buffer-list)
           when (string-match-p "\\` *hey-.*-\\(?:out\\|err\\)\\*\\'"
                                (buffer-name buffer))
           collect buffer))

(defvar hey-cli-test--discovered nil
  "Commands the stubbed `executable-find' was asked about.")

(defmacro hey-cli-test--stub-discovery (result &rest body)
  "Run BODY with `executable-find' returning RESULT for \"hey\".

Every requested command is recorded in `hey-cli-test--discovered'."
  (declare (indent 1) (debug (form body)))
  `(let ((hey-cli-test--discovered '()))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (command)
                  (push command hey-cli-test--discovered)
                  (and (string= command "hey") ,result))))
       ,@body)))

(defun hey-cli-test--fail-version (owner)
  "Return OWNER's `hey-error' from a version request that must not start."
  (let (failure)
    (should-not (hey-cli-test--start-version
                 owner
                 (lambda (_value) (ert-fail "Unexpected transport success"))
                 (lambda (error) (setq failure error))))
    (should failure)
    (should-not (hey-cli-test--live-processes))
    (should-not (hey-cli-test--transport-buffers))
    failure))

(defun hey-cli-test--assert-failure (failure patterns)
  "Assert FAILURE is a configuration failure matching every PATTERNS entry.

Package-owned prose names no path or operating-system detail; the list owns
the retry instruction."
  (should (eq (hey-error-category failure) 'configuration))
  (let ((message (hey-error-message failure)))
    (dolist (pattern patterns)
      (should (string-match-p pattern message)))
    (should-not (string-match-p "/" message))
    (should-not (string-match-p "retry" message))
    (should (string= message (hey-model-sanitize-metadata message)))))

(ert-deftest hey-cli-transport-parses-success-envelope ()
  (hey-test-with-fake '(:scenario "success")
    (let ((owner (generate-new-buffer " *hey-owner*")) result failure)
      (unwind-protect
          (progn
            (hey-cli-test--start-version
             owner (lambda (value) (setq result value))
             (lambda (error) (setq failure error)))
            (hey-test-await (lambda () (or result failure)))
            (should-not failure)
            (should (eq (cdr (assoc "ok" result)) t))
            (should (equal (cdr (assoc "id" (car (cdr (assoc "data" result)))))
                           "synthetic-posting-17")))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-transport-reassembles-chunked-unicode-json ()
  (hey-test-with-fake '(:scenario "chunked")
    (let ((owner (generate-new-buffer " *hey-owner*")) result failure)
      (unwind-protect
          (progn
            (hey-cli-test--start-version
             owner (lambda (value) (setq result value))
             (lambda (error) (setq failure error)))
            (hey-test-await (lambda () (or result failure)))
            (should-not failure)
            (should (equal
                     (cdr (assoc "name" (car (cdr (assoc "data" result)))))
                     "Café ☕")))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-transport-reports-malformed-json ()
  (hey-test-with-fake '(:scenario "malformed")
    (let ((owner (generate-new-buffer " *hey-owner*")) result failure)
      (unwind-protect
          (progn
            (hey-cli-test--start-version
             owner (lambda (value) (setq result value))
             (lambda (error) (setq failure error)))
            (hey-test-await (lambda () (or result failure)))
            (should-not result)
            (should (eq (hey-error-category failure) 'malformed-json)))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-transport-maps-documented-and-unknown-exits ()
  (let ((categories '((1 . usage) (2 . not-found) (3 . auth)
                      (4 . forbidden) (5 . rate-limit) (6 . network)
                      (7 . api) (8 . ambiguous) (9 . cli-exit))))
    (dolist (entry categories)
      (hey-test-with-fake
          (list :scenario (if (= (car entry) 9)
                              "error-unknown"
                            (format "error-%d" (car entry))))
        (let ((owner (generate-new-buffer " *hey-owner*")) result failure)
          (unwind-protect
              (progn
                (hey-cli-test--start-version
                 owner (lambda (value) (setq result value))
                 (lambda (error) (setq failure error)))
                (hey-test-await (lambda () (or result failure)))
                (should-not result)
                (should (eq (hey-error-category failure) (cdr entry)))
                (should (= (hey-error-exit-status failure) (car entry)))
                (should (equal (hey-error-code failure) "synthetic_failure")))
            (when (buffer-live-p owner) (kill-buffer owner))))))))

(ert-deftest hey-cli-transport-allows-success-with-redacted-stderr-note ()
  (hey-test-with-fake '(:scenario "stderr-success")
    (when (get-buffer "*hey-log*") (kill-buffer "*hey-log*"))
    (let ((owner (generate-new-buffer " *hey-owner*")) result failure)
      (unwind-protect
          (progn
            (hey-cli-test--start-version
             owner (lambda (value) (setq result value))
             (lambda (error) (setq failure error)))
            (hey-test-await (lambda () (or result failure)))
            (should result)
            (should-not failure)
            (with-current-buffer "*hey-log*"
              (should (string-match-p "stderr=yes" (buffer-string)))
              (should-not (string-match-p "synthetic warning" (buffer-string)))))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-transport-rejects-stdout-on-nonzero-exit ()
  (hey-test-with-fake '(:scenario "stdout-on-error")
    (let ((owner (generate-new-buffer " *hey-owner*")) result failure)
      (unwind-protect
          (progn
            (hey-cli-test--start-version
             owner (lambda (value) (setq result value))
             (lambda (error) (setq failure error)))
            (hey-test-await (lambda () (or result failure)))
            (should-not result)
            (should (eq (hey-error-category failure) 'cli-exit)))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-transport-times-out-once ()
  (hey-test-with-fake '(:scenario "delay" :timeout 0.05)
    (let ((owner (generate-new-buffer " *hey-owner*"))
          (success-count 0) failures request)
      (unwind-protect
          (progn
            (setq request
                  (hey-cli-test--start-version
                   owner (lambda (_value) (cl-incf success-count))
                   (lambda (error) (push error failures))))
            (hey-test-await (lambda () failures))
            (should (zerop success-count))
            (should (= (length failures) 1))
            (should (eq (hey-error-category (car failures)) 'timeout))
            (hey-cli--sentinel request (hey-cli--request-process request) "again")
            (should (= (length failures) 1)))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-transport-cancel-completes-once ()
  (hey-test-with-fake '(:scenario "delay")
    (let ((owner (generate-new-buffer " *hey-owner*")) failures request)
      (unwind-protect
          (progn
            (setq request
                  (hey-cli-test--start-version
                   owner (lambda (_value) (ert-fail "Canceled request succeeded"))
                   (lambda (error) (push error failures))))
            (hey-cli-cancel-request request)
            (hey-test-await (lambda () failures))
            (should (= (length failures) 1))
            (should (eq (hey-error-category (car failures)) 'canceled))
            (hey-cli-cancel-request request)
            (should (= (length failures) 1)))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-transport-cleans-captures-after-callback-throw ()
  (let* ((owner (generate-new-buffer " *hey-owner*"))
         (stdout (generate-new-buffer " *hey-throw-out*"))
         (stderr (generate-new-buffer " *hey-throw-err*"))
         (request
          (hey-cli--make-request
           :stdout-buffer stdout
           :stderr-buffer stderr
           :owner owner
           :success (lambda (_value) (throw 'hey-cli-test-escape t))
           :operation 'version
           :started-at (float-time))))
    (unwind-protect
        (progn
          (with-current-buffer stdout (insert "private stdout"))
          (with-current-buffer stderr (insert "private stderr"))
          (should
           (catch 'hey-cli-test-escape
             (hey-cli--deliver request t '(("ok" . t)) 'success 0 t)
             nil))
          (should (hey-cli--request-completed request))
          (should-not (buffer-live-p stdout))
          (should-not (buffer-live-p stderr)))
      (when (buffer-live-p owner) (kill-buffer owner))
      (when (buffer-live-p stdout) (kill-buffer stdout))
      (when (buffer-live-p stderr) (kill-buffer stderr)))))

(ert-deftest hey-cli-transport-cleans-captures-after-callback-quit ()
  (let* ((owner (generate-new-buffer " *hey-owner*"))
         (stdout (generate-new-buffer " *hey-quit-out*"))
         (stderr (generate-new-buffer " *hey-quit-err*"))
         (request
          (hey-cli--make-request
           :stdout-buffer stdout
           :stderr-buffer stderr
           :owner owner
           :success (lambda (_value) (signal 'quit nil))
           :operation 'version
           :started-at (float-time))))
    (unwind-protect
        (progn
          (with-current-buffer stdout (insert "private stdout"))
          (with-current-buffer stderr (insert "private stderr"))
          (condition-case nil
              (hey-cli--deliver request t '(("ok" . t)) 'success 0 t)
            (quit nil))
          (should (hey-cli--request-completed request))
          (should-not (buffer-live-p stdout))
          (should-not (buffer-live-p stderr)))
      (when (buffer-live-p owner) (kill-buffer owner))
      (when (buffer-live-p stdout) (kill-buffer stdout))
      (when (buffer-live-p stderr) (kill-buffer stderr)))))

(ert-deftest hey-cli-transport-kills-process-when-post-spawn-setup-fails ()
  (hey-test-with-fake '(:scenario "delay")
    (let ((owner (generate-new-buffer " *hey-owner*"))
          (real-make-process (symbol-function 'make-process))
          spawned
          failures)
      (unwind-protect
          ;; Install the process wrapper before replacing `run-at-time'.  On
          ;; native-comp builds, installing the wrapper itself can schedule
          ;; compilation work through `run-at-time'.
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest arguments)
                       (setq spawned (apply real-make-process arguments)))))
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (&rest _arguments)
                         (error "Synthetic timer setup failure"))))
              (should-not
               (hey-cli-test--start-version
                owner (lambda (_value) (ert-fail "Failed setup succeeded"))
                (lambda (error) (push error failures))))
              (should (processp spawned))
              (should-not (process-live-p spawned))
              (should (= (length failures) 1))
              (should (eq (hey-error-category (car failures)) 'configuration))))
        (when (process-live-p spawned) (delete-process spawned))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-transport-suppresses-callback-after-owner-death ()
  (hey-test-with-fake '(:scenario "delay")
    (let ((owner (generate-new-buffer " *hey-owner*")) called request)
      (setq request
            (hey-cli-test--start-version
             owner (lambda (_value) (setq called t))
             (lambda (_error) (setq called t))))
      (kill-buffer owner)
      (hey-test-await (lambda () (hey-cli--request-completed request)))
      (should-not called))))

(ert-deftest hey-cli-transport-reports-process-signals ()
  (hey-test-with-fake '(:scenario "signal")
    (let ((owner (generate-new-buffer " *hey-owner*")) result failure)
      (unwind-protect
          (progn
            (hey-cli-test--start-version
             owner (lambda (value) (setq result value))
             (lambda (error) (setq failure error)))
            (hey-test-await (lambda () (or result failure)))
            (should-not result)
            (should (eq (hey-error-category failure) 'signal)))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-transport-bounds-combined-output ()
  (hey-test-with-fake '(:scenario "large" :max-output 64)
    (let ((owner (generate-new-buffer " *hey-owner*")) result failure)
      (unwind-protect
          (progn
            (hey-cli-test--start-version
             owner (lambda (value) (setq result value))
             (lambda (error) (setq failure error)))
            (hey-test-await (lambda () (or result failure)))
            (should-not result)
            (should (eq (hey-error-category failure) 'output-limit)))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-transport-sanitizes-environment-and-uses-neutral-cwd ()
  (hey-test-with-fake '(:scenario "success")
    (dolist (name '("HEY_TOKEN" "HEY_BASE_URL" "HEY_ACCOUNT_ID" "HEY_DEBUG"
                    "HEY_THEME" "HEY_CABLE_URL" "HEY_SETUP_AGENT"))
      (setenv name "must-not-reach-fake"))
    (setenv "HEY_NO_KEYRING" "1")
    (let ((owner (generate-new-buffer " *hey-owner*")) done failure)
      (unwind-protect
          (progn
            (with-current-buffer owner
              (setq default-directory hey-test-root))
            (hey-cli-test--start-version
             owner (lambda (_value) (setq done t))
             (lambda (error) (setq failure error)))
            (hey-test-await (lambda () (or done failure)))
            (should-not failure)
            (let ((record (hey-test-read-record)))
              (should (string-match-p
                       (concat "cwd="
                               (regexp-quote
                                (directory-file-name
                                 (file-truename hey-test-working-directory))))
                       record))
              (should (string-match-p "HEY_NONINTERACTIVE=1" record))
              (should (string-match-p "HEY_NO_KEYRING=1" record))
              (dolist (name '("HEY_TOKEN" "HEY_BASE_URL" "HEY_ACCOUNT_ID"
                              "HEY_DEBUG" "HEY_THEME" "HEY_CABLE_URL"
                              "HEY_SETUP_AGENT"))
                (should (string-match-p (concat name "=unset") record)))))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-transport-runs-concurrent-requests-independently ()
  (hey-test-with-fake '(:scenario "chunked")
    (let ((first-owner (generate-new-buffer " *hey-first-owner*"))
          (second-owner (generate-new-buffer " *hey-second-owner*"))
          first second failures)
      (unwind-protect
          (progn
            (hey-cli-version first-owner 'first 1
                             (lambda (value) (setq first value))
                             (lambda (error) (push error failures)))
            (hey-cli-version second-owner 'second 2
                             (lambda (value) (setq second value))
                             (lambda (error) (push error failures)))
            (hey-test-await (lambda () (or failures (and first second))))
            (should-not failures)
            (should first)
            (should second))
        (when (buffer-live-p first-owner) (kill-buffer first-owner))
        (when (buffer-live-p second-owner) (kill-buffer second-owner))))))

(ert-deftest hey-cli-transport-redacts-query-account-and-server-output-from-log ()
  (hey-test-with-fake '(:scenario "error-7")
    (when (get-buffer "*hey-log*") (kill-buffer "*hey-log*"))
    (let ((owner (generate-new-buffer " *hey-owner*")) failure)
      (unwind-protect
          (progn
            (hey-cli-search
             "private-account-17" "private quarterly phrase" nil
             owner 'search-source 3
             (lambda (_value) (ert-fail "Synthetic failure succeeded"))
             (lambda (error) (setq failure error)))
            (hey-test-await (lambda () failure))
            (with-current-buffer "*hey-log*"
              (let ((log (buffer-string)))
                (should (string-match-p "operation=search" log))
                (should-not (string-match-p "private-account-17" log))
                (should-not (string-match-p "private quarterly phrase" log))
                (should-not (string-match-p "Synthetic request failed" log)))))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-transport-rejects-remote-owner-and-paths ()
  (hey-test-with-fake '(:scenario "success")
    (let ((owner (generate-new-buffer " *hey-owner*")) failures)
      (unwind-protect
          (progn
            (with-current-buffer owner
              (setq default-directory "/ssh:example.invalid:/tmp/"))
            (should-not
             (hey-cli-test--start-version
              owner (lambda (_value) (ert-fail "Remote owner succeeded"))
              (lambda (error) (push error failures))))
            (should (eq (hey-error-category (car failures)) 'configuration))
            (with-current-buffer owner
              (setq default-directory hey-test-root))
            (let ((hey-executable "/ssh:example.invalid:/usr/bin/hey"))
              (should-not
               (hey-cli-test--start-version
                owner (lambda (_value) (ert-fail "Remote executable succeeded"))
                (lambda (error) (push error failures)))))
            (let ((hey-working-directory "/ssh:example.invalid:/tmp/hey/"))
              (should-not
               (hey-cli-test--start-version
                owner (lambda (_value) (ert-fail "Remote cwd succeeded"))
                (lambda (error) (push error failures)))))
            (should (= (length failures) 3)))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-transport-rejects-working-directory-below-repository ()
  (hey-test-with-fake '(:scenario "success")
    (let ((owner (generate-new-buffer " *hey-owner*")) failure
          (hey-working-directory (expand-file-name "test/unsafe-cwd" hey-test-root)))
      (unwind-protect
          (progn
            (should-not
             (hey-cli-test--start-version
              owner (lambda (_value) (ert-fail "Unsafe cwd succeeded"))
              (lambda (error) (setq failure error))))
            (should (eq (hey-error-category failure) 'configuration)))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-working-directory-rejects-final-symlink-without-chmod ()
  (let* ((temporary-root (make-temp-file "hey-cwd-symlink-test-" t))
         (target (expand-file-name "target" temporary-root))
         (link (expand-file-name "link" temporary-root))
         (hey-working-directory (file-name-as-directory link)))
    (unwind-protect
        (progn
          (make-directory target)
          (set-file-modes target #o750)
          (make-symbolic-link target link)
          (should-error (hey-cli--prepare-working-directory))
          (should (= (file-modes target) #o750)))
      (when (file-directory-p temporary-root)
        (delete-directory temporary-root t)))))

(ert-deftest hey-cli-working-directory-rejects-shared-writable-parent ()
  (let* ((temporary-root (make-temp-file "hey-cwd-writable-test-" t))
         (hey-working-directory
          (file-name-as-directory (expand-file-name "neutral" temporary-root))))
    (unwind-protect
        (progn
          (set-file-modes temporary-root #o777)
          (should-error (hey-cli--prepare-working-directory))
          (should-not (file-exists-p hey-working-directory)))
      (when (file-directory-p temporary-root)
        (set-file-modes temporary-root #o700)
        (delete-directory temporary-root t)))))

(ert-deftest hey-cli-working-directory-rejects-foreign-owner ()
  (let* ((temporary-root (make-temp-file "hey-cwd-owner-test-" t))
         (hey-working-directory
          (file-name-as-directory (expand-file-name "neutral" temporary-root)))
         (actual-uid (user-uid)))
    (unwind-protect
        (cl-letf (((symbol-function 'user-uid)
                   (lambda () (+ actual-uid 10000))))
          (should-error (hey-cli--prepare-working-directory))
          (should-not (file-exists-p hey-working-directory)))
      (when (file-directory-p temporary-root)
        (delete-directory temporary-root t)))))

(ert-deftest hey-cli-working-directory-returns-canonical-private-directory ()
  (let* ((temporary-root (make-temp-file "hey-cwd-private-test-" t))
         (hey-working-directory
          (file-name-as-directory
           (expand-file-name "parent/neutral" temporary-root))))
    (unwind-protect
        (let ((prepared (hey-cli--prepare-working-directory)))
          (should (equal prepared
                         (file-name-as-directory
                          (file-truename hey-working-directory))))
          (should (= (file-modes prepared) #o700))
          (should (equal (file-attribute-user-id
                          (file-attributes prepared 'integer))
                         (user-uid))))
      (when (file-directory-p temporary-root)
        (delete-directory temporary-root t)))))

(ert-deftest hey-cli-undiscovered-executable-explains-discovery ()
  "Nil `hey-executable' names the CLI baseline and its remedies."
  (let ((owner (generate-new-buffer " *hey-owner*"))
        (hey-executable nil)
        (hey-working-directory
         (file-name-as-directory (make-temp-file "hey-discover-test-" t))))
    (unwind-protect
        (hey-cli-test--stub-discovery nil
          (hey-cli-test--assert-failure
           (hey-cli-test--fail-version owner)
           '("not found in `exec-path'" "1.4.0 or newer" "restart Emacs"
             "`hey-executable'"))
          (should (equal hey-cli-test--discovered '("hey"))))
      (when (buffer-live-p owner) (kill-buffer owner))
      (when (file-directory-p hey-working-directory)
        (delete-directory hey-working-directory t)))))

(ert-deftest hey-cli-invalid-executable-overrides-fail-closed ()
  "Every unusable `hey-executable' shares one message and never falls back."
  (let* ((temporary-root
          (file-name-as-directory (make-temp-file "hey-override-test-" t)))
         (directory-override (expand-file-name "directory" temporary-root))
         (non-executable (expand-file-name "not-executable" temporary-root)))
    (make-directory directory-override)
    (with-temp-file non-executable (insert "#!/bin/sh\n"))
    (set-file-modes non-executable #o600)
    (unwind-protect
        ;; Discovery would find the fake, so consulting it would prove fallback.
        (hey-cli-test--stub-discovery hey-test-fake-executable
          (dolist (candidate (list "relative/hey"
                                   "/ssh:remote.example.invalid/usr/bin/hey"
                                   (expand-file-name "absent" temporary-root)
                                   directory-override
                                   non-executable))
            (let ((owner (generate-new-buffer " *hey-owner*"))
                  (hey-executable candidate)
                  (hey-working-directory
                   (expand-file-name "neutral" temporary-root)))
              (unwind-protect
                  (let ((failure (hey-cli-test--fail-version owner)))
                    (hey-cli-test--assert-failure
                     failure
                     '("Configured `hey-executable'" "absolute path"
                       "nil to search" "no fallback"))
                    (should-not (member "hey" hey-cli-test--discovered))
                    ;; The rejected value never reaches the reader.
                    (should-not (string-match-p
                                 (regexp-quote temporary-root)
                                 (hey-error-message failure))))
                (when (buffer-live-p owner) (kill-buffer owner))))))
      (set-file-modes temporary-root #o700)
      (delete-directory temporary-root t))))

(ert-deftest hey-cli-nil-executable-resolves-through-discovery ()
  "Discovery still drives a real request once `hey-executable' is nil."
  (hey-test-with-fake '(:scenario "success")
    (let ((owner (generate-new-buffer " *hey-owner*"))
          (hey-executable nil)
          result failure)
      (unwind-protect
          (hey-cli-test--stub-discovery hey-test-fake-executable
            (should
             (hey-cli-test--start-version
              owner (lambda (value) (setq result value))
              (lambda (error) (setq failure error))))
            (hey-test-await (lambda () (or result failure)))
            (should (equal hey-cli-test--discovered '("hey")))
            (should-not failure)
            (should result)
            (should (string-match-p "arg=version" (hey-test-read-record))))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest hey-cli-executable-vanishing-at-start-is-named ()
  "A `file-missing' for an executable that no longer validates is classified."
  (let* ((temporary-root (make-temp-file "hey-vanish-test-" t))
         ;; A byte copy of the fake, so only this path can vanish.
         (volatile (expand-file-name "hey" temporary-root))
         (owner (generate-new-buffer " *hey-owner*"))
         (hey-executable volatile)
         (hey-working-directory
          (file-name-as-directory (expand-file-name "neutral" temporary-root))))
    (copy-file hey-test-fake-executable volatile)
    (set-file-modes volatile #o750)
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest _args)
                     ;; The executable disappears between validation and start.
                     (delete-file volatile)
                     (signal 'file-missing
                             '("Searching for program"
                               "No such file or directory")))))
          (hey-cli-test--assert-failure
           (hey-cli-test--fail-version owner)
           '("became unavailable" "`hey-executable'"))
          (should-not (file-exists-p volatile)))
      (when (buffer-live-p owner) (kill-buffer owner))
      (when (file-directory-p temporary-root)
        (delete-directory temporary-root t)))))

(ert-deftest hey-cli-other-start-failures-stay-generic ()
  "Start errors with a valid executable leak no operating-system detail."
  (hey-test-with-fake '(:scenario "success")
    (dolist (error-data
             '((file-missing "Searching for program"
                             "No such file or directory"
                             "/secret/working/directory")
               (file-error "Permission denied" "/secret/bin/hey")))
      (let ((owner (generate-new-buffer " *hey-owner*")) failure)
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'make-process)
                         (lambda (&rest _args)
                           (signal (car error-data) (cdr error-data)))))
                (setq failure (hey-cli-test--fail-version owner)))
              (should (equal (hey-error-message failure)
                             "HEY process could not be started."))
              (should-not (string-match-p "secret" (hey-error-message failure)))
              (should-not (hey-error-exit-status failure)))
          (when (buffer-live-p owner) (kill-buffer owner)))))))

(ert-deftest hey-test-guard-rejects-symlink-to-real-fake ()
  (let* ((directory (make-temp-file "hey-fake-link-test-" t))
         (link (expand-file-name "hey" directory)))
    (unwind-protect
        (progn
          (make-symbolic-link hey-test-fake-executable link)
          (should (file-equal-p link hey-test-fake-executable))
          (should-error (hey-test-assert-exact-fake link) :type 'ert-test-failed))
      (when (file-directory-p directory)
        (delete-directory directory t)))))

(provide 'hey-cli-test)
;;; hey-cli-test.el ends here
