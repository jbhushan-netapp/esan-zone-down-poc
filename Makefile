GOOS   ?= linux
GOARCH ?= amd64

# Detect Microsoft Go fork and set required flags
MS_GO := $(shell go version 2>/dev/null | grep -q microsoft && echo 1)
ifeq ($(MS_GO),1)
  export GOEXPERIMENT = ms_nocgo_opensslcrypto
  export CGO_ENABLED = 0
endif

.PHONY: all primary secondary clean

all: primary secondary

primary: primary_main.go
	GOOS=$(GOOS) GOARCH=$(GOARCH) go build -o $@ $<

secondary: secondary_main.go
	GOOS=$(GOOS) GOARCH=$(GOARCH) go build -o $@ $<

clean:
	rm -f primary secondary
