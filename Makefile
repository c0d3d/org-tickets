EMACS ?= emacs

# Source files (exclude the generated autoloads file)
SRCS := $(filter-out org-tickets-autoloads.el, $(wildcard org-tickets*.el))
ELCS := $(SRCS:.el=.elc)

INSTALL_DIR ?= ~/.emacs.d/packages/org-tickets

.PHONY: help test compile lint autoloads build clean install

help:
	@echo "org-tickets makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  test      - Run ERT tests (recompiles changed sources first)"
	@echo "  compile   - Byte-compile source files (warnings are errors)"
	@echo "  lint      - Run checkdoc, and package-lint when it is installed"
	@echo "  autoloads - Generate org-tickets-autoloads.el"
	@echo "  build     - Compile and generate autoloads"
	@echo "  install   - Copy package to INSTALL_DIR (default: ~/.emacs.d/packages/org-tickets)"
	@echo "  clean     - Remove .elc files"

# Per-file .elc rule: recompile only when .el is newer
%.elc: %.el
	$(EMACS) --batch -L . --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile $<

test: $(ELCS)
	@echo "Running tests..."
	$(EMACS) --batch -L . -L test -l org-tickets-test.el -f ert-run-tests-batch-and-exit

compile: $(ELCS)

lint:
	$(EMACS) --batch -L . \
	  --eval "(dolist (f command-line-args-left) (checkdoc-file f))" $(SRCS)
	$(EMACS) --batch -L . --eval "(package-initialize)" \
	  --eval "(if (require 'package-lint nil t) \
	            (progn (setq package-lint-main-file \"org-tickets.el\") \
	                   (package-lint-batch-and-exit)) \
	          (message \"package-lint not installed; skipping\"))" $(SRCS)

autoloads:
	@echo "Generating autoloads..."
	$(EMACS) --batch -l scripts/generate-autoloads.el

build: compile autoloads

install: build
	@echo "Installing to $(INSTALL_DIR)..."
	rm -rf $(INSTALL_DIR)
	mkdir -p $(INSTALL_DIR)
	cp $(SRCS) $(ELCS) org-tickets-autoloads.el $(INSTALL_DIR)/
	@echo "Installed. Add to your ~/.emacs:"
	@echo "  (add-to-list 'load-path \"$(INSTALL_DIR)\")"
	@echo "  (require 'org-tickets)"

clean:
	@echo "Cleaning..."
	rm -f *.elc
