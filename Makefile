.PHONY: default help build build-doc doc test install install-all install-exe install-doc

##
# Make sure we have 'git' and it works OK.
GIT ?= $(shell which git)
ifeq ($(GIT),)
    $(error 'git' is not installed on this system)
endif
GIT_INSTALL_LIB ?= $(shell git --exec-path)
ifeq ($(GIT_INSTALL_LIB),)
    $(error Cannot determine location of git commands)
endif
MAN1DIR ?= /usr/local/share/man/man1
GITVER ?= $(word 3,$(shell git --version))

##
# Define common variables
CMD := git-hub
TMP := ./tmp

##
# User facing rules start here:
default: help

help:
	@echo 'Makefile rules:'
	@echo ''
	@echo 'build      Build $(CMD)'
	@echo 'test       Run all tests'
	@echo 'install    Install $(CMD)'
	@echo 'uninstall  Uninstall $(CMD)'
	@echo 'clean      Remove build/test files'

build: lib/$(CMD) lib/$(CMD)./json.bash
build-doc doc: $(CMD).1

test: build
	@# prove -e bash test
	@#bash test/repos-create.t
	bash test/all_commands.t

install: uninstall install-exe

install-all: uninstall install-exe install-doc

install-exe: build $(GIT_INSTALL_LIB)/$(CMD)./
	cp lib/$(CMD) $(GIT_INSTALL_LIB)/
	cp lib/$(CMD)./json.bash $(GIT_INSTALL_LIB)/$(CMD)./json.bash

install-doc: build-doc
	install -c -d -m 0755 $(MAN1DIR)
	install -c -m 0644 $(CMD).1 $(MAN1DIR)

uninstall:
	rm -f $(GIT_INSTALL_LIB)/$(CMD)
	rm -fr $(GIT_INSTALL_LIB)/$(CMD).

$(GIT_INSTALL_LIB)/$(CMD)./:
	mkdir -p $@

clean purge:
	rm -fr lib/$(CMD)./json.bash $(CMD).* $(TMP) /tmp/$(CMD)-*

##
# Build rules:
lib/$(CMD)./json.bash: ext/JSON.sh/JSON.sh lib/$(CMD).
	cp $< $@
	chmod -x $@

$(CMD).txt: README.asc
	cp $< $@

%.1: %.xml
	xmlto -m doc/manpage-normal.xsl man $^

%.xml: %.txt
	asciidoc -b docbook -d manpage -f doc/asciidoc.conf \
		-agit_version=$(GITVER) $^

lib/$(CMD).:
	mkdir $@

ext/JSON.sh/JSON.sh:
	git submodule update --init
	if [ ! -f "$@" ]; then \
	    echo "Failed to create '$@'"; \
	    exit 1; \
	fi

##
# Undocumented dev rules
install-link: build uninstall
	ln -s $$PWD/lib/$(CMD) $(GIT_INSTALL_LIB)/$(CMD)
	ln -s $$PWD/lib/$(CMD). $(GIT_INSTALL_LIB)/$(CMD).
