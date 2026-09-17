;;; hey-demo-test.el --- Regression tests for the synthetic demo  -*- lexical-binding: t; -*-

;;; Commentary:

;; Ensure the demo mirrors the real reader's bundle-to-thread interaction.

;;; Code:

(require 'ert)
(require 'hey-demo)
(require 'hey-test-helper)

(defmacro hey-demo-test-with-session (&rest body)
  "Run BODY in a sample session which cannot start a subprocess."
  (declare (indent 0) (debug t))
  `(hey-test-with-fake ()
     (save-window-excursion
       (let ((existing (buffer-list)))
         (cl-letf (((symbol-function 'make-process)
                    (lambda (&rest _) (ert-fail "Demo started a subprocess")))
                   ((symbol-function 'hey-cli-mark-read)
                    (lambda (&rest _) (ert-fail "Demo reached mark-read CLI"))))
           (unwind-protect
               (progn
                 (hey-demo)
                 (hey-test-await (lambda () (not hey--loading)))
                 (goto-char (point-min))
                 (while (not (tabulated-list-get-id)) (forward-line 1))
                 ,@body)
             (dolist (buffer (buffer-list))
               (when (and (not (memq buffer existing))
                          (string-prefix-p "*HEY" (buffer-name buffer)))
                 (kill-buffer buffer)))))))))

(ert-deftest hey-demo-mark-read-preserves-list-and-refreshes-sample-state ()
  (hey-demo-test-with-session
    (let ((identity (tabulated-list-get-id)))
      (should (eq (hey-posting-seen (hey--posting-at-point)) 'unseen))
      (should (eq (key-binding (kbd "r")) #'hey-mark-read))
      (hey-mark-read)
      (hey-test-await
       (lambda () (eq (hey-posting-seen (hey--posting-at-point)) 'seen)))
      (should (equal (tabulated-list-get-id) identity))
      (should (= (length hey--records) 3))
      (hey-refresh)
      (hey-test-await (lambda () (not hey--loading)))
      (should (equal (tabulated-list-get-id) identity))
      (should (eq (hey-posting-seen (hey--posting-at-point)) 'seen)))))

(ert-deftest hey-demo-mark-read-in-thread-updates-its-origin ()
  (hey-demo-test-with-session
    (let ((origin (current-buffer)))
      (hey-open)
      (hey-test-await (lambda () hey--thread))
      (should (eq (key-binding (kbd "r")) #'hey-mark-read))
      (should (eq (hey-thread-seen hey--thread) 'unseen))
      (hey-mark-read)
      (hey-test-await (lambda () (eq (hey-thread-seen hey--thread) 'seen)))
      (with-current-buffer origin
        (should (eq (hey-posting-seen (car hey--records)) 'seen))))))

(ert-deftest hey-demo-attachments-never-reach-cli-or-save-files ()
  (save-window-excursion
    (cl-letf (((symbol-function 'hey-cli-attachment-list)
               (lambda (&rest _) (ert-fail "Demo reached attachment CLI")))
              ((symbol-function 'hey-cli-attachment-save)
               (lambda (&rest _) (ert-fail "Demo reached save CLI"))))
      (unwind-protect
          (progn
            (hey-demo)
            (hey-test-await (lambda () (not hey--loading)))
            (goto-char (point-min))
            (while (not (tabulated-list-get-id)) (forward-line 1))
            (hey-open)
            (hey-test-await (lambda () hey--thread))
            (hey-list-attachments)
            (hey-test-await (lambda () (not hey--loading)))
            (should (= 1 (length hey--attachments)))
            (let ((directory (make-temp-file "hey-demo-attachment-" t)))
              (unwind-protect
                  (let ((destination (expand-file-name "example.txt" directory)))
                    (hey--start-attachment-save (car hey--attachments) destination)
                    (should-not hey--attachment-save-token)
                    (should-not (file-exists-p destination))
                    (should (equal (directory-files directory nil "[^.]") nil)))
                (delete-directory directory t))))
        (dolist (buffer (buffer-list))
          (when (string-prefix-p "*HEY" (buffer-name buffer))
            (kill-buffer buffer)))))))

(ert-deftest hey-demo-bundle-expands-to-readable-thread-rows ()
  (let (envelope)
    (cl-letf (((symbol-function 'hey-demo--deliver)
               (lambda (success value) (funcall success value))))
      (hey-demo--bundle
       (make-hash-table :test #'equal)
       "101" "502" nil (current-buffer) '(bundle) 1
       (lambda (value) (setq envelope value))
       (lambda (_error) (ert-fail "Synthetic bundle failed"))))
    (let* ((source (make-hey-source
                    :key '(bundle "101" "502") :kind 'bundle
                    :account-id "101" :id "502"))
           (result (hey-model-normalize-postings envelope source))
           (postings (plist-get result :value)))
      (should (= (length postings) 2))
      (should (cl-every (lambda (posting)
                          (and (eq (hey-posting-kind posting) 'thread)
                               (hey-posting-topic-id posting)))
                        postings)))))

(provide 'hey-demo-test)
;;; hey-demo-test.el ends here
