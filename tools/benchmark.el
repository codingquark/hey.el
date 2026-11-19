;;; benchmark.el --- Measure synthetic HEY workloads -*- lexical-binding: t; -*-

;;; Commentary:

;; Run byte-compiled package code with synthetic records and no subprocesses.
;; Timings include garbage collection and report the median of five samples.
;; These measurements are diagnostic, not pass/fail thresholds.

;;; Code:

(require 'benchmark)
(load (expand-file-name
       "common.el" (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)
(hey-build-initialize-packages)
(add-to-list 'load-path (hey-build-path "test"))
(require 'hey-test-helper)
(setq hey-executable hey-test-fake-executable
      exec-path nil)
(hey-test-assert-exact-fake hey-executable)

;; The optional directory lets the same workloads measure a compiled baseline.
(let ((directory (or (hey-build-environment-directory "HEY_BENCHMARK_LIBRARY_DIR")
                     (hey-build-path "test/tmp/byte-compile"))))
  (dolist (file (hey-build-library-files))
    (load (expand-file-name (concat (file-name-base file) ".elc") directory)
          nil 'nomessage t)))

(require 'hey-thread-performance-test)

(defun hey-benchmark--measure (name function &optional prepare)
  "Report median elapsed milliseconds and GC count for NAME's FUNCTION.
Run PREPARE before each sample, outside its timed region, when non-nil."
  (when prepare (funcall prepare))
  (funcall function)
  (let (samples)
    (dotimes (_ 5)
      (when prepare (funcall prepare))
      (garbage-collect)
      (push (benchmark-call function) samples))
    (let ((median (nth 2 (sort samples (lambda (a b) (< (car a) (car b)))))))
      (princ (format "%-43s %10.3f ms  %2d GCs\n"
                     name (* 1000 (car median)) (cadr median))))))

(defun hey-benchmark--page-through-list (source)
  "Measure consecutive first-page and append requests for SOURCE."
  (let ((pages (cl-loop for page below 100 collect
                        `(("data"
                           ("postings" . ,(cl-loop for n from 1 to 25
                                                   for id = (+ (* page 25) n)
                                                   collect `(("id" . ,id) ("topic_id" . ,id)
                                                             ("name" . "Synthetic subject")
                                                             ("seen" . t))))
                           ("next_page" . ,(and (< page 99) (number-to-string (1+ page)))))))))
    (hey-benchmark--measure
     "Browse 100 pages of 25 postings"
     (lambda ()
       (with-temp-buffer
         (hey-list-mode)
         (let ((remaining pages))
           (setq hey--source source
                 hey--operation-overrides
                 `((hey-cli-box-view . ,(lambda (_a _b _p _o _k _g success _fail)
                                          (funcall success (pop remaining))
                                          nil))))
           (cl-letf (((symbol-function 'hey--minimum-window-width) (lambda () 120)))
             (hey-refresh)
             (while remaining (hey-load-more) (hey--status-header)))
           (unless (and (= (length hey--records) 2500) (not (hey--continuation-p)))
             (error "Synthetic paging did not finish"))))))))

(defun hey-benchmark--refresh-thread ()
  "Measure a reader reopening a long thread before and after a reply arrives."
  (let* ((body (mapconcat #'identity (make-list 15 "Read [the notes](/topics/1) before Friday.") "\n\n"))
         (rows (cl-loop for id from 1 to 1000 collect
                        `(("id" . ,id) ("body" . ,(format "Message %d\n\n%s" id body)))))
         (initial (json-encode `(("data" . ,rows))))
         (appended (json-encode `(("data" . ,(append rows '((("id" . 1001) ("body" . "A reply.")))))))))
    (hey-thread-performance--with-session
      (let ((thread (hey-thread-performance--open source-buffer)) response)
        (with-current-buffer thread
          (let ((noninteractive nil)) (font-lock-mode 1)))
        (dolist (sample (list (list "Reopen 1000 messages / identical" initial "Message 250")
                              (list "One new reply / reading message 250" appended "Message 250")
                              (list "One new reply / reading message 999" appended "Message 999")))
          (hey-benchmark--measure
           (car sample)
           (lambda ()
             (hey-thread-performance--open source-buffer)
             (funcall (caar callbacks) response))
           (lambda ()
             (hey-thread-performance--open source-buffer)
             (funcall (caar callbacks) (hey-cli--parse-json initial))
             (with-current-buffer thread
               (goto-char (point-min))
               (search-forward (nth 2 sample))
               (set-window-start (selected-window) (line-beginning-position)))
             ;; Independent JSON objects reflect the next real response.
             (setq response (hey-cli--parse-json (cadr sample))))))))))

(defun hey-benchmark--cold-thread (name thread)
  "Measure a fresh render of THREAD and fontification of its first 40 lines."
  (hey-benchmark--measure
   name
   (lambda ()
     (with-temp-buffer
       ;; Temporary buffers and batch mode normally disable font locking.
       (rename-buffer "HEY benchmark thread" t)
       (hey-thread-mode)
       (let ((noninteractive nil)) (font-lock-mode 1))
       (unless font-lock-mode
         (error "Thread benchmark requires active font locking"))
       (setq hey--thread thread)
       (hey--render-thread)
       (font-lock-ensure (point-min) (save-excursion (forward-line 40) (point)))))))

(defun hey-benchmark--track-prose (name)
  "Measure five cursor moves over prose near the end of the thread under NAME."
  (goto-char (point-max))
  (search-backward "Friday")
  (let ((start (point)))
    (hey-benchmark--measure
     name
     (lambda ()
       (goto-char start)
       (dotimes (_ 5)
         (forward-char 1)
         (hey--track-body-link))))))

(defun hey-benchmark--run ()
  "Measure normalization, rendering, navigation, and transport helpers."
  (let* ((source (make-hey-source :key '(box "101" "imbox") :kind 'box
                                 :account-id "101" :id "imbox" :title "Imbox"
                                 :continuation-kind 'cursor :exhausted t))
         (raw (cl-loop for id from 1 to 1000 collect
                       `(("id" . ,id) ("topic_id" . ,id)
                         ("name" . "Synthetic project notes")
                         ("creator" ("name" . "Synthetic sender"))
                         ("summary" . "Synthetic message preview")
                         ("seen" . t) ("created_at" . "2026-09-17T09:30:00Z")
                         ("folders" (("id" . 1) ("name" . "Planning"))
                                    (("id" . 2) ("name" . "Travel")))
                         ("collections" (("id" . 3) ("name" . "Launch"))))))
         (envelope `(("ok" . t) ("data" ("postings" . ,raw))))
         (postings (plist-get (hey-model-normalize-postings envelope source) :value))
         (now (encode-time '(0 0 12 17 9 2026 nil -1 nil))))
    (hey-benchmark--page-through-list source)
    (hey-benchmark--refresh-thread)
    (hey-benchmark--measure
     "Normalize 1000 postings"
     (lambda () (hey-model-normalize-postings envelope source)))
    (hey-benchmark--measure
     "Format 1000 membership rows"
     (lambda () (mapcar (lambda (p) (hey-model-posting-row p 'wide)) postings)))
    (hey-benchmark--measure
     "Format 1000 dates"
     (lambda () (mapcar (lambda (p) (hey-model-format-posting-timestamp
                                    (hey-posting-timestamp p) now)) postings)))
    (let ((json (json-encode envelope)))
      (hey-benchmark--measure
       (format "Parse JSON (%d KiB)" (/ (string-bytes json) 1024))
       (lambda () (hey-cli--parse-json json))))
    (hey-benchmark--measure
     "Cold 1000 rows / one timestamp"
     (lambda ()
       (with-temp-buffer
         (hey-list-mode)
         (setq hey--source (copy-hey-source source) hey--records postings
               hey--account (make-hey-account :id "101" :name "Synthetic"))
         (hey--render-list nil 130))))
    (let ((distinct-postings
           (cl-loop for posting in postings for index from 0 collect
                    (let ((copy (copy-hey-posting posting)))
                      (setf (hey-posting-timestamp copy)
                            (format-time-string
                             "%Y-%m-%dT%H:%M:%SZ"
                             (time-subtract now (seconds-to-time (* index 607))) t))
                      copy))))
      (hey-benchmark--measure
       "Cold 1000 rows / distinct timestamps"
       (lambda ()
         (with-temp-buffer
           (hey-list-mode)
           (setq hey--source (copy-hey-source source) hey--records distinct-postings
                 hey--account (make-hey-account :id "101" :name "Synthetic"))
           (hey--render-list nil 130))))
      (with-temp-buffer
        (hey-list-mode)
        (setq hey--source (copy-hey-source source) hey--records distinct-postings
              hey--account (make-hey-account :id "101" :name "Synthetic"))
        (hey--render-list nil 130)
        (hey-benchmark--measure "Warm 1000 rows / distinct timestamps"
                                (lambda () (hey--render-list t 130)))))
    (with-temp-buffer
      (hey-list-mode)
      (setq hey--source source hey--records postings
            hey--account (make-hey-account :id "101" :name "Synthetic"))
      (hey--render-list nil 130)
      (hey-benchmark--measure "Warm render 1000 posting rows"
                              (lambda () (hey--render-list t 130)))
      (hey-benchmark--measure "Header x1000 / 1000 postings"
                              (lambda () (dotimes (_ 1000) (hey--status-header))))
      (hey-benchmark--measure "Render 1000 labeled rows / narrow"
                              (lambda () (hey--render-list t 70)))
      (let ((hey--last-refreshed now))
        (hey-benchmark--measure "Narrow header x1000 after refresh"
                                (lambda () (dotimes (_ 1000) (hey--status-header)))))
      ;; Keep responsive columns constant when the public command chooses width.
      (cl-letf (((symbol-function 'hey--minimum-window-width) (lambda () 130)))
        (setq hey--operation-overrides '((hey-cli-box-view . ignore)))
        (hey-benchmark--measure
         "Begin refresh / 1000 existing rows"
         #'hey-refresh
         (lambda ()
           (setq hey--loading nil hey--stale nil hey--error nil)
           (hey--render-list t 130)))
        (let ((next-id 1000) page)
          (setq hey--operation-overrides
                `((hey-cli-box-view
                   . ,(lambda (_account _box _page _owner _key _generation
                               success _failure)
                        (funcall success page)
                        nil))))
          (hey-benchmark--measure
           "Append 50 to 1000 rows / complete request"
           #'hey-load-more
           (lambda ()
             ;; Every sample appends fresh identities, even if row caches retain
             ;; entries that disappeared when the fixture was reset.
             (setq page
                   `(("ok" . t)
                     ("data"
                      ("postings"
                       . ,(cl-loop repeat 50 collect
                                   (let ((row (copy-tree (car raw)))
                                         (id (cl-incf next-id)))
                                     (setcdr (assoc "id" row) id)
                                     (setcdr (assoc "topic_id" row) id)
                                     (setcdr
                                      (assoc "created_at" row)
                                      (format-time-string
                                       "%Y-%m-%dT%H:%M:%SZ"
                                       (time-subtract
                                        now (seconds-to-time (* id 607))) t))
                                     row))))))
             (setq hey--records postings hey--source (copy-hey-source source)
                   hey--loading nil hey--stale nil hey--error nil)
             (setf (hey-source-continuation hey--source) "next-50"
                   (hey-source-exhausted hey--source) nil)
             (hey--render-list t 130)))
          (unless (and (= (length hey--records) 1050) (not hey--loading)
                       (not hey--error))
            (error "Synthetic append did not produce 1050 loaded rows"))))))
  (let ((memberships (cl-loop for id from 1 to 1000 collect
                              (make-hey-membership :id (number-to-string id)
                                                   :name "Label")))
        (thread-envelope
         `(("data" . ,(cl-loop for id from 1 to 5000 collect
                                `(("id" . ,id)
                                  ("alternative_sender_name"
                                   . ,(format "Synthetic sender %d" id))))))))
    (hey-benchmark--measure
     "Fit 1000 labels / 6000 columns"
     (lambda () (hey-model-format-memberships memberships 6000)))
    (hey-benchmark--measure
     "Normalize 5000 distinct senders"
     (lambda () (hey-model-normalize-thread thread-envelope nil))))
  (let* ((entries (cl-loop for id from 1 to 1000 collect
                           (make-hey-entry :id (number-to-string id)
                                           :sender "Synthetic sender"
                                           :timestamp "2026-09-17"
                                           :body "Synthetic body.\n"
                                           :body-state 'hydrated)))
         (thread (make-hey-thread :account-id "101" :account-name "Synthetic"
                                  :topic-id "1" :subject "Synthetic thread"
                                  :source-title "Imbox" :entries entries))
         (attachments
          `(("data" . ,(cl-loop for id from 1 to 5000 collect
                                 `(("id" . ,(format "%d:1" id))
                                   ("message_id" . ,(1+ (% id 1000)))
                                   ("filename" . "report.pdf")
                                   ("content_type" . "application/pdf")
                                   ("byte_size" . 123)))))))
    (hey-benchmark--measure "Normalize 5000 attachments"
                            (lambda () (hey-model-normalize-attachments attachments)))
    (with-temp-buffer
      (hey-attachment-mode)
      (setq hey--attachment-thread thread
            hey--attachments (cl-subseq
                              (plist-get (hey-model-normalize-attachments attachments)
                                         :value) 0 1000))
      (hey-benchmark--measure "Render 1000 attachments / messages"
                              #'hey--render-attachments))
    (with-temp-buffer
      (hey-thread-mode)
      (setq hey--thread thread)
      (hey-benchmark--measure "Render thread / 1000 messages" #'hey--render-thread)
      (hey-benchmark--measure
       "Thread header x1000 / 1000 messages"
       (lambda () (dotimes (_ 1000) (hey--thread-header))))
      (let ((middle (/ (point-max) 2)))
        (hey-benchmark--measure
         "Next entry x1000 / 1000 messages"
         (lambda () (dotimes (_ 1000) (goto-char middle) (hey-next-entry))))
        (hey-benchmark--measure
         "Previous entry x1000 / 1000 msgs"
         (lambda () (dotimes (_ 1000) (goto-char middle) (hey-previous-entry))))))
    (with-temp-buffer
      (hey-thread-mode)
      (setq hey--thread
            (make-hey-thread
             :entries (cl-loop for id from 1 to 1000 collect
                               (make-hey-entry
                                :id (number-to-string id)
                                :body "Read [the notes](https://example.invalid/notes) before Friday."))))
      (hey--render-thread)
      (hey-benchmark--track-prose "Track cursor on prose x5 / message 1000"))
    (let* ((paragraph
            (concat "The **synthetic project** is ready for its next review. "
                    "Read the design notes and the follow-up questions, "
                    "then check `fixture-only` before the planning meeting.\n"))
           (body (mapconcat #'identity (make-list 6 paragraph) "\n"))
           (large-thread (copy-hey-thread thread)))
      (setf (hey-thread-entries large-thread)
            (mapcar (lambda (entry)
                      (let ((copy (copy-hey-entry entry)))
                        (setf (hey-entry-body copy) body)
                        copy))
                    entries))
      (hey-benchmark--cold-thread
       (format "Cold thread 1000 x %d B + first 40 lines" (string-bytes body))
       large-thread)
      (dolist (kib '(3 10 32))
        (let* ((section (concat paragraph "\n- Read [the notes](/topics/1).\n\n"
                                "> I can review this on Friday.\n\n"))
               (repetitions (ceiling (* kib 1024) (length section)))
               (entry (copy-hey-entry (car entries)))
               (short-thread (copy-hey-thread thread)))
          (setf (hey-entry-body entry) (apply #'concat (make-list repetitions section))
                (hey-thread-entries short-thread) (list entry))
          (hey-benchmark--cold-thread
           (format "Cold 1 message / %.1f KiB + first 40 lines"
                   (/ (string-bytes (hey-entry-body entry)) 1024.0))
           short-thread)
          (when (= kib 10)
            (with-temp-buffer
              (hey-thread-mode)
              (setq hey--thread short-thread)
              (hey--render-thread)
              (hey-benchmark--track-prose "Track cursor on prose x5 / one 10 KiB body")))))))
  (let ((chunk (make-string 1024 ?x))
        (hey-max-output-bytes (* 4 1024 1024)))
    (hey-benchmark--measure
     "Capture 4 MiB in 1 KiB chunks"
     (lambda ()
       (with-temp-buffer
         (let ((request (hey-cli--make-request :bytes 0)))
           (dotimes (_ 4096) (hey-cli--capture request (current-buffer) chunk))))))))

(princ (format "Emacs %s; compiled runtime; median of 5; GC threshold %d bytes\n"
               emacs-version gc-cons-threshold))
(cl-letf (((symbol-function 'make-process)
           (lambda (&rest _) (error "Benchmarks must not start processes"))))
  (hey-benchmark--run))

;;; benchmark.el ends here
