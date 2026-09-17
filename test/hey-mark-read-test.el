;;; hey-mark-read-test.el --- Explicit read-state tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercise write identities and asynchronous view changes with synthetic
;; operations.  The repository runner binds the executable to the fake.

;;; Code:

(require 'ert)
(require 'hey)
(require 'hey-test-helper)

(defun hey-mark-test--source (&optional kind account)
  "Return a synthetic source with KIND and ACCOUNT."
  (make-hey-source :key (list (or kind 'box) (or account "101") "inbox")
                   :kind (or kind 'box) :account-id (or account "101")
                   :id "inbox" :title "Inbox" :continuation-kind 'cursor))

(defun hey-mark-test--posting (id &optional seen account)
  "Return a synthetic posting with ID, SEEN, and ACCOUNT."
  (make-hey-posting :key (list (or account "101") id) :kind 'thread
                    :account-id (or account "101") :id id :topic-id "901"
                    :subject "Synthetic thread" :contacts "Sender"
                    :summary "" :timestamp "" :seen (or seen 'unseen)))

(defun hey-mark-test--envelope (ids &optional seen)
  "Return a source envelope for IDS with the specified SEEN state."
  `(("ok" . t)
    ("data" ("postings"
             ,@(mapcar (lambda (id)
                         `(("id" . ,id) ("topic_id" . "901")
                           ("name" . "Synthetic thread")
                           ("seen" . ,(if seen t 'hey-json-false))))
                       ids)))))

(defvar hey-mark-test--messages nil)
(defvar hey-mark-test--message-logging nil)

(defmacro hey-mark-test-with-messages (&rest body)
  "Evaluate BODY while capturing echo messages and their logging settings."
  (declare (indent 0) (debug body))
  `(let (hey-mark-test--messages hey-mark-test--message-logging)
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (when format-string
                    (push message-log-max hey-mark-test--message-logging)
                    (push (apply #'format format-string args)
                          hey-mark-test--messages)))))
       ,@body)))

(defmacro hey-mark-test-with-list (&rest body)
  "Evaluate BODY in a disposable synthetic list, capturing echo messages."
  (declare (indent 0) (debug body))
  `(hey-mark-test-with-messages
     (with-temp-buffer
       (hey-list-mode)
       (setq hey--account (make-hey-account :id "101" :name "Personal")
             hey--source (hey-mark-test--source)
             hey--records (list (hey-mark-test--posting "71")))
       (hey--render-list)
       ,@body)))

(defun hey-mark-test--assert-result (text)
  "Assert that only TEXT was echoed without logging and the header cleared.
When TEXT is nil, require silence."
  (should (equal hey-mark-test--messages (and text (list text))))
  (should-not (cl-some #'identity hey-mark-test--message-logging))
  (should-not hey--mark-read-status)
  (should-not (hey--mark-read-status-text)))

(defun hey-mark-test--thread (backend &optional id)
  "Initialize this thread with BACKEND and posting ID."
  (hey-thread-mode)
  (setq hey--thread-origin-context
        (list :account-id "101" :topic-id "901" :posting-id (or id "71")
              :seen 'unseen :subject "Synthetic thread")
        hey--thread-key '("101" "901")
        hey--operation-overrides backend
        hey--thread
        (plist-get (hey-model-normalize-thread
                    '(("ok" . t) ("data")) hey--thread-origin-context)
                   :value)))

(ert-deftest hey-mark-read-retains-posting-identity-in-model ()
  (let ((thread (plist-get
                 (hey-model-normalize-thread
                  '(("ok" . t) ("data"))
                  '(:account-id "101" :topic-id "901" :posting-id 71
                    :seen unseen))
                 :value)))
    (should (equal (hey-thread-posting-id thread) "71"))
    (should (equal (hey-thread-topic-id thread) "901"))
    (should (eq (hey-thread-seen thread) 'unseen)))
  (let ((thread (plist-get
                 (hey-model-normalize-thread
                  '(("ok" . t) ("data")) '(:topic-id "901"))
                 :value)))
    (should-not (hey-thread-posting-id thread))
    (should (eq (hey-thread-seen thread) 'unknown))))

(ert-deftest hey-mark-read-binds-both-views ()
  (should (eq (lookup-key hey-list-mode-map (kbd "r")) #'hey-mark-read))
  (should (eq (lookup-key hey-thread-mode-map (kbd "r")) #'hey-mark-read)))

(ert-deftest hey-mark-read-rejects-bundles-and-invalid-identities ()
  (hey-mark-test-with-list
    (dolist (id '(nil "0" "001" "-2" "abc" "71\n"))
      (setf (hey-posting-id (car hey--records)) id)
      (should-error (hey-mark-read) :type 'user-error))
    (setf (hey-posting-id (car hey--records)) "71"
          (hey-posting-kind (car hey--records)) 'bundle)
    (should-error (hey-mark-read) :type 'user-error)
    (should-not hey--mark-read-token))
  (with-temp-buffer
    (hey-thread-mode)
    (setq hey--loading t)
    (should-error (hey-mark-read) :type 'user-error)))

(ert-deftest hey-mark-read-keeps-point-pages-and-posting-target ()
  (hey-mark-test-with-list
    (let (success calls)
      (setq hey--records (list (hey-mark-test--posting "71")
                               (hey-mark-test--posting "72"))
            hey--operation-overrides
            `((hey-cli-mark-read
               . ,(lambda (account id _owner _key _gen ok _bad &optional _finish)
                    (push (list 'write account id) calls)
                    (setq success ok)
                    'write-request))
              (hey-cli-box-view
               . ,(lambda (_account _box page _owner _key _gen ok _bad)
                    (push (list 'read page) calls)
                    (funcall ok (hey-mark-test--envelope
                                 (if page '("72") '("71")) t))
                    'finished-read))))
      (setf (hey-source-consumed hey--source) '("cursor-two")
            (hey-source-continuation hey--source) "cursor-three")
      (hey--render-list)
      (hey-next-row)
      (hey-mark-read)
      (should (string-match-p "Marking read" (hey--status-header)))
      (should (equal (tabulated-list-get-id) '("101" "72")))
      (should (equal hey--mark-read-request 'write-request))
      (should (equal calls '((write "101" "72"))))
      (should (eq (hey-posting-seen (cadr hey--records)) 'unseen))
      (should-error (hey-mark-read) :type 'user-error)
      (funcall success '(("ok" . t)))
      (should-not hey--mark-read-token)
      (should-not hey--mark-read-request)
      (should-not hey--request)
      (should (equal (tabulated-list-get-id) '("101" "72")))
      (should (equal (hey-source-consumed hey--source) '("cursor-two")))
      (should (equal (hey-source-continuation hey--source) "cursor-three"))
      (should (equal (mapcar #'hey-posting-id hey--records) '("71" "72")))
      (should (equal calls '((read "cursor-two") (read nil) (write "101" "72"))))
      (hey-mark-test--assert-result nil)
      (should-not (string-match-p "Marking read\\|Read verified"
                                  (hey--status-header))))))

(ert-deftest hey-mark-read-search-stays-unknown ()
  (hey-mark-test-with-list
    (setq hey--source (hey-mark-test--source 'search)
          hey--operation-overrides
          `((hey-cli-mark-read
             . ,(lambda (_account id _owner _key _gen ok _bad &optional finish)
                  (should (equal id "71"))
                  (funcall ok '(("ok" . t)))
                  (funcall finish)))))
    (setf (hey-posting-seen (car hey--records)) 'unknown)
    (hey-mark-read)
    (should (eq (hey-posting-seen (car hey--records)) 'unknown))
    (hey-mark-test--assert-result nil))
  (hey-mark-test-with-list
    (setf (hey-posting-id (car hey--records)) nil)
    (should-error (hey-mark-read) :type 'user-error)))

(ert-deftest hey-mark-read-thread-captures-posting-and-clears-search-reuse ()
  (let (calls)
    (with-temp-buffer
      (hey-mark-test--thread
       `((hey-cli-mark-read
          . ,(lambda (account posting _owner _key _gen ok _bad &optional _finish)
               (push (list account posting) calls)
               (funcall ok '(("ok" . t)))))))
      ;; The origin is no longer available; no lookup through its point occurs.
      (setq hey--origin (list :list-buffer (get-buffer "no-such-origin")))
      (hey-mark-read)
      (should (equal calls '(("101" "71"))))
      (setf (plist-get hey--thread-origin-context :posting-id) nil)
      (setq hey--thread
            (plist-get (hey-model-normalize-thread
                        '(("ok" . t) ("data")) hey--thread-origin-context)
                       :value))
      (should-error (hey-mark-read) :type 'user-error)
      (should (equal calls '(("101" "71")))))))

(ert-deftest hey-mark-read-duplicates-share-only-the-same-backend ()
  (let ((calls 0)
        (one (generate-new-buffer " *hey-mark-one*"))
        (two (generate-new-buffer " *hey-mark-two*")))
    (unwind-protect
        (let ((backend `((hey-cli-mark-read
                          . ,(lambda (&rest _args) (cl-incf calls))))))
          (with-current-buffer one
            (hey-mark-test--thread backend)
            (hey-mark-read))
          (with-current-buffer two
            (hey-mark-test--thread backend)
            (should-error (hey-mark-read) :type 'user-error)
            (setq hey--operation-overrides (copy-tree backend))
            (hey-mark-read))
          (should (= calls 2)))
      (kill-buffer one)
      (kill-buffer two))))

(ert-deftest hey-mark-read-isolates-other-backend-and-account ()
  (let ((one (generate-new-buffer " *hey-mark-source*"))
        (two (generate-new-buffer " *hey-mark-other*"))
        (three (generate-new-buffer " *hey-mark-account*"))
        success)
    (unwind-protect
        (let ((backend `((hey-cli-mark-read
                          . ,(lambda (_a _p _o _k _g ok _bad &optional _f)
                               (setq success ok)))
                         (hey-cli-box-view
                          . ,(lambda (&rest _args)
                               (ert-fail "Crossed into another view"))))))
          (with-current-buffer one
            (hey-mark-test--thread backend)
            (hey-mark-read))
          (dolist (buffer (list two three))
            (with-current-buffer buffer
              (hey-list-mode)
              (setq hey--source (hey-mark-test--source)
                    hey--records (list (hey-mark-test--posting "71"))
                    hey--operation-overrides (copy-tree backend))))
          (with-current-buffer three
            (setq hey--source (hey-mark-test--source 'box "202")
                  hey--records (list (hey-mark-test--posting "71" 'unseen "202"))
                  hey--operation-overrides backend))
          (funcall success '(("ok" . t)))
          (dolist (buffer (list two three))
            (with-current-buffer buffer
              (should (eq (hey-posting-seen (car hey--records)) 'unseen))
              (should-not hey--mark-read-status))))
      (mapc #'kill-buffer (list one two three)))))

(ert-deftest hey-mark-read-protects-a-pending-first-page ()
  (hey-mark-test-with-messages
    (let ((list-buffer (generate-new-buffer " *hey-mark-first-page*"))
          (thread-buffer (generate-new-buffer " *hey-mark-thread*"))
          read-success write-success)
      (unwind-protect
          (let ((backend
                 `((hey-cli-box-view
                    . ,(lambda (_a _s _p _o _k _g ok _bad)
                         (setq read-success ok)))
                   (hey-cli-mark-read
                    . ,(lambda (_a _p _o _k _g ok _bad &optional _f)
                         (setq write-success ok))))))
            (with-current-buffer list-buffer
              (hey-list-mode)
              (setq hey--source (hey-mark-test--source)
                    hey--operation-overrides backend)
              (hey-refresh))
            (with-current-buffer thread-buffer
              (hey-mark-test--thread backend)
              (hey-mark-read))
            (funcall write-success '(("ok" . t)))
            (with-current-buffer list-buffer (should hey--loading))
            (funcall read-success (hey-mark-test--envelope '("71")))
            (with-current-buffer list-buffer
              (should-not hey--loading)
              (should (eq (hey-posting-seen (car hey--records)) 'seen))
              (hey-mark-test--assert-result nil)))
        (mapc #'kill-buffer (list list-buffer thread-buffer))))))

(ert-deftest hey-mark-read-rejects-an-older-refresh-callback ()
  (hey-mark-test-with-list
    (let (old-read write-success (reads 0))
      (setq hey--operation-overrides
            `((hey-cli-box-view
               . ,(lambda (_a _s _p _o _k _g ok _bad)
                    (if (= (cl-incf reads) 1)
                        (setq old-read ok)
                      (funcall ok (hey-mark-test--envelope '("71") t)))))
              (hey-cli-mark-read
               . ,(lambda (_a _p _o _k _g ok _bad &optional _f)
                    (setq write-success ok)))))
      (hey-refresh)
      (hey-mark-read)
      (funcall write-success '(("ok" . t)))
      (funcall old-read (hey-mark-test--envelope '("71")))
      (should (eq (hey-posting-seen (car hey--records)) 'seen))
      (hey-mark-test--assert-result nil))))

(ert-deftest hey-mark-read-source-switch-does-not-retarget-write ()
  (hey-mark-test-with-list
    (let (success args)
      (setq hey--operation-overrides
            `((hey-cli-mark-read
               . ,(lambda (account posting _o _k _g ok _bad &optional _f)
                    (setq args (list account posting) success ok)))))
      (hey-mark-read)
      (setq hey--source (hey-mark-test--source 'label)
            hey--records (list (hey-mark-test--posting "72")))
      (hey--next-generation)
      (should hey--mark-read-token)
      (funcall success '(("ok" . t)))
      (should (equal args '("101" "71")))
      (should (eq (hey-posting-seen (car hey--records)) 'unseen))
      (should-not (hey--mark-read-status-text))
      (should-not hey--mark-read-token))))

(ert-deftest hey-mark-read-reconciliation-failure-keeps-acknowledgment ()
  (hey-mark-test-with-list
    (setq hey--operation-overrides
          `((hey-cli-mark-read
             . ,(lambda (_a _p _o _k _g ok _bad &optional _f)
                  (funcall ok '(("ok" . t)))))
            (hey-cli-box-view
             . ,(lambda (_a _s _p _o _k _g _ok bad)
                  (funcall bad (make-hey-error :category 'network))))))
    (hey-mark-read)
    (should (eq (hey-posting-seen (car hey--records)) 'seen))
    (hey-mark-test--assert-result
     "Read accepted; refresh failed. Press g in the list.")
    (should-not hey--request)))

(ert-deftest hey-mark-read-reconciliation-reports-unread ()
  (hey-mark-test-with-list
    (setq hey--operation-overrides
          `((hey-cli-mark-read
             . ,(lambda (_a _p _o _k _g ok _bad &optional _f)
                  (funcall ok '(("ok" . t)))))
            (hey-cli-box-view
             . ,(lambda (_a _s _p _o _k _g ok _bad)
                  (funcall ok (hey-mark-test--envelope '("71")))))))
    (hey-mark-read)
    (should (eq (hey-posting-seen (car hey--records)) 'unseen))
    (hey-mark-test--assert-result "Read accepted; server reports unread")))

(ert-deftest hey-mark-read-uncertain-errors-never-retry ()
  (dolist (category '(timeout canceled network protocol configuration api))
    (hey-mark-test-with-list
      (let ((calls 0))
        (setq hey--operation-overrides
              `((hey-cli-mark-read
                 . ,(lambda (_a _p _o _k _g _ok bad &optional finish)
                      (cl-incf calls)
                      (funcall bad (make-hey-error :category category))
                      (funcall finish)))))
        (hey-mark-read)
        (should (= calls 1))
        (should (eq (hey-posting-seen (car hey--records)) 'unseen))
        (hey-mark-test--assert-result "Read outcome unknown; refresh the list to check")
        (should-not hey--mark-read-token)))))

(ert-deftest hey-mark-read-finalizer-before-failure-preserves-uncertainty ()
  (hey-mark-test-with-list
    (setq hey--operation-overrides
          `((hey-cli-mark-read
             . ,(lambda (_a _p _o _k _g _ok bad &optional finish)
                  (funcall finish)
                  (funcall bad (make-hey-error :category 'configuration))
                  (funcall finish)))))
    (hey-mark-read)
    (hey-mark-test--assert-result "Read outcome unknown; refresh the list to check")
    (should-not hey--mark-read-token)))

(ert-deftest hey-mark-read-owner-death-reports-unknown-in-surviving-view ()
  (hey-mark-test-with-messages
    (let ((one (generate-new-buffer " *hey-mark-owner*"))
          (two (generate-new-buffer " *hey-mark-survivor*"))
          finish)
      (unwind-protect
          (let ((backend `((hey-cli-mark-read
                            . ,(lambda (_a _p _o _k _g _ok _bad &optional finalizer)
                                 (setq finish finalizer))))))
            (with-current-buffer one (hey-mark-test--thread backend))
            (with-current-buffer two (hey-mark-test--thread backend))
            (with-current-buffer one (hey-mark-read))
            (kill-buffer one)
            (funcall finish)
            (with-current-buffer two
              (hey-mark-test--assert-result
               "Read outcome unknown; refresh the list to check")
              (should (eq (hey-thread-seen hey--thread) 'unseen))))
        (when (buffer-live-p one) (kill-buffer one))
        (kill-buffer two)))))

(ert-deftest hey-mark-read-new-refresh-reports-newer-server-state ()
  (hey-mark-test-with-list
    (let ((seen t))
      (setq hey--operation-overrides
            `((hey-cli-mark-read
               . ,(lambda (_a _p _o _k _g ok _bad &optional _f)
                    (funcall ok '(("ok" . t)))))
              (hey-cli-box-view
               . ,(lambda (_a _s _p _o _k _g ok _bad)
                    (funcall ok (hey-mark-test--envelope '("71") seen))))))
      (hey-mark-read)
      (hey-mark-test--assert-result nil)
      (setq seen nil)
      (hey-refresh)
      (should (eq (hey-posting-seen (car hey--records)) 'unseen))
      (hey-mark-test--assert-result nil)
      (setq hey--error (make-hey-error :category 'network) hey--stale t)
      (should (string-match-p "stale" (hey--status-header)))
      (should-not (string-match-p "Read verified" (hey--status-header))))))

(ert-deftest hey-mark-read-preserves-all-accounts-selector ()
  (hey-mark-test-with-list
    (setq hey--source (hey-mark-test--source 'search "all")
          hey--records (list (hey-mark-test--posting "71" 'unknown "all"))
          hey--operation-overrides
          `((hey-cli-mark-read
             . ,(lambda (account posting _o _k _g ok _bad &optional _f)
                  (should (equal account "all"))
                  (should (equal posting "71"))
                  (funcall ok '(("ok" . t)))))))
    (hey--render-list)
    (hey-mark-read)
    (should-not hey--mark-read-token)))


(ert-deftest hey-mark-read-cleans-up-after-presentation-and-setup-quit ()
  (dolist (phase '(presentation setup))
    (hey-mark-test-with-list
      (let ((present (symbol-function 'hey--mark-read-present)))
        (setq hey--operation-overrides
              `((hey-cli-mark-read
                 . ,(lambda (&rest _args) (signal 'quit nil)))))
        (cl-letf (((symbol-function 'hey--mark-read-present)
                   (lambda (&rest args)
                     (if (eq phase 'presentation)
                         (signal 'quit nil)
                       (apply present args)))))
          (condition-case nil (hey-mark-read) (quit nil)))
        (should-not hey--mark-read-token)
        (should-not hey--mark-read-target)
        (should-not hey--mark-read-request)))))

(ert-deftest hey-mark-read-definite-failure-preserves-recovery-hint ()
  (hey-mark-test-with-list
    (setq hey--operation-overrides
          `((hey-cli-mark-read
             . ,(lambda (_a _p _o _k _g _ok bad &optional _f)
                  (funcall bad (make-hey-error :category 'auth
                                               :message "Authentication failed."
                                               :hint "Run: hey auth login"))))))
    (hey-mark-read)
    (hey-mark-test--assert-result
     "Mark read failed. Authentication failed. Run: hey auth login")
    (should (eq (hey-posting-seen (car hey--records)) 'unseen))
    (should-not hey--mark-read-token)))

(ert-deftest hey-mark-read-thread-clears-progress-and-echoes-only-errors ()
  (dolist (result '(success failure))
    (hey-mark-test-with-messages
      (with-temp-buffer
        (let (success failure)
          (hey-mark-test--thread
           `((hey-cli-mark-read
              . ,(lambda (_a _p _o _k _g ok bad &optional _finish)
                   (setq success ok failure bad)))))
          (hey-mark-read)
          (should (string-match-p "Marking read" (hey--thread-header)))
          (if (eq result 'success)
              (progn
                (funcall success '(("ok" . t)))
                (hey-mark-test--assert-result nil))
            (funcall failure (make-hey-error :category 'timeout))
            (hey-mark-test--assert-result
             "Read outcome unknown; refresh the list to check"))
          (should-not (string-match-p "Marking read\\|Read accepted\\|outcome unknown"
                                      (hey--thread-header))))))))

(ert-deftest hey-mark-read-completion-preserves-another-threads-progress ()
  (hey-mark-test-with-list
    (let ((list-buffer (current-buffer))
          (thread-buffer (generate-new-buffer " *hey-mark-second*"))
          first-failure second-failure)
      (unwind-protect
          (progn
            (setq hey--records (list (hey-mark-test--posting "71")
                                     (hey-mark-test--posting "72"))
                  hey--operation-overrides
                  `((hey-cli-mark-read
                     . ,(lambda (_a posting _o _k _g _ok bad &optional _finish)
                          (if (equal posting "71")
                              (setq first-failure bad)
                            (setq second-failure bad))))))
            (hey--render-list)
            (hey-mark-read)
            (let ((backend hey--operation-overrides))
              (with-current-buffer thread-buffer
                (hey-mark-test--thread backend "72")
                (hey-mark-read)))
            (funcall first-failure (make-hey-error :category 'timeout))
            (with-current-buffer list-buffer
              (should (string-match-p "Marking read" (hey--status-header)))
              (should (equal hey--mark-read-status-target '("101" "72"))))
            (setq hey-mark-test--messages nil)
            (funcall second-failure (make-hey-error :category 'timeout))
            (dolist (buffer (list list-buffer thread-buffer))
              (with-current-buffer buffer
                (hey-mark-test--assert-result
                 "Read outcome unknown; refresh the list to check"))))
        (kill-buffer thread-buffer)))))

(ert-deftest hey-mark-read-old-verification-preserves-a-new-writes-progress ()
  (hey-mark-test-with-list
    (let (write-success write-failure read-success)
      (setq hey--operation-overrides
            `((hey-cli-mark-read
               . ,(lambda (_a _p _o _k _g ok bad &optional _finish)
                    (setq write-success ok write-failure bad)))
              (hey-cli-box-view
               . ,(lambda (_a _s _p _o _k _g ok _bad)
                    (setq read-success ok)))))
      (hey-mark-read)
      (funcall write-success '(("ok" . t)))
      (hey-mark-read)
      (funcall read-success (hey-mark-test--envelope '("71") t))
      (should (string-match-p "Marking read" (hey--status-header)))
      (should-not hey-mark-test--messages)
      (funcall write-failure (make-hey-error :category 'timeout))
      (hey-mark-test--assert-result "Read outcome unknown; refresh the list to check"))))


(ert-deftest hey-mark-read-preserves-pending-source-and-account-choosers ()
  (dolist (entry '((hey-choose-box . hey-cli-box-list)
                   (hey-choose-label . hey-cli-label-list)
                   (hey-choose-collection . hey-cli-collection-list)
                   (hey-choose-account . hey-cli-account-list)))
    (hey-mark-test-with-list
      (let (write-success picker-success selected
            (prompts 0) (reads 0))
        (setq hey--operation-overrides
              `((hey-cli-mark-read
                 . ,(lambda (_a _p _o _k _g ok _bad &optional _finish)
                      (setq write-success ok)))
                (,(cdr entry)
                 . ,(lambda (&rest args)
                      (setq picker-success (nth (- (length args) 2) args))
                      'picker-request))
                (hey-cli-box-view
                 . ,(lambda (&rest _args) (cl-incf reads)))))
        (hey-mark-read)
        (funcall (car entry))
        (let ((generation hey--generation))
          (funcall write-success '(("ok" . t)))
          (should (= generation hey--generation)))
        (should hey--loading)
        (should (eq hey--request 'picker-request))
        (should (zerop reads))
        (should (eq (hey-posting-seen (car hey--records)) 'seen))
        (hey-mark-test--assert-result nil)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt choices &rest _args)
                     (cl-incf prompts)
                     (caar choices)))
                  ((symbol-function 'hey--switch-source)
                   (lambda (source) (setq selected source)))
                  ((symbol-function 'hey--activate-account)
                   (lambda (account) (setq selected account))))
          (funcall picker-success
                   '(("ok" . t) ("data" (("id" . "9") ("name" . "Choice"))))))
        (should (= prompts 1))
        (should selected)
        (should-not hey--loading)
        (should-not hey--request)))))

(ert-deftest hey-mark-read-formats-only-changed-rows ()
  (hey-mark-test-with-list
    (let ((row-vector (symbol-function 'hey--row-vector))
          formatted write-success write-failure read-success)
      (setq hey--records
            (cons (hey-mark-test--posting "71")
                  (mapcar (lambda (id) (hey-mark-test--posting id 'seen))
                          '("72" "73" "74")))
            hey--operation-overrides
            `((hey-cli-mark-read
               . ,(lambda (_a _p _o _k _g ok bad &optional _finish)
                    (setq write-success ok write-failure bad)))
              (hey-cli-box-view
               . ,(lambda (_a _s _p _o _k _g ok _bad)
                    (setq read-success ok)))))
      (hey--render-list)
      (cl-letf (((symbol-function 'hey--row-vector)
                 (lambda (posting now)
                   (push (hey-posting-key posting) formatted)
                   (funcall row-vector posting now))))
        (hey-mark-read)
        (should-not formatted)
        (funcall write-failure (make-hey-error :category 'timeout))
        (should-not formatted)
        (hey-mark-read)
        (should-not formatted)
        (funcall write-success '(("ok" . t)))
        (should (equal formatted '(("101" "71"))))
        (setq formatted nil)
        (funcall read-success
                 (hey-mark-test--envelope '("71" "72" "73" "74") t))
        (should-not formatted)
        (should-not hey--request)))))

(ert-deftest hey-mark-read-preserves-unaffected-text-and-point ()
  (dolist (case '(("71" 12) ("72" 0) ("72" 12)))
    (hey-mark-test-with-list
      (setq hey--records (list (hey-mark-test--posting "71")
                               (hey-mark-test--posting "72"))
            hey--warnings '("Synthetic warning"))
      (setf (hey-source-continuation hey--source) "cursor-more")
      (hey--render-list)
      (hey-next-row)
      (let ((other-row (point-marker))
            (changes 0)
            footer button)
        (let ((inhibit-read-only t))
          (add-text-properties (line-beginning-position) (line-end-position)
                               '(hey-mark-test-preserved row))
          (goto-char (point-max))
          (search-backward "[Load more]")
          (setq button (button-at (point))
                footer (point-marker))
          (add-text-properties (point) (1+ (point))
                               '(hey-mark-test-preserved footer)))
        (set-buffer-modified-p nil)
        (hey--first-row)
        (when (equal (car case) "72") (hey-next-row))
        (move-to-column (cadr case))
        (let ((after-change-functions
               (list (lambda (&rest _args) (cl-incf changes)))))
          (hey--mark-read-present '("101" "71") nil nil 'seen))
        (should (equal (tabulated-list-get-id) (list "101" (car case))))
        (should (= (current-column) (cadr case)))
        (should (eq (get-text-property other-row 'hey-mark-test-preserved) 'row))
        (should (eq (get-text-property footer 'hey-mark-test-preserved) 'footer))
        (should (eq (button-get (button-at footer) 'action)
                    (button-get button 'action)))
        (should (string-match-p "1/2" (hey--status-header)))
        (should (string-match-p "malformed results" (buffer-string)))
        (should (zerop changes))
        (should-not (buffer-modified-p))
        (set-marker other-row nil)
        (set-marker footer nil)))))

(ert-deftest hey-mark-read-stops-after-observing-target ()
  (dolist (case '((nil t) ("cursor-two" t) (nil nil)))
    (hey-mark-test-with-list
      (let ((target-page (car case))
            (seen (cadr case))
            calls)
        (setf (hey-source-consumed hey--source) '("cursor-three" "cursor-two")
              (hey-source-continuation hey--source) "cursor-four")
        (setq hey--operation-overrides
              `((hey-cli-mark-read
                 . ,(lambda (_a _p _o _k _g ok _bad &optional _finish)
                      (funcall ok '(("ok" . t)))))
                (hey-cli-box-view
                 . ,(lambda (_a _s page _o _k _g ok _bad)
                      (push page calls)
                      (funcall ok
                               (hey-mark-test--envelope
                                (if (equal page target-page) '("71") '("72"))
                                seen))))))
        (hey-mark-read)
        (should (equal (reverse calls)
                       (if target-page '(nil "cursor-two") '(nil))))
        (should (eq (hey-posting-seen (car hey--records))
                    (if seen 'seen 'unseen)))
        (should (equal (hey-source-consumed hey--source)
                       '("cursor-three" "cursor-two")))
        (should (equal (hey-source-continuation hey--source) "cursor-four"))
        (should-not hey--request)
        (hey-mark-test--assert-result
         (unless seen "Read accepted; server reports unread"))))))

(ert-deftest hey-mark-read-exhausts-pages-without-known-target-state ()
  (dolist (state '(missing unknown))
    (hey-mark-test-with-list
      (let ((normalize (symbol-function 'hey-model-normalize-postings))
            calls)
        (setf (hey-source-consumed hey--source) '("cursor-three" "cursor-two"))
        (setq hey--operation-overrides
              `((hey-cli-mark-read
                 . ,(lambda (_a _p _o _k _g ok _bad &optional _finish)
                      (funcall ok '(("ok" . t)))))
                (hey-cli-box-view
                 . ,(lambda (_a _s page _o _k _g ok _bad)
                      (push page calls)
                      (funcall ok (hey-mark-test--envelope
                                   (if (eq state 'missing) '("72") '("71")) t))))))
        (cl-letf (((symbol-function 'hey-model-normalize-postings)
                   (lambda (envelope source)
                     (let ((result (funcall normalize envelope source)))
                       (when (eq state 'unknown)
                         (dolist (posting (plist-get result :value))
                           (setf (hey-posting-seen posting) 'unknown)))
                       result))))
          (hey-mark-read))
        (should (equal (reverse calls) '(nil "cursor-two" "cursor-three")))
        (should-not hey--request)
        (hey-mark-test--assert-result nil)))))

(ert-deftest hey-mark-read-checks-all-deferred-acknowledgments ()
  (hey-mark-test-with-list
    (let (calls)
      (setq hey--records (list (hey-mark-test--posting "71")
                               (hey-mark-test--posting "72"))
            hey--operation-overrides
            `((hey-cli-mark-read
               . ,(lambda (_a _p _o _k _g ok _bad &optional _finish)
                    (funcall ok '(("ok" . t)))))
              (hey-cli-box-view
               . ,(lambda (_a _s page _o _k _g ok _bad)
                    (push page calls)
                    (funcall ok (hey-mark-test--envelope
                                 (if page '("72") '("71")) t))))))
      (setf (hey-source-consumed hey--source) '("cursor-three" "cursor-two"))
      (hey--render-list)
      ;; Hold verification while a source request is still pending.
      (setq hey--loading t)
      (hey-mark-read)
      (hey-next-row)
      (hey-mark-read)
      (should-not calls)
      (should (member '("101" "71") hey--read-acknowledgements))
      (should (member '("101" "72") hey--read-acknowledgements))
      (setq hey--loading nil)
      (hey--mark-read-reconcile '("101" "71") hey--operation-overrides)
      (should (equal (reverse calls) '(nil "cursor-two")))
      (should-not hey--request)
      (hey-mark-test--assert-result nil))))

(ert-deftest hey-mark-read-keeps-first-observation-across-pages ()
  (hey-mark-test-with-list
    (let (calls)
      (setq hey--records (list (hey-mark-test--posting "71")
                               (hey-mark-test--posting "72"))
            hey--operation-overrides
            `((hey-cli-mark-read
               . ,(lambda (_a _p _o _k _g ok _bad &optional _finish)
                    (funcall ok '(("ok" . t)))))
              (hey-cli-box-view
               . ,(lambda (_a _s page _o _k _g ok _bad)
                    (push page calls)
                    (funcall ok (hey-mark-test--envelope
                                 (if page '("72" "71") '("72")) page))))))
      (setf (hey-source-consumed hey--source) '("cursor-three" "cursor-two"))
      (hey--render-list)
      (hey-mark-read)
      (should (equal (reverse calls) '(nil "cursor-two")))
      (should (eq (hey-posting-seen (car hey--records)) 'seen))
      (should (eq (hey-posting-seen (cadr hey--records)) 'unseen))
      (hey-mark-test--assert-result nil))))

(provide 'hey-mark-read-test)
;;; hey-mark-read-test.el ends here
