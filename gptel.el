;;; gptel.el --- A simple ChatGPT client      -*- lexical-binding: t; -*-

;; Copyright (C) 2023  Karthik Chikmagalur

;; Author: Karthik Chikmagalur
;; Version: 0.10
;; Package-Requires: ((emacs "27.1") (aio "1.0") (transient "0.3.7"))
;; Keywords: convenience
;; URL: https://github.com/karthink/gptel

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; A ChatGPT client for Emacs.
;;
;; Requirements:
;; - You need an OpenAI API key. Set the variable `gptel-api-key' to the key or to
;;   a function of no arguments that returns the key.
;;
;; - If installing manually: Install the package `emacs-aio' using `M-x package-install'
;;   or however you install packages.
;;
;; - Not required but recommended: Install `markdown-mode'.
;;
;; Usage:
;; - M-x gptel: Start a ChatGPT session
;; - C-u M-x gptel: Start another or multiple independent ChatGPT sessions
;;
;; - In the GPT session: Press `C-c RET' (control + c, followed by return) to send
;;   your prompt.
;; - To jump between prompts, use `C-c C-n' and `C-c C-p'.

;;; Code:
(declare-function markdown-mode "markdown-mode")
(declare-function gptel-curl-get-response "gptel-curl")
(declare-function gptel-send-menu "gptel-transient")
(declare-function pulse-momentary-highlight-region "pulse")

(eval-when-compile
  (require 'subr-x)
  (require 'cl-lib))

(require 'aio)
(require 'json)
(require 'map)
(require 'text-property-search)

(defcustom gptel-api-key nil
  "An OpenAI API key (string).

Can also be a function of no arguments that returns an API
key (more secure)."
  :group 'gptel
  :type '(choice
          (string :tag "API key")
          (function :tag "Function that retuns the API key")))

(defcustom gptel-playback nil
  "Whether responses from ChatGPT be played back in chunks.

When set to nil, it is inserted all at once.

'tis a bit silly."
  :group 'gptel
  :type 'boolean)

(defcustom gptel-use-curl (and (executable-find "curl") t)
  "Whether gptel should prefer Curl when available."
  :group 'gptel
  :type 'boolean)

(defcustom gptel-response-filter-functions
  '(gptel--convert-org)
  "Abnormal hook for transforming the response from ChatGPT.

This is useful if you want to format the response in some way,
such as filling paragraphs, adding annotations or recording
information in the response like links.

Each function in this hook receives two arguments, the response
string to transform and the ChatGPT interaction buffer. It should
return the transformed string."
  :group 'gptel
  :type 'hook)

(defvar gptel-default-session "*ChatGPT*")
(defvar gptel-default-mode (if (featurep 'markdown-mode)
                               'markdown-mode
                             'text-mode))
(defvar gptel-prompt-string "### ")

;; Model and interaction parameters
(defvar-local gptel--system-message
  "You are a large language model living in Emacs and a helpful assistant. Respond concisely.")
(defvar gptel--system-message-alist
  `((default . ,gptel--system-message)
    (programming . "You are a large language model and a careful programmer. Provide code and only code as output without any additional text, prompt or note.")
    (writing . "You are a large language model and a writing assistant. Respond concisely.")
    (chat . "You are a large language model and a conversation partner. Respond concisely."))
  "Prompt templates (directives).")
(defvar-local gptel--max-tokens nil)
(defvar-local gptel--model "gpt-3.5-turbo")
(defvar-local gptel--temperature 1.0)
(defvar-local gptel--num-messages-to-send nil)

(defsubst gptel--numberize (val)
  "Ensure VAL is a number."
  (if (stringp val) (string-to-number val) val))

(aio-defun gptel-send (&optional arg)
  "Submit this prompt to ChatGPT."
  (interactive "P")
  (if (and arg (require 'gptel-transient nil t))
      (call-interactively #'gptel-send-menu)
  (message "Querying ChatGPT...")
  (and header-line-format
    (setf (nth 1 header-line-format)
          (propertize " Waiting..." 'face 'warning))
    (force-mode-line-update))
  (let* ((gptel-buffer (current-buffer))
         (full-prompt (gptel--create-prompt))
         (response (aio-await
                    (funcall
                     (if gptel-use-curl
                         #'gptel-curl-get-response #'gptel--url-get-response)
                     full-prompt)))
         (content-str (plist-get response :content))
         (status-str  (plist-get response :status)))
    (if content-str
        (with-current-buffer gptel-buffer
          (setq content-str (gptel--transform-response
                             content-str gptel-buffer))
          (save-excursion
            (put-text-property 0 (length content-str) 'gptel 'response content-str)
            (message "Querying ChatGPT... done.")
            (goto-char (point-max))
            (display-buffer (current-buffer)
                            '((display-buffer-reuse-window
                               display-buffer-use-some-window)))
            (unless (bobp) (insert "\n\n"))
            (if gptel-playback
                (gptel--playback (current-buffer) content-str (point))
              (let ((p (point)))
                (insert content-str)
                (pulse-momentary-highlight-region p (point))))
            (insert "\n\n" gptel-prompt-string)
            (unless gptel-playback
              (setf (nth 1 header-line-format)
                    (propertize " Ready" 'face 'success)))))
      (and header-line-format
           (setf (nth 1 header-line-format)
                 (propertize (format " Response Error: %s" status-str)
                             'face 'error)))))))

(defun gptel--create-prompt ()
  "Return a full conversation prompt from the contents of this buffer.

If `gptel--num-messages-to-send' is set, limit to that many
recent exchanges.

If the region is active limit the prompt to the region contents
instead."
  (save-excursion
    (save-restriction
      (when (use-region-p)
        (narrow-to-region (region-beginning) (region-end)))
      (goto-char (point-max))
      (let ((max-entries (and gptel--num-messages-to-send
                              (* 2 (gptel--numberize
                                    gptel--num-messages-to-send))))
            (prop) (prompts))
        (while (and
                (or (not max-entries) (>= max-entries 0))
                (setq prop (text-property-search-backward
                            'gptel 'response
                            (when (get-char-property (max (point-min) (1- (point)))
                                                     'gptel)
                              t))))
          (push (list :role (if (prop-match-value prop) "assistant" "user")
                      :content
                      (string-trim
                       (buffer-substring-no-properties (prop-match-beginning prop)
                                                       (prop-match-end prop))
                       "[*# \t\n\r]+"))
                prompts)
          (and max-entries (cl-decf max-entries)))
        (cons (list :role "system"
                    :content gptel--system-message)
              prompts)))))

(defun gptel--request-data (prompts)
  "JSON encode PROMPTS for sending to ChatGPT."
  (let ((prompts-plist
         `(:model ,gptel--model
           :messages [,@prompts])))
    (when gptel--temperature
      (plist-put prompts-plist :temperature (gptel--numberize gptel--temperature)))
    (when gptel--max-tokens
      (plist-put prompts-plist :max_tokens (gptel--numberize gptel--max-tokens)))
    prompts-plist))

;; TODO: Use `run-hook-wrapped' with an accumulator instead to handle
;; buffer-local hooks, etc.
(defun gptel--transform-response (content-str buffer)
  (let ((filtered-str content-str))
    (dolist (filter-func gptel-response-filter-functions filtered-str)
      (condition-case nil
          (when (functionp filter-func)
            (setq filtered-str
                  (funcall filter-func filtered-str buffer)))
        (error
         (display-warning '(gptel filter-functions)
                          (format "Function %S returned an error"
                                  filter-func)))))))

(defun gptel--convert-org (content buffer)
  "Transform CONTENT according to required major-mode.

Currently only org-mode is handled.

BUFFER is the interaction buffer for ChatGPT."
  (pcase (buffer-local-value 'major-mode buffer)
    ('org-mode (gptel--convert-markdown->org content))
    (_ content)))

(aio-defun gptel--url-get-response (prompts)
  "Fetch response for PROMPTS from ChatGPT.

Return the message received."
  (let* ((inhibit-message t)
         (message-log-max nil)
         (api-key
          (cond
           ((stringp gptel-api-key) gptel-api-key)
           ((functionp gptel-api-key) (funcall gptel-api-key))))
         (url-request-method "POST")
         (url-request-extra-headers
         `(("Content-Type" . "application/json")
           ("Authorization" . ,(concat "Bearer " api-key))))
        (url-request-data
         (encode-coding-string (json-encode (gptel--request-data prompts)) 'utf-8)))
    (pcase-let ((`(,_ . ,response-buffer)
                 (aio-await
                  (aio-url-retrieve "https://api.openai.com/v1/chat/completions"))))
      (prog1
          (gptel--url-parse-response response-buffer)
        (kill-buffer response-buffer)))))

(defun gptel--url-parse-response (response-buffer)
  "Parse response in RESPONSE-BUFFER."
  (when (buffer-live-p response-buffer)
    (with-current-buffer response-buffer
      (if-let* ((status (buffer-substring (line-beginning-position) (line-end-position)))
                ((string-match-p "200 OK" status))
                (response (progn (forward-paragraph)
                                 (json-read)))
                (content (map-nested-elt
                          response '(:choices 0 :message :content))))
          (list :content (string-trim content)
                :status status)
        (list :content nil :status status)))))

(define-minor-mode gptel-mode
  "Minor mode for interacting with ChatGPT."
  :glboal nil
  :lighter " GPT"
  :keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c RET") #'gptel-send)
    map))

;;;###autoload
(defun gptel (name &optional api-key initial)
  "Switch to or start ChatGPT session with NAME.

With a prefix arg, query for a (new) session name.

Ask for API-KEY if `gptel-api-key' is unset.

If region is active, use it as the INITIAL prompt."
  (interactive (list (if current-prefix-arg
                         (read-string "Session name: " (generate-new-buffer-name gptel-default-session))
                       gptel-default-session)
                     (or gptel-api-key
                         (setq gptel-api-key
                               (read-passwd "OpenAI API key: ")))
                     (and (use-region-p)
                          (buffer-substring (region-beginning)
                                            (region-end)))))
  (unless api-key
    (user-error "No API key available"))
  (with-current-buffer (get-buffer-create name)
    (cond ;Set major mode
     ((eq major-mode gptel-default-mode))
     ((eq gptel-default-mode 'text-mode)
      (text-mode)
      (visual-line-mode 1))
     (t (funcall gptel-default-mode)))
    (unless gptel-mode (gptel-mode 1))
    (if (bobp) (insert (or initial gptel-prompt-string)))
    (pop-to-buffer (current-buffer))
    (goto-char (point-max))
    (skip-chars-backward "\t\r\n")
    (or header-line-format
      (setq header-line-format
            (list (concat (propertize " " 'display '(space :align-to 0))
                          (format "%s" (buffer-name)))
                  (propertize " Ready" 'face 'success))))
    (message "Send your query with %s!"
             (substitute-command-keys "\\[gptel-send]"))))

(defun gptel--convert-markdown->org (str)
  "Convert string STR from markdown to org markup.

This is a very basic converter that handles only a few markup
elements."
  (interactive)
  (with-temp-buffer
    (insert str)
    (goto-char (point-min))
    (while (re-search-forward "`\\|\\*\\{1,2\\}\\|_" nil t)
      (pcase (match-string 0)
        ("`" (if (looking-at "``")
                 (progn (backward-char)
                        (delete-char 3)
                        (insert "#+begin_src ")
                        (when (re-search-forward "^```" nil t)
                          (replace-match "#+end_src")))
               (replace-match "=")))
        ("**" (cond
               ((looking-at "\\*\\(?:[[:word:]]\\|\s\\)")
                (delete-char 1))
               ((looking-back "\\(?:[[:word:]]\\|\s\\)\\*\\{2\\}"
                              (max (- (point) 3) (point-min)))
                (backward-delete-char 1))))
        ((or "_" "*")
         (if (save-match-data
               (and (looking-back "\\(?:[[:space:]]\\|\s\\)\\(?:_\\|\\*\\)"
                                  (max (- (point) 2) (point-min)))
                    (not (looking-at "[[:space:]]\\|\s"))))
             ;; Possible beginning of italics
             (and
              (save-excursion
                (when (and (re-search-forward (regexp-quote (match-string 0)) nil t)
                           (looking-at "[[:space]]\\|\s")
                           (not (looking-back "\\(?:[[:space]]\\|\s\\)\\(?:_\\|\\*\\)"
                                              (max (- (point) 2) (point-min)))))
                  (backward-delete-char 1)
                  (insert "/") t))
              (progn (backward-delete-char 1)
                     (insert "/")))))))
    (buffer-string)))

(defun gptel--playback (buf content-str start-pt)
  "Playback CONTENT-STR in BUF.

Begin at START-PT."
  (let ((handle (gensym "gptel-change-group-handle--"))
        (playback-timer (gensym "gptel--playback-"))
        (content-length (length content-str))
        (idx 0) (pt (make-marker)))
    (setf (symbol-value handle) (prepare-change-group buf))
    (activate-change-group (symbol-value handle))
    (setf (symbol-value playback-timer)
          (run-at-time
          0 0.15
           (lambda ()
             (with-current-buffer buf
               (if (>= content-length idx)
                   (progn
                     (when (= idx 0) (set-marker pt start-pt))
                     (goto-char pt)
                     (insert-before-markers-and-inherit
                      (cl-subseq
                       content-str idx
                       (min content-length (+ idx 16))))
                     (setq idx (+ idx 16)))
                 (when start-pt (goto-char (- start-pt 2)))
                 (and header-line-format
                      (setf (nth 1 header-line-format)
                            (propertize " Ready" 'face 'success))
                      (force-mode-line-update))
                 (accept-change-group (symbol-value handle))
                 (undo-amalgamate-change-group (symbol-value handle))
                 (cancel-timer (symbol-value playback-timer)))))))
    nil))

(provide 'gptel)
;;; gptel.el ends here
