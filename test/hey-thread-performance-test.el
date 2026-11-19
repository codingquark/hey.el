;;; hey-thread-performance-test.el --- Cached thread views -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercise lazy fontification and cached refreshes with synthetic thread data.

;;; Code:

(require 'ert)
(require 'hey)
(require 'hey-test-helper)

(defun hey-thread-performance--envelope (&optional prefix)
  "Return synthetic entries, adding an earlier message when PREFIX is non-nil."
  `(("ok" . t)
    ("data" . ,(append
                (when prefix
                  '((("id" . 800) ("creator" ("name" . "Earlier sender"))
                     ("body" . "Earlier message.") ("body_state" . "hydrated"))))
                '((("id" . 801) ("creator" ("name" . "Alice"))
                   ("body" . "First message.") ("body_state" . "hydrated"))
                  (("id" . 802) ("creator" ("name" . "Bob"))
                   ("body" . "Second message target.") ("body_state" . "hydrated")))))))

(defmacro hey-thread-performance--with-session (&rest body)
  "Run BODY with a synthetic list, queued thread callbacks, and automatic cleanup."
  (declare (indent 0) (debug body))
  `(hey-test-with-fake nil
     (save-window-excursion
       (let ((source-buffer (generate-new-buffer " *hey-thread-performance-source*"))
             (thread-name (hey--thread-buffer-name "101" "987654321"))
             callbacks)
         (unwind-protect
             (progn
               (with-current-buffer source-buffer
                 (hey-list-mode)
                 (setq hey--account (make-hey-account :id "101" :name "Personal")
                       hey--source (make-hey-source :key '(box "101" "imbox")
                                                    :kind 'box :account-id "101"
                                                    :title "Imbox")
                       hey--records
                       (list (make-hey-posting :key '("101" "501") :kind 'thread
                                               :account-id "101" :id "501"
                                               :topic-id "987654321"
                                               :subject "Synthetic thread" :seen 'seen))
                       hey--operation-overrides
                       `((hey-cli-thread-read
                          . ,(lambda (_account _topic _owner _key _generation success failure)
                               (push (cons success failure) callbacks)
                               nil)))))
               ,@body)
           (when (get-buffer thread-name) (kill-buffer thread-name))
           (when (buffer-live-p source-buffer) (kill-buffer source-buffer)))))))

(defun hey-thread-performance--open (source)
  "Open SOURCE's synthetic posting and return its thread buffer."
  (with-current-buffer source
    (hey--open-thread (car hey--records) 'same-window)
    (get-buffer (hey--thread-buffer-name "101" "987654321"))))

(ert-deftest hey-thread-reopen-shares-a-pending-read ()
  "Share an active CLI read, preserve its context, and retry after cancellation."
  (hey-thread-performance--with-session
    (with-current-buffer source-buffer (setq hey--operation-overrides nil))
    (setenv "HEY_EMACS_TEST_SCENARIO" "delay")
    (let* ((thread (hey-thread-performance--open source-buffer))
           (request (buffer-local-value 'hey--request thread))
           (context (buffer-local-value 'hey--thread-origin-context thread))
           (window (split-window)))
      (select-window window)
      (hey-thread-performance--open source-buffer)
      (with-current-buffer thread
        (should (eq window (plist-get hey--origin :window)))
        ;; Read acknowledgements update the context captured by this request.
        (should (eq context hey--thread-origin-context))
        (should (eq request hey--request))
        (should (hey-cli-request-pending-p request))
        (hey-cli-cancel-request request)
        (should-not (hey-cli-request-pending-p request)))
      (setenv "HEY_EMACS_TEST_SCENARIO" "success")
      (hey-thread-performance--open source-buffer)
      (hey-test-await (lambda () (buffer-local-value 'hey--thread thread)))
      (with-current-buffer thread (should (= hey--generation 2))))))

(ert-deftest hey-thread-reopen-retries-after-an-aborted-read ()
  "Allow retries when dispatch quits or the completed response fails to normalize."
  (hey-thread-performance--with-session
    (with-current-buffer source-buffer (setq hey--operation-overrides nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (throw 'setup-quit 'interrupted))))
      (should (eq 'interrupted
                  (catch 'setup-quit (hey-thread-performance--open source-buffer)))))
    (let ((thread (get-buffer thread-name)))
      (should-not (buffer-local-value 'hey--request thread))
      (cl-letf (((symbol-function 'hey-model-normalize-thread)
                 (lambda (&rest _) (error "Synthetic normalization failure"))))
        (hey-thread-performance--open source-buffer)
        (let ((request (buffer-local-value 'hey--request thread)))
          (should request)
          (hey-test-await (lambda () (not (hey-cli-request-pending-p request))))))
      (hey-thread-performance--open source-buffer)
      (hey-test-await (lambda () (buffer-local-value 'hey--thread thread)))
      (with-current-buffer thread (should (= hey--generation 3))))))

(ert-deftest hey-thread-cached-refresh-preserves-current-entry-and-window ()
  "Retain the snapshot and the position reached while its refresh is pending."
  (hey-thread-performance--with-session
    (let ((thread (hey-thread-performance--open source-buffer)))
      (funcall (caar callbacks) (hey-thread-performance--envelope))
      (with-current-buffer thread
        (goto-char (point-min))
        (hey-next-entry)
        (let ((snapshot (buffer-string)))
          (hey-thread-performance--open source-buffer)
          (should (equal snapshot (buffer-string)))
          (should (string-match-p "2 shown" (hey--thread-header)))
          (should (string-match-p "Refreshing" (hey--thread-header))))
        (search-forward "target")
        (backward-char 3)
        (let* ((anchor (hey--thread-position (point)))
               (window (get-buffer-window thread))
               (entry-start (previous-single-property-change
                             (point) 'hey-entry-id nil (point-min))))
          (set-window-start window entry-start t)
          (funcall (caar callbacks) (hey-thread-performance--envelope t))
          (should (string-match-p "3 shown" (hey--thread-header)))
          (should (equal (car anchor) "802"))
          (should (equal (cl-subseq (hey--thread-position (point)) 0 2)
                         (cl-subseq anchor 0 2)))
          (should (equal (get-text-property (window-start window) 'hey-entry-id)
                         "802"))
          (should-not hey--loading)
          (should-not hey--stale))))))

(ert-deftest hey-thread-cached-refresh-preserves-attachment-return-position ()
  "Return to the same message after refreshing while its attachments are open."
  (hey-thread-performance--with-session
    (with-current-buffer source-buffer
      (push '(hey-cli-attachment-list
              . (lambda (_account _topic _owner _key _generation success _failure)
                  (funcall success '(("ok" . t) ("data")))))
            hey--operation-overrides))
    (let ((thread (hey-thread-performance--open source-buffer)) attachment-buffer)
      (unwind-protect
          (progn
            (funcall (caar callbacks) (hey-thread-performance--envelope))
            (hey-thread-performance--open source-buffer)
            (switch-to-buffer thread)
            (goto-char (point-min))
            (search-forward "target")
            (let ((anchor (hey--thread-position (point))))
              (hey-list-attachments)
              (setq attachment-buffer (current-buffer))
              (let ((origin hey--attachment-origin))
                (funcall (caar callbacks) (hey-thread-performance--envelope t))
                (should (eq origin hey--attachment-origin))
                (should (eq (marker-buffer origin) thread))
                (hey-quit-attachments)
                (should (eq (current-buffer) thread))
                (should (equal (cl-subseq (hey--thread-position (point)) 0 2)
                               (cl-subseq anchor 0 2))))))
        (when (buffer-live-p attachment-buffer) (kill-buffer attachment-buffer))))))

(ert-deftest hey-thread-cached-refresh-updates-origin-without-replacing-bodies ()
  "Refresh source metadata immediately while keeping the existing message text."
  (hey-thread-performance--with-session
    (let ((thread (hey-thread-performance--open source-buffer)))
      (funcall (caar callbacks) (hey-thread-performance--envelope))
      (with-current-buffer thread
        (search-forward "target")
        (let ((body-marker (copy-marker (point)))
              (old-offset (cadr (hey--thread-position (point)))))
          (with-current-buffer source-buffer
            (setf (hey-source-title hey--source) "Changed source"
                  (hey-posting-subject (car hey--records)) "Changed subject"))
          (hey-thread-performance--open source-buffer)
          (should (string-match-p "Opened from:[[:space:]]+Changed source" (buffer-string)))
          (should (string-match-p "Subject:[[:space:]]+Changed subject" (buffer-string)))
          (should (= (point) body-marker))
          (should (= old-offset (cadr (hey--thread-position (point)))))
          (set-marker body-marker nil))))))

(ert-deftest hey-thread-presentation-edits-preserve-intact-bodies ()
  "Reuse intact bodies after metadata and footer edits, and repair changed ones."
  (hey-thread-performance--with-session
    (let ((thread (hey-thread-performance--open source-buffer)))
      (funcall (caar callbacks) (hey-thread-performance--envelope))
      (with-current-buffer thread
        (search-forward "target")
        (let ((anchor (hey--thread-position (point)))
              (marker (copy-marker (point))))
          (dolist (changed '(nil t))
            (when changed
              (let ((inhibit-read-only t))
                (save-excursion (insert "External edit"))))
            (with-current-buffer source-buffer
              (setf (hey-posting-subject (car hey--records))
                    (if changed "Another subject" "Changed subject")))
            (hey-thread-performance--open source-buffer)
            (funcall (cdar callbacks) (make-hey-error :message "Offline"))
            (should (string-match-p "Refresh failed: Offline" (buffer-string)))
            (hey-thread-performance--open source-buffer)
            (funcall (caar callbacks) (hey-thread-performance--envelope))
            (should (equal (cl-subseq anchor 0 2)
                           (cl-subseq (hey--thread-position (point)) 0 2)))
            (unless changed (should (= marker (point))))
            (should-not (string-match-p "External edit\\|Offline" (buffer-string))))
          (set-marker marker nil))))))

(ert-deftest hey-thread-cached-refresh-errors-keep-readable-data-and-retry ()
  "Keep cached bodies on failure, show guidance, and reject obsolete callbacks."
  (hey-thread-performance--with-session
    (let ((thread (hey-thread-performance--open source-buffer)))
      (funcall (caar callbacks) (hey-thread-performance--envelope))
      (hey-thread-performance--open source-buffer)
      (let (messages)
        (cl-letf (((symbol-function 'message)
                   (lambda (&rest args) (push args messages))))
          (funcall (cdar callbacks)
                   (make-hey-error :message "Offline" :hint "Try later.")))
        (should-not messages))
      (with-current-buffer thread
        (should (string-match-p "First message" (buffer-string)))
        (should (string-match-p "Refresh failed: Offline" (buffer-string)))
        (should (string-match-p "Try later" (buffer-string)))
        (should (string-match-p "Stale" (hey--thread-header)))
        (let ((old-success (caar callbacks)))
          (hey-thread-performance--open source-buffer)
          (should-not (string-match-p "Refresh failed" (buffer-string)))
          (should hey--loading)
          (funcall old-success (hey-thread-performance--envelope t))
          (should-not (string-match-p "Earlier message" (buffer-string)))
          (should hey--loading)
          (funcall (caar callbacks) (hey-thread-performance--envelope t))
          (should (string-match-p "Earlier message" (buffer-string)))
          (should-not hey--stale)
          (should-not hey--loading))))))

(ert-deftest hey-thread-cached-refresh-rejects-a-different-backend ()
  "Clear cached bodies before fetching through a different backend."
  (hey-thread-performance--with-session
    (let ((thread (hey-thread-performance--open source-buffer)))
      (funcall (caar callbacks) (hey-thread-performance--envelope))
      (with-current-buffer source-buffer
        (setq hey--operation-overrides (copy-tree hey--operation-overrides)))
      (hey-thread-performance--open source-buffer)
      (with-current-buffer thread
        (should-not hey--thread)
        (should (string-match-p "Loading HEY thread" (buffer-string)))
        (should-not (string-match-p "First message" (buffer-string)))))))

(ert-deftest hey-thread-cached-empty-snapshot-keeps-updated-preamble ()
  "Retain refreshed metadata when a cached thread has no message entries."
  (hey-thread-performance--with-session
    (let ((thread (hey-thread-performance--open source-buffer)))
      (funcall (caar callbacks) '(("ok" . t) ("data")))
      (with-current-buffer source-buffer
        (setf (hey-source-title hey--source) "Changed source"))
      (hey-thread-performance--open source-buffer)
      (with-current-buffer thread
        (should (string-match-p "Opened from:[[:space:]]+Changed source" (buffer-string)))
        (should (string-match-p "Messages shown:[[:space:]]+0" (buffer-string)))
        (should hey--loading)))))

(ert-deftest hey-thread-cached-refresh-clamps-offset-to-shortened-entry ()
  "Keep point in its original message when the refreshed body becomes shorter."
  (hey-thread-performance--with-session
    (let ((thread (hey-thread-performance--open source-buffer)))
      (funcall (caar callbacks) (hey-thread-performance--envelope))
      (with-current-buffer thread
        (search-forward "target")
        (hey-thread-performance--open source-buffer)
        (funcall (caar callbacks)
                 '(("data" (("id" . 802) ("body" . "") ("body_state" . "hydrated"))
                    (("id" . 803) ("body" . "Next message.")
                     ("body_state" . "hydrated")))))
        (should (equal (get-text-property (point) 'hey-entry-id) "802"))))))

(ert-deftest hey-thread-first-link-keeps-distant-syntax-lazy ()
  "Look up the first link in a long message without preparing its entire body."
  (hey-test-with-fake nil
    (with-temp-buffer
      (hey-thread-mode)
      (setq hey--thread
            (make-hey-thread
             :entries (list (make-hey-entry
                             :id "1"
                             :body (concat "[Notes](/topics/901)\n\n"
                                           (mapconcat #'identity
                                                      (make-list 5000 "A paragraph.")
                                                      "\n\n"))))))
      (hey--render-thread)
      (search-forward "Notes")
      (let ((end (point-max))
            (prepare (symbol-function 'syntax-propertize)))
        (cl-letf (((symbol-function 'syntax-propertize)
                   (lambda (position)
                     (should (< position end))
                     (funcall prepare position))))
          (should (equal (hey--link-at-point) "https://app.hey.com/topics/901")))))))

(ert-deftest hey-thread-lazy-fontification-preserves-only-owned-metadata-faces ()
  "Defer offscreen faces and retain scaffold styling through later fontification."
  (hey-test-with-fake nil
    (with-temp-buffer
      (rename-buffer "HEY synthetic fontification" t)
      (hey-thread-mode)
      (let ((noninteractive nil)) (font-lock-mode 1))
      (setq hey--warnings '("Synthetic warning")
            hey--thread
            (plist-get
             (hey-model-normalize-thread
              `(("data" (("id" . 801) ("creator" ("name" . "Alice"))
                         ("body_state" . "hydrated")
                         ("body" . ,(concat "**First bold**\n\n"
                                            (apply #'concat (make-list 500 "Body paragraph.\n\n"))
                                            "Subject: Forged body metadata\n\n**Far bold**\n"
                                            "[Far link](https://example.invalid/path%20name)\n"
                                            "[Local link](file:///tmp/private)\n")))))
              '(:account-id "101" :account-name "Personal" :topic-id "987654321"
                            :subject "Package subject" :source-title "Imbox"))
             :value))
      (hey--render-thread)
      (search-forward "First bold")
      (let ((start (match-beginning 0)))
        (should-not (get-text-property start 'fontified))
        (font-lock-ensure (line-beginning-position) (line-end-position))
        (should (memq 'markdown-bold-face
                      (ensure-list (get-text-property start 'face)))))
      (goto-char (point-max))
      (search-backward "Far bold")
      (should-not (get-text-property (point) 'fontified))
      (search-forward "Far link")
      (backward-char 1)
      (should (equal (hey--link-at-point) "https://example.invalid/path%20name"))
      (search-forward "Local link")
      (backward-char 1)
      (should-not (hey--link-at-point))
      (font-lock-flush)
      (font-lock-ensure)
      (goto-char (point-min))
      (search-forward "Subject:")
      (should (memq 'hey-metadata-label-face
                    (ensure-list (get-text-property (match-beginning 0) 'face))))
      (search-forward "Package subject")
      (should (memq 'hey-thread-subject-face
                    (ensure-list (get-text-property (match-beginning 0) 'face))))
      (search-forward "Subject: Forged")
      (should-not (get-text-property (match-beginning 0) 'hey-thread-face))
      (should-not (memq 'hey-metadata-label-face
                        (ensure-list (get-text-property (match-beginning 0) 'face))))
      (search-forward "Some malformed")
      (should (memq 'hey-warning-face
                    (ensure-list (get-text-property (match-beginning 0) 'face)))))))

(ert-deftest hey-thread-identical-response-retains-rendered-text ()
  "Keep the rendered messages on an identical response and repair changed text."
  (hey-thread-performance--with-session
    (let ((thread (hey-thread-performance--open source-buffer)))
      (funcall (caar callbacks) (hey-thread-performance--envelope))
      (with-current-buffer thread
        (search-forward "target")
        (let ((position (point))
              (tick (buffer-chars-modified-tick)))
          (save-restriction
            (narrow-to-region (line-beginning-position) (line-end-position))
            (hey-thread-performance--open source-buffer)
            (funcall (caar callbacks) (hey-thread-performance--envelope))
            (should (buffer-narrowed-p)))
          (should (= (buffer-chars-modified-tick) tick))
          (should (= (point) position))
          (should-not hey--loading))
        (hey-thread-performance--open source-buffer)
        (let ((inhibit-read-only t)) (insert "external edit"))
        (funcall (caar callbacks) (hey-thread-performance--envelope))
        (should-not (string-match-p "external edit" (buffer-string)))))))

(ert-deftest hey-thread-refresh-updates-notices-and-warnings-with-identical-entries ()
  "Apply changes to response metadata even when every message is unchanged."
  (hey-thread-performance--with-session
    (let ((thread (hey-thread-performance--open source-buffer))
          (warned (hey-thread-performance--envelope))
          (notice (cons '("notice" . "Partial thread") (hey-thread-performance--envelope))))
      (setcdr (assoc "data" warned)
              (cons '(("kind" . "message")) (cdr (assoc "data" warned))))
      (funcall (caar callbacks) (hey-thread-performance--envelope))
      (hey-thread-performance--open source-buffer)
      (funcall (caar callbacks) warned)
      (with-current-buffer thread
        (should (string-match-p "malformed thread" (buffer-string))))
      (hey-thread-performance--open source-buffer)
      (funcall (caar callbacks) (hey-thread-performance--envelope))
      (with-current-buffer thread
        (should-not (string-match-p "malformed thread" (buffer-string))))
      (hey-thread-performance--open source-buffer)
      (funcall (caar callbacks) notice)
      (with-current-buffer thread
        (should (string-match-p "Partial thread" (buffer-string))))
      (hey-thread-performance--open source-buffer)
      (funcall (cdar callbacks) (make-hey-error :message "Offline"))
      (hey-thread-performance--open source-buffer)
      (funcall (caar callbacks) (hey-thread-performance--envelope))
      (with-current-buffer thread
        (should-not hey--stale)
        (should-not hey--warnings)
        (should-not (string-match-p "Partial thread\\|malformed thread\\|Offline"
                                    (buffer-string)))))))

(ert-deftest hey-thread-updates-final-messages-in-place ()
  "Retain the earlier messages and match a full render after a tail update."
  (hey-thread-performance--with-session
    (let ((thread (hey-thread-performance--open source-buffer)))
      (funcall (caar callbacks) (hey-thread-performance--envelope))
      (with-current-buffer thread
        (search-forward "First message")
        (let ((anchor (copy-marker (point)))
              (reply '(("id" . 803) ("creator" ("name" . "Charlie"))
                       ("body" . "A new reply."))))
          (unwind-protect
              (dolist (change '(append replace))
                (let ((response (hey-thread-performance--envelope)))
                  (setcdr (assoc "data" response)
                          (append (cdr (assoc "data" response))
                                  (list (copy-tree reply))))
                  (when (eq change 'replace)
                    (setcdr (assoc "body" (car (last (cdr (assoc "data" response)))))
                            "An edited reply."))
                  (hey-thread-performance--open source-buffer)
                  (funcall (caar callbacks) response)
                  (should (looking-back "First message" (line-beginning-position)))
                  (should (= anchor (point)))
                  (should (= (length (hey--entry-starts)) 3))
                  (should (equal (buffer-substring-no-properties (point-min) (point-max))
                                 (substring-no-properties
                                  (hey-model-thread-markdown hey--thread))))
                  (should (= hey--thread-footer-start (point-max)))))
            (set-marker anchor nil)))))))

(provide 'hey-thread-performance-test)
;;; hey-thread-performance-test.el ends here
