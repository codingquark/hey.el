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
    ("created_at" . "2026-09-03T10:00:00")
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

(ert-deftest hey-ui-list-highlights-current-row-with-theme-face ()
  (let ((hey-highlight-current-row t))
    (hey-test-with-list
      (should (local-variable-p 'hl-line-mode))
      (should hl-line-mode)
      (should (eq hl-line-face 'hl-line))))
  (let ((hey-highlight-current-row nil))
    (hey-test-with-list
      (should (local-variable-p 'hl-line-mode))
      (should-not hl-line-mode))))

(ert-deftest hey-ui-defines-theme-native-semantic-faces ()
  (dolist (face '(hey-unseen-face
                  hey-date-face
                  hey-label-face
                  hey-collection-face
                  hey-thread-subject-face
                  hey-metadata-label-face
                  hey-status-face
                  hey-warning-face
                  hey-error-face))
    (should (facep face))
    (should (eq (face-attribute face :foreground nil nil) 'unspecified))
    (should (eq (face-attribute face :background nil nil) 'unspecified)))
  (should (eq (face-attribute 'hey-unseen-face :inherit) 'bold))
  (should (eq (face-attribute 'hey-label-face :inherit) 'shadow))
  (should (eq (face-attribute 'hey-collection-face :inherit)
              'font-lock-constant-face))
  (should (eq (face-attribute 'hey-warning-face :inherit) 'warning))
  (should (eq (face-attribute 'hey-error-face :inherit) 'error)))

(ert-deftest hey-ui-thread-states-use-semantic-faces ()
  (with-temp-buffer
    (hey-thread-mode)
    (hey--render-thread-state "Loading HEY thread…")
    (should (eq (get-text-property (point-min) 'face) 'hey-status-face))
    (hey--render-thread-state "HEY could not load this thread: Offline"
                              'hey-error-face)
    (should (eq (get-text-property (point-min) 'face) 'hey-error-face))))

(ert-deftest hey-ui-renders-loading-empty-stale-and-error-states ()
  (hey-test-with-list
    (setq hey--loading t)
    (hey--render-list)
    (should (string-match-p "Loading HEY mail" (buffer-string)))
    (goto-char (point-min))
    (search-forward "Loading HEY mail")
    (should (eq (get-text-property (match-beginning 0) 'face)
                'hey-status-face))
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
    (goto-char (point-min))
    (search-forward "Showing stale results")
    (should (eq (get-text-property (match-beginning 0) 'face)
                'hey-error-face))
    (let* ((header (hey--status-header))
           (stale-start (string-match "stale" header)))
      (should stale-start)
      (should (eq (get-text-property stale-start 'face header)
                  'hey-error-face)))))

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
      (should (= (length (cadar (hey--tabulated-entries)))
                 (length tabulated-list-format)))
      (hey--resize-buffer 70)
      (should (eq hey--layout 'narrow))
      (should (= (length (cadar (hey--tabulated-entries)))
                 (length tabulated-list-format)))
      (hey--resize-buffer 40)
      (should (eq hey--layout 'minimal))
      (should (= (length (cadar (hey--tabulated-entries)))
                 (length tabulated-list-format)))
      (should (= calls 0)))))

(defun hey-test--column-width (name)
  "Return the configured width for column NAME."
  (cadr (cl-find name tabulated-list-format :key #'car :test #'equal)))

(defun hey-test--configured-table-width ()
  "Return the total configured table width including padding."
  (+ tabulated-list-padding
     (max 0 (1- (length tabulated-list-format)))
     (cl-loop for column across tabulated-list-format sum (cadr column))))

(defun hey-test--column-start (name)
  "Return the rendered column offset where table column NAME begins."
  (let ((start tabulated-list-padding))
    (cl-loop for column across tabulated-list-format
             while (not (equal (car column) name))
             do (cl-incf start (1+ (cadr column))))
    start))

(defun hey-test--rendered-row-line ()
  "Return the first rendered table row as a string."
  (goto-char (point-min))
  (while (and (not (eobp)) (null (tabulated-list-get-id)))
    (forward-line 1))
  (buffer-substring (line-beginning-position) (line-end-position)))

(defun hey-test--records-from (&rest postings)
  "Return normalized records for synthetic POSTINGS."
  (plist-get (hey-model-normalize-postings
              (hey-test--postings-envelope postings) hey--source)
             :value))

(ert-deftest hey-ui-narrow-layout-leaves-the-right-gutter ()
  (hey-test-with-list
    (dolist (width '(58 40))
      (hey--resize-buffer width)
      (should (= (hey-test--configured-table-width)
                 (- width hey--list-right-gutter))))))

(ert-deftest hey-ui-empty-memberships-expand-subject-to-its-cap ()
  (hey-test-with-list
    (let ((raw (copy-tree
                (hey-test--posting 501 901
                                   "A subject that can stay visible"))))
      (setf (alist-get "folders" raw nil nil #'equal) nil
            (alist-get "collections" raw nil nil #'equal) nil)
      (setq hey--records
            (plist-get (hey-model-normalize-postings
                        (hey-test--postings-envelope (list raw))
                        hey--source)
                       :value))
      (hey--render-list nil 130)
      (should-not (cl-find "Labels / collections" tabulated-list-format
                           :key #'car :test #'equal))
      (should (equal (mapcar #'car (append tabulated-list-format nil))
                     '("Subject" "Sender" "When")))
      (should (= (length (cadar (hey--tabulated-entries))) 3))
      (should (= (hey-test--column-width "Subject") 70))
      (should (= (hey-test--column-width "Sender") 24))
      (should (= (hey-test--column-width "When") 12))
      (should (= (hey-test--configured-table-width) 110))
      (should (< (hey-test--configured-table-width) 130)))))

(ert-deftest hey-ui-populated-memberships-retain-their-column ()
  (hey-test-with-list
    (setq hey--records
          (plist-get (hey-model-normalize-postings
                      (hey-test--postings-envelope
                       (list (hey-test--posting 501 901 "Memberships")))
                      hey--source)
                     :value))
    (hey--render-list nil 130)
    (should (equal (mapcar #'car (append tabulated-list-format nil))
                   '("Subject" "Sender" "Labels / collections"
                     "When")))
    (should (= (length (cadar (hey--tabulated-entries))) 4))
    (should (= (hey-test--column-width "Subject") 70))
    (should (= (hey-test--column-width "Sender") 21))
    (should (= (hey-test--column-width "When") 12))
    (should (= (hey-test--configured-table-width) 128))))

(ert-deftest hey-ui-layouts-keep-subject-first-with-time-at-end ()
  (hey-test-with-list
    (setq hey--records
          (plist-get (hey-model-normalize-postings
                      (hey-test--postings-envelope
                       (list (hey-test--posting 501 901 "Subject")))
                      hey--source)
                     :value))
    (dolist (case '((130 . ("Subject" "Sender" "Labels / collections"
                            "When"))
                    (90 . ("Subject" "Sender" "Labels / collections"
                           "When"))
                    (70 . ("Subject" "Sender" "When"))
                    (40 . ("Subject" "When"))))
      (hey--render-list nil (car case))
      (should (equal (mapcar #'car (append tabulated-list-format nil))
                     (cdr case)))
      (should (= (hey-test--column-width "When") 12))
      (should (= (hey-test--configured-table-width)
                 (- (car case) hey--list-right-gutter))))))

(ert-deftest hey-ui-when-column-keeps-its-width-and-the-table-fits ()
  (hey-test-with-list
    (setq hey--records (hey-test--records-from
                        (hey-test--posting 501 901 "Subject")))
    (dolist (width '(40 58 70 90 110 130 160 240))
      (hey--render-list nil width)
      (should (= (hey-test--column-width "When") 12))
      (should (<= (hey-test--column-width "Subject")
                  hey-list-subject-max-width))
      (should (<= (hey-test--configured-table-width)
                  (- width hey--list-right-gutter))))
    (dolist (width '(160 240))
      (hey--render-list nil width)
      (should (= (hey-test--column-width "Subject") 70))
      (should (= (hey-test--column-width "Sender") 24))
      (should (= (hey-test--configured-table-width) 131))
      (should (< (hey-test--configured-table-width) width)))))

(ert-deftest hey-ui-list-reserves-a-right-gutter-and-its-column-floors ()
  (hey-test-with-list
    (setq hey--records (hey-test--records-from
                        (hey-test--posting 501 901 "Gutter row")))
    (dolist (width '(40 58 70 90 130))
      (hey--render-list nil width)
      (should (= (hey-test--configured-table-width)
                 (- width hey--list-right-gutter)))
      (should (= (length (hey-test--rendered-row-line))
                 (- width hey--list-right-gutter))))
    ;; Minimal layout floors: padding, one Subject column, one gap, and the
    ;; fixed When column.  Below that the gutter yields to the floors.
    (dolist (width '(18 16 14))
      (hey--render-list nil width)
      (should (= (hey-test--configured-table-width) 16))
      (should (= (hey-test--column-width "Subject") 1))
      (should (= (hey-test--column-width "When") 12)))))

(ert-deftest hey-ui-long-memberships-stay-inside-their-column ()
  (hey-test-with-list
    (let ((raw (copy-tree (hey-test--posting 501 901 "Memberships"))))
      (setf (alist-get "folders" raw nil nil #'equal)
            '((("id" . 11) ("name" . "Receipts"))
              (("id" . 12) ("name" . "Travel"))
              (("id" . 13) ("name" . "Invoices")))
            (alist-get "collections" raw nil nil #'equal)
            '((("id" . 21) ("name" . "Launch Pad"))))
      (setq hey--records (hey-test--records-from raw))
      (dolist (width '(90 130))
        (hey--render-list nil width)
        (let* ((line (hey-test--rendered-row-line))
               (cell (aref (cadar (hey--tabulated-entries)) 2)))
          (should (= (length line) (- width hey--list-right-gutter)))
          (should (= (string-width cell)
                     (hey-test--column-width "Labels / collections")))
          (should (string-match-p "Invoices"
                                  (get-text-property 0 'help-echo cell)))
          (should (string-match-p "Launch Pad"
                                  (get-text-property 0 'help-echo cell))))))))

(ert-deftest hey-ui-capped-list-places-when-after-sender-not-the-window ()
  (hey-test-with-list
    (let ((raw (copy-tree (hey-test--posting 501 901 "Settlement reminder"))))
      (setf (alist-get "folders" raw nil nil #'equal) nil
            (alist-get "collections" raw nil nil #'equal) nil)
      (setq hey--records (hey-test--records-from raw))
      (hey--render-list nil 160)
      (let* ((line (hey-test--rendered-row-line))
             (entry (tabulated-list-get-entry))
             (date-index
              (cl-position "When" tabulated-list-format
                           :key #'car :test #'equal))
             (timestamp
              (substring-no-properties (aref entry date-index))))
        (should (= (length line) (hey-test--configured-table-width)))
        (should (< (length line) 160))
        (should (equal (substring line (hey-test--column-start "When"))
                       (format "%12s" timestamp)))
        (should (equal (substring line
                                  (hey-test--column-start "Sender")
                                  (hey-test--column-start "When"))
                       (format "%-25s" "Synthetic Sender")))))))

(ert-deftest hey-ui-wide-layout-caps-subject-width-with-full-help ()
  (hey-test-with-list
    (let* ((subject (make-string 120 ?S))
           (raw (copy-tree (hey-test--posting 501 901 subject))))
      (setf (alist-get "folders" raw nil nil #'equal) nil
            (alist-get "collections" raw nil nil #'equal) nil)
      (setq hey--records
            (plist-get (hey-model-normalize-postings
                        (hey-test--postings-envelope (list raw))
                        hey--source)
                       :value))
      (hey--render-list nil 130)
      (let* ((row (cadar (hey--tabulated-entries)))
             (subject-index
              (cl-position "Subject" tabulated-list-format
                           :key #'car :test #'equal))
             (date-format
              (cl-find "When" tabulated-list-format
                       :key #'car :test #'equal))
             (subject-cell (aref row subject-index)))
        (should (= (string-width subject-cell) 70))
        (should (plist-get (nthcdr 3 date-format) :right-align))
        (should (= (cadr date-format) 12))
        (should (= (hey-test--configured-table-width) 110))
        (should-not (cl-find "Summary" tabulated-list-format
                             :key #'car :test #'equal))
        (should (equal (get-text-property 0 'help-echo subject-cell)
                       (concat "Subject: ● " subject)))))))

(ert-deftest hey-ui-flexible-column-width-caps-are-customizable ()
  (let ((hey-list-subject-max-width 48)
        (hey-list-sender-max-width 20))
    (hey-test-with-list
      (setq hey--records
            (plist-get (hey-model-normalize-postings
                        (hey-test--postings-envelope
                         (list (hey-test--posting 501 901 "Subject")))
                        hey--source)
                       :value))
      (hey--render-list nil 200)
      (should (= (hey-test--column-width "Subject") 48))
      (should (= (hey-test--column-width "Sender") 20))
      (should (= (hey-test--column-width "When") 12))
      (should (= (hey-test--configured-table-width) 105))
      (should (< (hey-test--configured-table-width) 200)))))

(ert-deftest hey-ui-wide-layout-caps-sender-width-with-full-help ()
  (hey-test-with-list
    (let* ((sender (make-string 60 ?A))
           (raw (copy-tree (hey-test--posting 501 901 "Subject"))))
      (setf (alist-get "name" (alist-get "creator" raw nil nil #'equal)
                       nil nil #'equal)
            sender)
      (setq hey--records
            (plist-get (hey-model-normalize-postings
                        (hey-test--postings-envelope (list raw))
                        hey--source)
                       :value))
      (hey--render-list nil 200)
      (let* ((row (cadar (hey--tabulated-entries)))
             (sender-index
              (cl-position "Sender" tabulated-list-format
                           :key #'car :test #'equal))
             (sender-cell (aref row sender-index)))
        (should (= (string-width sender-cell) 24))
        (should (equal (get-text-property 0 'help-echo sender-cell)
                       (concat "Sender: " sender)))))))

(ert-deftest hey-ui-bundle-annotation-survives-column-projection ()
  (hey-test-with-list
    (let ((raw (copy-tree (hey-test--posting 502 nil "Bundle" "bundle"))))
      (setf (alist-get "folders" raw nil nil #'equal) nil
            (alist-get "collections" raw nil nil #'equal) nil)
      (setq hey--records
            (plist-get (hey-model-normalize-postings
                        (hey-test--postings-envelope (list raw))
                        hey--source)
                       :value))
      (hey--render-list nil 130)
      (let* ((entry (car (hey--tabulated-entries)))
             (row (cadr entry))
             (subject-index
              (cl-position "Subject" tabulated-list-format
                           :key #'car :test #'equal)))
        (should (= (length row) (length tabulated-list-format)))
        (should (string-match-p "◇ Bundle"
                                (aref row subject-index)))))))

(ert-deftest hey-ui-formats-all-list-dates-at-one-current-time ()
  (hey-test-with-list
    (setq hey--records
          (plist-get (hey-model-normalize-postings
                      (hey-test--postings-envelope
                       (list (hey-test--posting 501 901 "First")
                             (hey-test--posting 502 902 "Second")))
                      hey--source)
                     :value))
    (let ((calls 0)
          (now (encode-time 0 0 12 3 9 2026)))
      (cl-letf (((symbol-function 'current-time)
                 (lambda () (cl-incf calls) now)))
        (let ((entries (hey--tabulated-entries)))
          (should (= calls 1))
          (let* ((date-index
                  (cl-position "When" tabulated-list-format
                               :key #'car :test #'equal))
                 (date (aref (cadar entries) date-index)))
            (should (equal (substring-no-properties date) "10:00"))
            (should (eq (get-text-property 0 'face date) 'hey-date-face))
            (should (equal (get-text-property 0 'help-echo date)
                           "2026-09-03T10:00:00"))))))))

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

(ert-deftest hey-ui-load-more-button-appends-and-anchors-the-last-row ()
  "Append through the footer control without moving the reading position."
  (hey-test-with-list
    (let ((responses
           (list
            (hey-test--postings-envelope
             (list (hey-test--posting 501 901 "First")
                   (hey-test--posting 502 902 "Second"))
             "cursor-3")
            (hey-test--postings-envelope
             (list (hey-test--posting 503 903 "Third")))))
          (pages '()))
      (setq hey--operation-overrides
            `((hey-cli-box-view
               . ,(lambda (_account _box page _owner _key _generation success _failure)
                    (push page pages)
                    (funcall success (pop responses))))))
      (hey-refresh)
      (should-not (string-match-p "up to date" (hey--status-header)))
      (goto-char (point-min))
      (should (eq (key-binding (kbd "RET")) #'hey-open))
      (should (re-search-forward (regexp-quote "[Load more]") nil t))
      (let ((button (match-beginning 0)))
        (forward-line 1)
        (should (= (point) (point-max)))
        (should (> button (progn (hey--last-row) (point))))
        (should (equal (tabulated-list-get-id) '("101" "502")))
        (goto-char button)
        (should (eq (key-binding (kbd "RET")) #'push-button))
        (should (eq (key-binding [mouse-2]) #'push-button))
        (push-button))
      (should (equal (nreverse pages) (list nil "cursor-3")))
      (should (= (length hey--records) 3))
      (should (equal (tabulated-list-get-id) '("101" "502")))
      (should-not (string-match-p (regexp-quote "[Load more]") (buffer-string)))
      (should (string-match-p "up to date" (hey--status-header))))))

(ert-deftest hey-ui-load-more-button-visibility-follows-pagination-state ()
  "Show the control only when loaded rows can be extended."
  (hey-test-with-list
    (let ((result (hey-model-normalize-postings
                   (hey-test--postings-envelope
                    (list (hey-test--posting 501 901 "Row")) "cursor-2")
                   hey--source)))
      (setq hey--records (plist-get result :value)
            hey--source (plist-get result :source)))
    (should (equal (hey-source-continuation hey--source) "cursor-2"))
    (hey--render-list)
    (should (string-match-p (regexp-quote "[Load more]") (buffer-string)))
    (dolist (state '("loading" "stale" "error" "partial" "up to date"))
      (should-not (string-match-p state (hey--status-header))))
    (let ((hey--loading t))
      (hey--render-list)
      (should-not (string-match-p (regexp-quote "[Load more]") (buffer-string)))
      (should (string-match-p "loading" (hey--status-header))))
    (let ((hey--records nil))
      (hey--render-list)
      (should-not (string-match-p (regexp-quote "[Load more]") (buffer-string))))
    (setf (hey-source-continuation hey--source) nil
          (hey-source-exhausted hey--source) t)
    (hey--render-list)
    (should-not (string-match-p (regexp-quote "[Load more]") (buffer-string)))
    (should (string-match-p "up to date" (hey--status-header)))))

(ert-deftest hey-ui-append-failure-keeps-the-load-more-control ()
  "Keep the control available after a failed append."
  (hey-test-with-list
    (let ((fail-append nil))
      (setq hey--operation-overrides
            `((hey-cli-box-view
               . ,(lambda (_account _box page _owner _key _generation success failure)
                    (cond
                     ((and page fail-append)
                      (funcall failure
                               (make-hey-error :category 'network
                                               :message "Synthetic offline")))
                     (page
                      (funcall success
                               (hey-test--postings-envelope
                                (list (hey-test--posting 502 902 "Second"))
                                "cursor-3")))
                     (t
                      (funcall success
                               (hey-test--postings-envelope
                                (list (hey-test--posting 501 901 "First"))
                                "cursor-2"))))))))
      (hey-refresh)
      (setq fail-append t)
      (hey-load-more)
      (should (equal (hey-source-continuation hey--source) "cursor-2"))
      (should (string-match-p (regexp-quote "[Load more]") (buffer-string)))
      (setq fail-append nil)
      (hey-load-more)
      (should (= (length hey--records) 2)))))

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

(ert-deftest hey-ui-missing-executable-remediation-appears-once ()
  "The list shows transport guidance verbatim and one retry instruction."
  (save-window-excursion
    (let ((hey-executable nil)
          (hey-account nil)
          (hey-working-directory
           (file-name-as-directory (make-temp-file "hey-ui-missing-exec-" t))))
      (cl-letf (((symbol-function 'executable-find) (lambda (_command) nil)))
        (unwind-protect
            (progn
              (hey)
              (should (eq (hey-error-category hey--error) 'configuration))
              (should (string-match-p "not found in `exec-path'"
                                      (buffer-string)))
              (should (= 1 (how-many "Press g to retry"))))
          (dolist (buffer (buffer-list))
            (when (string-prefix-p "*HEY" (buffer-name buffer))
              (kill-buffer buffer)))
          (when (file-directory-p hey-working-directory)
            (delete-directory hey-working-directory t)))))))

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

(ert-deftest hey-ui-search-rows-suppress-the-unseen-presentation ()
  "A search hit renders without the unseen marker or the unseen face."
  (hey-test-with-list
    (setq hey--operation-overrides
          `((hey-cli-search
             . ,(lambda (_account _query _page _owner _key _generation success _failure)
                  (funcall success
                           '(("ok" . t)
                             ("data"
                              (("topic_id" . 77)
                               ("subject" . "Search hit")
                               ("messages"
                                (("id" . 701)
                                 ("creator" ("name" . "Match"))
                                 ("summary" . "Excerpt")))))
                             ("meta" ("page" . 1))))))))
    (hey-search "private query")
    (should (eq (hey-posting-seen (car hey--records)) 'unknown))
    (hey--render-list nil 130)
    (let* ((row (cadar (hey--tabulated-entries)))
           (subject-index (cl-position "Subject" tabulated-list-format
                                       :key #'car :test #'equal)))
      (should (equal (substring-no-properties (aref row subject-index))
                     "Search hit"))
      (should-not (get-text-property 0 'face (aref row subject-index))))))

(ert-deftest hey-ui-bundle-expands-in-one-stable-buffer ()
  (save-window-excursion
    (hey-test-with-list
      (let* ((result (hey-model-normalize-postings
                      (hey-test--postings-envelope
                       (list (hey-test--posting 502 nil "Bundle" "bundle")))
                      hey--source))
             (origin-buffer (current-buffer))
             (calls 0)
             bundle-buffer)
        (setq hey--records (plist-get result :value)
              hey--operation-overrides
              `((hey-cli-bundle-view
                 . ,(lambda (_account posting-id _page _owner _key _generation success _failure)
                      (should (equal posting-id "502"))
                      (cl-incf calls)
                      (funcall
                       success
                       (hey-test--postings-envelope
                        (list (hey-test--posting
                               510 910 "Contained thread"))))))))
        (hey--render-list)
        (hey-open)
        (setq bundle-buffer (current-buffer))
        (should (equal (buffer-name) "*HEY bundle: 101/502*"))
        (should (eq (hey-source-kind hey--source) 'bundle))
        (should (= (length hey--records) 1))
        (should (eq (hey-posting-kind (car hey--records)) 'thread))
        (with-current-buffer origin-buffer
          (hey-open))
        (should (eq (current-buffer) bundle-buffer))
        (should (= calls 2))
        (should-not (get-buffer "*HEY bundle: 101/502*<2>"))
        (kill-buffer bundle-buffer)))))

(ert-deftest hey-ui-bundle-with-contact-opens-seen-and-unseen-threads ()
  (save-window-excursion
    (hey-test-with-list
      (let* ((raw (hey-test--posting 502 nil "Bundle" "bundle"))
             (origin-buffer (current-buffer))
             (calls 0)
             bundle-buffer)
        (setcdr (assoc-string "creator" raw)
                '(("id" . 51) ("name" . "Synthetic Sender")))
        (setq hey--records
              (plist-get
               (hey-model-normalize-postings
                (hey-test--postings-envelope (list raw)) hey--source)
               :value)
              hey--operation-overrides
              `((hey-cli-contact-threads
                 . ,(lambda (_account contact-id _page _owner _key _generation success _failure)
                      (should (equal contact-id "51"))
                      (cl-incf calls)
                      (funcall
                       success
                       (hey-test--postings-envelope
                        (list (hey-test--posting
                               510 910 "Contained thread"))))))
                (hey-cli-bundle-view
                 . ,(lambda (&rest _arguments)
                      (ert-fail "Bundle unseen fallback was used")))))
        (hey--render-list)
        (hey-open)
        (setq bundle-buffer (current-buffer))
        (should (equal (buffer-name) "*HEY bundle: 101/502*"))
        (should (eq (hey-source-kind hey--source) 'contact-threads))
        (should (= calls 1))
        (should (= (length hey--records) 1))
        (should (equal (hey-posting-topic-id (car hey--records)) "910"))
        (with-current-buffer origin-buffer
          (should (eq (hey-posting-kind (car hey--records)) 'bundle)))
        (kill-buffer bundle-buffer)))))

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
      (goto-char (point-min))
      (re-search-forward "^Subject:[[:space:]]+\\(.+\\)$")
      (should (memq 'hey-metadata-label-face
                    (ensure-list
                     (get-text-property (match-beginning 0) 'face))))
      (should (memq 'hey-thread-subject-face
                    (ensure-list
                     (get-text-property (match-beginning 1) 'face))))
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
    (should (string-match-p "malformed thread entries" (buffer-string)))
    (goto-char (point-min))
    (search-forward "malformed thread entries")
    (should (memq 'hey-warning-face
                  (ensure-list
                   (get-text-property (match-beginning 0) 'face))))))

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
