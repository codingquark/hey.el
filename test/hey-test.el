;;; hey-test.el --- Fake-backed UI tests for HEY  -*- lexical-binding: t; -*-

;;; Commentary:

;; These tests replace only public named CLI operations and use synthetic
;; envelopes.  They never resolve or invoke an installed HEY executable.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'hey)
(require 'hey-test-helper)

(defconst hey-test--account-envelope
  '(("ok" . t)
    ("data" (("id" . "all") ("name" . "All Accounts"))
            (("id" . "101") ("name" . "Personal")
             ("email" . "reader@example.invalid")))))

(defconst hey-test--auth-envelope
  '(("ok" . t)
    ("data" ("authenticated" . t) ("mail_account" . "101")
            ("install_id" . "discard-me"))))

(defconst hey-test--version-envelope
  '(("ok" . t) ("data" ("version" . "1.4.0") ("source" . "release"))))

(defun hey-test--posting (id topic subject &optional kind)
  "Return a synthetic posting alist with ID, TOPIC, SUBJECT, and KIND."
  `(("id" . ,id) ("topic_id" . ,topic) ("kind" . ,(or kind "topic"))
    ("name" . ,subject) ("seen" . hey-json-false)
    ("creator" ("name" . "Synthetic Sender"))
    ("summary" . "Synthetic summary")
    ("created_at" . "2026-09-03 10:00")
    ("folders" (("id" . 11) ("name" . "Planning")))
    ("collections" (("id" . 21) ("name" . "Launch")))
    ("app_url" . ,(and topic (format "https://app.hey.com/topics/%s" topic)))))

(defun hey-test--postings-envelope (postings &optional cursor)
  "Return a synthetic box envelope containing POSTINGS and CURSOR."
  `(("ok" . t)
    ("data" ("postings" ,@postings)
            ,@(when cursor `(("next_page" . ,cursor))))))

(defun hey-test--thread-envelope (&optional notice)
  "Return a synthetic two-entry thread envelope with optional NOTICE."
  `(("ok" . t)
    ("data"
     (("id" . 801) ("created_at" . "2026-09-01 09:10")
      ("creator" ("name" . "Alice Example"))
      ("body" . "# Body heading\n\n[Open](/topics/901).")
      ("body_state" . "hydrated")
      ("app_url" . "https://app.hey.com/topics/901#entry-801"))
     (("id" . 802) ("created_at" . "2026-09-02 10:31")
      ("creator" ("name" . "Bob Example"))
      ("body" . "") ("body_state" . "over_limit")))
    ,@(when notice `(("notice" . ,notice)))))

(defun hey-test--account ()
  "Return the normalized synthetic account used by UI tests."
  (make-hey-account :id "101" :name "Personal"
                    :email "reader@example.invalid"))

(defun hey-test--source (&optional kind id title)
  "Return a synthetic source with KIND, ID, and TITLE."
  (let ((kind (or kind 'box)) (id (or id "imbox")))
    (make-hey-source :key (list kind "101" id) :kind kind
                     :account-id "101" :id id :title (or title "Imbox")
                     :continuation-kind (if (eq kind 'search) 'page 'cursor))))

(defmacro hey-test-with-list (&rest body)
  "Evaluate BODY in a disposable initialized HEY list buffer."
  (declare (indent 0) (debug body))
  `(with-temp-buffer
     (hey-list-mode)
     (setq hey--account (hey-test--account)
           hey--source (hey-test--source))
     ,@body))

(ert-deftest hey-ui-modes-are-read-only-and-restrict-markdown-map ()
  (hey-test-with-list
    (should (derived-mode-p 'tabulated-list-mode))
    (should (local-variable-p 'hey--account))
    (should (local-variable-p 'hey--source))
    (should (local-variable-p 'hey--records))
    (should (eq (key-binding (kbd "g")) #'hey-refresh))
    (should-not (lookup-key hey-list-mode-map (kbd "x"))))
  (with-temp-buffer
    (hey-thread-mode)
    (should (derived-mode-p 'markdown-view-mode))
    (should buffer-read-only)
    (should-not buffer-file-name)
    (should backup-inhibited)
    (should-not markdown-display-remote-images)
    (should-not markdown-enable-math)
    (should-not markdown-fontify-code-blocks-natively)
    (should-not markdown-mouse-follow-link)
    (should (eq (lookup-key hey-thread-mode-map (kbd "TAB")) #'ignore))
    (should-not (commandp (lookup-key hey-thread-mode-map (kbd "C-c C-c"))))
    (should-not (lookup-key hey-thread-mode-map [mouse-2]))
    (should (eq (key-binding (kbd "RET")) #'hey-follow-link))))

(ert-deftest hey-ui-renders-loading-empty-stale-and-error-states ()
  (hey-test-with-list
    (setq hey--loading t)
    (hey--render-list)
    (should (string-match-p "Loading HEY mail" (buffer-string)))
    (setq hey--loading nil hey--records nil)
    (setf (hey-source-exhausted hey--source) t)
    (hey--render-list)
    (should (string-match-p "No mail in this source" (buffer-string)))
    (setq hey--records
          (plist-get (hey-model-normalize-postings
                      (hey-test--postings-envelope
                       (list (hey-test--posting 501 901 "Status row")))
                      (hey-test--source))
                     :value)
          hey--stale t
          hey--error (make-hey-error :category 'network :message "Offline"))
    (hey--render-list)
    (should (string-match-p "Showing stale results" (buffer-string)))
    (should (string-match-p "stale" (hey--status-header)))))

(ert-deftest hey-ui-malformed-empty-response-is-not-presented-as-empty-mail ()
  (hey-test-with-list
    (setq hey--operation-overrides
          `((hey-cli-box-view
             . ,(lambda (_account _box _page _owner _key _generation success _failure)
                  (funcall success '(("ok" . t) ("data" ("wrong"))))))))
    (hey-refresh)
    (should hey--warnings)
    (should (string-match-p "no usable rows" (buffer-string)))
    (should-not (string-match-p "No mail in this source" (buffer-string)))))

(ert-deftest hey-ui-responsive-layout-never-issues-transport-I/O ()
  (hey-test-with-list
    (let ((calls 0))
      (setq hey--records
            (plist-get (hey-model-normalize-postings
                        (hey-test--postings-envelope
                         (list (hey-test--posting 501 901 "Responsive")))
                        hey--source)
                       :value)
            hey--operation-overrides
            `((hey-cli-box-view . ,(lambda (&rest _args) (cl-incf calls)))))
      (hey--resize-buffer 130)
      (should (eq hey--layout 'wide))
      (hey--resize-buffer 70)
      (should (eq hey--layout 'narrow))
      (hey--resize-buffer 40)
      (should (eq hey--layout 'minimal))
      (should (= calls 0)))))

(ert-deftest hey-ui-refresh-and-revert-share-the-same-funnel ()
  (hey-test-with-list
    (let ((calls 0))
      (setq hey--operation-overrides
            `((hey-cli-box-view
               . ,(lambda (_account _box page _owner _key _generation success _failure)
                    (cl-incf calls)
                    (should-not page)
                    (funcall success
                             (hey-test--postings-envelope
                              (list (hey-test--posting 501 901 "Fresh"))))))))
      (hey-refresh)
      (should (= calls 1))
      (should (= (length hey--records) 1))
      (should (equal (hey-posting-subject (car hey--records)) "Fresh"))
      (funcall revert-buffer-function nil nil)
      (should (= calls 2)))))

(ert-deftest hey-ui-load-more-deduplicates-and-stops-nonadvancing-cursors ()
  (hey-test-with-list
    (let ((responses
           (list
            (hey-test--postings-envelope
             (list (hey-test--posting 501 901 "First")) "cursor-2")
            (hey-test--postings-envelope
             (list (hey-test--posting 501 901 "Duplicate")) "cursor-3"))))
      (setq hey--operation-overrides
            `((hey-cli-box-view
               . ,(lambda (_account _box _page _owner _key _generation success _failure)
                    (funcall success (pop responses))))))
      (hey-refresh)
      (should (equal (hey-source-continuation hey--source) "cursor-2"))
      (hey-load-more)
      (should (= (length hey--records) 1))
      (should (hey-source-exhausted hey--source))
      (should-not (hey-source-continuation hey--source)))))

(ert-deftest hey-ui-ignores-out-of-order-generation-callbacks ()
  (hey-test-with-list
    (let (successes)
      (setq hey--operation-overrides
            `((hey-cli-box-view
               . ,(lambda (_account _box _page _owner _key _generation success _failure)
                    (push success successes)))))
      (hey-refresh)
      (hey-refresh)
      (funcall (car successes)
               (hey-test--postings-envelope
                (list (hey-test--posting 502 902 "Newest"))))
      (funcall (cadr successes)
               (hey-test--postings-envelope
                (list (hey-test--posting 501 901 "Stale"))))
      (should (equal (mapcar #'hey-posting-subject hey--records) '("Newest"))))))

(ert-deftest hey-ui-starts-at-explicit-account-imbox-without-auth-prompt ()
  (save-window-excursion
    (let ((hey-account "101") calls)
      (cl-letf (((symbol-function 'hey-cli-version)
                 (lambda (_owner _key _generation success _failure)
                   (push 'version calls) (funcall success hey-test--version-envelope)))
                ((symbol-function 'hey-cli-account-list)
                 (lambda (_owner _key _generation success _failure)
                   (push 'accounts calls) (funcall success hey-test--account-envelope)))
                ((symbol-function 'hey-cli-auth-status)
                 (lambda (&rest _args) (ert-fail "Explicit account queried auth status")))
                ((symbol-function 'hey-cli-box-view)
                 (lambda (account box page _owner _key _generation success _failure)
                   (push (list account box page) calls)
                   (funcall success (hey-test--postings-envelope nil)))))
        (unwind-protect
            (progn
              (hey)
              (with-current-buffer (current-buffer)
                (should (derived-mode-p 'hey-list-mode))
                (should (equal (hey-account-id hey--account) "101"))
                (should (equal (hey-source-id hey--source) "imbox")))
              (should (member '("101" "imbox" nil) calls)))
          (dolist (buffer (buffer-list))
            (when (string-prefix-p "*HEY" (buffer-name buffer))
              (kill-buffer buffer))))))))

(ert-deftest hey-ui-nil-account-resolves-auth-status-before-imbox ()
  (save-window-excursion
    (let ((hey-account nil) calls)
      (cl-letf (((symbol-function 'hey-cli-version)
                 (lambda (_owner _key _generation success _failure)
                   (funcall success hey-test--version-envelope)))
                ((symbol-function 'hey-cli-account-list)
                 (lambda (_owner _key _generation success _failure)
                   (push 'accounts calls)
                   (funcall success hey-test--account-envelope)))
                ((symbol-function 'hey-cli-auth-status)
                 (lambda (_owner _key _generation success _failure)
                   (push 'auth calls) (funcall success hey-test--auth-envelope)))
                ((symbol-function 'hey-cli-box-view)
                 (lambda (_account _box _page _owner _key _generation success _failure)
                   (funcall success (hey-test--postings-envelope nil)))))
        (unwind-protect
            (progn
              (hey)
              (should (equal (hey-account-id hey--account) "101"))
              ;; Calls are pushed, so this proves auth preceded account-list.
              (should (equal calls '(accounts auth))))
          (dolist (buffer (buffer-list))
            (when (string-prefix-p "*HEY" (buffer-name buffer))
              (kill-buffer buffer))))))))

(ert-deftest hey-ui-unavailable-explicit-account-becomes-visible-error ()
  (save-window-excursion
    (let ((hey-account "missing"))
      (cl-letf (((symbol-function 'hey-cli-version)
                 (lambda (_owner _key _generation success _failure)
                   (funcall success hey-test--version-envelope)))
                ((symbol-function 'hey-cli-account-list)
                 (lambda (_owner _key _generation success _failure)
                   (funcall success hey-test--account-envelope))))
        (unwind-protect
            (progn
              (hey)
              (should-not hey--loading)
              (should (hey-error-p hey--error))
              (should (string-match-p "not linked" (buffer-string))))
          (dolist (buffer (buffer-list))
            (when (string-prefix-p "*HEY" (buffer-name buffer))
              (kill-buffer buffer))))))))

(ert-deftest hey-ui-unauthenticated-startup-becomes-visible-error ()
  (save-window-excursion
    (let ((hey-account nil)
          (unauth '(("ok" . t)
                    ("data" ("authenticated" . hey-json-false)
                            ("mail_account" . nil)))))
      (cl-letf (((symbol-function 'hey-cli-version)
                 (lambda (_owner _key _generation success _failure)
                   (funcall success hey-test--version-envelope)))
                ((symbol-function 'hey-cli-account-list)
                 (lambda (&rest _args)
                   (ert-fail "Unauthenticated startup queried accounts")))
                ((symbol-function 'hey-cli-auth-status)
                 (lambda (_owner _key _generation success _failure)
                   (funcall success unauth))))
        (unwind-protect
            (progn
              (hey)
              (should-not hey--loading)
              (should (string-match-p "not authenticated" (buffer-string))))
          (dolist (buffer (buffer-list))
            (when (string-prefix-p "*HEY" (buffer-name buffer))
              (kill-buffer buffer))))))))

(ert-deftest hey-ui-unsupported-cli-version-becomes-visible-error ()
  (save-window-excursion
    (let ((hey-account "101")
          (old-version
           '(("ok" . t)
             ("data" ("version" . "1.3.9") ("source" . "release")))))
      (cl-letf (((symbol-function 'hey-cli-version)
                 (lambda (_owner _key _generation success _failure)
                   (funcall success old-version)))
                ((symbol-function 'hey-cli-account-list)
                 (lambda (&rest _args)
                   (ert-fail "Unsupported CLI queried accounts"))))
        (unwind-protect
            (progn
              (hey)
              (should-not hey--loading)
              (should (string-match-p "1.4.0 or newer" (buffer-string))))
          (dolist (buffer (buffer-list))
            (when (string-prefix-p "*HEY" (buffer-name buffer))
              (kill-buffer buffer))))))))

(ert-deftest hey-ui-synchronous-builder-failure-becomes-visible-error ()
  (hey-test-with-list
    (setq hey--source
          (make-hey-source :key '(box "101" "--help") :kind 'box
                           :account-id "101" :id "--help" :title "Unsafe"
                           :continuation-kind 'cursor)
          hey--operation-overrides nil)
    (hey-refresh)
    (should-not hey--loading)
    (should (hey-error-p hey--error))
    (should (string-match-p "must not begin with a dash" (buffer-string)))))

(ert-deftest hey-ui-source-selectors-use-normalized-inventories ()
  (hey-test-with-list
    (let ((operations nil))
      (setq hey--operation-overrides
            `((hey-cli-box-list
               . ,(lambda (_account _owner _key _generation success _failure)
                    (push 'boxes operations)
                    (funcall success '(("ok" . t)
                                       ("data" (("id" . 2) ("kind" . "feedbox")
                                                ("name" . "The Feed")))))))
              (hey-cli-box-view
               . ,(lambda (_account _id _page _owner _key _generation success _failure)
                    (funcall success (hey-test--postings-envelope nil))))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _args) "The Feed")))
        (hey-choose-box))
      (should (equal operations '(boxes)))
      (should (equal (hey-source-id hey--source) "feedbox")))))

(ert-deftest hey-ui-inventory-failure-keeps-rows-and-marks-them-stale ()
  (hey-test-with-list
    (setq hey--records
          (plist-get (hey-model-normalize-postings
                      (hey-test--postings-envelope
                       (list (hey-test--posting 501 901 "Retained")))
                      hey--source)
                     :value)
          hey--operation-overrides
          `((hey-cli-box-list
             . ,(lambda (_account _owner _key _generation _success failure)
                  (funcall failure
                           (make-hey-error :category 'network
                                           :message "Synthetic offline"))))))
    (hey--render-list)
    (hey-choose-box)
    (should hey--stale)
    (should (= (length hey--records) 1))
    (should (string-match-p "Showing stale results" (buffer-string)))))

(ert-deftest hey-ui-search-buffer-name-and-header-omit-private-query ()
  (hey-test-with-list
    (let ((query "private quarterly secret"))
      (setq hey--operation-overrides
            `((hey-cli-search
               . ,(lambda (_account seen-query _page _owner _key _generation success _failure)
                    (should (equal seen-query query))
                    (funcall success '(("ok" . t) ("data")
                                       ("meta" ("page" . 1))))))))
      (hey-search query)
      (should-not (string-match-p (regexp-quote query) (buffer-name)))
      (should-not (string-match-p (regexp-quote query) (hey--status-header)))
      (should (eq (hey-source-kind hey--source) 'search)))))

(ert-deftest hey-ui-bundle-expands-by-posting-id-not-topic-id ()
  (save-window-excursion
    (hey-test-with-list
      (let* ((result (hey-model-normalize-postings
                      (hey-test--postings-envelope
                       (list (hey-test--posting 502 nil "Bundle" "bundle")))
                      hey--source))
             called)
        (setq hey--records (plist-get result :value)
              hey--operation-overrides
              `((hey-cli-bundle-view
                 . ,(lambda (_account posting-id _page _owner _key _generation success _failure)
                      (setq called posting-id)
                      (funcall success (hey-test--postings-envelope nil))))))
        (hey--render-list)
        (hey-open)
        (should (equal called "502"))
        (should (eq (hey-source-kind hey--source) 'bundle))
        (kill-buffer (current-buffer))))))

(ert-deftest hey-ui-thread-rendering-keeps-entry-properties-and-navigation ()
  (save-window-excursion
    (hey-test-with-list
      (setq hey--records
            (plist-get (hey-model-normalize-postings
                        (hey-test--postings-envelope
                         (list (hey-test--posting 501 901 "Thread subject")))
                        hey--source)
                       :value)
            hey--operation-overrides
            `((hey-cli-thread-read
               . ,(lambda (_account topic-id _owner _key _generation success _failure)
                    (should (equal topic-id "901"))
                    (funcall success (hey-test--thread-envelope "Partial read"))))))
      (hey--render-list)
      (hey-open)
      (should (derived-mode-p 'hey-thread-mode))
      (should (string-match-p "Messages shown:[[:space:]]+2" (buffer-string)))
      (should (string-match-p "Notice:[[:space:]]+Partial read" (buffer-string)))
      (let ((starts (hey--entry-starts)))
        (should (= (length starts) 2))
        (goto-char (point-min))
        (hey-next-entry)
        (should (= (point) (car starts)))
        (hey-next-entry)
        (should (= (point) (cadr starts)))
        (hey-previous-entry)
        (should (= (point) (car starts))))
      (kill-buffer (current-buffer)))))

(ert-deftest hey-ui-thread-normalization-warnings-are-visible ()
  (with-temp-buffer
    (hey-thread-mode)
    (setq hey--thread
          (plist-get
           (hey-model-normalize-thread
            '(("ok" . t) ("data" (("body" . "missing id"))))
            (list :account-id "101" :account-name "Personal"
                  :topic-id "901" :subject "Warning"
                  :source-title "Imbox"))
           :value)
          hey--warnings '("Skipped malformed entry"))
    (hey--render-thread)
    (should (string-match-p "malformed thread entries" (buffer-string)))))

(ert-deftest hey-ui-thread-reuse-rejects-an-out-of-order-callback ()
  (save-window-excursion
    (hey-test-with-list
      (let (successes)
        (setq hey--records
              (plist-get (hey-model-normalize-postings
                          (hey-test--postings-envelope
                           (list (hey-test--posting 501 901 "Thread subject")))
                          hey--source)
                         :value)
              hey--operation-overrides
              `((hey-cli-thread-read
                 . ,(lambda (_account _topic _owner _key _generation success _failure)
                      (push success successes)))))
        (hey--render-list)
        (let ((posting (car hey--records)))
          (hey--open-thread posting 'same-window)
          (with-current-buffer (plist-get hey--origin :list-buffer)
            (hey--open-thread posting 'same-window)))
        (funcall (car successes) (hey-test--thread-envelope "Newest"))
        (funcall (cadr successes) (hey-test--thread-envelope "Stale"))
        (should (equal (hey-thread-notice hey--thread) "Newest"))
        (should (= hey--generation 2))
        (kill-buffer (current-buffer))))))

(ert-deftest hey-ui-restores-origin-row-by-identity ()
  (hey-test-with-list
    (setq hey--records
          (plist-get
           (hey-model-normalize-postings
            (hey-test--postings-envelope
             (list (hey-test--posting 501 901 "First")
                   (hey-test--posting 502 902 "Second")))
            hey--source)
           :value))
    (hey--render-list)
    (let ((list-buffer (current-buffer))
          (origin-source (hey-source-key hey--source)))
      (with-temp-buffer
        (hey-thread-mode)
        (setq hey--origin
              (list :list-buffer list-buffer :source-key origin-source
                    :row-id '("101" "502")))
        (should (hey--restore-origin-point)))
      (should (equal (tabulated-list-get-id) '("101" "502"))))))

(ert-deftest hey-ui-url-handoff-revalidates-stored-targets ()
  (hey-test-with-list
    (setq hey--records
          (plist-get (hey-model-normalize-postings
                      (hey-test--postings-envelope
                       (list (hey-test--posting 501 901 "Link")))
                      hey--source)
                     :value))
    (hey--render-list)
    (let (opened copied)
      (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url)))
                ((symbol-function 'kill-new) (lambda (url &rest _) (setq copied url))))
        (hey-browse-url)
        (hey-copy-url))
      (should (equal opened "https://app.hey.com/topics/901"))
      (should (equal copied opened)))))

(ert-deftest hey-ui-thread-link-activation-allows-only-official-targets ()
  (with-temp-buffer
    (hey-thread-mode)
    (let (opened)
      (cl-letf (((symbol-function 'markdown-link-url) (lambda () "/topics/901"))
                ((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url))))
        (hey-follow-link))
      (should (equal opened "https://app.hey.com/topics/901"))
      (cl-letf (((symbol-function 'markdown-link-url)
                 (lambda () "file:///tmp/private")))
        (should-error (hey-follow-link) :type 'user-error)))))

(provide 'hey-test)
;;; hey-test.el ends here
