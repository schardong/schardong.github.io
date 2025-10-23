;; Load the publishing system
(require 'ox-publish)

(setq org-html-validation-link nil             ;; Don't show validation link
      org-html-head-include-scripts nil        ;; Use our own scripts
      org-html-head-include-default-style nil) ;; Use our own styles

;; Define the publishing project
(setq org-publish-project-alist
      (list
       ;; --- Component 1: The Papers/Posts ---
       (list "papers"
             :recursive nil
             :base-directory "org/papers/"
             :base-extension "org"
             :publishing-directory "public_html/papers/"
             :publishing-function 'org-html-publish-to-html
             :with-author t
             :with-date nil)

       ;; --- Component 2: The Index Page ---
       (list "index"
             :recursive nil
             :base-directory "org/"
             :base-extension "org"
             :publishing-directory "public_html/"
             :publishing-function 'org-html-publish-to-html
             :with-author nil
             :with-creator t
             :with-toc nil
             :section-numbers nil
             :time-stamp-file t)

       ;; --- Component 3: Style files (CSS) ---
       (list "css"
             :base-directory "css/"
             :base-extension "css\\|eot\\|svg\\|ttf\\|woff"
             :publishing-directory "public_html/css"
             :publishing-function 'org-publish-attachment
             :recursive t)

        (list "schardong.github.io" :components '("css" "papers" "index"))))

;; Generate the site output
(org-publish-all t)
(message "Build complete!")
