;;; operation-audit.el --- Audit the closed process boundary -*- lexical-binding: t -*-

;;; Commentary:

;; Check that only the frozen named reads and the sole approved mailbox
;; mutation can reach the package's private subprocess primitive.

;;; Code:

(require 'cl-lib)
(load (expand-file-name
       "common.el" (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(defconst hey-build-read-operations
  '((hey-cli-version . hey-cli-build-version)
    (hey-cli-auth-status . hey-cli-build-auth-status)
    (hey-cli-account-list . hey-cli-build-account-list)
    (hey-cli-box-list . hey-cli-build-box-list)
    (hey-cli-box-view . hey-cli-build-box-view)
    (hey-cli-bundle-view . hey-cli-build-bundle-view)
    (hey-cli-contact-threads . hey-cli-build-contact-threads)
    (hey-cli-search . hey-cli-build-search)
    (hey-cli-thread-read . hey-cli-build-thread-read)
    (hey-cli-label-list . hey-cli-build-label-list)
    (hey-cli-label-view . hey-cli-build-label-view)
    (hey-cli-collection-list . hey-cli-build-collection-list)
    (hey-cli-collection-view . hey-cli-build-collection-view)
    (hey-cli-attachment-list . hey-cli-build-attachment-list)
    (hey-cli-attachment-save . hey-cli-build-attachment-save))
  "Map closed mailbox-read operations to pure argv builders.
Attachment saving also writes a user-requested local file.")

(defconst hey-build-mutation-operations
  '((hey-cli-mark-read . hey-cli-build-mark-read))
  "Map the sole approved mailbox mutation to its pure argv builder.")

(defconst hey-build-process-primitives
  '(async-shell-command call-process call-process-region
    call-process-shell-command make-network-process make-pipe-process
    make-process network-stream-open-starttls open-gnutls-stream
    open-network-stream process-file process-lines process-lines-ignore-status
    shell-command shell-command-on-region start-file-process
    start-file-process-shell-command start-process start-process-shell-command
    url-retrieve url-retrieve-synchronously)
  "Process and network primitives forbidden outside the private transport.")

(defun hey-build-read-forms (file)
  "Read and return every top-level Lisp form in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (condition-case nil
        (let ((inhibit-message t)) (check-parens))
      (error (error "Unbalanced Emacs Lisp source: %s" file)))
    (goto-char (point-min))
    (let (forms form)
      (condition-case nil
          (while t
            (setq form (read (current-buffer)))
            (push form forms))
        (end-of-file))
      (nreverse forms))))

(defun hey-build-form-calls (form)
  "Return function-position symbols and explicit function refs in FORM."
  (let (calls)
    (cl-labels ((walk
                  (value)
                  (when (consp value)
                    (cond
                     ((eq (car value) 'quote))
                     ((eq (car value) 'function)
                      (when (symbolp (cadr value))
                        (push (cadr value) calls)))
                     (t
                      (when (symbolp (car value))
                        (push (car value) calls))
                      (mapc #'walk (cdr value)))))))
      (walk form))
    (delete-dups calls)))

(defun hey-build-find-call-forms (name form)
  "Return every actual call to NAME contained in FORM."
  (let (calls)
    (cl-labels ((walk
                  (value)
                  (when (consp value)
                    (unless (memq (car value) '(quote function))
                      (when (eq (car value) name)
                        (push value calls))
                      (mapc #'walk (cdr value))))))
      (walk form))
    (nreverse calls)))

(defun hey-build-function-call-graph (forms)
  "Return a function call graph for top-level defuns in FORMS."
  (let (graph)
    (dolist (form forms (nreverse graph))
      (when (eq (car-safe form) 'defun)
        (push (cons (nth 1 form)
                    (hey-build-form-calls (cddr form)))
              graph)))))

(defun hey-build-reaches-p (from target graph &optional seen)
  "Return non-nil when FROM can reach TARGET in call GRAPH.
SEEN contains functions already visited during recursion."
  (if (eq from target)
      t
    (unless (memq from seen)
      (cl-some (lambda (callee)
                 (hey-build-reaches-p
                  callee target graph (cons from seen)))
               (cdr (assq from graph))))))

(defun hey-build-audit-operations (all-forms)
  "Reject ALL-FORMS unless their process calls match the closed allowlists."
  (let* ((graph (hey-build-function-call-graph all-forms))
         (operations (append hey-build-read-operations
                             hey-build-mutation-operations))
         (allowed-operations (mapcar #'car operations)))
    (dolist (pair operations)
      (pcase-let ((`(,operation . ,builder) pair))
        (unless (assq operation graph)
          (error "Missing named operation: %s" operation))
        (unless (assq builder graph)
          (error "Missing pure command builder: %s" builder))
        (unless (hey-build-reaches-p operation builder graph)
          (error "%s does not reach its frozen builder %s" operation builder))
        (when (hey-build-reaches-p builder 'hey-cli--start-process graph)
          (error "Builder reaches subprocess transport: %s" builder))
        (let* ((definition
                (cl-find-if (lambda (form)
                              (and (eq (car-safe form) 'defun)
                                   (eq (nth 1 form) operation)))
                            all-forms))
               (calls (hey-build-find-call-forms
                       'hey-cli--start-process definition))
               (tag (intern (string-remove-prefix "hey-cli-"
                                                  (symbol-name operation))))
               (call (car calls)))
          (unless (= (length calls) 1)
            (error "%s must call the transport exactly once" operation))
          (unless (and (equal (nth 1 call) (list 'quote tag))
                       (consp (nth 2 call))
                       (eq (car (nth 2 call)) builder))
            (error "%s must pass its frozen operation and builder directly"
                   operation)))))
    (unless (assq 'hey-cli--start-process graph)
      (error "Missing private process primitive hey-cli--start-process"))
    (unless (memq 'make-process (cdr (assq 'hey-cli--start-process graph)))
      (error "Private process primitive does not call make-process"))
    (let ((direct-callers
           (sort (cl-loop for (name . calls) in graph
                          when (memq 'hey-cli--start-process calls)
                          collect name)
                 (lambda (left right)
                   (string< (symbol-name left) (symbol-name right)))))
          (expected-callers
           (sort (copy-sequence allowed-operations)
                 (lambda (left right)
                   (string< (symbol-name left) (symbol-name right))))))
      (unless (equal direct-callers expected-callers)
        (error "Transport direct callers differ from operation allowlists: %S"
               direct-callers)))
    (dolist (entry graph)
      (let ((name (car entry))
            (calls (cdr entry)))
        (dolist (primitive hey-build-process-primitives)
          (when (and (memq primitive calls)
                     (not (and (eq name 'hey-cli--start-process)
                               (memq primitive '(make-pipe-process
                                                 make-process)))))
            (error "%s calls forbidden process primitive %s" name primitive)))
        (when (and (hey-build-reaches-p name 'hey-cli--start-process graph)
                   (not (memq name allowed-operations))
                   (not (eq name 'hey-cli--start-process)))
          (error "Function reaches transport outside allowlist: %s" name))))))

(let* ((runtime-files (hey-build-library-files))
       (all-forms
        (apply #'append
               (mapcar (lambda (file)
                         (hey-build-read-forms (hey-build-path file)))
                       runtime-files))))
  (hey-build-audit-operations all-forms)
  ;; Exercise the rejecting path with complete sources, so these checks also
  ;; catch accidental weakening of the operation and primitive allowlists.
  (dolist (addition
           '(((defun synthetic-write ()
                (hey-cli--start-process 'unseen nil)))
             ((defun synthetic-helper ()
                (hey-cli--start-process 'mark-read nil))
              (defun synthetic-indirect () (synthetic-helper)))
             ((defun synthetic-funcall () (funcall #'make-process)))
             ((defun hey-cli-mark-read ()
                (hey-cli--start-process
                 'mark-read (hey-cli-build-thread-read "all" "1"))))
             ((defun hey-cli-mark-read ()
                (hey-cli--start-process
                 'unseen (hey-cli-build-mark-read "all" "1"))))))
    (let* ((names (mapcar #'cadr addition))
           (forms (append addition
                          (cl-remove-if
                           (lambda (form)
                             (and (eq (car-safe form) 'defun)
                                  (memq (cadr form) names)))
                           all-forms)))
           rejected)
      (condition-case nil
          (hey-build-audit-operations forms)
        (error (setq rejected t)))
      (unless rejected
        (error "Operation audit accepted forbidden synthetic source: %S"
               addition))))
  (let ((malformed (make-temp-file "hey-audit-malformed-" nil ".el"))
        rejected)
    (unwind-protect
        (progn
          (with-temp-file malformed
            (insert "(defun unfinished ("))
          (condition-case nil
              (hey-build-read-forms malformed)
            (error (setq rejected t)))
          (unless rejected
            (error "Operation audit accepted malformed trailing source")))
      (when (file-exists-p malformed)
        (delete-file malformed))))
  (message "Closed process boundary verified: %d reads and %d mailbox mutation"
           (length hey-build-read-operations)
           (length hey-build-mutation-operations)))
