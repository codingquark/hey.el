;;; hey-attachment-test.el --- Synthetic attachment tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'hey)
(require 'hey-test-helper)

(defun hey-attachment-test--thread ()
  "Return normalized synthetic thread context."
  (make-hey-thread :account-id "101" :account-name "Personal"
                   :topic-id "901" :subject "Kitchen remodel"
                   :entries (list (make-hey-entry :id "801" :sender "Alice"
                                                  :timestamp "2026-09-09 10:00"))))

(defun hey-attachment-test--file ()
  "Return a synthetic downloadable file."
  (make-hey-attachment :id "801:1" :message-id "801"
                       :filename "floor-plan.pdf" :content-type "application/pdf" :byte-size 22))

(defun hey-attachment-test--envelope ()
  "Read synthetic attachment metadata."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/fixtures/hey/attachments.json"
                                            hey-test-root))
    (hey-cli--parse-json (buffer-string))))

(defmacro hey-attachment-test--with-save (scenario &rest body)
  "Run BODY in an attachment buffer using fake SCENARIO."
  (declare (indent 1))
  `(hey-test-with-fake (list :scenario ,scenario)
     (setenv "HEY_EMACS_TEST_SAVE_ROOT" (directory-file-name
                                        (file-truename (file-name-directory hey-test-record-file))))
     (with-temp-buffer
       (hey-attachment-mode)
       (setq hey--attachment-thread (hey-attachment-test--thread))
       (let ((destination (expand-file-name "saved file.pdf"
                                            (file-truename (file-name-directory hey-test-record-file)))))
         ,@body))))

(defun hey-attachment-test--staging ()
  "Return staging directories under the current test root."
  (directory-files (file-name-directory hey-test-record-file) t
                   "\\`\\.hey-attachment-"))

(ert-deftest hey-attachment-normalization-preserves-identities-and-optional-size ()
  (let* ((result (hey-model-normalize-attachments (hey-attachment-test--envelope)))
         (records (plist-get result :value)))
    (should (= 3 (length records)))
    (should (equal (mapcar #'hey-attachment-id records)
                   '("801:1" "802:e-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "803:1")))
    (should (equal (mapcar #'hey-attachment-byte-size records) '(22 nil 0)))
    (should (plist-get result :notice))
    (should-not (plist-get result :warnings)))
  (let ((result (hey-model-normalize-attachments
                 '(("ok" . t) ("data"
                   (("id" . "-flag") ("message_id" . 801))
                   (("id" . "801:1") ("message_id" . 801) ("filename" . "A\nB"))
                   (("id" . "801:1") ("message_id" . 801)))))))
    (should (= 1 (length (plist-get result :value))))
    (should (= 2 (length (plist-get result :warnings))))
    (should (equal "A B" (hey-attachment-filename (car (plist-get result :value))))))
  (should-not (plist-get (hey-model-normalize-attachments '(("data"))) :value))
  (should (plist-get (hey-model-normalize-attachments '(("data" . "bad"))) :warnings)))

(ert-deftest hey-attachment-builders-are-account-scoped-and-never-force ()
  (should (equal (hey-cli-build-attachment-list "101" "901")
                 '("--base-url" "https://app.hey.com" "--account" "101"
                   "attachment" "list" "901" "--allow-partial" "--json")))
  (should (equal (hey-cli-build-attachment-save "all" "802:e-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "/tmp/a b.pdf")
                 '("--base-url" "https://app.hey.com" "--account" "all"
                   "attachment" "save" "802:e-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "--output" "/tmp/a b.pdf" "--json")))
  (should-error (hey-cli-build-attachment-list "101" "--force"))
  (should-error (hey-cli-build-attachment-save "101" "--force" "/tmp/a"))
  (should-error (hey-cli-build-attachment-save "101" "801:1" "/ssh:host:/tmp/a"))
  (should-error (hey-cli-build-attachment-save "101" "801:1" "relative")))

(ert-deftest hey-attachment-list-fake-renders-notice-and-message-fallback ()
  (hey-test-with-fake '(:scenario "attachment-list")
    (with-temp-buffer
      (hey-attachment-mode)
      (setq hey--attachment-thread (hey-attachment-test--thread))
      (hey-refresh-attachments)
      (hey-test-await (lambda () (not hey--loading)))
      (should (= 3 (length hey--attachments)))
      (should (string-match-p "Alice" (buffer-string)))
      (should (string-match-p "803" (buffer-string)))
      (should (string-match-p "some attachments may be missing" (buffer-string)))
      (should (string-match-p "arg=--allow-partial" (hey-test-read-record)))
      (let ((rows (mapcar #'hey--attachment-row hey--attachments)))
        (should (hey--attachment-size-less-p (nth 2 rows) (car rows)))))))

(ert-deftest hey-attachment-list-is-on-demand-and-reused ()
  (save-window-excursion
    (let ((thread-buffer (generate-new-buffer " *attachment-origin*"))
          attachment-buffer (calls 0))
      (unwind-protect
          (with-current-buffer thread-buffer
            (hey-thread-mode)
            (setq hey--thread (hey-attachment-test--thread)
                  hey--operation-overrides
                  `((hey-cli-attachment-list
                     . ,(lambda (&rest args)
                          (cl-incf calls)
                          (funcall (nth 5 args) (hey-attachment-test--envelope))
                          nil))))
            (should (= calls 0))
            (switch-to-buffer thread-buffer)
            (hey-list-attachments)
            (setq attachment-buffer (current-buffer))
            (should (derived-mode-p 'hey-attachment-mode))
            (should (= calls 1))
            (hey-quit-attachments)
            (should (eq (current-buffer) thread-buffer))
            (hey-list-attachments)
            (should (= calls 1))
            (hey-refresh-attachments)
            (should (= calls 2)))
        (when (buffer-live-p attachment-buffer) (kill-buffer attachment-buffer))
        (kill-buffer thread-buffer)))))

(ert-deftest hey-attachment-refresh-discards-old-callback-and-preserves-row ()
  (with-temp-buffer
    (hey-attachment-mode)
    (let (callbacks)
      (setq hey--attachment-thread (hey-attachment-test--thread)
            hey--operation-overrides
            `((hey-cli-attachment-list
               . ,(lambda (&rest args) (push (nth 5 args) callbacks) nil))))
      (hey-refresh-attachments)
      (hey-refresh-attachments)
      (funcall (car callbacks) (hey-attachment-test--envelope))
      (goto-char (point-min))
      (while (not (equal (tabulated-list-get-id) "802:e-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")) (forward-line 1))
      (hey--render-attachments)
      (should (equal (tabulated-list-get-id) "802:e-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
      (funcall (cadr callbacks) '(("ok" . t) ("data")))
      (should (= 3 (length hey--attachments))))))

(ert-deftest hey-attachment-save-writes-exact-bytes-and-cleans-staging ()
  (hey-attachment-test--with-save "attachment-save"
    (let (messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (when format-string
                     (push (apply #'format format-string args) messages)))))
        (hey--start-attachment-save (hey-attachment-test--file) destination)
        (should (string-match-p "Saving attachment" (hey--attachment-header)))
        (hey-test-await (lambda () (not hey--attachment-save-token))))
      (should (member "Saving attachment…" messages))
      (should (member "Attachment saved." messages)))
    (should-not hey--attachment-save-status)
    (should-not (string-match-p "Saving\\|saved" (hey--attachment-header)))
    (should (equal (with-temp-buffer (insert-file-contents destination) (buffer-string))
                   "Synthetic attachment.\n"))
    (should-not (hey-attachment-test--staging))
    (should (string-match-p "arg=101" (hey-test-read-record)))
    (should-not (string-match-p "arg=--force" (hey-test-read-record)))))

(ert-deftest hey-attachment-save-cancel-timeout-and-failure-clean-staging ()
  (dolist (kind '(cancel timeout failure bad-result))
    (hey-attachment-test--with-save
        (pcase kind ('failure "attachment-failed") ('bad-result "attachment-bad-result")
               (_ "attachment-delay"))
      (let ((hey-attachment-save-timeout-seconds (if (eq kind 'timeout) 0.2 5)))
        (let (messages)
          (cl-letf (((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (when format-string
                         (push (apply #'format format-string args) messages)))))
            (hey--start-attachment-save (hey-attachment-test--file) destination)
            (when (eq kind 'cancel)
              (hey-test-await (lambda () (directory-files-recursively
                                          (file-name-directory hey-test-record-file)
                                          "hey-file-partial")))
              (hey-cancel-attachment-save))
            (hey-test-await (lambda () (not hey--attachment-save-token))))
          (should (member
                   (pcase kind
                     ('cancel "Attachment download canceled.")
                     ('timeout "Attachment download timed out; retry saving.")
                     ('failure "Attachment download failed; retry saving.")
                     (_ "Attachment could not be verified or saved; choose another destination."))
                   messages)))
        (should-not hey--attachment-save-status)
        (should-not (string-match-p "Saving\\|failed\\|canceled\\|timed out"
                                     (hey--attachment-header)))
        (should-not (file-exists-p destination))
        (should-not (hey-attachment-test--staging))))))

(ert-deftest hey-attachment-save-buffer-death-cleans-staging ()
  (hey-attachment-test--with-save "attachment-delay"
    (hey--start-attachment-save (hey-attachment-test--file) destination)
    (kill-buffer (current-buffer))
    (hey-test-await (lambda () (not (hey-attachment-test--staging))))
    (should-not (file-exists-p destination))))

(ert-deftest hey-attachment-save-continues-after-q-and-list-refresh ()
  (save-window-excursion
    (hey-attachment-test--with-save "attachment-delay"
      (let ((attachments (current-buffer))
            (origin (generate-new-buffer " *attachment-return*")))
        (unwind-protect
            (progn
              (setq hey--attachment-origin (with-current-buffer origin (point-marker)))
              (switch-to-buffer attachments)
              (hey--start-attachment-save (hey-attachment-test--file) destination)
              (should-error (hey--start-attachment-save (hey-attachment-test--file) destination))
              (setq hey--operation-overrides
                    `((hey-cli-attachment-list . ,(lambda (&rest args)
                                                  (funcall (nth 5 args) '(("data"))) nil))))
              (hey-refresh-attachments)
              (hey-quit-attachments)
              (should (eq (current-buffer) origin))
              (hey-test-await (lambda () (file-exists-p destination)) 4)
              (should-not (hey-attachment-test--staging)))
          (kill-buffer origin))))))

(ert-deftest hey-attachment-destination-refuses-existing-remote-and-symlink ()
  (hey-attachment-test--with-save "attachment-save"
    (write-region "keep" nil destination nil 'silent)
    (should-error (hey--attachment-destination destination))
    (should-error (hey--attachment-destination (file-name-directory destination)))
    (should-error (hey--attachment-destination "/ssh:host:/file"))
    (let ((link (concat destination ".link")))
      (make-symbolic-link (concat destination ".absent") link)
      (should-error (hey--attachment-destination link)))
    (should (equal "floor-plan.pdf" (hey--attachment-basename "../../floor-plan.pdf")))
    (should (equal "floor-plan.pdf" (hey--attachment-basename "..\\floor-plan.pdf")))
    (should (equal "attachment" (hey--attachment-basename "..")))))

(ert-deftest hey-attachment-save-preserves-destination-created-during-download ()
  (hey-attachment-test--with-save "attachment-delay"
    (hey--start-attachment-save (hey-attachment-test--file) destination)
    (write-region "keep" nil destination nil 'silent)
    (hey-test-await (lambda () (not hey--attachment-save-token)) 4)
    (should (equal "keep" (with-temp-buffer (insert-file-contents destination) (buffer-string))))
    (should-not (hey-attachment-test--staging))))

(ert-deftest hey-attachment-save-publication-failure-leaves-no-destination ()
  (hey-attachment-test--with-save "attachment-save"
    (cl-letf (((symbol-function 'add-name-to-file)
               (lambda (&rest _) (signal 'file-error '("unsupported filesystem")))))
      (hey--start-attachment-save (hey-attachment-test--file) destination)
      (hey-test-await (lambda () (not hey--attachment-save-token))))
    (should-not (file-exists-p destination))
    (should-not (hey-attachment-test--staging))))

(ert-deftest hey-attachment-save-setup-failure-finalizes-once ()
  (hey-attachment-test--with-save "attachment-save"
    (let ((hey-executable "/nonexistent/hey") (count 0))
      (hey-cli-attachment-save "101" "801:1" destination (current-buffer) 'save 1
                               #'ignore #'ignore (lambda () (cl-incf count)))
      (should (= count 1)))
    (let ((hey-executable "/nonexistent/hey"))
      (hey--start-attachment-save (hey-attachment-test--file) destination))
    (should-not hey--attachment-save-token)
    (should-not (hey-attachment-test--staging))))

(ert-deftest hey-attachment-save-finalizes-after-callback-throw ()
  (hey-attachment-test--with-save "attachment-save"
    (let ((count 0) request)
      (setq request (hey-cli-attachment-save
                     "101" "801:1" destination (current-buffer) 'save 1
                     (lambda (_) (throw 'attachment-test-done t)) #'ignore
                     (lambda () (cl-incf count))))
      (catch 'attachment-test-done
        (hey-test-await (lambda () (hey-cli--request-completed request))))
      (should (= count 1)))))


(ert-deftest hey-attachment-save-prompt-retries-an-existing-file ()
  (hey-attachment-test--with-save "attachment-save"
    (let ((existing (concat destination ".existing"))
          (attachment (hey-attachment-test--file)) (prompts 0))
      (write-region "keep" nil existing nil 'silent)
      (setq hey--attachments (list attachment))
      (hey--render-attachments)
      (goto-char (point-min))
      (while (not (tabulated-list-get-id)) (forward-line 1))
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _)
                   (cl-incf prompts)
                   (if (= prompts 1) existing destination))))
        (hey-save-attachment))
      (hey-test-await (lambda () (not hey--attachment-save-token)))
      (should (= prompts 2))
      (should (file-exists-p destination))
      (should (equal hey--attachment-directory (file-name-directory destination))))))

(ert-deftest hey-attachment-publish-rejects-unverified-result-and-symlink ()
  (hey-attachment-test--with-save "attachment-save"
    (let* ((staged (concat destination ".staged"))
           (result (make-hey-saved-attachment :id "801:1" :path staged :byte-size 4)))
      (write-region "data" nil staged nil 'silent)
      (dolist (bad (list nil
                        (make-hey-saved-attachment :id "801:2" :path staged :byte-size 4)
                        (make-hey-saved-attachment :id "801:1" :path destination :byte-size 4)
                        (make-hey-saved-attachment :id "801:1" :path staged :byte-size 5)))
        (should-error (hey--publish-attachment bad "801:1" staged destination))
        (should-not (file-exists-p destination)))
      (delete-file staged)
      (write-region "data" nil (concat staged ".target") nil 'silent)
      (make-symbolic-link (concat staged ".target") staged)
      (should-error (hey--publish-attachment result "801:1" staged destination))
      (should-not (file-exists-p destination)))))

(ert-deftest hey-attachment-save-post-spawn-failure-finalizes-once ()
  (hey-attachment-test--with-save "attachment-save"
    (let ((count 0))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (&rest _) (error "Synthetic timer failure"))))
        (hey-cli-attachment-save "101" "801:1" destination (current-buffer) 'save 1
                                 #'ignore #'ignore (lambda () (cl-incf count))))
      (should (= count 1)))))

(ert-deftest hey-attachment-save-late-callback-cannot-publish ()
  (hey-attachment-test--with-save "attachment-save"
    (let (complete finalize staged)
      (setq hey--operation-overrides
            `((hey-cli-attachment-save
               . ,(lambda (&rest args)
                    (setq staged (nth 2 args) complete (nth 6 args)
                          finalize (nth 8 args))
                    nil))))
      (hey--start-attachment-save (hey-attachment-test--file) destination)
      (write-region "data" nil staged nil 'silent)
      (setq hey--attachment-save-token nil)
      (funcall complete `(("ok" . t) ("data" ("id" . "801:1")
                                             ("path" . ,staged) ("byte_size" . 4))))
      (funcall finalize)
      (should-not (file-exists-p destination))
      (should-not (hey-attachment-test--staging)))))


(ert-deftest hey-attachment-quit-unwinds-through-thread-to-mail-list ()
  (require 'hey-demo)
  (dolist (other-window '(nil t))
    (save-window-excursion
      (unwind-protect
          (progn
            (hey-demo)
            (hey-test-await (lambda () (not hey--loading)))
            (let ((mail-list (current-buffer))
                  (mail-window (selected-window))
                  (window-count (length (window-list))))
              (goto-char (point-min))
              (while (not (tabulated-list-get-id)) (forward-line 1))
              (let ((row-id (tabulated-list-get-id)))
                (if other-window (hey-open-other-window) (hey-open))
                (hey-test-await (lambda () hey--thread))
                (let ((thread (current-buffer))
                      (thread-window (selected-window)))
                  (goto-char (point-max))
                  (let ((thread-point (point)))
                    (dotimes (_ 2)
                      (hey-list-attachments)
                      (hey-test-await (lambda () (not hey--loading)))
                      (call-interactively (key-binding (kbd "q")))
                      (should (eq (current-buffer) thread))
                      (should (eq (selected-window) thread-window))
                      (should (= (point) thread-point)))))
                (call-interactively (key-binding (kbd "q")))
                (should (eq (current-buffer) mail-list))
                (should (eq (selected-window) mail-window))
                (should (= (length (window-list)) window-count))
                (should (equal (tabulated-list-get-id) row-id)))))
        (dolist (buffer (buffer-list))
          (when (string-prefix-p "*HEY" (buffer-name buffer))
            (kill-buffer buffer)))))))

(provide 'hey-attachment-test)
