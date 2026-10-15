all:
	@emacs -Q --script build-site.el
	@rm -Rf docs/setup.html docs/TODO.html

clean:
	@rm -Rf docs/*
