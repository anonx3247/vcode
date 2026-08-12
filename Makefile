V ?= v

.PHONY: build test fmt check

build:
	mkdir -p bin
	$(V) -o bin/vc cmd/vc

test:
	$(V) test vc

fmt:
	$(V) fmt -w cmd vc

check:
	$(V) -check cmd/vc
	$(V) test vc
