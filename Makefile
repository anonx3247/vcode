V ?= v
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
DESTDIR ?=
INSTALL ?= install

.PHONY: build install test fmt check

build:
	mkdir -p bin
	$(V) -o bin/vc cmd/vcode

install: build
	$(INSTALL) -d "$(DESTDIR)$(BINDIR)"
	$(INSTALL) -m 0755 bin/vc "$(DESTDIR)$(BINDIR)/vc"

test:
	$(V) test vc

fmt:
	$(V) fmt -w cmd vc

check:
	$(V) -check cmd/vcode
	$(V) test vc
