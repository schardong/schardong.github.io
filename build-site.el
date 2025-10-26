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
             :publishing-directory "docs/papers/"
             :publishing-function 'org-html-publish-to-html
             :with-author t
             :with-date nil)

       ;; --- Component 2: The Index Page ---
       (list "index"
             :recursive nil
             :base-directory "org/"
             :base-extension "org"
             :publishing-directory "docs/"
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
             :publishing-directory "docs/css"
             :publishing-function 'org-publish-attachment
             :recursive t)

       ;; --- Component 4: Static resources ---
       (list "res"
             :base-directory "res/"
             :base-extension "css\\|eot\\|svg\\|ttf\\|woff\\|jpg\\|png\\|txt"
             :publishing-directory "docs/res"
             :publishing-function 'org-publish-attachment
             :recursive t)

        (list "schardong.github.io" :components '("css" "papers" "res" "index"))))

;; Generate the site output
(org-publish-all t)
(message "Build complete!")
