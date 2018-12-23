;;; keystore-mode.el --- A major mode for displaying JKS keystore
;;; -*- lexical-binding: t; -*-

;; Copyright (C) 2018 Peterpaul Taekele Klein Haneveld

;; Author: Peterpaul Taekele Klein Haneveld <pp.kleinhaneveld@gmail.com>
;; URL: https://github.com/peterpaul/keystore-mode
;; Version: 0.0.1
;; Keywords: tools
;; Package-Requires: ((origami "1.0") (s "1.12.0"))

;; This file is not part of GNU Emacs.

;; MIT License
;;
;; Copyright (C) 2018 Peterpaul Taekele Klein Haneveld
;;
;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to
;; deal in the Software without restriction, including without limitation the
;; rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
;; sell copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
;; FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
;; IN THE SOFTWARE.

;;; Commentary:

;; Elisp wrapper around the java `keytool` command

;;; Code:

(require 's)
(require 'keystore-details-mode)

(defun keystore-get-passphrase-lazy ()
  "Get keystore passphrase and remember for next time."
  (when (not keystore-passphrase)
    (setq keystore-passphrase
          (read-passwd (format "Enter keystore passphrase of '%s': " keystore-filename))))
  keystore-passphrase)

(defun keystore--record-of-size-5 (record)
  (eq 5 (length record)))

(defun keystore--prepare-record (record)
  (let* ((alias (nth 0 record))
         (type (nth 3 record))
         (fingerprint-field (nth 4 record))
         (fingerprint (s-replace ":" ""
                                 (substring fingerprint-field (+ 2 (s-index-of ": " fingerprint-field))))))
    (vector fingerprint type alias)))

(defun keystore--parse-keystore ()
  (let* ((out)
         (entry-index 0)
         (keystore-info (keystore--do-list keystore-filename (keystore-get-passphrase-lazy) ""))
         (keystore-entries
          (split-string (s-replace ", \n" ", " keystore-info)
                        "[\n\r]+" t)))
    (dolist (entry keystore-entries out)
      (let ((record (split-string entry "," nil " \t")))
        (when (keystore--record-of-size-5 record)
          (progn
            (setq entry-index (+ 1 entry-index))
            (setq out (cons (list (number-to-string entry-index) (keystore--prepare-record record))
                            out))))))))

(defun keystore--do-list (keystore-filename keystore-password style)
  (shell-command-to-string
   (format "keytool -list -keystore '%s' -storepass '%s' -storetype '%s' %s"
           keystore-filename
           keystore-password
           (keystore--storetype-from-name keystore-filename)
           style)))

(defun keystore--read-entries-from-keystore ()
  "Recompute tabulated-list-entries."
  (setq tabulated-list-entries (keystore--parse-keystore)))

(defun keystore-toggle-mark-delete (&optional _num)
  "Mark a keystore entry for deletion and move to the next line."
  (interactive "p")
  (if (save-excursion
        (beginning-of-line)
        (eq (char-after) ?\s))
      (tabulated-list-put-tag "D" t)
    (tabulated-list-put-tag " " t)))

(defun keystore--get-alias (id)
  "Retrieve alias for keystore entry with ID."
  (elt (cadr (assoc id tabulated-list-entries)) 2))

(defun keystore-render ()
  "Render buffer."
  (revert-buffer)
  (goto-char (point-min)))

(defun keystore-execute ()
  "Execute marked changes (i.e. deletes)."
  (interactive)
  (let (delete-list cmd keystore-entry)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (setq cmd (char-after))
        (unless (eq cmd ?\s)
          ;; This is the key KEYSTORE-ENTRY.
          (setq keystore-entry (tabulated-list-get-id))
          (cond ((eq cmd ?D)
                 (push keystore-entry delete-list))))
        (forward-line)))
    (when (y-or-n-p (format "Are you sure you want to delete: %s?" (mapcar #'keystore--get-alias delete-list)))
      (dolist (entry-id delete-list)
        (message "Deleting: '%s'" (keystore--get-alias entry-id))
        (keystore--do-delete keystore-filename (keystore-get-passphrase-lazy) (keystore--get-alias entry-id)))
      (keystore-render))))

(defun keystore-list-style (style)
  "Invoke `keytool -list' command with STYLE."
  (when keystore-filename
    (let ((inhibit-read-only t)
          (keystore keystore-filename)
          (storepass (keystore-get-passphrase-lazy))
          (buf (get-buffer-create (format "*Keystore details: %s*" keystore-filename))))
      (with-current-buffer buf
        (keystore-details-mode)
        (origami-mode)
        (erase-buffer)
        (insert (keystore--do-list keystore storepass style))
        (goto-char (point-min))
        (while (re-search-forward "\n\n+" nil t)
          (replace-match "\n\n" nil nil))
        (goto-char (point-min))
        (origami-close-all-nodes buf)
        (switch-to-buffer-other-window buf)
        ))))

(defun keystore-list ()
  "Invoke `keytool -list'."
  (interactive)
  (keystore-list-style ""))

(defun keystore-list-verbose ()
  "Invoke `keytool -list -v'."
  (interactive)
  (keystore-list-style "-v"))

(defun keystore-list-rfc ()
  "Invoke `keytool -list -rfc'."
  (interactive)
  (keystore-list-style "-rfc"))

(defun keystore-importcert-buffer (cert-buffer cert-alias)
  "Import certificate from CERT-BUFFER with alias CERT-ALIAS."
  (interactive "bBuffer with certificate to import: \nsSet alias for certificate: ")
  (let ((keystore-file keystore-filename)
        (keystore-pass (read-passwd (format "Enter keystore passphrase to import certificate from '%s' to '%s': "
                                            cert-buffer
                                            keystore-filename))))
    (save-excursion
      (set-buffer cert-buffer)
      (shell-command-on-region (point-min)
                               (point-max)
                               (format "keytool -importcert -keystore '%s' -storepass '%s' -storetype '%s' -alias '%s' -noprompt"
                                       keystore-file
                                       keystore-pass
                                       (keystore--storetype-from-name keystore-file)
                                       cert-alias))))
  (keystore-render))

(defun keystore-importcert-file (cert-file cert-alias)
  "Import certificate from CERT-FILE with alias CERT-ALIAS."
  (interactive "fFile with certificate to import: \nsSet alias for certificate: ")
  (let ((keystore-file keystore-filename)
        (keystore-pass (read-passwd (format "Enter keystore passphrase to import certificate from '%s' to '%s': "
                                            cert-file
                                            keystore-filename))))
    (shell-command (format "keytool -importcert -keystore '%s' -storepass '%s' -storetype '%s' -alias '%s' -file '%s' -noprompt"
                           keystore-file
                           keystore-pass
                           (keystore--storetype-from-name keystore-file)
                           cert-alias
                           cert-file)))
  (keystore-render))

(defun keystore--do-delete (keystore storepass alias)
  "Delete an entry with ALIAS from KEYSTORE with STOREPASS."
  (shell-command (format "keytool -delete -keystore '%s' -storepass '%s' -storetype '%s' -alias '%s'"
                         keystore
                         storepass
                         (keystore--storetype-from-name keystore)
                         alias)))

(defun keystore-changealias (pos destalias)
  "Move an existing keystore entry from the line at POS to DESTALIAS."
  (interactive "d\nsDestination alias: ")
  (save-excursion
    (let* ((alias (keystore--get-alias (tabulated-list-get-id)))
           (keystore-pass (read-passwd (format "Enter keystore passphrase to change alias '%s' to '%s' in '%s': "
                                               alias
                                               destalias
                                               keystore-filename))))
      (shell-command (format "keytool -changealias -keystore '%s' -storepass '%s' -storetype '%s' -alias '%s' -destalias '%s'"
                             keystore-filename
                             keystore-pass
                             (keystore--storetype-from-name keystore-filename)
                             alias
                             destalias))))
  (keystore-render))

(defun keystore-exportcert (pos)
  "Export the certificate from the line at POS."
  (interactive "d")
  (save-excursion
    (let* ((alias (keystore--get-alias (tabulated-list-get-id)))
           (cert-buffer (get-buffer-create (format "%s.pem" alias))))
      (shell-command (format "keytool -exportcert -keystore '%s' -storepass '%s' -storetype '%s' -alias '%s' -rfc"
                             keystore-filename
                             keystore-passphrase
                             (keystore--storetype-from-name keystore-filename)
                             alias) cert-buffer))))

(defun keystore-importkeystore (srckeystore)
  "Import SRCKEYSTORE into this one."
  (interactive "fKeystore to import: ")
  (let ((srcstorepass (read-passwd (format "Enter keystore passphrase of '%s': " srckeystore)))
        (deststorepass (read-passwd (format "Enter keystore passphrase of '%s': " keystore-filename))))
    (shell-command (format "keytool -importkeystore -srckeystore '%s' -srcstorepass '%s' -srcstoretype '%s' -destkeystore '%s' -deststorepass '%s' -deststoretype '%s' -noprompt"
                           srckeystore
                           srcstorepass
                           (keystore--storetype-from-name srckeystore)
                           keystore-filename
                           deststorepass
                           (keystore--storetype-from-name keystore-filename))))
  (keystore-render))

(defun keystore--blank-string-p (str)
  "Return t if STR contains only whitespace, is empty or is nil."
  (if str
      (string-equal (s-replace-regexp "^[[:space:]]+" "" str) "")
    't))

(defun keystore--dname-prompt-element (keyname prompt &optional previous-result)
  "Prompt the user to enter a dname element value.

Returns a string with the dname element, including the KEYNAME, like \"CN=<value>\",
or nil if the user entered a blank string.

If previous-result is not nil, then the default value is parsed from the previous result.

TODO escape commas in the value, and unescape when parsing."
  (let* ((default-value (and previous-result
                           (nth 1 (s-split "=" previous-result))))
         (actual-prompt (if default-value
                            (format "%s[%s] " prompt default-value)
                          prompt))
         (value (read-string actual-prompt nil nil default-value)))
    (if (keystore--blank-string-p value)
        nil
      (format "%s=%s" keyname value))))

(defun keystore-ask-dname ()
  "Ask the user for dname entries and returns a dname"
  (interactive)
  (let (common-name organization-unit organization-name locality-name state-name country dname dname-elements)
    (while (not (and dname
                 (y-or-n-p (format "Do you accept: '%s'?" dname))))
      (setq dname-elements (list
                            (setq common-name (keystore--dname-prompt-element "CN" "Common Name: " common-name))
                            (setq organization-unit (keystore--dname-prompt-element "OU" "Organization Unit: " organization-unit))
                            (setq organization-name (keystore--dname-prompt-element "O" "Organization Name: " organization-name))
                            (setq locality-name (keystore--dname-prompt-element "L" "Locality Name/City: " locality-name))
                            (setq state-name (keystore--dname-prompt-element "S" "State Name/Province: " state-name))
                            (setq country (keystore--dname-prompt-element "C" "2 Character Country Id: " country))))
      (setq dname-elements (seq-filter 'identity dname-elements))
      (setq dname (mapconcat 'identity dname-elements ", ")))
    dname))

(defun keystore--do-genkeypair (keystore storepass keysize validity alias dname)
  (async-shell-command (format "keytool -genkeypair -keyalg RSA -keysize '%s' -validity '%s' -alias '%s' -keystore '%s' -storepass '%s' -storetype '%s' -dname '%s'"
                               keysize
                               validity
                               alias
                               keystore
                               storepass
                               (keystore--storetype-from-name keystore)
                               dname)))

(defun keystore--prompt-passwd-twice (prompt)
  (let (val1 val2)
    (while (or (not val1)
              (not (string-equal val1 val2)))
      (setq val1 (read-passwd prompt))
      (setq val2 (read-passwd (format "Repeat %s" prompt)))
      (when (not (string-equal val1 val2))
        (when (not (y-or-n-p "The two provided values do not match, retry?"))
          (error "The two provided values do not match"))))
    val1))

(defun keystore-genkeypair (keystore storepass keysize validity alias dname)
  ""
  (interactive
   (list (read-file-name "Keystore File: ")
         (keystore--prompt-passwd-twice "Keystore Passphrase: ")
         (completing-read "Key Size: " '("1024" "2048" "4096" "8192") nil t nil nil "4096")
         (read-number "Validity (Days): " 365)
         (read-string "Alias: ")
         (keystore-ask-dname)))
  (keystore--do-genkeypair keystore storepass keysize validity alias dname))

(defun keystore--jks? (keystore)
  (s-ends-with? ".jks" keystore t))

(defun keystore--pkcs12? (keystore)
  (s-ends-with? ".p12" keystore t))

(setq keystore-default-storetype "JKS")

(defun keystore--storetype-from-name (keystore)
  "Try to determine the keystore type from the KEYSTORE filename extension.

When the type cannot be determined from the extension, this function returns
`keystore-default-storetype'.

Returns \"JKS\" or \"PKCS12\"."
  (pcase keystore
    ((pred keystore--jks?)    "JKS")
    ((pred keystore--pkcs12?) "PKCS12")
    (_                       keystore-default-storetype)))

(defvar keystore-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "d" 'keystore-toggle-mark-delete)
    (define-key map "q" 'kill-this-buffer)
    (define-key map "x" 'keystore-execute)
    (define-key map "c" 'keystore-changealias)
    (define-key map "e" 'keystore-exportcert)
    (define-key map "ib" 'keystore-importcert-buffer)
    (define-key map "if" 'keystore-importcert-file)
    (define-key map "I" 'keystore-importkeystore)
    (define-key map "l" 'keystore-list)
    (define-key map "r" 'keystore-list-rfc)
    (define-key map "v" 'keystore-list-verbose)
    map)
  "Local keymap for `keystore-mode' buffers.")

(define-derived-mode keystore-mode tabulated-list-mode "keystore"
  "\\<keystore-mode-map>
\\{keystore-mode-map}"
  (setq tabulated-list-format
        `[("fingerprint" 64 nil)
          ("type"        20 t)
          ("alias"       64 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "alias" nil))
  (add-hook 'tabulated-list-revert-hook 'keystore--read-entries-from-keystore nil t)
  (tabulated-list-init-header))

(defun list-keystore (file)
  "Open keystore from FILE."
  (interactive "fKeystore File: ")
  (message "Opening keystore: '%s'" file)
  (let ((buf (get-buffer-create file)))
    (with-current-buffer buf
      (keystore-mode)
      (make-local-variable 'keystore-filename)
      (setq keystore-filename file)
      (make-local-variable 'keystore-passphrase)
      (setq keystore-passphrase nil)
      (keystore--read-entries-from-keystore)  
      (tabulated-list-print t)
      (switch-to-buffer file))))

(provide 'keystore-mode)

;;; keystore-mode.el ends here