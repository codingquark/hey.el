;;; hey-model-test.el --- Tests for HEY model  -*- lexical-binding: t; -*-

;;; Commentary:

;; Pure tests use only synthetic JSON fixtures.  They never invoke HEY.

;;; Code:

(require 'ert)
(require 'json)
(require 'subr-x)
(require 'hey-model)

(defconst hey-model-test--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Repository root used to locate synthetic model fixtures.")

(defun hey-model-test--fixture (name)
  "Parse synthetic fixture NAME with the frozen JSON representation."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (concat "test/fixtures/hey/" name)
                       hey-model-test--root))
    (let ((json-object-type 'alist)
          (json-array-type 'list)
          (json-key-type 'string)
          (json-null nil)
          (json-false 'hey-json-false))
      (json-read))))

(ert-deftest hey-model-sanitize-metadata-removes-terminal-and-bidi-controls ()
  (let ((unsafe (concat "  Alpha\tBeta\nGamma"
                        (string 27) "[31m red " (string 27) "[0m"
                        (string 27) "]0;title" (string 7)
                        (string #x202e) " tail " (string 1) "  ")))
    (should (equal (hey-model-sanitize-metadata unsafe)
                   "Alpha Beta Gamma red tail")))
  (should (equal (hey-model-sanitize-metadata nil) "")))

(ert-deftest hey-model-validates-only-the-official-application-origin ()
  (should (equal (hey-model-validate-app-url
                  "https://app.hey.com/topics/77?view=all#entry-1")
                 "https://app.hey.com/topics/77?view=all#entry-1"))
  (dolist (url '("http://app.hey.com/topics/77"
                 "https://app.hey.com:443/topics/77"
                 "https://app.hey.com.evil.invalid/topics/77"
                 "https://app.hey.com@evil.invalid/topics/77"
                 "https://APP.HEY.COM/topics/77"
                 "https://app.hey.com\\topics\\77"
                 "https://app.hey.com/topics/77\nnext"
                 "https://example.invalid/topics/77"))
    (should-not (hey-model-validate-app-url url))))

(ert-deftest hey-model-validates-any-host-for-absolute-web-links ()
  (dolist (url '("https://example.invalid/report?a=1#top"
                 "http://example.invalid"
                 "https://example.invalid:8443/report"
                 "https://example.invalid:65535/report"
                 "https://user:pw@example.invalid:8443/report"
                 "https://[::1]/report"
                 "https://[2001:db8::1]/report"
                 "https://[::1]:8443/report"
                 "HTTP://EXAMPLE.INVALID/report"
                 "https://example.invalid#frag"
                 "https://xn--80ak6aa92e.com"
                 "https://xn--bcher-kva.example"))
    (should (equal (hey-model-validate-web-url url) url)))
  (dolist (url (list "javascript:alert(1)"
                     "file:///tmp/mail"
                     "mailto:reader@example.invalid"
                     "ftp://example.invalid/mail"
                     "data:text/html,x"
                     "https://"
                     "https:///report"
                     "https:/report"
                     "//evil.invalid/report"
                     "report"
                     "../report"
                     "/topics/77"
                     "https://#fragment"
                     "https://example.invalid:bad/report"
                     "https://example.invalid:65536/report"
                     "https://example.invalid:80:90/report"
                     "https://:80/report"
                     "https://a@b@c/report"
                     "https://[garbage]/report"
                     "https://[::1]:bad/report"
                     "https://[::1]:65536/report"
                     "https://[::1]:/report"
                     "https://example.invalid/a b"
                     (concat "https://example.invalid/a" (string 27))
                     (concat "https://example.invalid/a" (string #x202e))
                     "https://example.invalid\\a"))
    (should-not (hey-model-validate-web-url url))))

(ert-deftest hey-model-checks-bracketed-hosts-only-for-shape ()
  "Accept any bracketed run of hexadecimal digits, dots, and colons.

The IPv6 grammar is out of scope: Emacs has no pure syntax predicate for
it, and a malformed literal fails at the browser rather than here."
  (dolist (url '("https://[::1]/report"
                 "https://[2001:db8::1]:8443/report"
                 "https://[abc]/report"
                 "https://[::::]/report"))
    (should (equal (hey-model-validate-web-url url) url))))

(ert-deftest hey-model-keeps-percent-encoded-link-targets ()
  "Keep written escapes intact rather than decoding them."
  (dolist (url '("https://example.invalid/report%20name.pdf"
                 "https://example.invalid/a%0Ab%0Dc%1Bd"
                 "https://example.invalid/a%25b%2Fc%3Fd%23e"
                 "https://example.invalid/wiki/A_%28b%29"))
    (should (equal (hey-model-validate-web-url url) url))
    (should (equal (hey-model-resolve-body-url url) url))))

(ert-deftest hey-model-escapes-unsafe-url-display-characters ()
  (should (equal (hey-model-format-url-display
                  "https://example.invalid/report?a=1#top")
                 "https://example.invalid/report?a=1#top"))
  (should (equal (hey-model-format-url-display
                  (concat "https://example.invalid/a" (string 27)
                          (string #x202e) "b"))
                 "https://example.invalid/a\\u001B\\u202Eb")))

(ert-deftest hey-model-resolves-body-links-to-a-followable-destination ()
  (should (equal (hey-model-resolve-body-url "/topics/77#entry-1")
                 "https://app.hey.com/topics/77#entry-1"))
  (should (equal (hey-model-resolve-body-url
                  "https://app.hey.com/topics/77")
                 "https://app.hey.com/topics/77"))
  (should (equal (hey-model-resolve-body-url
                  "https://example.invalid/report")
                 "https://example.invalid/report"))
  (dolist (url '("//evil.invalid/topics/77"
                 "topics/77"
                 "../topics/77"
                 "file:///tmp/mail"
                 "javascript:alert(1)"
                 "mailto:reader@example.invalid"))
    (should-not (hey-model-resolve-body-url url))))

(ert-deftest hey-model-normalizes-accounts-defensively ()
  (let* ((result (hey-model-normalize-accounts
                  (hey-model-test--fixture "accounts-adversarial.json")))
         (accounts (plist-get result :value)))
    (should (= (length accounts) 2))
    (should (= (length (plist-get result :warnings)) 1))
    (should (equal (mapcar #'hey-account-id accounts) '("all" "101")))
    (should (hey-account-all-p (car accounts)))
    (should-not (hey-account-all-p (cadr accounts)))
    (should (equal (hey-account-name (cadr accounts)) "Personal account"))
    (should (equal (hey-account-email (cadr accounts))
                   "reader@example.invalid"))))

(ert-deftest hey-model-normalizes-auth-status-without-device-metadata ()
  (let* ((result
          (hey-model-normalize-auth-status
           '(("ok" . t)
             ("data" ("authenticated" . t)
              ("mail_account" . "all")
              ("install_id" . "must-not-cross-boundary")))))
         (status (plist-get result :value)))
    (should (hey-auth-status-authenticated status))
    (should (equal (hey-auth-status-account-id status) "all"))
    (should-not (plist-get result :warnings)))
  (let ((result (hey-model-normalize-auth-status
                 '(("ok" . t) ("data" ("mail_account" . "all"))))))
    (should-not (hey-auth-status-authenticated (plist-get result :value)))
    (should (plist-get result :warnings)))
  (let ((result (hey-model-normalize-auth-status
                 '(("ok" . t)
                   ("data" ("authenticated" . hey-json-false))))))
    (should-not (hey-auth-status-authenticated (plist-get result :value)))
    (should-not (plist-get result :warnings))))

(ert-deftest hey-model-normalizes-version-with-minimal-provenance ()
  (let* ((result
          (hey-model-normalize-version
           '(("ok" . t)
             ("data" ("version" . "1.4.0")
              ("source" . "release")
              ("commit" . "must-not-cross-boundary")
              ("date" . "must-not-cross-boundary")
              ("go" . "must-not-cross-boundary")))))
         (version (plist-get result :value)))
    (should (equal (hey-version-version version) "1.4.0"))
    (should (equal (hey-version-source version) "release"))
    (should-not (plist-get result :warnings)))
  (let* ((result
          (hey-model-normalize-version
           `(("ok" . t)
             ("data" ("version" . ,(concat "1.4.0" (string 10)))
              ("source" . "release")))))
         (version (plist-get result :value)))
    (should-not (hey-version-version version))
    (should (plist-get result :warnings))))

(ert-deftest hey-model-normalizes-label-and-collection-inventories ()
  (let ((envelope
         (list (cons "ok" t)
               (cons "data"
                     (list '(("id" . 11) ("name" . "Planning"))
                           '(("id" . 12) ("name" . "Launch\nNotes"))
                           '(("id" . "--help") ("name" . "Unsafe")))))))
    (dolist (case `((hey-model-normalize-labels . label)
                    (hey-model-normalize-collections . collection)))
      (let* ((result (funcall (car case) envelope "all"))
             (sources (plist-get result :value)))
        (should (= (length sources) 2))
        (should (= (length (plist-get result :warnings)) 1))
        (should (eq (hey-source-kind (car sources)) (cdr case)))
        (should (equal (hey-source-key (car sources))
                       (list (cdr case) "all" "11")))
        (should (equal (hey-source-title (cadr sources)) "Launch Notes"))))))

(ert-deftest hey-model-normalizes-box-kind-as-command-identity ()
  (let* ((result (hey-model-normalize-boxes
                  (hey-model-test--fixture "boxes-defensive.json") "101"))
         (sources (plist-get result :value)))
    (should (= (length sources) 2))
    (should (= (length (plist-get result :warnings)) 1))
    (should (equal (mapcar #'hey-source-id sources) '("imbox" "2")))
    (should (equal (mapcar #'hey-source-title sources)
                   '("Imbox" "Receipts Archive")))
    (should (equal (hey-source-key (car sources)) '(box "101" "imbox")))
    (should (eq (hey-source-continuation-kind (car sources)) 'cursor))))

(ert-deftest hey-model-normalizes-source-postings-with-exact-identities ()
  (let* ((source (make-hey-source
                  :key '(box "101" "imbox")
                  :kind 'box :account-id "101" :id "imbox"
                  :title "Imbox" :continuation-kind 'cursor))
         (result (hey-model-normalize-postings
                  (hey-model-test--fixture "postings-adversarial.json") source))
         (postings (plist-get result :value))
         (updated (plist-get result :source))
         (first (car postings))
         (bundle (cadr postings)))
    (should (= (length postings) 2))
    (should (= (length (plist-get result :warnings)) 1))
    (should (equal (hey-posting-key first) '("101" "501")))
    (should (equal (hey-posting-id first) "501"))
    (should (equal (hey-posting-topic-id first) "901"))
    (should (eq (hey-posting-kind first) 'thread))
    (should (eq (hey-posting-seen first) 'unseen))
    (should (equal (hey-posting-subject first) "Quarterly planX"))
    (should (equal (hey-posting-contacts first) "Alice Example"))
    (should (equal (hey-posting-summary first) "First line Second line"))
    (should (equal (mapcar #'hey-membership-name (hey-posting-labels first))
                   '("Planning" "Receipts" "Travel")))
    (should (equal (mapcar #'hey-membership-name
                           (hey-posting-collections first))
                   '("Launch")))
    (should (equal (hey-posting-app-url first)
                   "https://app.hey.com/topics/901"))
    (should (eq (hey-posting-kind bundle) 'bundle))
    (should-not (hey-posting-topic-id bundle))
    (should (equal (hey-posting-contact-id bundle) "51"))
    (should (eq (hey-posting-seen bundle) 'unseen))
    (should-not (hey-posting-app-url bundle))
    (should (equal (hey-source-continuation updated) "cursor-2"))
    (should-not (hey-source-exhausted updated))
    ;; The model API is pure: response pagination updates a copy.
    (should-not (hey-source-continuation source))))

(ert-deftest hey-model-omits-an-aggregate-bundle-date-from-list-rows ()
  (let* ((source (make-hey-source :kind 'box :account-id "101"))
         (posting (cadr
                   (plist-get
                    (hey-model-normalize-postings
                     (hey-model-test--fixture "postings-adversarial.json")
                     source)
                    :value))))
    (should (equal (hey-posting-timestamp posting)
                   "2025-11-27T10:00:00Z"))
    (should (equal (aref (hey-model-posting-row posting 'wide) 3) "")))
  (let ((posting (make-hey-posting
                  :kind 'bundle :topic-id "901"
                  :timestamp "2025-11-27T10:00:00Z")))
    (should (equal (aref (hey-model-posting-row posting 'wide) 3)
                   "2025-11-27T10:00:00Z"))))

(ert-deftest hey-model-separates-command-targets-from-opaque-cursors ()
  (let* ((source (make-hey-source :kind 'box :account-id "101"))
         (cursor-result
          (hey-model-normalize-postings
           '(("ok" . t)
             ("data" ("postings") ("next_page" . "-opaque-cursor")))
           source))
         (box-result
          (hey-model-normalize-boxes
           '(("ok" . t)
             ("data" (("kind" . "--help") ("name" . "Unsafe"))))
           "101")))
    (should (equal (hey-source-continuation
                    (plist-get cursor-result :source))
                   "-opaque-cursor"))
    (should-not (plist-get box-result :value))
    (should (plist-get box-result :warnings))))

(ert-deftest hey-model-normalizes-every-cursor-source-with-one-contract ()
  (dolist (kind '(box bundle contact-threads label collection))
    (let* ((source (make-hey-source
                    :key (list kind "101" "source")
                    :kind kind :account-id "101" :id "source"
                    :title "Synthetic" :continuation-kind 'cursor))
           (result (hey-model-normalize-postings
                    (hey-model-test--fixture "postings-adversarial.json")
                    source)))
      (should (= (length (plist-get result :value)) 2))
      (should (equal (hey-posting-key (car (plist-get result :value)))
                     '("101" "501")))
      (should (equal (hey-source-continuation (plist-get result :source))
                     "cursor-2")))))

(ert-deftest hey-model-omits-only-malformed-array-members ()
  (let* ((good '(("id" . 501) ("name" . "Good")))
         (envelope `(("ok" . t)
                     ("data" ("postings" ,good 42 "bad"))))
         (source (make-hey-source :kind 'box :account-id "101"))
         (result (hey-model-normalize-postings envelope source)))
    (should (= (length (plist-get result :value)) 1))
    (should (= (length (plist-get result :warnings)) 2)))
  (should (plist-get (hey-model-normalize-accounts '(("ok" . t)))
                     :warnings)))

(ert-deftest hey-model-rejects-repeated-cursors-without-mutating-source ()
  (let* ((source (make-hey-source
                  :key '(box "101" "imbox")
                  :kind 'box :account-id "101" :id "imbox"
                  :continuation-kind 'cursor :continuation "cursor-2"))
         (result (hey-model-normalize-postings
                  (hey-model-test--fixture "postings-adversarial.json") source))
         (updated (plist-get result :source)))
    (should (hey-source-exhausted updated))
    (should-not (hey-source-continuation updated))
    (should (member "cursor-2" (hey-source-consumed updated)))
    (should (equal (hey-source-continuation source) "cursor-2"))
    (should (cl-find-if (lambda (warning)
                          (string-match-p "repeated" warning))
                        (plist-get result :warnings)))))

(ert-deftest hey-model-search-uses-topic-identity-and-first-match-metadata ()
  (let* ((source (make-hey-source
                  :key '(search "all" "synthetic query")
                  :kind 'search :account-id "all" :title "Search"
                  :query "synthetic query" :continuation-kind 'page
                  :current-page 1))
         (result (hey-model-normalize-postings
                  (hey-model-test--fixture "search-defensive.json") source))
         (posting (car (plist-get result :value)))
         (updated (plist-get result :source)))
    (should (= (length (plist-get result :value)) 1))
    (should (= (length (plist-get result :warnings)) 1))
    (should (equal (hey-posting-key posting) '("all" "77")))
    (should-not (hey-posting-id posting))
    (should (equal (hey-posting-topic-id posting) "77"))
    (should (eq (hey-posting-seen posting) 'unknown))
    (should-not (hey-posting-labels posting))
    (should-not (hey-posting-collections posting))
    (should (equal (hey-posting-contacts posting) "First Match"))
    (should (equal (hey-posting-summary posting) "First matching excerpt"))
    (should (equal (hey-posting-app-url posting)
                   "https://app.hey.com/topics/77#entry-701"))
    (should (= (length (hey-posting-matches posting)) 2))
    (should (= (hey-source-current-page updated) 4))
    (should (= (hey-source-continuation updated) 5))
    (should-not (hey-source-exhausted updated))))

(ert-deftest hey-model-empty-search-page-is-exhausted ()
  (let* ((source (make-hey-source
                  :key '(search "all" "synthetic query")
                  :kind 'search :account-id "all" :title "Search"
                  :query "synthetic query" :continuation-kind 'page
                  :current-page 2))
         (result (hey-model-normalize-postings
                  '(("ok" . t) ("data") ("meta" ("page" . 2)))
                  source))
         (updated (plist-get result :source)))
    (should-not (plist-get result :value))
    (should (hey-source-exhausted updated))
    (should-not (hey-source-continuation updated))))

(ert-deftest hey-model-repeated-search-page-is-exhausted ()
  (let* ((source (make-hey-source
                  :key '(search "all" "synthetic query")
                  :kind 'search :account-id "all" :title "Search"
                  :query "synthetic query" :continuation-kind 'page
                  :current-page 4 :consumed '(4)))
         (result (hey-model-normalize-postings
                  (hey-model-test--fixture "search-defensive.json") source))
         (updated (plist-get result :source)))
    (should (plist-get result :value))
    (should (hey-source-exhausted updated))
    (should-not (hey-source-continuation updated))
    (should (equal (hey-source-consumed source) '(4)))
    (should (cl-find-if (lambda (warning)
                          (string-match-p "repeated" warning))
                        (plist-get result :warnings)))))

(ert-deftest hey-model-normalizes-flat-partial-thread-in-cli-order ()
  (let* ((context (list :account-id "all"
                        :account-name "All Accounts"
                        :topic-id "77"
                        :subject "*[Forged]#\nAccount: evil"
                        :source-title "Search"
                        :labels nil
                        :labels-known-p t
                        :collections nil
                        :collections-known-p nil))
         (result (hey-model-normalize-thread
                  (hey-model-test--fixture "thread-partial-adversarial.json")
                  context))
         (thread (plist-get result :value)))
    (should (= (length (hey-thread-entries thread)) 2))
    (should (= (length (plist-get result :warnings)) 1))
    (should (equal (mapcar #'hey-entry-id (hey-thread-entries thread))
                   '("801" "802")))
    (should (equal (hey-entry-body (car (hey-thread-entries thread)))
                   "# Body heading\n\nBody text with [relative](/topics/77)."))
    (should (eq (hey-entry-body-state (cadr (hey-thread-entries thread)))
                'over-limit))
    (should (equal (hey-thread-senders thread)
                   '("Mallory # forged Subject: fake")))
    (should (equal (hey-thread-app-url thread)
                   "https://app.hey.com/topics/77#entry-801"))
    (should (equal (hey-thread-notice thread) "Thread read only in part!"))))

(ert-deftest hey-model-memberships-compact-with-full-help ()
  (let* ((memberships (mapcar
                       (lambda (name) (make-hey-membership :name name))
                       '("Planning" "Receipts" "Travel")))
         (formatted (hey-model-format-memberships memberships 20)))
    (should (equal (substring-no-properties formatted) "Planning +2"))
    (should (equal (get-text-property 0 'help-echo formatted)
                   "Planning, Receipts, Travel")))
  (should (equal (hey-model-format-memberships nil 20) "")))

(ert-deftest hey-model-posting-row-has-four-frozen-layouts ()
  (let* ((posting (car
                   (plist-get
                    (hey-model-normalize-postings
                     (hey-model-test--fixture "postings-adversarial.json")
                     (make-hey-source :kind 'box :account-id "101"))
                    :value)))
         (wide (hey-model-posting-row posting 'wide))
         (medium (hey-model-posting-row posting 'medium))
         (narrow (hey-model-posting-row posting 'narrow))
         (minimal (hey-model-posting-row posting 'minimal)))
    (should (= (length wide) 4))
    (should (= (length medium) 4))
    (should (= (length narrow) 4))
    (should (= (length minimal) 2))
    (should (equal (substring-no-properties (aref wide 0))
                   "● Quarterly planX"))
    (should (eq (get-text-property 0 'face (aref wide 0))
                'hey-unseen-face))
    (should (equal (aref wide 1) "Alice Example"))
    (should (equal (aref wide 3) "2026-09-03T09:30:00Z"))
    (should (equal (aref narrow 1) "Alice Example"))
    (should (equal (aref narrow 3) "2026-09-03T09:30:00Z"))
    (should (equal (substring-no-properties (aref minimal 0))
                   "● Quarterly planX"))
    (should (equal (aref minimal 1) "2026-09-03T09:30:00Z"))
    (should (string-match-p "◇ Launch"
                            (substring-no-properties (aref wide 2))))
    (should (eq (get-text-property 0 'face (aref wide 2))
                'hey-label-face))
    (let ((collection-start (string-match "◇" (aref wide 2))))
      (should collection-start)
      (should (eq (get-text-property collection-start 'face (aref wide 2))
                  'hey-collection-face)))
    (should (string-match-p "Labels: Planning, Receipts, Travel"
                            (get-text-property 0 'help-echo (aref wide 2))))
    (should (<= (string-width (aref wide 2)) 28))
    (should (<= (string-width (aref medium 2)) 24))
    (should (<= (string-width (aref narrow 2)) 16))
    (let ((copy (copy-hey-posting posting)))
      (setf (hey-posting-seen copy) 'seen)
      (should-not
       (get-text-property 0 'face (aref (hey-model-posting-row copy 'wide)
                                         0))))
    (should-error (hey-model-posting-row posting 'unknown-layout))))

(ert-deftest hey-model-formats-same-day-posting-timestamp ()
  (let* ((timestamp "2026-09-03T09:30:00")
         (now (encode-time '(0 0 18 3 9 2026 nil -1 nil)))
         (formatted (hey-model-format-posting-timestamp timestamp now)))
    (should (equal (substring-no-properties formatted) "09:30"))
    (should (eq (get-text-property 0 'face formatted) 'hey-date-face))
    (should (equal (get-text-property 0 'help-echo formatted) timestamp))))

(ert-deftest hey-model-formats-previous-year-posting-with-year ()
  (let ((now (encode-time '(0 0 12 1 1 2026 nil -1 nil))))
    (should (equal (substring-no-properties
                    (hey-model-format-posting-timestamp
                     "2025-12-31T23:45:00" now))
                   "Dec 31, 2025"))))

(ert-deftest hey-model-formats-current-year-posting-as-month-and-day ()
  (let ((now (encode-time '(0 0 12 3 9 2026 nil -1 nil))))
    (should (equal (substring-no-properties
                    (hey-model-format-posting-timestamp
                     "2026-08-28T17:05:00" now))
                   "Aug 28"))))

(ert-deftest hey-model-honors-timezone-in-posting-timestamp ()
  (let* ((timestamp "2026-09-03T09:30:00+05:30")
         (instant (date-to-time timestamp)))
    (should (equal (substring-no-properties
                    (hey-model-format-posting-timestamp timestamp instant))
                   (format-time-string "%H:%M" instant)))))

(ert-deftest hey-model-falls-back-for-malformed-posting-timestamp ()
  (should (equal (substring-no-properties
                  (hey-model-format-posting-timestamp
                   "  not-a-date\nwith-noise  "
                   (encode-time '(0 0 12 3 9 2026 nil -1 nil))))
                 "not-a-date with-noise"))
  (should (equal (substring-no-properties
                  (hey-model-format-posting-timestamp
                   "2026-09-03T09:30:00" nil))
                 "2026-09-03T09:30:00")))

(ert-deftest hey-model-treats-only-json-true-as-seen ()
  (should (eq (hey-model--seen-state t) 'seen))
  (dolist (raw (list 'hey-json-false nil "false" 0))
    (should (eq (hey-model--seen-state raw) 'unseen))))

(ert-deftest hey-model-search-rows-never-claim-read-state ()
  "Stray `seen' values must not assign read state to search rows."
  (dolist (raw-seen '(t hey-json-false))
    (let* ((source (make-hey-source :key '(search "all" "synthetic query")
                                    :kind 'search :account-id "all"
                                    :title "Search" :query "synthetic query"
                                    :continuation-kind 'page))
           (row `(("topic_id" . 77) ("subject" . "Search result")
                  ("seen" . ,raw-seen)))
           (posting (car (plist-get (hey-model-normalize-postings
                                     `(("ok" . t) ("data" ,row))
                                     source)
                                    :value)))
           (subject (aref (hey-model-posting-row posting 'wide) 0)))
      (should (eq (hey-posting-seen posting) 'unknown))
      (should (equal (substring-no-properties subject) "Search result"))
      (should-not (get-text-property 0 'face subject)))))

(ert-deftest hey-model-renders-bodyless-entry-summary ()
  (let* ((context (list :account-id "all" :account-name "All Accounts"
                        :topic-id "77" :subject "Synthetic"
                        :source-title "Search"))
         (result
          (hey-model-normalize-thread
           '(("ok" . t)
             ("data" (("id" . 803)
                      ("created_at" . "2026-09-03 12:00")
                      ("creator" ("name" . "Alice"))
                      ("body" . "")
                      ("summary" . "Only\ncontent *safe*")
                      ("body_state" . "bodyless"))))
           context))
         (entry (car (hey-thread-entries (plist-get result :value))))
         (markdown (hey-model-thread-markdown (plist-get result :value))))
    (should (equal (hey-entry-summary entry) "Only content *safe*"))
    (should (string-match-p
             (regexp-quote "Only content \\*safe\\*") markdown))
    (should-not (string-match-p "no body" markdown))))

(ert-deftest hey-model-preserves-cli-1-4-3-image-markdown ()
  (dolist (body '("[Kitchen remodel](https://example.com/remodel)"
                  "[floor-plan.pdf](https://example.com/files/floor-plan.pdf)"
                  "[image](https://example.com/newsletter)"
                  "![Kitchen photo](https://example.com/kitchen.jpg)"))
    (let* ((result
            (hey-model-normalize-thread
             `(("ok" . t)
               ("data" (("id" . 803)
                        ("creator" ("name" . "Alice"))
                        ("body" . ,body)
                        ("body_state" . "hydrated"))))
             '(:account-id "101" :account-name "Personal"
               :topic-id "77" :subject "Kitchen remodel"
               :source-title "Imbox")))
           (thread (plist-get result :value))
           (entry (car (hey-thread-entries thread))))
      (should (equal (hey-entry-body entry) body))
      (should (string-match-p (regexp-quote (concat "\n" body "\n"))
                              (hey-model-thread-markdown thread))))))

(ert-deftest hey-model-thread-markdown-escapes-scaffold-not-body ()
  (let* ((context (list :account-id "all"
                        :account-name "All Accounts"
                        :topic-id "77"
                        :subject "*[Forged]#\nAccount: evil"
                        :source-title "Search"
                        :labels nil
                        :labels-known-p t
                        :collections nil
                        :collections-known-p nil))
         (thread (plist-get
                  (hey-model-normalize-thread
                   (hey-model-test--fixture "thread-partial-adversarial.json")
                   context)
                  :value))
         (markdown (hey-model-thread-markdown thread))
         (subject-pos (string-match "\\`Subject:" markdown))
         (senders-pos (string-match "^Senders:" markdown))
         (messages-pos (string-match "^Messages shown:" markdown))
         (account-pos (string-match "^Account:" markdown))
         (origin-pos (string-match "^Opened from:" markdown))
         (labels-pos (string-match "^Labels:" markdown)))
    (should (< subject-pos senders-pos messages-pos account-pos origin-pos labels-pos))
    (should (string-match-p
             (regexp-quote "\\*\\[Forged\\]\\# Account: evil") markdown))
    (should (string-match-p "^Labels:         none$" markdown))
    (should-not (string-match-p "^Collections:" markdown))
    (should-not (string-match-p "\nSubject: fake" markdown))
    ;; Body Markdown stays structurally intact, including its own heading.
    (should (string-match-p (regexp-quote "# Body heading\n\nBody text") markdown))
    (should (string-match-p (regexp-quote "*(body not read: over limit)*")
                            markdown))
    (let ((first (text-property-any 0 (length markdown)
                                    'hey-entry-start t markdown)))
      (should first)
      (should (equal (get-text-property first 'hey-entry-id markdown) "801"))
      (let ((second (text-property-any (1+ first) (length markdown)
                                       'hey-entry-start t markdown)))
        (should second)
        (should (equal (get-text-property second 'hey-entry-id markdown) "802"))))
    (should (string-match-p "^Notice:         Thread read only in part\\\\!$"
                            markdown))))

(provide 'hey-model-test)

;;; hey-model-test.el ends here
