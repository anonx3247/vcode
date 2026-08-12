V ?= v

.PHONY: build test fmt check

build:
	mkdir -p bin
	$(V) -o bin/vc cmd/vcode

test:
	$(V) test vc

fmt:
	$(V) fmt -w cmd vc

check:
	$(V) -check cmd/vcode
	$(V) test vc
