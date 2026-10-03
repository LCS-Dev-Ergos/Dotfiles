;;; security-export.el --- Offline Org PDF regression -*- lexical-binding: t; -*-
;; Run: SECURITY_TEST_TMPDIR=<private fixture root> emacs --batch -Q --load this-file.
;; Load only the repository's Org configuration, then export Unicode, math and
;; a C++ block with a hostile write18 command. Success requires an actual PDF
;; and an absent execution marker; generated files stay in the fixture root.
(require 'org)
(require 'ox-latex)
(provide 'ox-hugo) ; Hugo is unrelated to the PDF boundary exercised here.

;; Evaluate the Org after! block without loading unrelated Doom configuration.
(let ((config (expand-file-name "../doom/config.el"
                                (file-name-directory load-file-name))))
  (with-temp-buffer
    (insert-file-contents config)
    (goto-char (point-min))
    (let (form)
      (condition-case nil
          (while t
            (setq form (read (current-buffer)))
            (when (and (listp form) (eq (car form) 'after!) (eq (cadr form) 'org))
              (eval (cons 'progn (cddr form)))))
        (end-of-file nil)))))

(unless (and (eq org-latex-src-block-backend 'listings)
             (cl-every (lambda (command) (string-match-p "-no-shell-escape" command))
                       org-latex-pdf-process))
  (error "Unsafe or incompatible Org export configuration"))

;; Exercise the configured PDF process, not only the shell-escape option text.
(let* ((default-directory (make-temp-file
                           (expand-file-name "org-export-" (getenv "SECURITY_TEST_TMPDIR")) t))
       (source (expand-file-name "fixture.org"))
       (marker (expand-file-name "shell-executed")))
  (with-temp-file source
    (insert "#+title: Export regression\n\nUnicode: café. Math: $x^2 + 1$.\n\n"
            "#+begin_src C++\nint main() { return 0; }\n#+end_src\n\n"
            "#+begin_export latex\n\\immediate\\write18{touch " marker "}\n#+end_export\n"))
  (find-file source)
  (let ((org-export-use-babel nil))
    (org-latex-export-to-pdf))
  (unless (file-exists-p (expand-file-name "fixture.pdf"))
    (error "Ordinary Unicode/math/code PDF export failed"))
  (when (file-exists-p marker)
    (error "Document shell command executed"))
  (princ "PASS: Org listings PDF export and disabled document shell execution\n"))
