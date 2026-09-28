;;; vtab.el --- Vertical tab bar -*- lexical-binding: t; -*-

;; Author: mugen <mugen.void42@gmail.com>
;; URL: https://github.com/mugen-void/vtab
;; Version: 1.2.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience, frames
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Copyright (C) 2025 mugen

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Extends Emacs `tab-bar-mode' to display a vertical tab bar in a side window.
;;
;; Usage:
;;   (require 'vtab)
;;   (vtab-mode 1)
;;
;; Keybindings (M-s prefix by default):
;;   M-s M-c  New tab
;;   M-s M-k  Close tab
;;   M-s M-n  Next tab
;;   M-s M-p  Previous tab
;;   M-s M-s  Go to tab by number
;;   M-s [key]  Direct tab selection (right-hand layout):
;;     7890 -> tab 1-4,  uiop -> tab 5-8
;;     jkl; -> tab 9-12, m,./ -> tab 13-16
;;   On a group header: TAB toggles expansion, RET selects its first tab.
;;   Click the arrow to toggle expansion or the name to select the group.
;;   Customize via (define-key vtab-mode-map ...)

;;; Code:

(require 'tab-bar)
(require 'seq)

;;;; Customization

(defgroup vtab nil
  "Vertical tab bar."
  :group 'tab-bar
  :prefix "vtab-")

(defcustom vtab-new-tab-position 'rightmost
  "Position where new tabs are inserted."
  :type '(choice (const :tag "End" rightmost)
                 (const :tag "Beginning" leftmost)
                 (const :tag "Right of current" right)
                 (const :tag "Left of current" left))
  :group 'vtab)

(defcustom vtab-window-width 25
  "Width of the side window."
  :type 'integer
  :group 'vtab)

(defcustom vtab-side 'left
  "Side where the tab bar is displayed."
  :type '(choice (const :tag "Left" left)
                 (const :tag "Right" right))
  :group 'vtab)

(defcustom vtab-new-tab-choice "*scratch*"
  "Buffer to display in new tabs."
  :type 'string
  :group 'vtab)

(defcustom vtab-style-window-divider t
  "Non-nil means vtab sets window-divider to 1px thin line when enabled."
  :type 'boolean
  :group 'vtab)

(defcustom vtab-style-fringe t
  "Non-nil means vtab makes fringe background transparent when enabled."
  :type 'boolean
  :group 'vtab)

(defcustom vtab-hide-cursor nil
  "Non-nil means hide the cursor in the vtab side window."
  :type 'boolean
  :group 'vtab)

(defcustom vtab-hide-scroll-bars nil
  "Non-nil means hide scroll bars in the vtab side window."
  :type 'boolean
  :group 'vtab)

(defcustom vtab-hide-mode-line nil
  "Non-nil means hide the mode and header lines in the vtab side window."
  :type 'boolean
  :group 'vtab)

(defcustom vtab-active-fill-width nil
  "Non-nil means highlight the active tab to the side window edge.
The filled area uses `vtab-active-line' while the tab text still uses
`vtab-active-face'."
  :type 'boolean
  :group 'vtab)

(defcustom vtab-scroll-to-current-tab t
  "Non-nil means keep the current tab visible in the side window.
When the current tab is outside the visible part of the side window,
scroll by the smallest number of lines needed to show it."
  :type 'boolean
  :group 'vtab)

(defvar vtab-mode) ; Forward declaration for byte-compiler; defined by `define-minor-mode'.

;;;; Keymaps

(defvar vtab-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-s M-c") #'tab-new)
    (define-key map (kbd "M-s M-k") #'tab-close)
    (define-key map (kbd "M-s M-n") #'tab-next)
    (define-key map (kbd "M-s M-p") #'tab-previous)
    (define-key map (kbd "M-s M-s") #'vtab-goto-tab)
    ;; Direct tab selection (right-hand layout)
    (dotimes (i 16)
      (let* ((n (1+ i))
             (keys ["7" "8" "9" "0" "u" "i" "o" "p"
                    "j" "k" "l" ";" "m" "," "." "/"])
             (key (aref keys i)))
        (define-key map (kbd (format "M-s %s" key))
                    (lambda () (interactive) (tab-bar-select-tab n)))))
    map)
  "Keymap for `vtab-mode'.")

;;;; Variables

(defun vtab--get-buffer (&optional frame)
  "Get or create the vtab buffer for FRAME.
Each frame gets its own dedicated buffer stored as a frame parameter."
  (let* ((f (or frame (selected-frame)))
         (buf (frame-parameter f 'vtab--buffer)))
    (if (buffer-live-p buf)
        buf
      (let ((new-buf (generate-new-buffer " *vtab*")))
        (set-frame-parameter f 'vtab--buffer new-buf)
        (set-frame-parameter f 'vtab--tab-state nil)
        (with-current-buffer new-buf
          (setq-local truncate-lines t))
        new-buf))))

(defvar vtab--saved-settings nil
  "Alist of settings saved before enabling `vtab-mode'.")

(defvar vtab--resizing nil
  "Non-nil while vtab is resizing window to prevent infinite loop.")

(defun vtab--regular-window-p (window)
  "Return non-nil if WINDOW is a regular non-vtab window."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (not (eq (window-buffer window)
                (frame-parameter (window-frame window) 'vtab--buffer)))))

(defun vtab--select-last-window ()
  "Select the remembered non-vtab window."
  (when-let ((window
              (or (and (vtab--regular-window-p
                        (frame-parameter nil 'vtab--last-selected-window))
                       (frame-parameter nil 'vtab--last-selected-window))
                  (seq-find #'vtab--regular-window-p
                            (window-list nil 'nomini)))))
    (select-window window)))

(defun vtab--protect-selected-window (&rest _)
  "Keep selected window out of the vtab side buffer."
  (let ((window (selected-window)))
    (cond
     ((eq (window-buffer window)
          (frame-parameter nil 'vtab--buffer))
      (vtab--select-last-window))
     ((and (window-live-p window)
           (not (window-minibuffer-p window)))
      (set-frame-parameter nil 'vtab--last-selected-window window)))))

(defvar-local vtab--saved-buffer-settings nil
  "Alist of buffer-local display settings changed by vtab.")

(defvar vtab--buffer-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'vtab--click)
    (define-key map (kbd "RET") #'vtab--select)
    map)
  "Keymap used in the vertical tab bar buffer.")

(defvar vtab--group-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'vtab--click-group)
    (define-key map (kbd "RET") #'vtab--select-group)
    (define-key map (kbd "TAB") #'vtab--toggle-group)
    map)
  "Keymap for group headers in the vertical tab bar.")

(defvar vtab--group-toggle-keymap
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vtab--group-keymap)
    (define-key map [mouse-1] #'vtab--click-toggle-group)
    map)
  "Keymap for the expand/collapse indicator on a group header.")

;;;; Faces

(defface vtab-active-face
  '((t :background "#3a3a8a" :foreground "#aaaaaa" :weight bold))
  "Face for the active tab."
  :group 'vtab)

(defface vtab-active-line
  '((t :inherit vtab-active-face :extend t))
  "Face for the full-width active tab line.
This face is used only when `vtab-active-fill-width' is non-nil."
  :group 'vtab)

(defface vtab-group-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a group header.")

(defface vtab-active-group-face
  '((t :inherit vtab-active-face))
  "Face for the group containing the active tab.")

;;;; Internal Functions

(defun vtab--get-tabs ()
  "Return (INDEX NAME GROUP CURRENT) for each tab on the selected frame."
  (let ((index 0))
    (mapcar (lambda (tab)
              (list (setq index (1+ index))
                    (alist-get 'name tab)
                    (alist-get 'group tab)
                    (eq (car tab) 'current-tab)))
            (tab-bar-tabs))))

(defun vtab--insert-tab (tab grouped)
  "Insert TAB, indenting it when GROUPED is non-nil."
  (pcase-let ((`(,index ,name ,_group ,current) tab))
    (let ((line (propertize (format "%s%s %d: %s\n"
                                    (if grouped "  " "")
                                    (if current ">" " ") index name)
                            'vtab-index index
                            'mouse-face 'highlight
                            'keymap vtab--buffer-keymap
                            'face (when current 'vtab-active-face))))
      (put-text-property (1- (length line)) (length line) 'face
                         (when (and current vtab-active-fill-width)
                           'vtab-active-line) line)
      (put-text-property (1- (length line)) (length line) 'mouse-face nil line)
      (insert line))))

(defun vtab--insert-group (group tabs collapsed)
  "Insert header for GROUP and its TABS unless GROUP is COLLAPSED."
  (let* ((first-tab (car tabs))
         (active (seq-some (lambda (tab) (nth 3 tab)) tabs))
         (face (if active 'vtab-active-group-face 'vtab-group-face))
         (properties (list 'vtab-group-header t
                           'vtab-group group
                           'vtab-group-first-tab (car first-tab)
                           'mouse-face 'highlight
                           'face face)))
    (insert (apply #'propertize (if collapsed "▶ " "▼ ")
                   (append properties (list 'keymap vtab--group-toggle-keymap))))
    (insert (apply #'propertize (format "%s\n" (or group "Other"))
                   (append properties (list 'keymap vtab--group-keymap))))
    (unless collapsed
      (dolist (tab tabs)
        (vtab--insert-tab tab t)))))

(defun vtab--insert-tabs (tabs collapsed-groups)
  "Insert TABS, grouping them when necessary using COLLAPSED-GROUPS."
  (if (seq-some (lambda (tab) (nth 2 tab)) tabs)
      (dolist (group (seq-uniq (mapcar (lambda (tab) (nth 2 tab)) tabs)))
        (vtab--insert-group group
                            (seq-filter (lambda (tab) (equal (nth 2 tab) group)) tabs)
                            (member group collapsed-groups)))
    (dolist (tab tabs)
      (vtab--insert-tab tab nil))))

(defun vtab--line-position (line)
  "Return the buffer position at the beginning of 1-based LINE."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (point)))

(defun vtab--row-column (position)
  "Return the 1-based row and display column at POSITION."
  (save-excursion
    (goto-char position)
    (cons (line-number-at-pos nil t) (current-column))))

(defun vtab--row-column-position (row-column line-count)
  "Return position for ROW-COLUMN, clamped to LINE-COUNT rows."
  (goto-char (vtab--line-position
              (min (car row-column) (max 1 line-count))))
  (move-to-column (cdr row-column))
  (point))

(defun vtab--refresh ()
  "Refresh the vertical tab bar buffer and return the current tab."
  (let* ((tabs (vtab--get-tabs))
         (current (seq-position tabs t (lambda (tab active) (eq (nth 3 tab) active))))
         (collapsed (frame-parameter nil 'vtab--collapsed-groups))
         (buf (vtab--get-buffer))
         (new-state (list tabs collapsed vtab-active-fill-width)))
    (when (and current
               (not (equal new-state (frame-parameter nil 'vtab--tab-state))))
      (let ((win (get-buffer-window buf)))
        (with-current-buffer buf
          (let ((buffer-point (vtab--row-column (point)))
                (window-state
                 (when (window-live-p win)
                   (list (line-number-at-pos (window-start win) t)
                         (vtab--row-column (window-point win))
                         (window-vscroll win t))))
                (inhibit-read-only t))
            (erase-buffer)
            (vtab--insert-tabs tabs collapsed)
            (setq buffer-read-only t)
            (let ((rows (max 1 (count-lines (point-min) (point-max)))))
              (when window-state
                (set-window-point
                 win (vtab--row-column-position (nth 1 window-state) rows))
                (set-window-start
                 win (vtab--line-position (min (nth 0 window-state) rows)) t)
                (set-window-vscroll win (nth 2 window-state) t))
              (goto-char (vtab--row-column-position buffer-point rows)))))
        (set-frame-parameter nil 'vtab--tab-state new-state)))
    current))

(defun vtab--current-row-position (current)
  "Return the visible row for zero-based tab CURRENT, or its group header."
  (let ((index (1+ current))
        (group (nth 2 (nth current (vtab--get-tabs)))))
    (save-excursion
      (goto-char (point-min))
      (let (header)
        (catch 'row
          (while (< (point) (point-max))
            (when (equal (get-text-property (point) 'vtab-index) index)
              (throw 'row (point)))
            (when (and (get-text-property (point) 'vtab-group-header)
                       (equal (get-text-property (point) 'vtab-group) group))
              (setq header (or header (point))))
            (forward-line 1))
          header)))))

(defun vtab--scroll-to-current-tab (win current)
  "Scroll WIN minimally so CURRENT tab is visible."
  (when (and vtab-scroll-to-current-tab
             (window-live-p win)
             (integerp current))
    (with-current-buffer (window-buffer win)
      (when-let* ((target (vtab--current-row-position current)))
        (unless (pos-visible-in-window-p target win)
          (let ((new-start target))
            (unless (<= target (window-start win))
              (let ((target-next-bol
                     (save-excursion
                       (goto-char target)
                       (line-beginning-position 2)))
                    (body (window-body-height win t))
                    previous)
                (while (and (> new-start (point-min))
                            (progn
                              (setq previous
                                    (save-excursion
                                      (goto-char new-start)
                                      (line-beginning-position 0)))
                              (<= (cdr (window-text-pixel-size
                                        win previous target-next-bol
                                        nil nil nil t))
                                  body)))
                  (setq new-start previous))))
            (set-window-point win target)
            (set-window-start win new-start)
            (set-window-vscroll win 0 t)))))))

(defun vtab--set-buffer-option-hidden (variable hidden)
  "Set VARIABLE to nil while HIDDEN, restoring its prior local state otherwise."
  (let ((saved (assq variable vtab--saved-buffer-settings)))
    (cond
     (hidden
      (unless saved
        (push (list variable (local-variable-p variable) (symbol-value variable))
              vtab--saved-buffer-settings))
      (set (make-local-variable variable) nil))
     (saved
      (if (nth 1 saved)
          (set (make-local-variable variable) (nth 2 saved))
        (kill-local-variable variable))
      (setq vtab--saved-buffer-settings
            (assq-delete-all variable vtab--saved-buffer-settings))))))

(defun vtab--apply-buffer-options (win)
  "Apply side-window buffer-local options for WIN."
  (with-current-buffer (window-buffer win)
    (vtab--set-buffer-option-hidden 'cursor-type vtab-hide-cursor)
    (vtab--set-buffer-option-hidden 'cursor-in-non-selected-windows
                                    vtab-hide-cursor)
    (vtab--set-buffer-option-hidden 'mode-line-format vtab-hide-mode-line)
    (vtab--set-buffer-option-hidden 'header-line-format vtab-hide-mode-line)
    (force-mode-line-update)))

(defun vtab--select-tab (index)
  "Select tab INDEX without leaving the vtab window selected."
  (vtab--select-last-window)
  (tab-bar-select-tab index)
  (vtab--select-last-window)
  (vtab--refresh))

(defun vtab--toggle-group-at (pos)
  "Toggle the group header at POS in the vtab buffer."
  (when (get-text-property pos 'vtab-group-header)
    (let* ((group (get-text-property pos 'vtab-group))
           (collapsed (frame-parameter nil 'vtab--collapsed-groups)))
      (set-frame-parameter nil 'vtab--collapsed-groups
                           (if (member group collapsed)
                               (seq-remove (lambda (name) (equal name group)) collapsed)
                             (cons group collapsed)))
      (vtab--refresh))))

(defun vtab--toggle-group ()
  "Expand or collapse the group at point."
  (interactive)
  (vtab--toggle-group-at (point)))

(defun vtab--click-toggle-group (event)
  "Expand or collapse the group clicked in EVENT."
  (interactive "e")
  (let* ((posn (event-end event))
         (window (posn-window posn))
         (pos (posn-point posn)))
    (when (and (windowp window) (integerp pos))
      (with-current-buffer (window-buffer window)
        (vtab--toggle-group-at pos)))))

(defun vtab--select-group-at (pos)
  "Select the first tab of the group header at POS."
  (when (get-text-property pos 'vtab-group-header)
    (let ((group (get-text-property pos 'vtab-group))
          (index (get-text-property pos 'vtab-group-first-tab)))
      (set-frame-parameter nil 'vtab--collapsed-groups
                           (seq-remove (lambda (name) (equal name group))
                                       (frame-parameter nil 'vtab--collapsed-groups)))
      (vtab--select-tab index))))

(defun vtab--select-group ()
  "Select the first tab of the group at point."
  (interactive)
  (vtab--select-group-at (point)))

(defun vtab--click-group (event)
  "Select the first tab of the group clicked in EVENT."
  (interactive "e")
  (let* ((posn (event-end event))
         (window (posn-window posn))
         (pos (posn-point posn)))
    (when (and (windowp window) (integerp pos))
      (with-current-buffer (window-buffer window)
        (vtab--select-group-at pos)))))

(defun vtab--click (event)
  "Select tab by mouse click EVENT."
  (interactive "e")
  (let* ((posn (event-end event))
         (window (posn-window posn))
         (pos (posn-point posn))
         (idx (when (and (windowp window) (integerp pos))
                (with-current-buffer (window-buffer window)
                  (get-text-property pos 'vtab-index)))))
    (when idx
      (vtab--select-tab idx))))

(defun vtab--select ()
  "Select tab at point."
  (interactive)
  (let ((idx (get-text-property (point) 'vtab-index)))
    (when idx
      (vtab--select-tab idx))))

(defun vtab--ensure-visible ()
  "Ensure the vertical tab bar is visible when `vtab-mode' is enabled."
  (when vtab-mode
    (let* ((buf (vtab--get-buffer))
           (win (get-buffer-window buf)))
      (unless win
        (setq win (display-buffer-in-side-window
                   buf `((side . ,vtab-side)
                         (window-width . ,vtab-window-width)))))
      (when (window-live-p win)
        (set-window-parameter win 'no-other-window t)
        (set-window-parameter win 'no-delete-other-windows t)
        (set-window-fringes win 0 0)
        (vtab--apply-buffer-options win)
        (set-window-scroll-bars win nil (unless vtab-hide-scroll-bars t)
                                nil (unless vtab-hide-scroll-bars t) t)
        (vtab--scroll-to-current-tab win (vtab--refresh))))))

;;;; Commands

(defun vtab-goto-tab ()
  "Switch to a tab by number."
  (interactive)
  (let ((num (read-number "Tab number: ")))
    (tab-bar-select-tab num)))

;;;; Hook Functions

(defun vtab--on-tab-select (&rest _)
  "Hook function called after tab selection."
  (vtab--ensure-visible))

(defun vtab--on-tab-open (&rest _)
  "Hook function called after tab creation."
  (vtab--ensure-visible))

(defun vtab--on-buffer-change (frame)
  "Hook function called after buffer change."
  (when vtab-mode
    (with-selected-frame frame
      (vtab--refresh))))

(defun vtab--refresh-if-enabled (&rest _)
  "Refresh the sidebar when `vtab-mode' is enabled."
  (when vtab-mode
    (vtab--refresh)))

(defun vtab--on-org-agenda-finalize ()
  "Hook function called after `org-agenda' display."
  (vtab--ensure-visible))

(defun vtab--on-window-size-change (&optional frame)
  "Hook function called after window size change.
Adjust the side window width to match `vtab-window-width'."
  (when (and vtab-mode (not vtab--resizing))
    (let ((f (or frame (selected-frame))))
      (when-let* ((buf (frame-parameter f 'vtab--buffer))
                  ((buffer-live-p buf))
                  (win (get-buffer-window buf f)))
        (let ((current-width (window-width win)))
          (unless (= current-width vtab-window-width)
            (let ((vtab--resizing t))
              (window-resize win (- vtab-window-width current-width) t))))
        (with-selected-frame f
          (vtab--scroll-to-current-tab win (vtab--refresh)))))))

(defun vtab--setup-new-frame (frame)
  "Setup vtab on new FRAME.
Hide top tab bar and show side window if `vtab-mode' is enabled."
  (set-frame-parameter frame 'tab-bar-lines 0)
  (when vtab-mode
    (with-selected-frame frame
      (vtab--ensure-visible))))

(defun vtab--on-frame-delete (frame)
  "Clean up vtab resources for FRAME."
  (when-let* ((buf (frame-parameter frame 'vtab--buffer)))
    (when (buffer-live-p buf)
      (kill-buffer buf)))
  (set-frame-parameter frame 'vtab--buffer nil)
  (set-frame-parameter frame 'vtab--tab-state nil)
  (set-frame-parameter frame 'vtab--last-selected-window nil)
  (set-frame-parameter frame 'vtab--collapsed-groups nil))

;;;; Enable / Disable

(defun vtab--enable ()
  "Internal function to enable `vtab-mode'."
  ;; Save original settings
  (setq vtab--saved-settings
        (list (cons 'tab-bar-show tab-bar-show)
              (cons 'tab-bar-new-tab-to tab-bar-new-tab-to)
              (cons 'tab-bar-new-tab-choice tab-bar-new-tab-choice)
              (cons 'tab-bar-lines (frame-parameter nil 'tab-bar-lines))))
  (when vtab-style-window-divider
    (push (cons 'window-divider-mode (bound-and-true-p window-divider-mode))
          vtab--saved-settings)
    (push (cons 'window-divider-default-right-width window-divider-default-right-width)
          vtab--saved-settings)
    (push (cons 'window-divider-default-places window-divider-default-places)
          vtab--saved-settings))
  (when vtab-style-fringe
    (push (cons 'fringe-background (face-background 'fringe nil t))
          vtab--saved-settings))
  ;; Enable tab-bar-mode but hide top tab bar
  (tab-bar-mode 1)
  (setq tab-bar-show nil)
  ;; Force hide top tab bar on all frames
  (modify-all-frames-parameters '((tab-bar-lines . 0)))
  ;; Hook to setup vtab on new frames (daemon/emacsclient support)
  (add-hook 'after-make-frame-functions #'vtab--setup-new-frame)
  ;; Hook to clean up vtab on frame deletion
  (add-hook 'delete-frame-functions #'vtab--on-frame-delete)
  ;; Apply defcustom values
  (setq tab-bar-new-tab-to vtab-new-tab-position)
  (setq tab-bar-new-tab-choice vtab-new-tab-choice)
  ;; Add hooks
  (if (boundp 'tab-bar-tab-post-select-functions)
      (add-hook 'tab-bar-tab-post-select-functions #'vtab--on-tab-select)
    ;; Emacs 27--29 need this simple after-advice fallback.
    (advice-add 'tab-bar-select-tab :after #'vtab--on-tab-select))
  (add-hook 'tab-bar-tab-post-open-functions #'vtab--on-tab-open)
  ;; There is no post-close hook through Emacs 31.
  (advice-add 'tab-bar-close-tab :after #'vtab--on-tab-select)
  (advice-add 'tab-bar-close-other-tabs :after #'vtab--on-tab-select)
  (add-hook 'tab-bar-tab-post-change-group-functions #'vtab--refresh-if-enabled t)
  ;; Catch renames, moves and inactive group closures without post-change hooks.
  (add-hook 'post-command-hook #'vtab--refresh-if-enabled)
  (add-hook 'window-buffer-change-functions #'vtab--on-buffer-change)
  (add-hook 'org-agenda-finalize-hook #'vtab--on-org-agenda-finalize)
  (add-hook 'window-size-change-functions #'vtab--on-window-size-change)
  (add-hook 'pre-command-hook #'vtab--protect-selected-window)
  (add-hook 'post-command-hook #'vtab--protect-selected-window)
  ;; Add to window-persistent-parameters
  (add-to-list 'window-persistent-parameters '(no-delete-other-windows . t))
  ;; Thin window divider
  (when vtab-style-window-divider
    (setq window-divider-default-right-width 1)
    (setq window-divider-default-places 'right-only)
    (window-divider-mode 1))
  ;; Make fringe background transparent for clean border
  (when vtab-style-fringe
    (set-face-background 'fringe nil))
  ;; Show side window
  (vtab--protect-selected-window)
  (vtab--ensure-visible))

(defun vtab--disable ()
  "Internal function to disable `vtab-mode'."
  ;; Clean up all frames: windows, buffers, and frame parameters
  (dolist (frame (frame-list))
    (when-let* ((buf (frame-parameter frame 'vtab--buffer)))
      (when-let* ((win (get-buffer-window buf frame)))
        (delete-window win))
      (when (buffer-live-p buf)
        (kill-buffer buf)))
    (set-frame-parameter frame 'vtab--buffer nil)
    (set-frame-parameter frame 'vtab--tab-state nil)
    (set-frame-parameter frame 'vtab--last-selected-window nil)
    (set-frame-parameter frame 'vtab--collapsed-groups nil))
  ;; Remove frame hooks
  (remove-hook 'after-make-frame-functions #'vtab--setup-new-frame)
  (remove-hook 'delete-frame-functions #'vtab--on-frame-delete)
  ;; Remove hooks
  ;; Do not bind the optional post-select hook on older Emacs versions.
  (when (boundp 'tab-bar-tab-post-select-functions)
    (remove-hook 'tab-bar-tab-post-select-functions #'vtab--on-tab-select))
  (advice-remove 'tab-bar-select-tab #'vtab--on-tab-select)
  (remove-hook 'tab-bar-tab-post-open-functions #'vtab--on-tab-open)
  (advice-remove 'tab-bar-close-tab #'vtab--on-tab-select)
  (advice-remove 'tab-bar-close-other-tabs #'vtab--on-tab-select)
  (remove-hook 'tab-bar-tab-post-change-group-functions #'vtab--refresh-if-enabled)
  (remove-hook 'post-command-hook #'vtab--refresh-if-enabled)
  (remove-hook 'window-buffer-change-functions #'vtab--on-buffer-change)
  (remove-hook 'org-agenda-finalize-hook #'vtab--on-org-agenda-finalize)
  (remove-hook 'window-size-change-functions #'vtab--on-window-size-change)
  (remove-hook 'pre-command-hook #'vtab--protect-selected-window)
  (remove-hook 'post-command-hook #'vtab--protect-selected-window)
  ;; Remove from window-persistent-parameters
  (setq window-persistent-parameters
        (delete '(no-delete-other-windows . t) window-persistent-parameters))
  ;; Restore original settings
  (when vtab--saved-settings
    (setq tab-bar-show (alist-get 'tab-bar-show vtab--saved-settings))
    (setq tab-bar-new-tab-to (alist-get 'tab-bar-new-tab-to vtab--saved-settings))
    (setq tab-bar-new-tab-choice (alist-get 'tab-bar-new-tab-choice vtab--saved-settings))
    (modify-all-frames-parameters
     `((tab-bar-lines . ,(alist-get 'tab-bar-lines vtab--saved-settings))))
    ;; Restore window divider settings (only if saved)
    (when (assq 'window-divider-mode vtab--saved-settings)
      (setq window-divider-default-right-width
            (alist-get 'window-divider-default-right-width vtab--saved-settings))
      (setq window-divider-default-places
            (alist-get 'window-divider-default-places vtab--saved-settings))
      (window-divider-mode (if (alist-get 'window-divider-mode vtab--saved-settings) 1 -1)))
    ;; Restore fringe background (only if saved)
    (when (assq 'fringe-background vtab--saved-settings)
      (set-face-background 'fringe (alist-get 'fringe-background vtab--saved-settings)))))

;;;; Minor Mode

;;;###autoload
(define-minor-mode vtab-mode
  "Toggle vertical tab bar display.
When enabled, displays a vertical tab bar in a side window."
  :global t
  :group 'vtab
  :lighter " VTab"
  :keymap vtab-mode-map
  (if vtab-mode
      (vtab--enable)
    (vtab--disable)))

(provide 'vtab)

;;; vtab.el ends here
