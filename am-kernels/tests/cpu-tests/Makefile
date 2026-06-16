.PHONY: all run gdb clean latest $(ALL)

LOCAL_AM_HOME = $(abspath $(CURDIR)/../../../abstract-machine)

COLOR_RED   = \033[1;31m
COLOR_GREEN = \033[1;32m
COLOR_NONE  = \033[0m

ALL = $(basename $(notdir $(shell find tests/. -name "*.c")))

all: $(addprefix Makefile., $(ALL))
	@echo "test list [$(words $(ALL)) item(s)]:" $(ALL)

$(ALL): %: Makefile.%

Makefile.%: tests/%.c latest
	@printf '[cpu-test] %s ...\n' '$*'
	@printf 'AM_HOME = %s\nNAME = %s\nSRCS = %s\ninclude %s/Makefile\n' "$(LOCAL_AM_HOME)" "$*" "$<" "$(LOCAL_AM_HOME)" > $@
	@if AM_HOME="$(LOCAL_AM_HOME)" make -s -f $@ ARCH=$(ARCH) $(MAKECMDGOALS); then \
		printf '[%14s] $(COLOR_GREEN)PASS$(COLOR_NONE)\n' $*; \
	else \
		printf '[%14s] $(COLOR_RED)***FAIL***$(COLOR_NONE)\n' $*; \
	fi
	-@rm -f Makefile.$$

run: all

gdb: all

clean:
	rm -rf Makefile.* build/

latest:
