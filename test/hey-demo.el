;;; hey-demo.el --- Synthetic interactive demo for HEY  -*- lexical-binding: t; -*-

;;; Commentary:

;; Load this file and run `hey-demo' to exercise the complete reader without a
;; HEY installation, credentials, private data, subprocess, or network access.

;;; Code:

(require 'hey)

(defun hey-demo--deliver (success envelope)
  "Deliver synthetic ENVELOPE to SUCCESS on the next event-loop turn."
  (run-at-time 0 nil success envelope))

(defun hey-demo--version (_owner _key _generation success _failure)
  "Fake the named version read and call SUCCESS."
  (hey-demo--deliver
   success '(("ok" . t) ("data" ("version" . "1.4.0")
                                ("source" . "synthetic demo")))))

(defun hey-demo--accounts (_owner _key _generation success _failure)
  "Fake the named account-list read and call SUCCESS."
  (hey-demo--deliver
   success '(("ok" . t)
             ("data" (("id" . "101") ("name" . "Personal Demo")
                       ("email" . "reader@example.invalid"))
                     (("id" . "all") ("name" . "All Demo Accounts"))))))

(defun hey-demo--auth (_owner _key _generation success _failure)
  "Fake the named authentication-status read and call SUCCESS."
  (hey-demo--deliver
   success '(("ok" . t)
             ("data" ("authenticated" . t) ("mail_account" . "101")))))

(defun hey-demo--boxes (_account _owner _key _generation success _failure)
  "Fake the named box-list read and call SUCCESS."
  (hey-demo--deliver
   success '(("ok" . t)
             ("data" (("id" . 1) ("kind" . "imbox") ("name" . "Imbox"))
                     (("id" . 2) ("kind" . "feedbox")
                      ("name" . "The Feed"))))))

(defun hey-demo--labels (_account _owner _key _generation success _failure)
  "Fake the named label-list read and call SUCCESS."
  (hey-demo--deliver
   success '(("ok" . t)
             ("data" (("id" . 11) ("name" . "Planning"))
                     (("id" . 12) ("name" . "Receipts"))))))

(defun hey-demo--collections
    (_account _owner _key _generation success _failure)
  "Fake the named collection-list read and call SUCCESS."
  (hey-demo--deliver
   success '(("ok" . t)
             ("data" (("id" . 21) ("name" . "Product launch"))))))

(defun hey-demo--posting (id topic name sender seen &optional kind)
  "Build a synthetic posting using ID, TOPIC, NAME, SENDER, SEEN, and KIND."
  `(("id" . ,id) ,@(when topic `(("topic_id" . ,topic)))
    ("kind" . ,(or kind "topic")) ("name" . ,name) ("seen" . ,seen)
    ("creator" ("name" . ,sender))
    ("summary" . "A safe excerpt shown by the synthetic demo.")
    ("created_at" . "2026-09-03 10:31")
    ("folders" (("id" . 11) ("name" . "Planning"))
               (("id" . 12) ("name" . "Receipts"))
               (("id" . 13) ("name" . "Travel")))
    ("collections" (("id" . 21) ("name" . "Product launch")))
    ,@(when topic
        `(("app_url" . ,(format "https://app.hey.com/topics/%s" topic))))))

(defun hey-demo--postings
    (_account source page _owner _key _generation success _failure)
  "Fake a named cursor source read for SOURCE and PAGE, then call SUCCESS."
  (hey-demo--deliver
   success
   (if page
       `(("ok" . t)
         ("data" ("postings"
                  ,(hey-demo--posting 504 904 "Second page: release notes"
                                      "Release Bot" t))))
     `(("ok" . t)
       ("data" ("next_page" . "demo-page-2")
        ("postings"
         ,(hey-demo--posting 501 901 "Design review moved"
                             "Alice Example" 'hey-json-false)
         ,(hey-demo--posting 502 nil "Build reports • status report"
                             "CI Bot" nil "bundle")
         ,(hey-demo--posting 503 903
                             (format "%s update" (capitalize source))
                             "Basecamp" t)))))))

(defun hey-demo--bundle
    (account posting-id page owner key generation success failure)
  "Fake bundle POSTING-ID in ACCOUNT at PAGE for OWNER.

Delegate with KEY and GENERATION, delivering to SUCCESS or FAILURE."
  (ignore account posting-id page owner key generation failure)
  (hey-demo--deliver
   success
   `(("ok" . t)
     ("data" ("postings"
              ,(hey-demo--posting 510 910 "Build completed"
                                  "CI Bot" t)
              ,(hey-demo--posting 511 911 "Status report"
                                  "Release Bot" t))))))

(defun hey-demo--search
    (_account query page _owner _key _generation success _failure)
  "Fake a named search for QUERY and PAGE, then call SUCCESS."
  (ignore query)
  (let* ((match
          '(("id" . 801)
            ("alternative_sender_name" . "Alice Example")
            ("summary" . "The matching synthetic passage.")
            ("created_at" . "2026-09-03 10:31")
            ("app_url" . "https://app.hey.com/topics/901#entry-801")))
         (result
          `(("id" . 501) ("topic_id" . 901)
            ("subject" . "Synthetic search result")
            ("updated_at" . "2026-09-03 10:31")
            ("messages" ,match)))
         (envelope
          (if page
              `(("ok" . t) ("data") ("meta" ("page" . ,page)))
            `(("ok" . t) ("data" ,result) ("meta" ("page" . 1))))))
    (hey-demo--deliver success envelope)))

(defun hey-demo--thread
    (_account topic _owner _key _generation success _failure)
  "Fake the named thread read for TOPIC and call SUCCESS."
  (hey-demo--deliver
   success
   `(("ok" . t)
     ("data"
      (("id" . 801) ("created_at" . "2026-09-02 09:10")
       ("creator" ("name" . "Alice Example"))
       ("body" .
        "# A body heading\n\nThe review moved to Friday. [Open in HEY](/topics/901).")
       ("body_state" . "hydrated")
       ("app_url" . ,(format "https://app.hey.com/topics/%s#entry-801"
                              topic)))
      (("id" . 802) ("created_at" . "2026-09-02 10:31")
       ("creator" ("name" . "Demo Reader"))
       ("body" . "Friday works for me.\n\n```elisp\n(message \"data only\")\n```")
       ("body_state" . "hydrated")))
     ("notice" . "Synthetic partial-read notice"))))

;;;###autoload
(defun hey-demo ()
  "Open the complete HEY reader with an asynchronous synthetic backend."
  (interactive)
  (let ((buffer (get-buffer-create "*HEY demo*")))
    (with-current-buffer buffer
      (hey-list-mode)
      (setq hey--operation-overrides
            '((hey-cli-version . hey-demo--version)
              (hey-cli-auth-status . hey-demo--auth)
              (hey-cli-account-list . hey-demo--accounts)
              (hey-cli-box-list . hey-demo--boxes)
              (hey-cli-box-view . hey-demo--postings)
              (hey-cli-bundle-view . hey-demo--bundle)
              (hey-cli-search . hey-demo--search)
              (hey-cli-thread-read . hey-demo--thread)
              (hey-cli-label-list . hey-demo--labels)
              (hey-cli-label-view . hey-demo--postings)
              (hey-cli-collection-list . hey-demo--collections)
              (hey-cli-collection-view . hey-demo--postings)))
      (let ((hey-account nil))
        (hey--start-session)))
    (hey-display-buffer buffer 'same-window)))

(provide 'hey-demo)
;;; hey-demo.el ends here
