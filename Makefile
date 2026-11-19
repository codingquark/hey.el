EMACS ?= emacs
ELPA_DIR ?= $(CURDIR)/test/tmp/elpa
PACKAGE_FILE ?= $(CURDIR)/dist/hey-0.4.0.tar

EMACS_BATCH = HEY_ELPA_DIR="$(ELPA_DIR)" \
	MARKDOWN_MODE_DIR="$(MARKDOWN_MODE_DIR)" \
	HEY_PACKAGE_FILE="$(PACKAGE_FILE)" \
	$(EMACS) -Q --batch

.PHONY: bootstrap test compile benchmark lint operation-check read-only-check package install-check check

bootstrap:
	$(EMACS_BATCH) -l "$(CURDIR)/tools/bootstrap.el"

test: bootstrap
	$(EMACS_BATCH) -l "$(CURDIR)/tools/test.el"

compile: bootstrap
	$(EMACS_BATCH) -l "$(CURDIR)/tools/compile.el"

benchmark: compile
	$(EMACS_BATCH) -l "$(CURDIR)/tools/benchmark.el"

lint: bootstrap
	$(EMACS_BATCH) -l "$(CURDIR)/tools/lint.el"

operation-check:
	$(EMACS_BATCH) -l "$(CURDIR)/tools/operation-audit.el"

read-only-check: operation-check

package:
	$(EMACS_BATCH) -l "$(CURDIR)/tools/package.el"

install-check: bootstrap package
	$(EMACS_BATCH) -l "$(CURDIR)/tools/install-check.el"

check: test compile lint operation-check package install-check
