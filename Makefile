PORT      ?= 8000
CONTAINER ?= docker
CI_IMAGE  ?= ubuntu:24.04
SRHT_IMAGE ?= alpine:edge

.PHONY: all clean serve ci srht

all:
	@emacs -Q --script build-site.el
	@rm -Rf docs/setup.html docs/TODO.html

clean:
	@rm -Rf docs/*

# Gera o site do zero e serve docs/ em http://localhost:$(PORT)
serve: clean all
	@echo "Servindo em http://localhost:$(PORT) (Ctrl-C para parar)"
	@python3 -m http.server $(PORT) -d docs

# Gera o site no mesmo ambiente do GitHub Actions (Ubuntu + emacs-nox).
# Use CONTAINER=podman ou CI_IMAGE=alpine:edge se preferir.
ci:
	$(CONTAINER) run --rm -e DEBIAN_FRONTEND=noninteractive -v "$(CURDIR)":/site -w /site $(CI_IMAGE) sh -c \
	  'if command -v apk >/dev/null; then apk add --no-cache emacs-nox make; \
	   else apt-get update -qq && apt-get install -y -qq --no-install-recommends emacs-nox make; fi \
	   && make clean && make'

# Emula o job do builds.sr.ht a partir do .build.yml (sem a task "upload").
# O pacote gerado fica em .srht-out/site.tar.gz e extraído em .srht-out/site/.
srht:
	@mkdir -p .srht-out
	$(CONTAINER) run --rm -v "$(CURDIR)":/src:ro -v "$(CURDIR)/.srht-out":/out $(SRHT_IMAGE) sh /src/scripts/srht-local.sh
	@echo "Para ver: python3 -m http.server $(PORT) -d .srht-out/site"
