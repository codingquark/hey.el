;;; test.el --- Run fake-only ERT suite -*- lexical-binding: t -*-

;;; Commentary:

;; Discover repository ERT files while forcing every subprocess test to use
;; the checked-in fake HEY executable.

;;; Code:

(require 'ert)
(load (expand-file-name
       "common.el" (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(hey-build-initialize-packages)

(let ((fake (hey-build-path "test/bin/hey")))
  (unless (and (file-name-absolute-p fake)
               (not (file-symlink-p fake))
               (file-regular-p fake)
               (file-executable-p fake)
               (file-equal-p fake (hey-build-path "test/bin/hey")))
    (error "Fake HEY executable is missing or not executable: %s" fake))
  ;; Set before loading package files so `defcustom' cannot replace it.
  (setq hey-executable fake)
  (setenv "HEY_TEST_FAKE" hey-executable)
  ;; Even a buggy test that clears `hey-executable' cannot discover a real
  ;; binary through the user's executable search path.
  (setq exec-path nil))

(add-to-list 'load-path hey-build-root)
(add-to-list 'load-path (hey-build-path "test"))

(let ((tests (directory-files (hey-build-path "test") t "-test\\.el\\'")))
  (unless tests
    (error "No ERT test files found"))
  (dolist (test tests)
    (load test nil 'nomessage)))

(unless (and (boundp 'hey-executable)
             (not (file-symlink-p hey-executable))
             (equal hey-executable (getenv "HEY_TEST_FAKE"))
             (file-equal-p hey-executable (hey-build-path "test/bin/hey")))
  (error "Tests changed hey-executable away from the repository fake"))

(ert-run-tests-batch-and-exit t)
