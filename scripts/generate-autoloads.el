;;; generate-autoloads.el --- Generate org-tickets autoloads  -*- lexical-binding: t; -*-

;; Usage: emacs --batch -l scripts/generate-autoloads.el

;;; Code:

(let* ((source-dir (file-name-directory (directory-file-name
                                          (file-name-directory load-file-name))))
       (output-file (expand-file-name "org-tickets-autoloads.el" source-dir)))
  ;; Delete existing file so generator starts fresh (no merge with old content)
  (when (file-exists-p output-file)
    (delete-file output-file))
  (loaddefs-generate source-dir output-file))

;;; generate-autoloads.el ends here
