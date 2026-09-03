;;; hey-demo-test.el --- Regression tests for the synthetic demo  -*- lexical-binding: t; -*-

;;; Commentary:

;; Ensure the demo mirrors the real reader's bundle-to-thread interaction.

;;; Code:

(require 'ert)
(require 'hey-demo)

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
