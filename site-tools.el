;;; site-tools.el --- Gera rascunhos das páginas de artigos do site  -*- lexical-binding: t; -*-

;; Uso:
;;   (load "~/public_html/schardong.github.io/site-tools.el")
;;   M-x site-new-paper      — pede um DOI e gera org/papers/AAAAMMDD-slug.org
;;   M-x site-sync-orcid     — gera rascunhos para os trabalhos do ORCID sem página
;;   M-x site-import-bibtex  — gera rascunhos a partir das entradas de um .bib
;;
;; Fontes: Crossref (metadados e BibTeX), Semantic Scholar (resumo, quando o
;; Crossref não tem), a API pública do ORCID e arquivos .bib locais.
;; Nada é sobrescrito: trabalhos cujo DOI ou título já aparecem em
;; org/papers/ são ignorados.
;;
;; Requer Emacs 28 ou mais recente.

;;; Code:

(require 'url)
(require 'url-http)
(require 'subr-x)
(require 'seq)
(require 'bibtex)
(require 'ucs-normalize)

(defgroup site-tools nil
  "Ferramentas para o site pessoal em Org."
  :group 'org)

(defcustom site-root
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Raiz do repositório do site (onde ficam org/, res/ e build-site.el)."
  :type 'directory)

(defcustom site-orcid "0000-0003-3927-0852"
  "ORCID iD usado por `site-sync-orcid'."
  :type 'string)

(defcustom site-my-family-names '("Schardong")
  "Sobrenomes destacados em negrito na linha #+AUTHOR."
  :type '(repeat string))

(defcustom site-crossref-mailto nil
  "E-mail opcional enviado ao Crossref (\"polite pool\", respostas mais rápidas).
Deixe nil para não enviar."
  :type '(choice (const nil) string))

(defconst site--index-sections
  '((journal    "** Journal Papers"    "** Artigos em periódicos")
    (conference "** Conference Papers" "** Artigos em conferências"))
  "Tipo do trabalho -> (cabeçalho em index.org, cabeçalho em pt-BR/index.org).")

;; Um trabalho é representado por um plist com as chaves:
;;   :title :authors :venue :date (ANO MÊS DIA) :doi :url :kind (journal,
;;   conference ou nil) :abstract :bibtex

;;;; HTTP e JSON

(defun site--http-get (url &optional accept)
  "Faz GET em URL e devolve o corpo como string UTF-8, ou nil se não for 200."
  (let* ((url-request-extra-headers (when accept `(("Accept" . ,accept))))
         (buf (ignore-errors (url-retrieve-synchronously url t t 30))))
    (when buf
      (unwind-protect
          (with-current-buffer buf
            (when (eql (bound-and-true-p url-http-response-status) 200)
              (goto-char url-http-end-of-headers)
              (decode-coding-string
               (buffer-substring-no-properties (point) (point-max)) 'utf-8)))
        (kill-buffer buf)))))

(defun site--json (url &optional accept)
  "GET em URL e decodifica o JSON (objetos como alist, arrays como listas)."
  (when-let ((body (site--http-get url (or accept "application/json"))))
    (json-parse-string body :object-type 'alist :array-type 'list
                       :null-object nil :false-object nil)))

(defun site--crossref-url (path)
  (concat "https://api.crossref.org/works/" path
          (when site-crossref-mailto
            (concat "?mailto=" (url-hexify-string site-crossref-mailto)))))

;;;; Limpeza de texto

(defun site--clean (s)
  "Remove marcação XML/HTML, decodifica entidades e normaliza espaços em S."
  (when s
    (let ((s (replace-regexp-in-string "<[^>]+>" "" s)))
      (dolist (pair '(("&amp;" . "&") ("&lt;" . "<") ("&gt;" . ">")
                      ("&quot;" . "\"") ("&#39;" . "'") ("&apos;" . "'")))
        (setq s (string-replace (car pair) (cdr pair) s)))
      (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " s)))))

(defconst site--latex-accents
  '(("'" . "́") ("`" . "̀") ("^" . "̂") ("\"" . "̈")
    ("~" . "̃") ("c" . "̧") ("=" . "̄") ("." . "̇"))
  "Acentos LaTeX -> caracteres combinantes Unicode.")

(defun site--latex-to-text (s)
  "Converte acentos e marcação simples de LaTeX/BibTeX em texto Unicode."
  (when s
    (let ((case-fold-search nil))
      (setq s (replace-regexp-in-string "\\\\[ij]\\b" (lambda (m) (substring m 1)) s t t))
      ;; \'{e}, {\'e}, \'e, \c{c}, \~{a} ...
      (setq s (replace-regexp-in-string
               "\\\\\\([`'^\"~=.]\\|c \\|c\\)[ ]*{?\\([[:alpha:]]\\)}?"
               (lambda (m)
                 (let ((acc (string-trim (match-string 1 m)))
                       (ch (match-string 2 m)))
                   (concat ch (or (cdr (assoc acc site--latex-accents)) ""))))
               s t t))
      ;; \textit{x}, \emph{x} ... -> x
      (setq s (replace-regexp-in-string "\\\\[a-zA-Z]+{\\([^{}]*\\)}" "\\1" s))
      (setq s (string-replace "---" "—" s))
      (setq s (string-replace "--" "–" s))
      (setq s (replace-regexp-in-string "[{}]" "" s))
      (setq s (replace-regexp-in-string "~" " " s))
      (setq s (string-replace "\\&" "&" s))
      (site--clean (ucs-normalize-NFC-string s)))))

(defun site--jats-abstract (s)
  "Converte o resumo JATS do Crossref em texto, um parágrafo por <jats:p>."
  (when (and s (not (string-empty-p s)))
    (let* ((s (replace-regexp-in-string
               "<jats:title>\\(?:.\\|\n\\)*?</jats:title>" "" s))
           (paras (split-string s "</jats:p>" t "[ \t\n\r]+")))
      (string-join (delq nil (mapcar (lambda (p)
                                       (let ((c (site--clean p)))
                                         (unless (string-empty-p c) c)))
                                     paras))
                   "\n\n"))))

(defun site--normalize-doi (doi)
  (when (and doi (not (string-empty-p (string-trim doi))))
    (downcase (string-trim
               (replace-regexp-in-string
                "\\`\\(?:https?://\\(?:dx\\.\\)?doi\\.org/\\|doi:\\)" ""
                (string-trim doi))))))

(defun site--title-key (title)
  "Forma normalizada de TITLE para detectar duplicatas."
  (replace-regexp-in-string "[^[:alnum:]]" "" (downcase (or title ""))))

(defun site--bold-if-me (family name)
  (if (member family site-my-family-names) (format "*%s*" name) name))

(defun site--default-slug (title)
  "Sugere um slug: o nome antes de \":\" (FLOWING, RiemStega...) ou as 2 primeiras palavras."
  (let* ((head (car (split-string title ":")))
         (words (split-string (downcase head) "[^[:alnum:]-]+" t))
         (stop '("a" "an" "the" "of" "for" "on" "in" "and" "to" "with" "how")))
    (if (and (string-match-p ":" title) (= (length words) 1))
        (car words)
      (string-join (seq-take (seq-remove (lambda (w) (member w stop)) words) 2) "-"))))

;;;; Metadados: Crossref

(defun site--s2-abstract (doi)
  "Resumo via Semantic Scholar (para DOIs sem resumo no Crossref, como IEEE)."
  (when doi
    (site--clean
     (alist-get 'abstract
                (site--json (format "https://api.semanticscholar.org/graph/v1/paper/DOI:%s?fields=abstract"
                                    doi))))))

(defun site--crossref-bibtex (doi)
  (when-let ((b (site--http-get
                 (site--crossref-url
                  (concat (url-hexify-string doi) "/transform/application/x-bibtex")))))
    (string-trim b)))

(defun site--crossref-date (msg)
  (let ((parts (seq-some (lambda (k)
                           (car (alist-get 'date-parts (alist-get k msg))))
                         '(published-print published-online issued published))))
    (list (or (nth 0 parts) 1970) (or (nth 1 parts) 1) (or (nth 2 parts) 1))))

(defun site--meta-from-crossref (doi)
  "Plist do trabalho com DOI, a partir do Crossref."
  (let* ((doi (site--normalize-doi doi))
         (msg (or (alist-get 'message
                             (site--json (site--crossref-url (url-hexify-string doi))))
                  (user-error "Crossref não encontrou o DOI %s" doi)))
         (date (site--crossref-date msg))
         (container (site--clean (car (alist-get 'container-title msg))))
         (event (site--clean (alist-get 'name (alist-get 'event msg))))
         (volume (alist-get 'volume msg)))
    (list :title (site--clean (car (alist-get 'title msg)))
          :authors (mapconcat
                    (lambda (a)
                      (let ((family (alist-get 'family a)))
                        (site--bold-if-me
                         family (string-trim (or (alist-get 'name a)
                                                 (concat (alist-get 'given a) " " family))))))
                    (alist-get 'author msg) ", ")
          :venue (string-join (delq nil (list (or container event)
                                              (when volume (format "Volume %s" volume))
                                              (number-to-string (car date))))
                              ", ")
          :date date
          :doi doi
          :kind (pcase (alist-get 'type msg)
                  ("journal-article" 'journal)
                  ("proceedings-article" 'conference))
          :abstract (or (site--jats-abstract (alist-get 'abstract msg))
                        (site--s2-abstract doi))
          :bibtex (site--crossref-bibtex doi))))

;;;; Metadados: BibTeX

(defconst site--months
  '(("jan" . 1) ("feb" . 2) ("mar" . 3) ("apr" . 4) ("may" . 5) ("jun" . 6)
    ("jul" . 7) ("aug" . 8) ("sep" . 9) ("oct" . 10) ("nov" . 11) ("dec" . 12)))

(defun site--bib-month (m)
  (cond ((null m) 1)
        ((string-match "\\`[0-9]+\\'" m) (string-to-number m))
        (t (or (cdr (assoc (downcase (substring m 0 (min 3 (length m)))) site--months)) 1))))

(defun site--bib-authors (s)
  "Converte \"Sobrenome, Nome and Nome Sobrenome\" em \"Nome Sobrenome, ...\"."
  (mapconcat
   (lambda (a)
     (let* ((a (string-trim a)))
       (if (string= (downcase a) "others")
           "et al."
         (let* ((parts (split-string a "," t "[ \t\n]+"))
                (family (if (cdr parts) (car parts) (car (last (split-string a)))))
                (name (if (cdr parts)
                          (concat (string-join (cdr parts) " ") " " (car parts))
                        a)))
           (site--bold-if-me family name)))))
   (split-string (site--latex-to-text s) "[ \t\n]+and[ \t\n]+" t)
   ", "))

(defun site--meta-from-bibtex (fields raw)
  "Plist do trabalho a partir de FIELDS (saída de `bibtex-parse-entry') e do texto RAW."
  (cl-flet ((f (name) (let ((v (cdr (assoc-string name fields t))))
                        (when (and v (not (string-empty-p (string-trim v))))
                          (site--latex-to-text v)))))
    (let* ((type (downcase (or (cdr (assoc "=type=" fields)) "")))
           (doi (site--normalize-doi (f "doi")))
           (year (if (f "year") (string-to-number (f "year")) 1970))
           (eprint (f "eprint")))
      (list :title (f "title")
            :authors (site--bib-authors (or (cdr (assoc-string "author" fields t)) ""))
            :venue (string-join
                    (delq nil (list (or (f "journal") (f "booktitle") (f "howpublished")
                                        (when eprint (format "arXiv:%s" eprint))
                                        (f "school") (f "publisher"))
                                    (when (f "volume") (format "Volume %s" (f "volume")))
                                    (f "year")))
                    ", ")
            :date (list year (site--bib-month (f "month")) 1)
            :doi doi
            :url (or (f "url") (when eprint (format "https://arxiv.org/abs/%s" eprint)))
            :kind (pcase type
                    ("article" 'journal)
                    ((or "inproceedings" "conference" "proceedings") 'conference))
            :abstract (or (f "abstract") (site--s2-abstract doi))
            :bibtex (string-trim raw)))))

(defun site--bibtex-entries (file)
  "Lista de plists, uma para cada entrada de FILE (ignora @string, @comment...)."
  (with-temp-buffer
    (insert-file-contents file)
    (delay-mode-hooks (bibtex-mode))
    (let (acc)
      (bibtex-map-entries
       (lambda (_key beg end)
         (save-excursion
           (goto-char beg)
           (let ((fields (bibtex-parse-entry t)))
             (unless (member (downcase (or (cdr (assoc "=type=" fields)) ""))
                             '("string" "preamble" "comment"))
               (push (site--meta-from-bibtex
                      fields (buffer-substring-no-properties beg end))
                     acc))))))
      (nreverse acc))))

;;;; Arquivos

(defun site--papers-dir () (expand-file-name "org/papers/" site-root))

(defun site--existing ()
  "Lista de (ARQUIVO DOI CHAVE-DO-TÍTULO) dos arquivos em org/papers/."
  (mapcar
   (lambda (f)
     (with-temp-buffer
       (insert-file-contents f)
       (list f
             (when (re-search-forward "^#\\+DOI:[ \t]*\\(.+\\)$" nil t)
               (site--normalize-doi (match-string 1)))
             (progn (goto-char (point-min))
                    (when (re-search-forward "^#\\+TITLE:[ \t]*\\(.+\\)$" nil t)
                      (site--title-key (match-string 1)))))))
   (directory-files (site--papers-dir) t "\\.org\\'")))

(defun site--find-existing (meta)
  "Arquivo existente com o mesmo DOI ou título de META, ou nil."
  (let ((doi (plist-get meta :doi))
        (key (site--title-key (plist-get meta :title))))
    (car (seq-find (lambda (e)
                     (or (and doi (equal doi (nth 1 e)))
                         (and (not (string-empty-p key)) (equal key (nth 2 e)))))
                   (site--existing)))))

(defun site--paper-content (meta)
  (pcase-let ((`(,y ,m ,d) (plist-get meta :date)))
    (concat
     (format "#+TITLE: %s\n" (plist-get meta :title))
     (format "#+AUTHOR: %s\n" (plist-get meta :authors))
     (format "#+VENUE: %s\n" (plist-get meta :venue))
     "#+SETUPFILE: ../setup.org\n"
     "#+html_head: <link rel=\"stylesheet\" href=\"../css/tufte.css\" type=\"text/css\" />\n"
     (format "#+EXPORT_DATE: %04d-%02d-%02d\n" y m d)
     (when (plist-get meta :doi) (format "#+DOI: %s\n" (plist-get meta :doi)))
     "\n#+begin_teaser\n# TODO: file:../../res/<imagem>.png\n#+end_teaser\n\n"
     "* Abstract\n"
     (or (plist-get meta :abstract) "TODO: resumo não encontrado.")
     "\n"
     (when (plist-get meta :bibtex)
       (format "\n* BibTeX\n#+begin_src bibtex\n%s\n#+end_src\n" (plist-get meta :bibtex))))))

(defun site--write-paper (meta &optional slug)
  "Grava o rascunho de META em org/papers/ e devolve o caminho do arquivo."
  (when-let ((old (site--find-existing meta)))
    (user-error "Já existe página para \"%s\": %s"
                (plist-get meta :title) (file-name-nondirectory old)))
  (pcase-let* ((`(,y ,m ,d) (plist-get meta :date))
               (slug (or slug (site--default-slug (plist-get meta :title))))
               (file (expand-file-name (format "%04d%02d%02d-%s.org" y m d slug)
                                       (site--papers-dir))))
    (when (file-exists-p file)
      (user-error "Arquivo já existe: %s" file))
    (with-temp-file file
      (insert (site--paper-content meta)))
    file))

;;;; Listas em index.org e pt-BR/index.org

(defun site--renumber-list ()
  "Renumera a lista numerada que começa na linha atual."
  (let ((n 0))
    (while (and (not (eobp)) (looking-at "^\\(?:\\([0-9]+\\)\\. \\|   \\)"))
      (when (match-beginning 1)
        (setq n (1+ n))
        (replace-match (number-to-string n) t t nil 1))
      (forward-line 1))))

(defun site--insert-index-entry (index-file heading meta paper-link paper-label)
  "Insere META como item 1 da lista sob HEADING em INDEX-FILE."
  (let ((link (cond ((plist-get meta :doi) (concat "https://doi.org/" (plist-get meta :doi)))
                    ((plist-get meta :url)))))
    (with-current-buffer (find-file-noselect index-file)
      (save-excursion
        (goto-char (point-min))
        (unless (re-search-forward (concat "^" (regexp-quote heading) "[ \t]*$") nil t)
          (user-error "Seção \"%s\" não encontrada em %s" heading index-file))
        (forward-line 1)
        (let ((start (point)))
          (insert (format "1. %s\n   %s[[[file:%s][Info]]]\n"
                          (plist-get meta :title)
                          (if link (format "[[[%s][%s]]] " link paper-label) "")
                          paper-link))
          (goto-char start)
          (site--renumber-list)))
      (save-buffer))))

(defun site--maybe-insert-in-indexes (file meta)
  "Pergunta a seção e insere META em index.org e pt-BR/index.org."
  (let* ((choices (append (mapcar #'cadr site--index-sections) '("Não inserir")))
         (default (or (cadr (assq (plist-get meta :kind) site--index-sections))
                      "Não inserir"))
         (en (completing-read (format "Seção em index.org para \"%s\": "
                                      (truncate-string-to-width (plist-get meta :title) 50
                                                                nil nil "…"))
                              choices nil t nil nil default)))
    (unless (string= en "Não inserir")
      (let ((pt (nth 2 (seq-find (lambda (s) (string= (cadr s) en)) site--index-sections)))
            (name (file-name-nondirectory file)))
        (site--insert-index-entry (expand-file-name "org/index.org" site-root)
                                  en meta (concat "papers/" name) "Paper link")
        (site--insert-index-entry (expand-file-name "org/pt-BR/index.org" site-root)
                                  pt meta (concat "../papers/" name) "Artigo")))))

(defun site--report (created buffer-name)
  "Mostra os arquivos CREATED num buffer com links."
  (if (null created)
      (message "Nenhum rascunho criado.")
    (with-current-buffer (get-buffer-create buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Rascunhos criados (revise teaser e resumo):\n\n")
        (dolist (f created)
          (insert-text-button (file-name-nondirectory f)
                              'action (lambda (_) (find-file f)) 'follow-link t)
          (insert "\n")))
      (pop-to-buffer (current-buffer)))))

;;;; Comandos

;;;###autoload
(defun site-new-paper (doi)
  "Gera org/papers/AAAAMMDD-slug.org a partir de DOI e abre para edição.
Também oferece inserir o artigo nas listas de index.org e pt-BR/index.org."
  (interactive "sDOI: ")
  (let* ((meta (site--meta-from-crossref doi)))
    (when-let ((old (site--find-existing meta)))
      (user-error "Já existe página para este DOI: %s" (file-name-nondirectory old)))
    (let ((file (site--write-paper
                 meta (read-string "Slug: " (site--default-slug (plist-get meta :title))))))
      (site--maybe-insert-in-indexes file meta)
      (find-file file)
      (message "Rascunho criado. Revise o teaser e o resumo."))))

;;;###autoload
(defun site-import-bibtex (file)
  "Gera rascunhos para as entradas do arquivo BibTeX FILE.
Entradas sem DOI são aceitas; duplicatas são detectadas pelo DOI ou pelo título.
Para cada entrada nova, pergunta se importa, o slug e a seção do index."
  (interactive
   (list (read-file-name "Arquivo BibTeX: " nil
                         (when (derived-mode-p 'bibtex-mode) buffer-file-name) t)))
  (let ((existing (site--existing))
        created)
    (dolist (meta (site--bibtex-entries file))
      (let ((title (plist-get meta :title)))
        (cond
         ((not title)
          (message "Entrada sem título ignorada."))
         ((seq-find (lambda (e)
                      (or (and (plist-get meta :doi) (equal (plist-get meta :doi) (nth 1 e)))
                          (equal (site--title-key title) (nth 2 e))))
                    existing)
          (message "Já tem página: %s" title))
         ((y-or-n-p (format "Importar \"%s\"? " title))
          (condition-case err
              (let ((f (site--write-paper
                        meta (read-string "Slug: " (site--default-slug title)))))
                (push f created)
                (site--maybe-insert-in-indexes f meta))
            (error (message "Falhou para \"%s\": %s" title (error-message-string err))))))))
    (site--report (nreverse created) "*site-import-bibtex*")))

(defun site--orcid-dois ()
  "Lista de (DOI . TÍTULO) dos trabalhos públicos em `site-orcid'."
  (let ((json (site--json (format "https://pub.orcid.org/v3.0/%s/works" site-orcid))))
    (delq nil
          (mapcar
           (lambda (group)
             (let* ((ids (alist-get 'external-id (alist-get 'external-ids group)))
                    (doi (seq-some (lambda (id)
                                     (when (string= (alist-get 'external-id-type id) "doi")
                                       (alist-get 'external-id-value id)))
                                   ids))
                    (summary (car (alist-get 'work-summary group)))
                    (title (alist-get 'value (alist-get 'title (alist-get 'title summary)))))
               (when doi (cons (site--normalize-doi doi) title))))
           (alist-get 'group json)))))

;;;###autoload
(defun site-sync-orcid ()
  "Gera rascunhos para os trabalhos do ORCID que ainda não têm página.
Pergunta um a um e não altera index.org: os novos arquivos são listados no fim."
  (interactive)
  (let* ((existing (site--existing))
         (missing (seq-remove (lambda (w)
                                (seq-find (lambda (e)
                                            (or (equal (car w) (nth 1 e))
                                                (equal (site--title-key (cdr w)) (nth 2 e))))
                                          existing))
                              (site--orcid-dois)))
         created)
    (if (null missing)
        (message "Nenhum trabalho novo no ORCID %s." site-orcid)
      (dolist (w missing)
        (when (y-or-n-p (format "Gerar página para \"%s\" (%s)? " (cdr w) (car w)))
          (condition-case err
              (push (site--write-paper (site--meta-from-crossref (car w))) created)
            (error (message "Falhou para %s: %s" (car w) (error-message-string err))))))
      (site--report (nreverse created) "*site-sync-orcid*"))))

(provide 'site-tools)
;;; site-tools.el ends here
