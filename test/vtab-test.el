;;; vtab-test.el --- Regression tests for vtab -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'vtab)

(defun vtab-test--tab-names ()
  "Return the names of the tabs on the selected frame."
  (mapcar (lambda (tab) (alist-get 'name tab)) (tab-bar-tabs)))

(defun vtab-test--current-index ()
  "Return the zero-based index of the current tab."
  (seq-position (tab-bar-tabs) 'current-tab
                (lambda (tab marker) (eq (car tab) marker))))

(defun vtab-test--buffer ()
  "Return the vtab buffer owned by the selected frame."
  (frame-parameter nil 'vtab--buffer))

(defun vtab-test--window ()
  "Return the live vtab window on the selected frame, if any."
  (let ((buffer (vtab-test--buffer)))
    (and (buffer-live-p buffer)
         (get-buffer-window buffer (selected-frame)))))

(defun vtab-test--line-position (line &optional column)
  "Return the position at one-based LINE and zero-based COLUMN in vtab."
  (with-current-buffer (vtab-test--buffer)
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- line))
      (move-to-column (or column 0))
      (point))))

(defun vtab-test--position-coordinates (position)
  "Return POSITION as a (LINE COLUMN) pair in the vtab buffer."
  (with-current-buffer (vtab-test--buffer)
    (save-excursion
      (goto-char position)
      (list (line-number-at-pos nil t) (current-column)))))

(defun vtab-test--rendered-names ()
  "Return tab names represented by the current vtab rows."
  (with-current-buffer (vtab-test--buffer)
    (mapcar (lambda (line)
              (if (string-match "\\`[ >] [0-9]+: \\(.*\\)\\'" line)
                  (match-string 1 line)
                line))
            (split-string (buffer-substring-no-properties
                           (point-min) (point-max))
                          "\n" t))))

(defun vtab-test--assert-render-matches-tabs ()
  "Assert that vtab has exactly one correctly named row per actual tab."
  (should (equal (vtab-test--rendered-names) (vtab-test--tab-names))))

(defun vtab-test--assert-row-newlines (fill-enabled active-index)
  "Check newline properties for every row.
FILL-ENABLED controls active-row filling and ACTIVE-INDEX is zero based."
  (with-current-buffer (vtab-test--buffer)
    (save-excursion
      (goto-char (point-min))
      (dotimes (index (length (vtab-test--tab-names)))
        (end-of-line)
        (should (eq (char-after) ?\n))
        (should (equal (get-text-property (point) 'vtab-index) (1+ index)))
        (let ((map (get-text-property (point) 'keymap)))
          (should (keymapp map))
          (should (commandp (lookup-key map (kbd "RET")))))
        (if (and fill-enabled (= index active-index))
            (should (eq (get-text-property (point) 'face)
                        'vtab-active-line))
          (should-not (get-text-property (point) 'face)))
        (forward-char 1)))))

(defun vtab-test--make-tabs (names &optional current buffer)
  "Replace frame tabs with NAMES and select one-based CURRENT.
Display BUFFER in every tab when BUFFER is non-nil."
  (tab-bar-close-other-tabs)
  (when buffer
    (switch-to-buffer buffer))
  (tab-bar-rename-tab (car names))
  (dolist (name (cdr names))
    (tab-new)
    (when buffer
      (switch-to-buffer buffer))
    (tab-bar-rename-tab name))
  (tab-bar-select-tab (or current 1))
  (when buffer
    (switch-to-buffer buffer)))

(defun vtab-test--frame-parameters ()
  "Return non-nil vtab-owned parameters of the selected frame."
  (seq-filter (lambda (entry)
                (and (cdr entry)
                     (string-prefix-p "vtab--" (symbol-name (car entry)))))
              (frame-parameters)))

(defun vtab-test--optional-hook-value (symbol)
  "Return a copy of optional hook SYMBOL, or nil when it is unbound."
  (and (boundp symbol) (copy-sequence (symbol-value symbol))))

(defmacro vtab-test--with-sandbox (&rest body)
  "Run BODY in a fresh disposable batch session with isolated tabs.
The tests deliberately reject interactive or initially active vtab sessions,
then restore their tab and window setup so tests remain independent."
  (declare (indent 0) (debug t))
  `(let* ((frame (selected-frame))
          (saved-window-configuration (current-window-configuration frame))
          (saved-tabs (copy-tree (frame-parameter frame 'tabs)))
          (saved-current-tab (copy-tree (frame-parameter frame 'current-tab)))
          (saved-vtab-buffer (frame-parameter frame 'vtab--buffer))
          (saved-tab-bar-mode tab-bar-mode)
          (saved-tab-bar-lines (frame-parameter frame 'tab-bar-lines))
          (editing-buffer (generate-new-buffer " *vtab-test-edit*"))
          (vtab-style-window-divider nil)
          (vtab-style-fringe nil)
          (vtab-window-width 18)
          (vtab-hide-cursor nil)
          (vtab-hide-scroll-bars nil)
          (vtab-hide-mode-line nil)
          (vtab-active-fill-width nil)
          (vtab-scroll-to-current-tab t)
          (tab-bar-close-last-tab-choice 'tab-bar-mode-disable))
     (unwind-protect
         (progn
           (should noninteractive)
           (should-not vtab-mode)
           (should-not (frame-parameter frame 'vtab--buffer))
           (delete-other-windows)
           (tab-bar-mode 1)
           (vtab-test--make-tabs '("sandbox") 1 editing-buffer)
           ,@body)
       (ignore-errors
         (when vtab-mode
           (vtab-mode -1)))
       (let ((owned (frame-parameter frame 'vtab--buffer)))
         (when (and (buffer-live-p owned) (not (eq owned saved-vtab-buffer)))
           (kill-buffer owned)))
       (set-frame-parameter frame 'vtab--buffer saved-vtab-buffer)
       (set-frame-parameter frame 'tabs saved-tabs)
       (set-frame-parameter frame 'current-tab saved-current-tab)
       (ignore-errors (set-window-configuration saved-window-configuration))
       (set-frame-parameter frame 'tab-bar-lines saved-tab-bar-lines)
       (tab-bar-mode (if saved-tab-bar-mode 1 -1))
       (when (buffer-live-p editing-buffer)
         (kill-buffer editing-buffer)))))

(ert-deftest vtab-refresh-unchanged-preserves-buffer-and-window-state ()
  (vtab-test--with-sandbox
    (vtab-test--make-tabs
     (cl-loop for n from 1 to 40 collect (format "tab-%02d-long-name" n))
     20 editing-buffer)
    (vtab-mode 1)
    (let* ((buffer (vtab-test--buffer))
           (window (vtab-test--window))
           (start (vtab-test--line-position 5))
           (window-point (vtab-test--line-position 10 3))
           (buffer-point (vtab-test--line-position 12 5)))
      (should (window-live-p window))
      (set-window-start window start t)
      (set-window-point window window-point)
      (with-current-buffer buffer (goto-char buffer-point))
      (set-window-vscroll window 3 t)
      (let ((tick (buffer-chars-modified-tick buffer))
            (point (with-current-buffer buffer (point)))
            (win-point (window-point window))
            (win-start (window-start window))
            (pixel-vscroll (window-vscroll window t)))
        (vtab--refresh)
        (should (= (buffer-chars-modified-tick buffer) tick))
        (should (= (with-current-buffer buffer (point)) point))
        (should (= (window-point window) win-point))
        (should (= (window-start window) win-start))
        (should (= (window-vscroll window t) pixel-vscroll))))))

(ert-deftest vtab-refresh-invalidates-on-name-current-and-fill-inputs ()
  (vtab-test--with-sandbox
    (vtab-test--make-tabs '("one" "two" "three") 1 editing-buffer)
    (vtab-mode 1)
    (let ((buffer (vtab-test--buffer)))
      (let ((tick (buffer-chars-modified-tick buffer)))
        (tab-bar-rename-tab "renamed-one")
        (vtab--refresh)
        (should (> (buffer-chars-modified-tick buffer) tick))
        (should (equal (car (vtab-test--rendered-names)) "renamed-one")))
      (let ((tick (buffer-chars-modified-tick buffer)))
        (tab-bar-select-tab 2)
        (should (> (buffer-chars-modified-tick buffer) tick))
        (should (= (vtab-test--current-index) 1))
        (with-current-buffer buffer
          (goto-char (point-min))
          (forward-line 1)
          (should (eq (get-text-property (point) 'face)
                      'vtab-active-face))))
      (let ((tick (buffer-chars-modified-tick buffer))
            (vtab-active-fill-width t))
        (vtab--refresh)
        (should (> (buffer-chars-modified-tick buffer) tick))
        (with-current-buffer buffer
          (goto-char (point-min))
          (forward-line 1)
          (end-of-line)
          (should (eq (get-text-property (point) 'face)
                      'vtab-active-line)))))))

(ert-deftest vtab-nil-side-window-does-not-touch-editing-window-or-buffer ()
  (vtab-test--with-sandbox
    (let* ((window (selected-window))
           (expected-cursor-type 'box)
           (cursor-other 'hollow)
           (mode-line '("existing mode"))
           (header-line '("existing header")))
      (with-current-buffer editing-buffer
        (setq-local cursor-type expected-cursor-type)
        (setq-local cursor-in-non-selected-windows cursor-other)
        (setq-local mode-line-format mode-line)
        (setq-local header-line-format header-line))
      (set-window-scroll-bars window 2 'left 1 'bottom t)
      (let ((scroll-bars (window-scroll-bars window)))
        (should-not (get-buffer-window (vtab--get-buffer)))
        (cl-letf (((symbol-function 'display-buffer-in-side-window)
                   (lambda (&rest _) nil)))
          (vtab-mode 1)
          (vtab-mode -1))
        (with-current-buffer editing-buffer
          (should (local-variable-p 'cursor-type))
          (should (eq cursor-type expected-cursor-type))
          (should (eq cursor-in-non-selected-windows cursor-other))
          (should (equal mode-line-format mode-line))
          (should (equal header-line-format header-line)))
        (should (equal (window-scroll-bars window) scroll-bars))))))

(ert-deftest vtab-changed-refresh-preserves-cursor-and-viewport-separately ()
  (vtab-test--with-sandbox
    (vtab-test--make-tabs
     (cl-loop for n from 1 to 40 collect (format "tab-%02d-long-name" n))
     18 editing-buffer)
    (vtab-mode 1)
    (let* ((buffer (vtab-test--buffer))
           (window (vtab-test--window)))
      (set-window-start window (vtab-test--line-position 4) t)
      (set-window-point window (vtab-test--line-position 9 2))
      (with-current-buffer buffer
        (goto-char (vtab-test--line-position 13 6)))
      (set-window-vscroll window 4 t)
      (let ((buffer-coordinates
             (vtab-test--position-coordinates
              (with-current-buffer buffer (point))))
            (window-coordinates
             (vtab-test--position-coordinates (window-point window)))
            (start-line (car (vtab-test--position-coordinates
                              (window-start window))))
            (pixel-vscroll (window-vscroll window t))
            (tick (buffer-chars-modified-tick buffer)))
        (tab-bar-rename-tab "changed-current-tab-name")
        (vtab--refresh)
        (should (> (buffer-chars-modified-tick buffer) tick))
        (should (equal (vtab-test--position-coordinates
                        (with-current-buffer buffer (point)))
                       buffer-coordinates))
        (should (equal (vtab-test--position-coordinates (window-point window))
                       window-coordinates))
        (should (= (car (vtab-test--position-coordinates
                         (window-start window)))
                   start-line))
        (should (= (window-vscroll window t) pixel-vscroll))))))

(ert-deftest vtab-every-row-newline-is-interactive-and-fill-is-specific ()
  (vtab-test--with-sandbox
    (vtab-test--make-tabs '("one" "two" "three") 3 editing-buffer)
    (vtab-mode 1)
    (vtab-test--assert-row-newlines nil 2)
    (let ((vtab-active-fill-width t))
      (vtab--refresh)
      (vtab-test--assert-row-newlines t 2)
      (let* ((window (vtab-test--window))
             (newline (with-current-buffer (vtab-test--buffer)
                        (goto-char (point-min))
                        (forward-line 1)
                        (end-of-line)
                        (point)))
             (command (get-text-property newline 'keymap
                                         (vtab-test--buffer))))
        (setq command (lookup-key command (kbd "RET")))
        (select-window window)
        (goto-char newline)
        (call-interactively command)
        (should (= (vtab-test--current-index) 1))))))

(defun vtab-test--prepare-same-buffer-tabs (editing-buffer)
  "Prepare and enable five tabs displaying the sandbox editing buffer."
  (vtab-test--make-tabs '("one" "two" "three" "four" "five")
                        3 editing-buffer)
  (dotimes (index 5)
    (tab-bar-select-tab (1+ index))
    (should (eq (window-buffer (selected-window)) editing-buffer)))
  (tab-bar-select-tab 3)
  (vtab-mode 1))

(ert-deftest vtab-close-current-tracks-same-buffer-tabs ()
  (vtab-test--with-sandbox
    (vtab-test--prepare-same-buffer-tabs editing-buffer)
    (tab-bar-close-tab)
    (vtab-test--assert-render-matches-tabs)))

(ert-deftest vtab-close-inactive-tracks-same-buffer-tabs ()
  (vtab-test--with-sandbox
    (vtab-test--prepare-same-buffer-tabs editing-buffer)
    (tab-bar-close-tab 1)
    (vtab-test--assert-render-matches-tabs)))

(ert-deftest vtab-close-other-tabs-renders-final-tab-list ()
  (vtab-test--with-sandbox
    (vtab-test--prepare-same-buffer-tabs editing-buffer)
    (tab-bar-close-other-tabs)
    (vtab-test--assert-render-matches-tabs)
    (should (= (length (vtab-test--tab-names)) 1))))

(ert-deftest vtab-killed-owned-buffer-is-recreated-with-content ()
  (vtab-test--with-sandbox
    (vtab-test--make-tabs '("one" "two" "three") 2 editing-buffer)
    (vtab-mode 1)
    (let ((old-buffer (vtab-test--buffer)))
      (should (buffer-live-p old-buffer))
      (kill-buffer old-buffer)
      (vtab--refresh)
      (let ((new-buffer (vtab-test--buffer)))
        (should (buffer-live-p new-buffer))
        (should-not (eq old-buffer new-buffer))
        (vtab-test--assert-render-matches-tabs)
        (should (> (buffer-size new-buffer) 0))))))

(ert-deftest vtab-undisplayed-refresh-preserves-buffer-point-coordinates ()
  (vtab-test--with-sandbox
    (vtab-test--make-tabs '("one" "two" "three") 1 editing-buffer)
    (vtab-mode 1)
    (let ((buffer (vtab-test--buffer))
          (window (vtab-test--window)))
      (delete-window window)
      (should-not (get-buffer-window buffer (selected-frame)))
      (with-current-buffer buffer
        (goto-char 4))
      (let ((coordinates
             (vtab-test--position-coordinates
              (with-current-buffer buffer (point)))))
        (tab-bar-rename-tab "renamed-one-with-a-longer-name")
        (vtab--refresh)
        (should-not (get-buffer-window buffer (selected-frame)))
        (should (equal (vtab-test--position-coordinates
                        (with-current-buffer buffer (point)))
                       coordinates))))))

(ert-deftest vtab-tab-selection-scrolls-down-to-current-row ()
  (vtab-test--with-sandbox
    (vtab-test--make-tabs
     (cl-loop for n from 1 to 45 collect (format "tab-%02d" n))
     1 editing-buffer)
    (vtab-mode 1)
    (let ((window (vtab-test--window)))
      (set-window-start window (vtab-test--line-position 1) t)
      (tab-bar-select-tab 45)
      (setq window (vtab-test--window))
      (redisplay t)
      (should (= (with-current-buffer (window-buffer window)
                   (line-number-at-pos (window-point window) t))
                 45)))))

(ert-deftest vtab-visible-scrollbars-inherit-frame-settings ()
  (vtab-test--with-sandbox
    (let ((vtab-hide-scroll-bars nil))
      (vtab-mode 1)
      (let ((scroll-bars (window-scroll-bars (vtab-test--window))))
        (should (eq (nth 2 scroll-bars) t))
        (should (eq (nth 5 scroll-bars) t))))))

(ert-deftest vtab-hide-options-restore-preexisting-buffer-local-values ()
  (vtab-test--with-sandbox
    (vtab-test--make-tabs '("one" "two") 1 editing-buffer)
    (let ((owned (vtab--get-buffer))
          (original-mode-line '("local mode"))
          (original-header-line '("local header")))
      (with-current-buffer owned
        (setq-local cursor-type 'bar)
        (setq-local cursor-in-non-selected-windows 'hollow)
        (setq-local mode-line-format original-mode-line)
        (setq-local header-line-format original-header-line))
      (let ((vtab-hide-cursor t)
            (vtab-hide-mode-line t))
        (vtab-mode 1)
        (with-current-buffer owned
          (should-not cursor-type)
          (should-not cursor-in-non-selected-windows)
          (should-not mode-line-format)
          (should-not header-line-format))
        (setq vtab-hide-cursor nil
              vtab-hide-mode-line nil)
        ;; Selecting a tab revisits the side window and reapplies display
        ;; options without coupling the test to an option helper.
        (tab-bar-select-tab 2)
        (with-current-buffer owned
          (should (local-variable-p 'cursor-type))
          (should (eq cursor-type 'bar))
          (should (eq cursor-in-non-selected-windows 'hollow))
          (should (equal mode-line-format original-mode-line))
          (should (equal header-line-format original-header-line)))))))

(ert-deftest vtab-false-hide-options-never-alter-buffer-local-values ()
  (vtab-test--with-sandbox
    (let ((owned (vtab--get-buffer))
          (original-mode-line '("local mode"))
          (original-header-line '("local header")))
      (with-current-buffer owned
        (setq-local cursor-type 'bar)
        (setq-local cursor-in-non-selected-windows 'hollow)
        (setq-local mode-line-format original-mode-line)
        (setq-local header-line-format original-header-line))
      (let ((vtab-hide-cursor nil)
            (vtab-hide-mode-line nil))
        (vtab-mode 1)
        (with-current-buffer owned
          (should (local-variable-p 'cursor-type))
          (should (eq cursor-type 'bar))
          (should (eq cursor-in-non-selected-windows 'hollow))
          (should (equal mode-line-format original-mode-line))
          (should (equal header-line-format original-header-line)))))))

(ert-deftest vtab-cursor-hiding-does-not-install-persistent-window-overrides ()
  (vtab-test--with-sandbox
    (vtab-test--make-tabs '("one" "two") 1 editing-buffer)
    (with-current-buffer editing-buffer
      (setq-local cursor-type 'bar)
      (setq-local cursor-in-non-selected-windows 'hollow))
    (let ((events nil)
          (real-setter (and (fboundp 'set-window-cursor-type)
                            (symbol-function 'set-window-cursor-type)))
          (vtab-hide-cursor t)
          (exercise
           (lambda ()
             (vtab-mode 1)
             (with-current-buffer (vtab-test--buffer)
               (should-not cursor-type)
               (should-not cursor-in-non-selected-windows))
             (tab-bar-select-tab 2)
             (tab-bar-select-tab 1)
             (vtab-mode -1)
             ;; Revisit a tab whose window configuration displayed vtab.
             (tab-bar-select-tab 2))))
      (if real-setter
          (cl-letf (((symbol-function 'set-window-cursor-type)
                     (lambda (window type)
                       (push (list window type) events)
                       (funcall real-setter window type))))
            (funcall exercise))
        (funcall exercise))
      ;; Buffer-local hiding is sufficient.  Calling the window-persistent
      ;; setter caused the original cursor leak when an old tab was revisited.
      (should-not events)
      (with-current-buffer editing-buffer
        (should (eq cursor-type 'bar))
        (should (eq cursor-in-non-selected-windows 'hollow))))))

(ert-deftest vtab-post-select-fallback-cleans-up-if-hook-appears ()
  (vtab-test--with-sandbox
    (let* ((hook 'tab-bar-tab-post-select-functions)
           (was-bound (boundp hook))
           (saved-hook (and was-bound (symbol-value hook)))
           (baseline-selector (symbol-function 'tab-bar-select-tab)))
      (unwind-protect
          (progn
            (makunbound hook)
            (vtab-mode 1)
            (should-not (eq (symbol-function 'tab-bar-select-tab)
                            baseline-selector))
            ;; Simulate a compatibility layer defining the hook after enable.
            (set hook nil)
            (vtab-mode -1)
            (should (eq (symbol-function 'tab-bar-select-tab)
                        baseline-selector)))
        (unless (eq (symbol-function 'tab-bar-select-tab) baseline-selector)
          (fset 'tab-bar-select-tab baseline-selector))
        (if was-bound
            (set hook saved-hook)
          (makunbound hook))))))

(ert-deftest vtab-post-select-fallback-repeats-while-hook-is-absent ()
  (vtab-test--with-sandbox
    (let* ((hook 'tab-bar-tab-post-select-functions)
           (was-bound (boundp hook))
           (saved-hook (and was-bound (symbol-value hook)))
           (baseline-selector (symbol-function 'tab-bar-select-tab)))
      (unwind-protect
          (progn
            (makunbound hook)
            (dotimes (_ 2)
              (vtab-mode 1)
              (should (advice-member-p #'vtab--on-tab-select
                                       'tab-bar-select-tab))
              (vtab-mode -1)
              (should-not (boundp hook))
              (should (eq (symbol-function 'tab-bar-select-tab)
                          baseline-selector))))
        (unless (eq (symbol-function 'tab-bar-select-tab) baseline-selector)
          (fset 'tab-bar-select-tab baseline-selector))
        (if was-bound
            (set hook saved-hook)
          (makunbound hook))))))

(ert-deftest vtab-repeated-enable-disable-cleans-lifecycle-state ()
  (vtab-test--with-sandbox
    (vtab-test--make-tabs '("one" "two" "three") 1 editing-buffer)
    (let ((baseline-after-frame (copy-sequence after-make-frame-functions))
          (baseline-delete-frame (copy-sequence delete-frame-functions))
          (baseline-post-select
           (vtab-test--optional-hook-value
            'tab-bar-tab-post-select-functions))
          (baseline-post-open
           (vtab-test--optional-hook-value
            'tab-bar-tab-post-open-functions))
          (baseline-buffer-change
           (vtab-test--optional-hook-value
            'window-buffer-change-functions))
          (baseline-size-change
           (vtab-test--optional-hook-value
            'window-size-change-functions))
          (baseline-agenda
           (vtab-test--optional-hook-value 'org-agenda-finalize-hook))
          (baseline-selector (symbol-function 'tab-bar-select-tab))
          (baseline-close-tab (symbol-function 'tab-bar-close-tab))
          (baseline-close-other (symbol-function 'tab-bar-close-other-tabs))
          (baseline-frame-parameters (vtab-test--frame-parameters))
          (old-buffers nil))
      (dotimes (iteration 3)
        (vtab-mode 1)
        (let ((owned (vtab-test--buffer)))
          (should (buffer-live-p owned))
          (push owned old-buffers)
          (tab-bar-rename-tab (format "iteration-%d" iteration))
          (vtab--refresh)
          (should (member (format "iteration-%d" iteration)
                          (vtab-test--rendered-names))))
        (vtab-mode -1)
        (should-not (frame-parameter nil 'vtab--buffer))
        (should (equal (vtab-test--frame-parameters)
                       baseline-frame-parameters))
        (should-not (seq-some #'buffer-live-p old-buffers))
        ;; Tab lifecycle events while disabled must not recreate vtab state.
        (tab-bar-select-tab 2)
        (should-not (frame-parameter nil 'vtab--buffer)))
      (should (equal after-make-frame-functions baseline-after-frame))
      (should (equal delete-frame-functions baseline-delete-frame))
      (should (equal (vtab-test--optional-hook-value
                      'tab-bar-tab-post-select-functions)
                     baseline-post-select))
      (should (equal (vtab-test--optional-hook-value
                      'tab-bar-tab-post-open-functions)
                     baseline-post-open))
      (should (equal (vtab-test--optional-hook-value
                      'window-buffer-change-functions)
                     baseline-buffer-change))
      (should (equal (vtab-test--optional-hook-value
                      'window-size-change-functions)
                     baseline-size-change))
      (should (equal (vtab-test--optional-hook-value
                      'org-agenda-finalize-hook)
                     baseline-agenda))
      (should (eq (symbol-function 'tab-bar-select-tab) baseline-selector))
      (should (eq (symbol-function 'tab-bar-close-tab) baseline-close-tab))
      (should (eq (symbol-function 'tab-bar-close-other-tabs)
                  baseline-close-other)))))

(provide 'vtab-test)

;;; vtab-test.el ends here
