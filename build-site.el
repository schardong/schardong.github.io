;; Load the publishing system
(require 'ox-publish)

(setq org-html-validation-link nil            ;; Don't show validation link
      org-html-head-include-scripts nil       ;; Use our own scripts
      org-html-head-include-default-style nil) ;; Use our own styles
      ;;org-html-head "<link rel=\"stylesheet\" href=\"css/stylesheet.css\" />")
      ;;org-html-head "<link rel=\"stylesheet\" href=\"https://cdn.simplecss.org/simple.min.css\" />")

;; Define the publishing project
(setq org-publish-project-alist
      (list
       (list "schardong.github.io"
             :recursive t
             :base-directory "./"
             :publishing-directory "./"
             :publishing-function 'org-html-publish-to-html
             :with-author nil
             :with-creator t
             :with-toc nil
             :section-numbers nil
             :time-stamp-file t)))


;; Generate the site output
(org-publish-all t)

(message "Build complete!")
