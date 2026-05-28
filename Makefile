SHELL := /usr/bin/env bash

.PHONY: validate install extras

validate:
	./scripts/validate.sh

install:
	./setup.sh --full

extras:
	./scripts/post-install-extras.sh
