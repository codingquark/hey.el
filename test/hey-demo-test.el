;;; hey-demo-test.el --- Regression tests for the synthetic demo  -*- lexical-binding: t; -*-

;;; Commentary:

;; Ensure the demo mirrors the real reader's bundle-to-thread interaction.

;;; Code:

(require 'ert)
(require 'hey-demo)
(require 'hey-test-helper)

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
