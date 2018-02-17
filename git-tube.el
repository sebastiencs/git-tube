;;; git-tube.el --- Git gutter with native module -*- lexical-binding: t; -*-

;; Copyright (C) 2018 Sebastien Chapuis

;; Author:  Sebastien Chapuis <sebastien@chapu.is>
;; Keywords: git
;; URL: https://github.com/sebastiencs/git-tube
;; Package-Requires: ((emacs "25.1") (dash "2.11"))
;; Version: 0.0.1

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; git-tube contains ...

;;; Code:

(require 'dash)
(require 'hydra)

(defgroup git-tube nil
  "‘git-tube’ contains.."
  :group 'tools
  :group 'convenience
  :link '(custom-manual "(git-tube) Top")
  :link '(info-link "(git-tube) Customizing"))

(defvar-local git-tube--diffs nil)

(defun git-tube--character (lines)
  "LINES."
  (let ((color (or (and (--all? (eq (plist-get it :kind) 'addition) lines) "green")
                   (and (--all? (eq (plist-get it :kind) 'deletion) lines) "red")
                   "orange")))
    (propertize "|" 'face (list :inherit 'default :foreground color))))

(defun git-tube--display (diffs)
  "DIFFS."
  (dolist (diff diffs)
    (-let* (((hunk . lines) diff)
            (char (git-tube--character lines))
            (nlines (plist-get hunk :lines)))
      (goto-char 1)
      (forward-line (1- (plist-get hunk :start)))
      (dotimes (_ (max nlines 1))
        (let ((ov (make-overlay (point) (point))))
          (overlay-put ov 'before-string (propertize " " 'display `((margin left-margin) ,char)))
          (overlay-put ov 'git-tube t))
        (forward-line 1)))))

(defun git-tube--sort (hunk-a hunk-b)
  "HUNK-A HUNK-B."
  (< (plist-get (car hunk-a) :start) (plist-get (car hunk-b) :start)))

(defun git-tube--update nil
  "."
  (interactive)
  (git-tube--clean)
  (let* ((inhibit-message t)
         (diffs (sort (git-tube-diff) 'git-tube--sort)))
    (git-tube--set-margin)
    (setq git-tube--diffs diffs)
    (save-excursion
      (git-tube--display diffs))))

(defun git-tube--goto (hunk)
  "HUNK."
  (when hunk
    (goto-char 1)
    (forward-line (1- (plist-get (car hunk) :start)))
    (-when-let* ((buffer (get-buffer "*git-tube*"))
                 (win (get-buffer-window buffer)))
      (git-tube--update-buffer hunk))))

(defun git-tube-next-hunk nil
  "."
  (interactive)
  (git-tube--goto (--first (> (plist-get (car it) :start) (line-number-at-pos))
                           git-tube--diffs)))

(defun git-tube-prev-hunk nil
  "."
  (interactive)
  (git-tube--goto (--last (< (plist-get (car it) :start) (line-number-at-pos))
                          git-tube--diffs)))

(defun git-tube--hunk-at-point nil
  "."
  (let* ((line (line-number-at-pos)))
    (--first (and (>= line (plist-get (car it) :start))
                  (< line (+ (plist-get (car it) :start) (max (plist-get (car it) :lines) 1))))
             git-tube--diffs)))

(defun git-tube--update-buffer (hunk)
  "HUNK."
  (-when-let* ((hunk hunk)
               (buffer (get-buffer-create "*git-tube*")))
    (with-current-buffer buffer
      (setq-local truncate-lines t)
      (setq-local buffer-read-only nil)
      (erase-buffer)
      (insert (plist-get (car hunk) :header))
      (dolist (line (cdr hunk))
        (insert (if (eq (plist-get line :kind) 'addition) "+" "-"))
        (insert (plist-get line :content)))
      (diff-mode)
      (goto-char 1))
    buffer))

(defun git-tube--clean nil
  "."
  (remove-overlays nil nil 'git-tube t))

(defun git-tube-pop nil
  "."
  (interactive)
  (-when-let (buffer (git-tube--update-buffer (git-tube--hunk-at-point)))
    (display-buffer-pop-up-window buffer nil)))

(defun git-tube-revert nil
  "."
  (interactive)
  (-when-let* (((hunk . lines) (git-tube--hunk-at-point))
               (kill-whole-line t))
    (save-excursion
      (goto-char 1)
      (forward-line (1- (plist-get hunk :start)))
      (when (--all? (eq (plist-get it :kind) 'deletion) lines)
        (forward-line 1))
      (dolist (line lines)
        (pcase (plist-get line :kind)
          ('addition (kill-whole-line))
          ('deletion (insert (plist-get line :content)))))
      (save-buffer))))

(defun git-tube-setup (&rest _)
  "FRAME."
  (remove-hook 'after-make-frame-functions 'git-tube-setup)
  (let* ((module-dir (->> (file-name-directory (find-library-name "git-tube"))
                          (expand-file-name "git-tube-module")))
         (lib (->> (expand-file-name "target" module-dir)
                   (expand-file-name "release")
                   (expand-file-name "libgit_tube_module"))))
    (or (load lib t t)
        ;; In the daemon init
        (and (null after-init-time)
             (string= (terminal-name) "initial_terminal")
             (add-hook 'after-make-frame-functions 'git-tube-setup t))
        (run-with-idle-timer
         3 nil
         (lambda nil
           (let ((default-directory module-dir))
             (with-current-buffer (compilation-start "cargo build --release")
               (font-lock-add-keywords nil '(("^error\\:?" . 'error)
                                             ("^warning\\:?" . 'warning)
                                             ("^\s*Compiling\s" . 'success)))
               (setq-local compilation-finish-functions
                           (list (lambda (&rest _) (load lib t)))))))))))

;;;###autoload
(define-minor-mode git-tube-mode
  "Git-tube mode"
  :init-value nil
  :global     nil
  :lighter    " tube"
  (cond
   (git-tube-mode
    (add-hook 'after-save-hook 'git-tube--update t t)
    (add-hook 'window-configuration-change-hook 'git-tube--set-margin nil t)
    (git-tube--update))
   (t
    (git-tube--clean)
    (remove-hook 'window-configuration-change-hook 'git-tube--set-margin t)
    (remove-hook 'after-save-hook 'git-tube--update t))))

(defun git-tube--set-margin (&rest _)
  "."
  (and git-tube-mode
       (= 0 (or (car (window-margins)) 0))
       (set-window-margins nil 1)))

(define-global-minor-mode global-git-tube-mode git-tube-mode
  (lambda nil
    (when buffer-file-name
      (git-tube-mode 1)))
  :require 'git-tube
  :group 'git-tube)

(defhydra hydra-git-tube (:body-pre (git-tube-mode 1)
					                :hint nil)
  "
=========================== Git tube =============================
  _<down>_: next      _f_irst  _S_tage hunk    set start _R_evision  _q_uit
  _<up>_:   previous  _l_ast   _r_evert hunk   _p_opup hunk
"
  ("<down>" git-tube-next-hunk)
  ("<up>" git-tube-prev-hunk)
  ("f" (progn (goto-char (point-min))
		      (git-tube-next-hunk)))
  ("l" (progn (goto-char (point-max))
		      (git-tube-prev-hunk)))
  ("S" (progn (message "Uninplemented")))
  ("r" (progn (git-tube-revert)))
  ("p" (progn (git-tube-pop)))
  ("R" (progn (message "Uninplemented")))
  ("q" nil :color blue)
  )

(defalias 'git-tube-hydra 'hydra-git-tube/body)

(provide 'git-tube)
;;; git-tube.el ends here
