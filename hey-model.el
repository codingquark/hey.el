;;; hey-model.el --- Pure records and formatting for HEY  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 codingquark
;; SPDX-License-Identifier: MIT

;; Author: Dhavan Vaidya <456712+codingquark@users.noreply.github.com>
;; Assisted-by: Codex:gpt-5
;; Keywords: mail
;; URL: https://github.com/codingquark/hey.el

;;; Commentary:

;; This file is the pure boundary between string-keyed HEY CLI JSON and the
;; package UI.  It performs no I/O and discards envelope fields the reader
;; does not need.

;;; Code:

(require 'cl-lib)
(require 'calendar)
(require 'iso8601)
(require 'subr-x)
(require 'url-parse)

(defgroup hey nil
  "Read HEY mail without mailbox mutations."
  :group 'applications
  :prefix "hey-")

(defface hey-unseen-face
  '((t :inherit bold))
  "Face for the subjects of explicitly unseen HEY postings."
  :group 'hey)

(defface hey-label-face
  '((t :inherit shadow))
  "Face for HEY label memberships."
  :group 'hey)

(defface hey-collection-face
  '((t :inherit font-lock-constant-face))
  "Face for HEY collection memberships."
  :group 'hey)

(defconst hey-model--official-origin "https://app.hey.com"
  "The only application origin accepted for displayed or followed URLs.")

(cl-defstruct hey-account
  "A linked HEY mail account or the all-accounts filter."
  id name email all-p)

(cl-defstruct hey-auth-status
  "Normalized authentication state and global account selection."
  authenticated account-id)

(cl-defstruct hey-version
  "Normalized HEY CLI version and build-source description."
  version source)

(cl-defstruct hey-source
  "A stable read source and its append-pagination state."
  key kind account-id id title query continuation-kind continuation consumed
  exhausted current-page)

(cl-defstruct hey-membership
  "A label or collection membership."
  id name)

(cl-defstruct hey-match
  "Metadata for one message which matched a search."
  id sender timestamp summary app-url)

(cl-defstruct hey-posting
  "A normalized row from a HEY posting source.

KIND is the symbol `bundle' for a bundle row and `thread' otherwise.  SEEN is
`seen' or `unseen' for sources which report read state, and `unknown' for
sources such as search which do not."
  key kind account-id id topic-id contact-id subject contacts summary timestamp
  seen
  labels collections app-url matches original-index)

(cl-defstruct hey-entry
  "One normalized entry in a HEY thread."
  id sender timestamp body summary body-state app-url)

(cl-defstruct hey-thread
  "A normalized HEY thread assembled from entries and origin context."
  account-id account-name topic-id subject source-title senders labels
  labels-known-p collections collections-known-p entries app-url notice)

(cl-defstruct hey-error
  "A transport or CLI error safe for presentation by the UI."
  category message code hint exit-status)

(defun hey-model--get (key object)
  "Return the value for string KEY in alist OBJECT."
  (and (hey-model--object-p object) (cdr (assoc-string key object))))

(defun hey-model--has-key-p (key object)
  "Return non-nil if string KEY is present in alist OBJECT."
  (and (hey-model--object-p object) (assoc-string key object)))

(defun hey-model--object-p (value)
  "Return non-nil when VALUE has the string-keyed alist representation."
  (and (consp value)
       (cl-every (lambda (item)
                   (and (consp item) (stringp (car item))))
                 value)))

(defun hey-model--array-p (value)
  "Return non-nil when VALUE has a JSON array representation.

Malformed array members are accepted here so normalizers can omit and warn
about individual records without discarding otherwise valid neighbors."
  (and (listp value) (or (null value) (not (hey-model--object-p value)))))

(defun hey-model--clean-string (value)
  "Return VALUE as sanitized metadata, or an empty string."
  (if (stringp value) (hey-model-sanitize-metadata value) ""))

;; String identifiers are never rewritten: a value which sanitization or
;; trimming would change is rejected, so two hostile identifiers cannot
;; collapse onto one composite identity.
(defun hey-model--id-string (value)
  "Return clean, exact identifier VALUE as a string, or nil.

Numeric identifiers must be positive integers."
  (cond
   ((and (integerp value) (> value 0)) (number-to-string value))
   ((stringp value)
    (let ((clean (hey-model-sanitize-metadata value)))
      (and (not (string-empty-p value))
           (string= clean value)
           (string= value (string-trim value))
           (not (string-prefix-p "-" value))
           (not (string-match-p "\\`0+\\'" value))
           value)))
   (t nil)))

(defun hey-model--opaque-string (value)
  "Return clean opaque VALUE unchanged, or nil when it is unsafe or empty."
  (when (stringp value)
    (let ((clean (hey-model-sanitize-metadata value)))
      (and (not (string-empty-p value))
           (string= clean value)
           (string= value (string-trim value))
           value))))

(defun hey-model--command-target-string (value)
  "Return opaque VALUE when safe as a positional command target."
  (let ((target (hey-model--opaque-string value)))
    (and target (not (string-prefix-p "-" target)) target)))

(defun hey-model--account-id-string (value)
  "Return VALUE as an account identity, including literal `all'."
  (if (and (stringp value) (string= value "all"))
      value
    (hey-model--id-string value)))

(defun hey-model--known-kind-p (kind expected)
  "Return non-nil when KIND denotes EXPECTED despite string/symbol form."
  (or (eq kind expected)
      (and (stringp kind) (string= kind (symbol-name expected)))))

(defun hey-model-sanitize-metadata (string)
  "Make untrusted metadata STRING safe for single-line display.

ANSI control sequences, C0/C1 controls, and Unicode bidirectional controls
are removed.  Tabs and line breaks become ordinary spaces, runs of ASCII
spacing collapse, and surrounding spacing is trimmed.  Non-string input
produces the empty string so absent and null JSON fields remain non-fatal."
  (if (not (stringp string))
      ""
    (let ((value string))
      ;; Remove complete terminal sequences before removing their ESC bytes.
      (setq value
            (replace-regexp-in-string
             "\e\\(?:\\[[0-?]*[ -/]*[@-~]\\|\\][^\a\e]*\\(?:\a\\|\e\\\\\\)\\|[PX^_][^\e]*\e\\\\\\|[@-_]\\)"
             "" value t t))
      (setq value (replace-regexp-in-string "[\t\n\r]+" " " value t t))
      (setq value
            (replace-regexp-in-string
             "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]" "" value t t))
      (setq value
            (replace-regexp-in-string
             "[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]" "" value t t))
      (string-trim (replace-regexp-in-string " +" " " value t t)))))

(defun hey-model-validate-app-url (string)
  "Return STRING for an exact official HEY-origin URL; otherwise return nil.

The accepted origin is `https://app.hey.com' with no user information and no
explicit port.  Whitespace, controls, backslashes, and bidi controls are also
rejected rather than normalized."
  (let ((case-fold-search nil))
    (when (and (stringp string)
               (string-match-p
                "\\`https://app\\.hey\\.com\\(?:[/?#]\\|\\'\\)" string)
               (not (string-match-p
                     "[[:space:][:cntrl:]\\\\\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]"
                     string)))
      (condition-case nil
          (let ((url (url-generic-parse-url string)))
            (when (and (string= (or (url-type url) "") "https")
                       (string= (or (url-host url) "") "app.hey.com")
                       (null (url-user url))
                       (null (url-password url))
                       ;; `url-port' reports the scheme default even without
                       ;; an explicit port.  The prefix check above rejects a
                       ;; colon after the host, so 443 here is that default.
                       (= (url-port url) 443))
              string))
        (error nil)))))

(defun hey-model-resolve-body-url (string)
  "Validate or resolve an email-body link STRING against the HEY origin.

Absolute links are accepted only at the official application origin.
Root-relative links are resolved there.  Scheme-relative, path-relative,
local-file, and all other URL forms return nil."
  (cond
   ((hey-model-validate-app-url string) string)
   ((and (stringp string)
         (string-prefix-p "/" string)
         (not (string-prefix-p "//" string)))
    (hey-model-validate-app-url (concat hey-model--official-origin string)))
   (t nil)))

(defun hey-model--warning (kind index reason)
  "Build a non-sensitive warning for KIND record INDEX and REASON."
  (format "Skipped %s at index %d: %s" kind index reason))

(defun hey-model--array-data (envelope)
  "Return ENVELOPE data when it is an array, else the symbol `malformed'."
  (let ((data (hey-model--get "data" envelope)))
    (if (and (hey-model--has-key-p "data" envelope)
             (hey-model--array-p data))
        data
      'malformed)))

(defun hey-model-normalize-accounts (envelope)
  "Normalize account-list ENVELOPE.

Return a plist with `:value' holding `hey-account' records and `:warnings'
holding non-fatal shape warnings."
  (let ((data (hey-model--array-data envelope)) values warnings)
    (if (eq data 'malformed)
        (setq warnings '("Envelope data is missing or not an account array."))
      (cl-loop for raw in data
               for index from 0
               for id = (hey-model--account-id-string (hey-model--get "id" raw))
               if (not id)
               do (push (hey-model--warning "account" index "missing or unsafe id") warnings)
               else
               do (let* ((all-p (string= id "all"))
                         (name (hey-model--clean-string (hey-model--get "name" raw)))
                         (email (hey-model--clean-string (hey-model--get "email" raw))))
                    (push (make-hey-account
                           :id id
                           :name (if (and all-p (string-empty-p name))
                                     "All Accounts"
                                   name)
                           :email email
                           :all-p all-p)
                          values))))
    (list :value (nreverse values) :warnings (nreverse warnings))))

(defun hey-model-normalize-auth-status (envelope)
  "Normalize authentication-status ENVELOPE without retaining device data.

Return `:value' as a `hey-auth-status' and `:warnings' for absent or unsafe
fields.  Installation identifiers and all other authentication metadata are
discarded at this boundary."
  (let* ((data (hey-model--get "data" envelope))
         (raw-authenticated (and (hey-model--object-p data)
                                 (hey-model--get "authenticated" data)))
         (authenticated (eq raw-authenticated t))
         (account-id (and (hey-model--object-p data)
                          (hey-model--account-id-string
                           (hey-model--get "mail_account" data))))
         warnings)
    (unless (hey-model--object-p data)
      (push "Envelope data is missing or not an authentication object."
            warnings))
    (when (and (hey-model--object-p data)
               (not (memq raw-authenticated '(t hey-json-false))))
      (push "Authentication status omitted an explicit boolean." warnings))
    (when (and authenticated (not account-id))
      (push "Authenticated status omitted a safe global account id." warnings))
    (list :value (make-hey-auth-status
                  :authenticated authenticated
                  :account-id account-id)
          :warnings (nreverse warnings))))

(defun hey-model-normalize-version (envelope)
  "Normalize version ENVELOPE without retaining build provenance details.

Return `:value' as a `hey-version' and `:warnings' for absent or unsafe
fields.  Commit, build date, and Go toolchain fields are deliberately
discarded because the UI only needs the CLI version and its broad source."
  (let* ((data (hey-model--get "data" envelope))
         (version (and (hey-model--object-p data)
                       (hey-model--opaque-string
                        (hey-model--get "version" data))))
         (source (and (hey-model--object-p data)
                      (hey-model--clean-string
                       (hey-model--get "source" data))))
         warnings)
    (unless (hey-model--object-p data)
      (push "Envelope data is missing or not a version object." warnings))
    (when (and (hey-model--object-p data) (not version))
      (push "Version response omitted a safe version string." warnings))
    (list :value (make-hey-version :version version :source source)
          :warnings (nreverse warnings))))

(defun hey-model--normalize-source-inventory (envelope account-id kind)
  "Normalize source inventory ENVELOPE for ACCOUNT-ID and source KIND."
  (let ((data (hey-model--array-data envelope))
        (account (hey-model--account-id-string account-id))
        values warnings)
    (unless account
      (push "Cannot normalize sources without a safe account id." warnings))
    (if (eq data 'malformed)
        (push "Envelope data is missing or not a source array." warnings)
      (when account
        (cl-loop for raw in data
                 for index from 0
                 for id = (hey-model--id-string (hey-model--get "id" raw))
                 if (not id)
                 do (push (hey-model--warning
                           (symbol-name kind) index "missing or unsafe id")
                          warnings)
                 else
                 do (let ((title (hey-model--clean-string
                                  (hey-model--get "name" raw))))
                      (push (make-hey-source
                             :key (list kind account id)
                             :kind kind
                             :account-id account
                             :id id
                             :title title
                             :continuation-kind 'cursor
                             :consumed nil
                             :exhausted nil)
                            values)))))
    (list :value (nreverse values) :warnings (nreverse warnings))))

(defun hey-model-normalize-labels (envelope account-id)
  "Normalize label-list ENVELOPE for ACCOUNT-ID into `hey-source' records."
  (hey-model--normalize-source-inventory envelope account-id 'label))

(defun hey-model-normalize-collections (envelope account-id)
  "Normalize collection-list ENVELOPE for ACCOUNT-ID into `hey-source' records."
  (hey-model--normalize-source-inventory envelope account-id 'collection))

(defun hey-model-normalize-boxes (envelope account-id)
  "Normalize box-list ENVELOPE for ACCOUNT-ID into `hey-source' records.

The source command identifier is the box `kind' slug when present and the
numeric box ID otherwise.  Human names never become command identifiers.
Return a plist with `:value' and `:warnings'."
  (let ((data (hey-model--array-data envelope))
        (account (hey-model--account-id-string account-id))
        values warnings)
    (unless account
      (push "Cannot normalize boxes without a safe account id." warnings))
    (if (eq data 'malformed)
        (push "Envelope data is missing or not a box array." warnings)
      (when account
        (cl-loop for raw in data
                 for index from 0
                 for numeric-id = (hey-model--id-string (hey-model--get "id" raw))
                 for box-kind = (hey-model--command-target-string
                                  (hey-model--get "kind" raw))
                 for source-id = (or box-kind numeric-id)
                 if (not source-id)
                 do (push (hey-model--warning "box" index "missing command id and kind") warnings)
                 else
                 do (let ((title (hey-model--clean-string (hey-model--get "name" raw))))
                      (push (make-hey-source
                             :key (list 'box account source-id)
                             :kind 'box
                             :account-id account
                             :id source-id
                             :title title
                             :continuation-kind 'cursor
                             :consumed nil
                             :exhausted nil)
                            values)))))
    (list :value (nreverse values) :warnings (nreverse warnings))))

(defun hey-model--contact-display (raw)
  "Return the best single-line sender display available in RAW."
  (let ((alternative
         (hey-model--clean-string
          (hey-model--get "alternative_sender_name" raw)))
        (creator (hey-model--get "creator" raw))
        (contacts (hey-model--get "contacts" raw)))
    (cond
     ((not (string-empty-p alternative)) alternative)
     ((hey-model--object-p creator)
      (let ((name (hey-model--clean-string (hey-model--get "name" creator)))
            (email (hey-model--clean-string
                    (hey-model--get "email_address" creator))))
        (if (string-empty-p name) email name)))
     ((hey-model--array-p contacts)
      (string-join
       (delete-dups
        (delq nil
              (mapcar
               (lambda (contact)
                 (let ((name (hey-model--clean-string
                              (hey-model--get "name" contact)))
                       (email (hey-model--clean-string
                               (hey-model--get "email_address" contact))))
                   (cond ((not (string-empty-p name)) name)
                         ((not (string-empty-p email)) email))))
               contacts)))
       ", "))
     ((stringp contacts) (hey-model--clean-string contacts))
     (t ""))))

(defun hey-model--normalize-memberships (raw)
  "Normalize ordered membership objects from RAW."
  (let (memberships)
    (when (hey-model--array-p raw)
      (dolist (item raw)
        (let ((id (hey-model--id-string (hey-model--get "id" item)))
              (name (hey-model--clean-string (hey-model--get "name" item))))
          (when (or id (not (string-empty-p name)))
            (push (make-hey-membership :id id :name name) memberships)))))
    (nreverse memberships)))

(defun hey-model--posting-contact-id (raw)
  "Return the first safe contact ID represented by RAW, or nil."
  (let ((creator (hey-model--get "creator" raw))
        (contacts (hey-model--get "contacts" raw)))
    (or (and (hey-model--object-p creator)
             (hey-model--id-string (hey-model--get "id" creator)))
        (and (hey-model--array-p contacts)
             (cl-loop for contact in contacts
                      thereis (hey-model--id-string
                               (hey-model--get "id" contact)))))))

(defun hey-model--seen-state (raw)
  "Return `seen' only when RAW is t, and `unseen' otherwise."
  (if (eq raw t) 'seen 'unseen))

(defun hey-model--normalize-match (raw)
  "Normalize one matching-message RAW object."
  (make-hey-match
   :id (hey-model--id-string (hey-model--get "id" raw))
   :sender (hey-model--contact-display raw)
   :timestamp (hey-model--clean-string (hey-model--get "created_at" raw))
   :summary (hey-model--clean-string (hey-model--get "summary" raw))
   :app-url (hey-model-validate-app-url (hey-model--get "app_url" raw))))

(defun hey-model--normalize-matches (raw)
  "Normalize every search match in RAW, preserving CLI order."
  (if (hey-model--array-p raw)
      (delq nil
            (mapcar (lambda (item)
                      (and (hey-model--object-p item)
                           (hey-model--normalize-match item)))
                    raw))
    nil))

(defun hey-model--normalize-posting (raw source index)
  "Normalize RAW posting from SOURCE at INDEX, or return nil."
  (let* ((search-p (hey-model--known-kind-p (hey-source-kind source) 'search))
         (account-id (hey-model--account-id-string (hey-source-account-id source)))
         (id (hey-model--id-string (hey-model--get "id" raw)))
         (topic-id (hey-model--id-string (hey-model--get "topic_id" raw)))
         (identity (if search-p topic-id id)))
    (when (and account-id identity)
      (let* ((matches (and search-p
                           (hey-model--normalize-matches
                            (hey-model--get "messages" raw))))
             (first-match (car matches))
             (kind (if (and (not search-p)
                            (string= (hey-model--clean-string
                                      (hey-model--get "kind" raw))
                                     "bundle"))
                       'bundle
                     'thread)))
        (make-hey-posting
         :key (list account-id identity)
         :kind kind
         :account-id account-id
         :id id
         :topic-id topic-id
         :contact-id (unless search-p
                       (hey-model--posting-contact-id raw))
         :subject (hey-model--clean-string
                   (hey-model--get (if search-p "subject" "name") raw))
         :contacts (if search-p
                       (or (and first-match (hey-match-sender first-match)) "")
                     (hey-model--contact-display raw))
         :summary (if search-p
                      (or (and first-match (hey-match-summary first-match)) "")
                    (hey-model--clean-string (hey-model--get "summary" raw)))
         :timestamp (hey-model--clean-string
                     (or (hey-model--get (if search-p "updated_at" "created_at") raw)
                         (hey-model--get "updated_at" raw)))
         ;; Search rows have no authoritative `seen' field; never guess.
         :seen (if search-p
                   'unknown
                 (hey-model--seen-state (hey-model--get "seen" raw)))
         :labels (unless search-p
                   (hey-model--normalize-memberships
                    (hey-model--get "folders" raw)))
         :collections (unless search-p
                        (hey-model--normalize-memberships
                         (hey-model--get "collections" raw)))
         :app-url (if search-p
                      (and first-match (hey-match-app-url first-match))
                    (hey-model-validate-app-url
                     (hey-model--get "app_url" raw)))
         :matches matches
         :original-index index)))))

(defun hey-model--source-with-continuation (source envelope records warnings)
  "Return a copied SOURCE updated from ENVELOPE, RECORDS, and WARNINGS.

The return value is a cons of the copied source and possibly extended warning
list.  SOURCE itself is never mutated."
  (let* ((copy (copy-hey-source source))
         (search-p (hey-model--known-kind-p (hey-source-kind source) 'search))
         (old (hey-source-continuation source))
         (consumed (copy-sequence (or (hey-source-consumed source) nil))))
    (if search-p
        (let* ((meta (hey-model--get "meta" envelope))
               (served (hey-model--get "page" meta))
               (page (if (and (integerp served) (> served 0))
                         served
                       (or (hey-source-current-page source) 1)))
               (repeated (member page consumed)))
          (when repeated
            (push "Search response repeated an already consumed page." warnings))
          (cl-pushnew page consumed :test #'equal)
          (setf (hey-source-current-page copy) page
                (hey-source-consumed copy) consumed
                (hey-source-continuation-kind copy) 'page
                (hey-source-continuation copy)
                (and records (not repeated) (1+ page))
                (hey-source-exhausted copy) (or repeated (null records))))
      (let* ((data (hey-model--get "data" envelope))
             (raw-next (and (hey-model--object-p data)
                            (hey-model--get "next_page" data)))
             (next (hey-model--opaque-string raw-next)))
        (when old (cl-pushnew old consumed :test #'equal))
        (cond
         ((and raw-next (not next))
          (push "Posting response returned an unsafe cursor." warnings)
          (setf (hey-source-continuation copy) nil
                (hey-source-exhausted copy) t))
         ((not next)
          (setf (hey-source-continuation copy) nil
                (hey-source-exhausted copy) t))
         ((member next consumed)
          (push "Posting response repeated an already consumed cursor." warnings)
          (setf (hey-source-continuation copy) nil
                (hey-source-exhausted copy) t))
         (t
          (setf (hey-source-continuation copy) next
                (hey-source-exhausted copy) nil)))
        (setf (hey-source-continuation-kind copy) 'cursor
              (hey-source-consumed copy) consumed)))
    (cons copy warnings)))

(defun hey-model-normalize-postings (envelope source)
  "Normalize a source-specific posting ENVELOPE for SOURCE.

Search consumes the envelope's data array, requires `topic_id', derives its
row metadata from the first matching message, and leaves seen/membership data
unknown.  Other sources consume `data.postings', require a posting `id', and
retain posting-level metadata.  Exact row keys are `(account-id posting-id)'
or `(account-id topic-id)' respectively.

Return `:value' records, `:source' as an updated copy with continuation state,
and `:warnings'.  SOURCE is not mutated."
  (let* ((search-p (hey-model--known-kind-p (hey-source-kind source) 'search))
         (data (hey-model--get "data" envelope))
         (raw-records (if search-p data (hey-model--get "postings" data)))
         (records-present-p
          (if search-p
              (hey-model--has-key-p "data" envelope)
            (and (hey-model--object-p data)
                 (hey-model--has-key-p "postings" data))))
         values warnings)
    (unless (hey-model--account-id-string (hey-source-account-id source))
      (push "Cannot normalize postings without a safe account id." warnings))
    (if (not (and records-present-p (hey-model--array-p raw-records)))
        (push "Envelope data does not contain the expected posting array." warnings)
      (cl-loop for raw in raw-records
               for index from 0
               for record = (hey-model--normalize-posting raw source index)
               if record do (push record values)
               else do (push (hey-model--warning
                              (if search-p "search result" "posting") index
                              (if search-p
                                  "missing account id or topic_id"
                                "missing account id or posting id"))
                             warnings)))
    (setq values (nreverse values))
    (pcase-let ((`(,updated . ,all-warnings)
                 (hey-model--source-with-continuation
                  source envelope values warnings)))
      (list :value values :source updated :warnings (nreverse all-warnings)))))

(defun hey-model-envelope-notice (envelope)
  "Return sanitized, single-line notice text from ENVELOPE, or nil."
  (let ((notice (hey-model--clean-string (hey-model--get "notice" envelope))))
    (unless (string-empty-p notice) notice)))

(defun hey-model--body-state (raw)
  "Map known RAW CLI body state strings to bounded symbols."
  (pcase raw
    ("hydrated" 'hydrated)
    ("bodyless" 'bodyless)
    ("over_limit" 'over-limit)
    ("failed" 'failed)
    ("not_requested" 'not-requested)
    (_ 'unknown)))

(defun hey-model--normalize-entry (raw)
  "Normalize one RAW thread entry, or return nil without an exact ID."
  (let ((id (hey-model--id-string (hey-model--get "id" raw))))
    (when id
      (let ((body (hey-model--get "body" raw)))
        (make-hey-entry
         :id id
         :sender (hey-model--contact-display raw)
         :timestamp (hey-model--clean-string (hey-model--get "created_at" raw))
         :body (if (stringp body) body "")
         :summary (hey-model--clean-string (hey-model--get "summary" raw))
         :body-state (hey-model--body-state (hey-model--get "body_state" raw))
         :app-url (hey-model-validate-app-url (hey-model--get "app_url" raw)))))))

(defun hey-model--sanitize-membership-records (memberships)
  "Copy and sanitize normalized MEMBERSHIPS supplied through thread context."
  (let (result)
    (dolist (membership memberships)
      (when (hey-membership-p membership)
        (let ((id (hey-model--id-string (hey-membership-id membership)))
              (name (hey-model--clean-string (hey-membership-name membership))))
          (when (or id (not (string-empty-p name)))
            (push (make-hey-membership :id id :name name) result)))))
    (nreverse result)))

(defun hey-model-normalize-thread (envelope context)
  "Normalize flat thread-entry ENVELOPE using normalized origin CONTEXT.

CONTEXT contains only the keys frozen in docs/interfaces.md.  Entry order is
preserved exactly; timestamps are never used to reorder messages.  Return a
plist with `:value' holding one `hey-thread' and non-fatal `:warnings'."
  (let ((data (hey-model--array-data envelope)) entries warnings)
    (if (eq data 'malformed)
        (push "Envelope data is missing or not a thread-entry array." warnings)
      (cl-loop for raw in data
               for index from 0
               for entry = (hey-model--normalize-entry raw)
               if entry do (push entry entries)
               else do (push (hey-model--warning
                              "thread entry" index "missing or unsafe id")
                             warnings)))
    (setq entries (nreverse entries))
    (let (senders app-url)
      (dolist (entry entries)
        (let ((sender (hey-entry-sender entry)))
          (unless (or (string-empty-p sender) (member sender senders))
            (setq senders (append senders (list sender)))))
        (unless app-url (setq app-url (hey-entry-app-url entry))))
      (list
       :value
       (make-hey-thread
        :account-id (hey-model--account-id-string (plist-get context :account-id))
        :account-name (hey-model--clean-string (plist-get context :account-name))
        :topic-id (hey-model--id-string (plist-get context :topic-id))
        :subject (hey-model--clean-string (plist-get context :subject))
        :source-title (hey-model--clean-string (plist-get context :source-title))
        :senders senders
        :labels (hey-model--sanitize-membership-records
                 (plist-get context :labels))
        :labels-known-p (eq (plist-get context :labels-known-p) t)
        :collections (hey-model--sanitize-membership-records
                      (plist-get context :collections))
        :collections-known-p (eq (plist-get context :collections-known-p) t)
        :entries entries
        :app-url app-url
        :notice (hey-model-envelope-notice envelope))
       :warnings (nreverse warnings)))))

(defun hey-model--membership-names (memberships)
  "Return display names for MEMBERSHIPS, preserving their order."
  (delq nil
        (mapcar (lambda (membership)
                  (when (hey-membership-p membership)
                    (let ((name (hey-model--clean-string
                                 (hey-membership-name membership)))
                          (id (hey-model--id-string
                               (hey-membership-id membership))))
                      (cond ((not (string-empty-p name)) name)
                            (id id)))))
                memberships)))

(defun hey-model-format-memberships (memberships max-width)
  "Format ordered MEMBERSHIPS within MAX-WIDTH columns.

The result is comma-separated.  Overflow is summarized as ` +N', for example
`Receipts, Travel +2'.  A truncated result carries the complete text in its
`help-echo' property.  MAX-WIDTH nil means unbounded."
  (let* ((names (hey-model--membership-names memberships))
         (full (string-join names ", "))
         (width (and (integerp max-width) (max 0 max-width))))
    (cond
     ((string-empty-p full) "")
     ((or (null width) (<= (string-width full) width)) full)
     ((zerop width) (propertize "" 'help-echo full))
     (t
      (let ((count 0) best)
        (while (< count (length names))
          (let* ((shown (1+ count))
                 (remaining (- (length names) shown))
                 (candidate
                  (concat (string-join (cl-subseq names 0 shown) ", ")
                          (if (> remaining 0) (format " +%d" remaining) ""))))
            (if (<= (string-width candidate) width)
                (setq best candidate count shown)
              (setq count (length names)))))
        (unless best
          (setq best (truncate-string-to-width (car names) width nil nil "…")))
        (propertize best 'help-echo full))))))

;; When both kinds are present, MAX-WIDTH reserves 5 columns for the " · " and
;; "◇ " separators and splits the rest three-to-two in favour of labels.  A
;; collections-only cell reserves 2 columns for its "◇ " prefix.
(defun hey-model--row-memberships (posting max-width)
  "Return a compact membership cell for POSTING within MAX-WIDTH columns."
  (let* ((label-records (hey-posting-labels posting))
         (collection-records (hey-posting-collections posting))
         (bounded (and (integerp max-width) (max 0 max-width)))
         (both (and label-records collection-records))
         (content-width (and bounded (max 0 (- bounded (if both 5 0)))))
         (label-width (and content-width
                           (if both (/ (+ (* content-width 3) 4) 5)
                             content-width)))
         (collection-width (and content-width
                                (if both (- content-width label-width)
                                  (max 0 (- content-width 2)))))
         (labels (hey-model-format-memberships label-records label-width))
         (collections (hey-model-format-memberships
                       collection-records collection-width))
         (cell
          (cond
           ((and (not (string-empty-p labels))
                 (not (string-empty-p collections)))
            (concat (propertize labels 'face 'hey-label-face)
                    " · "
                    (propertize (concat "◇ " collections)
                                'face 'hey-collection-face)))
           ((not (string-empty-p labels))
            (propertize labels 'face 'hey-label-face))
           ((not (string-empty-p collections))
            (propertize (concat "◇ " collections)
                        'face 'hey-collection-face))
           (t "")))
         (full-labels (string-join
                       (hey-model--membership-names (hey-posting-labels posting))
                       ", "))
         (full-collections
          (string-join
           (hey-model--membership-names (hey-posting-collections posting)) ", "))
         (help (string-join
                (delq nil
                      (list (and (not (string-empty-p full-labels))
                                 (concat "Labels: " full-labels))
                            (and (not (string-empty-p full-collections))
                                 (concat "Collections: " full-collections))))
                "\n")))
    (when (and bounded (> (string-width cell) bounded))
      (setq cell (truncate-string-to-width
                  cell bounded nil nil "…")))
    (if (string-empty-p help) cell (propertize cell 'help-echo help))))

(defun hey-model--local-date-number (time)
  "Return the absolute local calendar date containing TIME."
  (let ((decoded (decode-time time)))
    (calendar-absolute-from-gregorian
     (list (decoded-time-month decoded)
           (decoded-time-day decoded)
           (decoded-time-year decoded)))))

(defun hey-model-format-posting-timestamp (timestamp now)
  "Format posting TIMESTAMP relative to NOW in the local time zone.

Return `Today HH:MM' or `Yesterday HH:MM' for the corresponding local
calendar dates.  Return YYYY-MM-DD for any other parseable ISO 8601 timestamp.
Malformed timestamps fall back to their sanitized original text."
  (let ((clean (hey-model--clean-string timestamp)))
    (if (null now)
        clean
      (condition-case nil
          (let* ((time (encode-time (iso8601-parse clean)))
                 (date-difference (- (hey-model--local-date-number now)
                                     (hey-model--local-date-number time))))
            (cond
             ((zerop date-difference)
              (format-time-string "Today %H:%M" time))
             ((= date-difference 1)
              (format-time-string "Yesterday %H:%M" time))
             (t (format-time-string "%Y-%m-%d" time))))
        (error clean)))))

(defun hey-model-posting-row (posting layout)
  "Format POSTING as a vector for symbolic LAYOUT.

The frozen layouts are:

  `wide'    [date sender subject memberships summary]
  `medium'  [date sender subject memberships]
  `narrow'  [sender subject memberships date]
  `minimal' [sender subject date]

Unseen subjects carry a leading marker and `hey-unseen-face'; only an
explicit `unseen' state earns that presentation, so `seen' values and the
`unknown' state of search rows render plainly.  Memberships expose their
complete values via `help-echo'."
  (let* ((subject (hey-posting-subject posting))
         (subject-cell
          (if (eq (hey-posting-seen posting) 'unseen)
              (propertize (concat "● " subject) 'face 'hey-unseen-face)
            subject))
         ;; A bundle without one topic is an aggregate, so its timestamp does
         ;; not describe every subject joined in the row.
         (date (if (and (eq (hey-posting-kind posting) 'bundle)
                        (null (hey-posting-topic-id posting)))
                   ""
                 (hey-posting-timestamp posting)))
         (sender (hey-posting-contacts posting))
         (summary (hey-posting-summary posting)))
    (pcase layout
      ('wide
       (vector date sender subject-cell
               (hey-model--row-memberships posting 28) summary))
      ('medium
       (vector date sender subject-cell
               (hey-model--row-memberships posting 24)))
      ('narrow
       (vector sender subject-cell
               (hey-model--row-memberships posting 16) date))
      ('minimal (vector sender subject-cell date))
      (_ (error "Unknown HEY posting layout: %S" layout)))))

(defun hey-model--markdown-escape (value)
  "Escape sanitized metadata VALUE for literal Markdown text."
  (replace-regexp-in-string
   "[][\\\\`*{}_()#+.!|>-]" "\\\\\\&"
   (hey-model--clean-string value) t nil))

(defun hey-model--thread-field (label value)
  "Format preamble LABEL and Markdown-safe VALUE with aligned indentation."
  (format "%-16s%s\n" (concat label ":") (hey-model--markdown-escape value)))

;; `hydrated' means the CLI fetched a body which was itself empty, so this
;; description only renders when the body string is absent.
(defun hey-model--body-state-description (state)
  "Return a Markdown-safe human description of entry body STATE."
  (pcase state
    ('hydrated "empty body")
    ('bodyless "no body")
    ('over-limit "body not read: over limit")
    ('failed "body not read: failed")
    ('not-requested "body not requested")
    (_ "body unavailable")))

(defun hey-model-thread-markdown (thread)
  "Return the package-owned Markdown scaffold for normalized THREAD.

Metadata is sanitized and Markdown-escaped.  Entry bodies are already
Markdown from the CLI and are inserted unchanged; their headings do not
define UI entry boundaries."
  (let ((parts nil)
        (entries (hey-thread-entries thread)))
    (push (hey-model--thread-field "Subject" (hey-thread-subject thread)) parts)
    (push (hey-model--thread-field
           "Senders" (string-join (hey-thread-senders thread) ", ")) parts)
    (push (hey-model--thread-field
           "Messages shown" (number-to-string (length entries))) parts)
    (push (hey-model--thread-field "Account" (hey-thread-account-name thread)) parts)
    (push (hey-model--thread-field "Opened from" (hey-thread-source-title thread)) parts)
    (when (hey-thread-labels-known-p thread)
      (push (hey-model--thread-field
             "Labels"
             (or (and-let* ((names (hey-model--membership-names
                                    (hey-thread-labels thread)))
                            ((not (null names))))
                   (string-join names ", "))
                 "none"))
            parts))
    (when (hey-thread-collections-known-p thread)
      (push (hey-model--thread-field
             "Collections"
             (or (and-let* ((names (hey-model--membership-names
                                    (hey-thread-collections thread)))
                            ((not (null names))))
                   (string-join names ", "))
                 "none"))
            parts))
    (when (hey-thread-notice thread)
      (push (hey-model--thread-field "Notice" (hey-thread-notice thread)) parts))
    (push "\n---\n" parts)
    (dolist (entry entries)
      (let* ((entry-id (hey-entry-id entry))
             (header (format "\n## %s — %s\n\n"
                             (hey-model--markdown-escape
                              (hey-entry-sender entry))
                             (hey-model--markdown-escape
                              (hey-entry-timestamp entry))))
             (body (hey-entry-body entry))
             (content
              (cond
               ((and (stringp body) (not (string-empty-p body))) body)
               ((and (eq (hey-entry-body-state entry) 'bodyless)
                     (not (string-empty-p (hey-entry-summary entry))))
                (hey-model--markdown-escape (hey-entry-summary entry)))
               (t
                (format "*(%s)*"
                        (hey-model--body-state-description
                         (hey-entry-body-state entry))))))
             (chunk (concat header content "\n\n---\n")))
        ;; Text properties are the package-owned structural boundary.  They
        ;; survive insertion into the thread buffer and cannot be forged by a
        ;; Markdown heading inside CONTENT.
        (add-text-properties 0 (length chunk)
                             (list 'hey-entry-id entry-id) chunk)
        (add-text-properties 0 1 '(hey-entry-start t) chunk)
        (push chunk parts)))
    (apply #'concat (nreverse parts))))

(provide 'hey-model)

;;; hey-model.el ends here
