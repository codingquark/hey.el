;;; hey-test-helper.el --- Hermetic helpers for hey.el tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; All process tests use the repository's absolute fake executable.  The
;; helpers deliberately fail before a test body runs when that fake is absent
;; or non-executable, preventing accidental fallback to an installed HEY CLI.

;;; Code:

(require 'ert)
(require 'subr-x)

(defconst hey-test-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Absolute root of the hey.el checkout used by this test run.")

(defconst hey-test-fake-executable
  (expand-file-name "test/bin/hey" hey-test-root)
  "Absolute path to the only executable process tests may invoke.")

(defvar hey-test-record-file nil)
(defvar hey-test-working-directory nil)

(defconst hey-test-recovery-cases
  '(("auth-refused" auth "Run: hey auth login")
    ("refresh-rate-limited" rate-limit
     "Wait for the limit to clear, then run the command again"))
  "Fake scenarios with their expected error categories and recovery hints.")

(defun hey-test-assert-exact-fake (candidate)
  "Fail unless CANDIDATE is the checked-in, non-symlink fake executable."
  (unless (and (stringp candidate)
               (file-name-absolute-p candidate)
               (equal candidate hey-test-fake-executable)
               (not (file-symlink-p candidate))
               (file-regular-p candidate)
               (file-executable-p candidate)
               (file-equal-p candidate hey-test-fake-executable))
    (ert-fail (format "Hermetic fake unavailable: %s" candidate))))

(defun hey-test--set-environment (name value)
  "Set NAME to VALUE in the dynamically bound test environment."
  (setenv name value))

(defmacro hey-test-with-fake (settings &rest body)
  "Run BODY with the hermetic fake configured according to SETTINGS.

SETTINGS is a plist supporting `:scenario', `:timeout', and `:max-output'."
  (declare (indent 1) (debug (form body)))
  `(let* ((settings-value ,settings)
          (scenario (or (plist-get settings-value :scenario) "success"))
          (temporary-root (make-temp-file "hey-emacs-test-" t))
          (hey-test-working-directory
           (file-name-as-directory (expand-file-name "neutral" temporary-root)))
          (hey-test-record-file (expand-file-name "invocation.txt" temporary-root))
          (hey-executable hey-test-fake-executable)
          (hey-working-directory hey-test-working-directory)
          (hey-timeout-seconds (or (plist-get settings-value :timeout) 2))
          (hey-max-output-bytes
           (or (plist-get settings-value :max-output) (* 64 1024)))
          (process-environment (copy-sequence process-environment)))
     (hey-test-assert-exact-fake hey-executable)
     (hey-test--set-environment "HEY_EMACS_TEST_SCENARIO" scenario)
     (hey-test--set-environment "HEY_EMACS_TEST_RECORD" hey-test-record-file)
     (unwind-protect
         (progn ,@body)
       (dolist (buffer (buffer-list))
         (when (string-prefix-p " *hey-" (buffer-name buffer))
           (kill-buffer buffer)))
       (when (file-directory-p temporary-root)
         (delete-directory temporary-root t)))))

(defun hey-test-await (predicate &optional timeout)
  "Wait until PREDICATE returns non-nil, failing after TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 3))))
    (while (and (not (funcall predicate))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (unless (funcall predicate)
      (ert-fail "Timed out waiting for asynchronous HEY test completion"))))

(defun hey-test-read-record ()
  "Return the current fake invocation record."
  (unless (and hey-test-record-file (file-readable-p hey-test-record-file))
    (ert-fail "Fake invocation record was not written"))
  (with-temp-buffer
    (insert-file-contents hey-test-record-file)
    (buffer-string)))

(provide 'hey-test-helper)
;;; hey-test-helper.el ends here
