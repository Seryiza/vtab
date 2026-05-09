;;; init.el --- Sample vtab test config -*- lexical-binding: t; -*-

;;; Commentary:
;; Start with:
;;   emacs -Q --load ./init.el

;;; Code:

(require 'package)

(setq package-enable-at-startup nil)
(setq package-archives nil)

(package-initialize)

(unless (package-installed-p 'use-package)
  (package-refresh-contents)
  (package-install 'use-package))

(require 'use-package)
(setq use-package-always-ensure nil)

(defconst vtab-sample-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing this sample config and vtab.el.")

(setq inhibit-startup-screen t)
(setq initial-scratch-message nil)
(setq ring-bell-function #'ignore)
(setq make-backup-files nil)
(setq auto-save-default nil)
(setq load-prefer-newer t)
(setq tab-bar-show nil)

(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode 1)
(tab-bar-mode 1)

(set-face-attribute 'default nil :height 120)

(defun sz/right-or-tab-next ()
  "Move right when possible, otherwise switch to the next tab."
  (interactive)
  (condition-case nil
      (windmove-right)
    (error (tab-next))))

(defun sz/left-or-tab-previous ()
  "Move left when possible, otherwise switch to the previous tab."
  (interactive)
  (condition-case nil
      (windmove-left)
    (error (tab-previous))))

(use-package vtab
  :ensure nil
  :load-path vtab-sample-directory
  :demand t
  :bind*
  (("M-j" . sz/right-or-tab-next)
   ("M-k" . sz/left-or-tab-previous)
   ("M-n" . tab-new)
   ("M-u" . tab-close))
  :custom
  (tab-bar-show nil)
  (vtab-window-width 30)
  (vtab-hide-cursor t)
  (vtab-hide-mode-line t)
  (vtab-hide-scroll-bars nil)
  (vtab-active-fill-width t)
  :config
  (vtab-mode 1))

(dotimes (i 3)
  (let ((buf (get-buffer-create (format "*vtab sample %d*" (1+ i)))))
    (with-current-buffer buf
      (erase-buffer)
      (insert (format "Sample buffer %d\n\nUse M-n to create a tab, M-u to close it, M-j/M-k to move across tabs.\n" (1+ i))))
    (tab-new)
    (switch-to-buffer buf)))

(tab-bar-select-tab 1)

(provide 'init)
;;; init.el ends here
