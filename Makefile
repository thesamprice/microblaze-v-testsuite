# Build a RISC-V cross toolchain for the AMD MicroBlaze V and QEMU from
# upstream sources, run the binutils, GCC and newlib DejaGnu testsuites
# against them, with the execute tests running on QEMU's
# amd-microblaze-v-generic machine, and measure what they cover with tcgcov.
#
#   make                  fetch and build everything
#   make check            run every testsuite
#   make check-gcc-smoke  eight execute tests, a few minutes
#   make coverage         gcc execute + newlib under tcgcov, LCOV + HTML
#   make summary          print the summaries of the last run
#
# The 64-bit core: make TARGET=riscv64-unknown-elf (use another WORK).
# Every component can be replaced by your own; see "Using your own trees"
# in README.md.  Every variable below can be set on the command line.

TARGET       ?= riscv32-unknown-elf
WORK         ?= $(CURDIR)/work
PREFIX       ?= $(WORK)/install
JOBS         ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

# The MicroBlaze V configuration the toolchain's one multilib is built for.
# The defaults match RTEMS's riscv/mbv and riscv/mbv64 BSPs.  QEMU's
# amd-microblaze-v-generic turns off D, so RV32 gets F with ilp32f; RV64
# uses the integer ABI, and medany because RAM is at 0x80000000.
ifneq ($(filter riscv64%,$(TARGET)),)
MBV_ARCH     ?= rv64imac_zicsr_zifencei
MBV_ABI      ?= lp64
MBV_CMODEL   ?= medany
QEMU_SYSTEM  := qemu-system-riscv64
else
MBV_ARCH     ?= rv32imafc_zicsr_zifencei
MBV_ABI      ?= ilp32f
MBV_CMODEL   ?= medlow
QEMU_SYSTEM  := qemu-system-riscv32
endif

BINUTILS_GIT ?= https://sourceware.org/git/binutils-gdb.git
BINUTILS_REF ?= master
GCC_GIT      ?= https://gcc.gnu.org/git/gcc.git
GCC_REF      ?= master
NEWLIB_GIT   ?= https://sourceware.org/git/newlib-cygwin.git
NEWLIB_REF   ?= main
DEJAGNU_GIT  ?= https://git.savannah.gnu.org/git/dejagnu.git
DEJAGNU_REF  ?= master
QEMU_VERSION ?= 10.2.4
QEMU_URL     ?= https://download.qemu.org/qemu-$(QEMU_VERSION).tar.xz
# A local copy of the QEMU tarball to use instead of downloading it.
QEMU_TARBALL ?=

# The DejaGnu board, and what the runs cover.  RUNTESTFLAGS is passed
# through to every testsuite, e.g. RUNTESTFLAGS=-v.
BOARD        ?= microblaze-v-qemu
GCC_TESTS    ?= execute.exp
GCC_SMOKE    ?= execute.exp='20010221-1.c loop-2b.c memcpy-1.c 990208-1.c printf-1.c arith-rand-ll.c pr50865.c pr28982b.c'
NEWLIB_TESTS ?=
RUNTESTFLAGS ?=

MBV_TIMEOUT  ?= 90
NEWLIB_TIMEOUT ?= 300
MBV_RAM_MB   ?= 128
MBV_CPU      ?=

# Where each testsuite's .sum and .log are copied after a run.
RESULTS      ?= $(WORK)/results

SRC   := $(WORK)/src
BUILD := $(WORK)/build
STAMP := $(WORK)/stamps
LOGS  := $(WORK)/logs

# --- your own trees -----------------------------------------------------

own = $(if $(filter command line environment,$(origin $(1))),yes)

OWN_BINUTILS_SRC   := $(call own,BINUTILS_SRC)
OWN_BINUTILS_BUILD := $(call own,BINUTILS_BUILD)
OWN_GCC_SRC        := $(call own,GCC_SRC)
OWN_GCC_BUILD      := $(call own,GCC_BUILD)
OWN_NEWLIB_SRC     := $(call own,NEWLIB_SRC)
OWN_DEJAGNU_SRC    := $(call own,DEJAGNU_SRC)
OWN_QEMU           := $(call own,QEMU)

BINUTILS_SRC   ?= $(SRC)/binutils
BINUTILS_BUILD ?= $(BUILD)/binutils
GCC_SRC        ?= $(SRC)/gcc
GCC_BUILD      ?= $(BUILD)/gcc
NEWLIB_SRC     ?= $(SRC)/newlib
DEJAGNU_SRC    ?= $(SRC)/dejagnu
QEMU           ?= $(PREFIX)/bin/$(QEMU_SYSTEM)

TOOLBIN        ?= $(PREFIX)/bin
TARGET_CC      := $(TOOLBIN)/$(TARGET)-gcc

BREW := $(shell brew --prefix 2>/dev/null)
HOST_LIBS := --with-system-zlib --with-isl=no \
	$(if $(BREW),--with-gmp=$(BREW) --with-mpfr=$(BREW) --with-mpc=$(BREW))

RUNTEST := $(DEJAGNU_SRC)/runtest
BOARD_DIR := $(CURDIR)/board
MBV_START := $(BUILD)/board/mbv-start.o
MBV_STACK_TOP := $(shell printf '0x%x' $$((0x80000000 + $(MBV_RAM_MB) * 1048576)))

# The board's runner is on PATH, and DejaGnu's own directory too, because
# GCC's check-gcc ignores RUNTEST and runs whichever runtest it finds there.
export PATH := $(TOOLBIN):$(DEJAGNU_SRC):$(BOARD_DIR):$(PATH)
export DEJAGNU := $(WORK)/site.exp
export MBV_QEMU := $(QEMU)
export MBV_START
# Recursive, so it is looked up when a recipe runs, after gcc is installed.
export MBV_LIBGLOSS = $(patsubst %/,%,$(dir $(shell test -x $(TARGET_CC) && \
	$(TARGET_CC) -print-file-name=semihost.specs)))
export MBV_TIMEOUT
export MBV_RAM_MB
export MBV_CPU

DEP_BINUTILS := $(if $(OWN_BINUTILS_BUILD),,$(STAMP)/binutils)
DEP_GCC      := $(if $(OWN_GCC_BUILD),,$(STAMP)/gcc)
DEP_DEJAGNU  := $(STAMP)/dejagnu
DEP_QEMU     := $(if $(OWN_QEMU),,$(STAMP)/qemu)

.PHONY: all sources toolchain binutils gcc dejagnu board qemu \
	check check-start check-binutils check-gas check-ld check-gcc \
	check-gcc-smoke check-newlib coverage coverage-smoke coverage-report \
	summary env clean distclean

all: toolchain dejagnu board qemu

toolchain: binutils gcc
binutils: $(DEP_BINUTILS)
gcc: $(DEP_GCC)
dejagnu: $(DEP_DEJAGNU)
board: $(STAMP)/board
qemu: $(DEP_QEMU)

sources: $(if $(OWN_BINUTILS_SRC),,$(STAMP)/patch-binutils) \
	$(if $(OWN_GCC_SRC),,$(STAMP)/patch-gcc) \
	$(if $(OWN_NEWLIB_SRC),,$(STAMP)/patch-newlib) \
	$(if $(OWN_DEJAGNU_SRC),,$(STAMP)/patch-dejagnu)

# --- sources ------------------------------------------------------------

# patch-NAME: patches/NAME/*.patch applied, in order, to the clone; see
# README.md.  Changing the set resets the clone and applies them again.
PATCHES = $(sort $(wildcard $(CURDIR)/patches/$(1)/*.patch))

.SECONDEXPANSION:
$(STAMP)/patch-%: $(STAMP)/src-% $(CURDIR)/patches/% \
		$$(call PATCHES,$$*)
	git -C $(SRC)/$* reset -q --hard
	git -C $(SRC)/$* clean -qfd
	set -e; for p in $(call PATCHES,$*); do \
	  echo "applying $$p"; git -C $(SRC)/$* apply --index "$$p"; done
	touch $@

define clone
	rm -rf $(SRC)/$(1)
	mkdir -p $(SRC) $(STAMP)
	git clone --depth 1 --branch $(3) $(2) $(SRC)/$(1)
	git -C $(SRC)/$(1) log -1 --format='$(1) %H %cd' --date=short > $(SRC)/$(1).rev
endef

$(STAMP)/src-binutils:
	$(call clone,binutils,$(BINUTILS_GIT),$(BINUTILS_REF))
	touch $@

$(STAMP)/src-gcc:
	$(call clone,gcc,$(GCC_GIT),$(GCC_REF))
	touch $@

$(STAMP)/src-newlib:
	rm -rf $(SRC)/newlib
	mkdir -p $(SRC) $(STAMP)
	git clone --depth 1 --branch $(NEWLIB_REF) --filter=blob:none --sparse \
	  $(NEWLIB_GIT) $(SRC)/newlib
	git -C $(SRC)/newlib sparse-checkout set newlib libgloss
	git -C $(SRC)/newlib log -1 --format='newlib %H %cd' --date=short > $(SRC)/newlib.rev
	touch $@

$(STAMP)/src-dejagnu:
	$(call clone,dejagnu,$(DEJAGNU_GIT),$(DEJAGNU_REF))
	touch $@

# Stock DejaGnu, run from its source tree.  The board is not patched into
# it; the site file adds board/ to boards_dir.
$(STAMP)/dejagnu: $(if $(OWN_DEJAGNU_SRC),,$(STAMP)/patch-dejagnu)
	mkdir -p $(STAMP)
	echo 'lappend boards_dir "$(BOARD_DIR)"' > $(WORK)/site.exp
	touch $@

# --- toolchain ----------------------------------------------------------

$(STAMP)/binutils: $(if $(OWN_BINUTILS_SRC),,$(STAMP)/patch-binutils)
	rm -rf $(BINUTILS_BUILD) && mkdir -p $(BINUTILS_BUILD) $(LOGS) $(STAMP)
	cd $(BINUTILS_BUILD) && $(BINUTILS_SRC)/configure \
	  --target=$(TARGET) --prefix=$(PREFIX) \
	  --disable-gdb --disable-gdbserver --disable-sim \
	  --disable-nls --disable-werror --with-system-zlib \
	  > $(LOGS)/binutils-configure.log 2>&1
	$(MAKE) -C $(BINUTILS_BUILD) -j$(JOBS) > $(LOGS)/binutils-build.log 2>&1
	$(MAKE) -C $(BINUTILS_BUILD) install > $(LOGS)/binutils-install.log 2>&1
	touch $@

# newlib and libgloss are symlinked into the GCC tree so that GCC builds
# them.  One multilib, for the MicroBlaze V configuration above.
$(STAMP)/gcc: $(DEP_BINUTILS) $(if $(OWN_GCC_SRC),,$(STAMP)/patch-gcc) \
		$(if $(OWN_NEWLIB_SRC),,$(STAMP)/patch-newlib)
	ln -sfn $(NEWLIB_SRC)/newlib $(GCC_SRC)/newlib
	ln -sfn $(NEWLIB_SRC)/libgloss $(GCC_SRC)/libgloss
	rm -rf $(GCC_BUILD) && mkdir -p $(GCC_BUILD) $(LOGS) $(STAMP)
	cd $(GCC_BUILD) && $(GCC_SRC)/configure \
	  --target=$(TARGET) --prefix=$(PREFIX) \
	  --with-arch=$(MBV_ARCH) --with-abi=$(MBV_ABI) --with-cmodel=$(MBV_CMODEL) \
	  --with-newlib --disable-multilib --disable-threads --disable-shared \
	  --enable-languages=c \
	  --disable-libssp --disable-libquadmath --disable-libgomp \
	  --disable-libatomic --disable-nls --disable-werror \
	  $(HOST_LIBS) \
	  > $(LOGS)/gcc-configure.log 2>&1
	$(MAKE) -C $(GCC_BUILD) -j$(JOBS) > $(LOGS)/gcc-build.log 2>&1
	$(MAKE) -C $(GCC_BUILD) install > $(LOGS)/gcc-install.log 2>&1
	touch $@

# The board's reset stub, built for the target and the RAM size.
$(STAMP)/board: $(DEP_GCC) $(BOARD_DIR)/mbv-start.S
	mkdir -p $(dir $(MBV_START)) $(STAMP)
	$(TARGET_CC) -c -DMBV_STACK_TOP=$(MBV_STACK_TOP) \
	  $(BOARD_DIR)/mbv-start.S -o $(MBV_START)
	echo "$(MBV_RAM_MB)" > $@

# Upstream QEMU from the release tarball, plus any patches/qemu/*.patch.
# The board needs none: amd-microblaze-v-generic is upstream.
$(STAMP)/qemu: $(CURDIR)/patches/qemu $(call PATCHES,qemu)
	mkdir -p $(SRC) $(LOGS) $(STAMP)
	rm -rf $(SRC)/qemu-$(QEMU_VERSION)
	cd $(SRC) && { test -f qemu-$(QEMU_VERSION).tar.xz || \
	  $(if $(QEMU_TARBALL),cp $(QEMU_TARBALL) .,curl -fLO $(QEMU_URL)); } \
	  && tar xf qemu-$(QEMU_VERSION).tar.xz
	set -e; cd $(SRC)/qemu-$(QEMU_VERSION); for p in $(call PATCHES,qemu); do \
	  echo "applying $$p"; GIT_CEILING_DIRECTORIES=$(SRC) git apply "$$p"; done
	rm -rf $(BUILD)/qemu && mkdir -p $(BUILD)/qemu
	cd $(BUILD)/qemu && $(SRC)/qemu-$(QEMU_VERSION)/configure \
	  --prefix=$(PREFIX) \
	  --target-list=riscv32-softmmu,riscv64-softmmu \
	  --enable-plugins \
	  --disable-docs --disable-tools --disable-guest-agent \
	  > $(LOGS)/qemu-configure.log 2>&1
	$(MAKE) -C $(BUILD)/qemu -j$(JOBS) > $(LOGS)/qemu-build.log 2>&1
	$(MAKE) -C $(BUILD)/qemu install > $(LOGS)/qemu-install.log 2>&1
	echo "qemu $(QEMU_VERSION)" > $(SRC)/qemu.rev
	touch $@

# --- testsuites ---------------------------------------------------------

define collect
	mkdir -p $(RESULTS)
	for n in $(2); do \
	  f=$$(find $(1) -name $$n.sum -newer $(STAMP)/check-start | head -1); \
	  if [ -n "$$f" ]; then cp "$$f" "$${f%.sum}.log" $(RESULTS)/; \
	  else echo "no $$n.sum from this run"; fi; done
endef

check: check-binutils check-gcc check-newlib

check-start:
	@mkdir -p $(STAMP) && touch $(STAMP)/check-start

BINUTILS_CHECK = $(MAKE) -C $(BINUTILS_BUILD) -k RUNTEST=$(RUNTEST) \
	CC_FOR_TARGET=$(TARGET_CC) \
	RUNTESTFLAGS="--target_board=$(BOARD) $(RUNTESTFLAGS)"

check-binutils: all check-start
	-$(BINUTILS_CHECK) check-binutils check-gas check-ld
	@$(call collect,$(BINUTILS_BUILD),binutils gas ld)

check-gas: all check-start
	-$(BINUTILS_CHECK) check-gas
	@$(call collect,$(BINUTILS_BUILD),gas)

check-ld: all check-start
	-$(BINUTILS_CHECK) check-ld
	@$(call collect,$(BINUTILS_BUILD),ld)

check-gcc: all check-start
	-$(MAKE) -C $(GCC_BUILD) -k check-gcc RUNTEST=$(RUNTEST) \
	  RUNTESTFLAGS="--target_board=$(BOARD) $(RUNTESTFLAGS) $(GCC_TESTS)"
	@$(call collect,$(GCC_BUILD),gcc)

check-gcc-smoke: GCC_TESTS = $(GCC_SMOKE)
check-gcc-smoke: check-gcc

# newlib's own testsuite, newlib/testsuite, from the newlib GCC built.
# NEWLIB_TESTS picks .exp files, e.g. NEWLIB_TESTS=string.exp.
check-newlib: MBV_TIMEOUT = $(NEWLIB_TIMEOUT)
check-newlib: all check-start
	-$(MAKE) -C $(GCC_BUILD) -k check-target-newlib RUNTEST=$(RUNTEST) \
	  RUNTESTFLAGS="--target_board=$(BOARD) $(RUNTESTFLAGS) $(NEWLIB_TESTS)"
	@$(call collect,$(GCC_BUILD)/$(TARGET)/newlib,newlib)

# --- coverage -----------------------------------------------------------
#
# tcgcov (https://github.com/thesamprice/tcgcov) line and branch coverage
# of the target code the gcc execute and newlib testsuites run: libgcc,
# newlib and libgloss.  coverage/qemu-cov stands in for QEMU and records
# every run.  COV_GCC_TESTS and COV_NEWLIB_TESTS narrow the runs;
# coverage-smoke uses GCC_SMOKE and one newlib .exp.

TCGCOV           ?= $(HOME)/src/tcgcov
COV_DIR          ?= $(WORK)/coverage
COV_GCC_TESTS    ?= $(GCC_TESTS)
COV_NEWLIB_TESTS ?= $(NEWLIB_TESTS)
# Paths are kept relative to COV_ROOT; the test programs themselves are not
# what is being measured.
COV_ROOT         ?= $(SRC)
COV_EXCLUDE      ?= '*/testsuite/**' '*testglue*' 'dejagnu/**'
COV_JOBS         ?= $(JOBS)
COV_PLUGIN        = $(COV_DIR)/plugin/libtcgcov.$(if $(filter Darwin,$(shell uname)),dylib,so)
tcgcov            = PYTHONPATH=$(TCGCOV) python3 -m tcgcov

coverage: all
	rm -rf $(COV_DIR)/raw $(COV_DIR)/report $(COV_DIR)/results
	mkdir -p $(COV_DIR)/plugin $(COV_DIR)/raw
	cp $(TCGCOV)/plugin/*.c $(TCGCOV)/plugin/*.h $(TCGCOV)/plugin/Makefile \
	  $(COV_DIR)/plugin/
	$(MAKE) -s -C $(COV_DIR)/plugin \
	  QEMU_PLUGIN_H=$(dir $(QEMU))../include/qemu-plugin.h
	-MBVCOV_QEMU=$(QEMU) MBVCOV_PLUGIN=$(COV_PLUGIN) MBVCOV_DIR=$(COV_DIR)/raw \
	  $(MAKE) check-gcc check-newlib QEMU=$(CURDIR)/coverage/qemu-cov \
	  RESULTS=$(COV_DIR)/results \
	  GCC_TESTS="$(COV_GCC_TESTS)" NEWLIB_TESTS="$(COV_NEWLIB_TESTS)" \
	  > $(COV_DIR)/check.log 2>&1
	$(MAKE) coverage-report

coverage-smoke: COV_GCC_TESTS = $(GCC_SMOKE)
coverage-smoke: COV_NEWLIB_TESTS = string.exp
coverage-smoke: coverage

coverage-report:
	@echo "$$(ls $(COV_DIR)/raw/*.cov | wc -l | tr -d ' ') runs recorded"
	$(tcgcov) report --raw-dir $(COV_DIR)/raw --out-dir $(COV_DIR)/report \
	  --source-root $(COV_ROOT) $(foreach e,$(COV_EXCLUDE),--exclude $(e)) \
	  --toolchain-prefix $(TOOLBIN)/$(TARGET)- --arch riscv \
	  --jobs $(COV_JOBS)
	# lcov 2 rejects a line that ran while the branch on it did not, which
	# tcgcov reports faithfully (e.g. the setup half of a loop line).
	cd $(COV_ROOT) && genhtml --branch-coverage --quiet \
	  --ignore-errors inconsistent,inconsistent,unsupported,unsupported \
	  -o $(COV_DIR)/report/html $(COV_DIR)/report/lcov/aggregate-riscv.info
	python3 $(CURDIR)/coverage/summary.py $(COV_DIR)/report/lcov/aggregate-riscv.info \
	  | tee $(COV_DIR)/report/summary.txt

summary:
	@for f in $(RESULTS)/*.sum; do \
	  [ -f "$$f" ] || { echo "no results yet"; break; }; \
	  sed -n '/=== .* Summary ===/,$$p' "$$f"; echo; done
	@cat $(SRC)/*.rev 2>/dev/null || true

env:
	@echo "export PATH=$(TOOLBIN):$(DEJAGNU_SRC):$(BOARD_DIR):\$$PATH"
	@echo "export DEJAGNU=$(DEJAGNU)"
	@echo "export MBV_QEMU=$(MBV_QEMU)"
	@echo "export MBV_START=$(MBV_START)"
	@echo "export MBV_LIBGLOSS=$(MBV_LIBGLOSS)"
	@echo "export MBV_TIMEOUT=$(MBV_TIMEOUT)"
	@echo "export MBV_RAM_MB=$(MBV_RAM_MB)"
	@echo "# runtest: $(RUNTEST)"
	@echo "# binutils build: $(BINUTILS_BUILD)"
	@echo "# gcc build:      $(GCC_BUILD)"

clean:
	rm -rf $(BUILD) $(PREFIX) $(RESULTS) $(LOGS) $(COV_DIR)
	rm -f $(STAMP)/binutils $(STAMP)/gcc $(STAMP)/board $(STAMP)/qemu

distclean:
	rm -rf $(WORK)

# --- docker -------------------------------------------------------------
#
# make docker-<target> runs `make <target>` in the image the Dockerfile
# describes.  The work tree lives in a Docker volume, not a bind mount:
# GCC and newlib are not safe to build on the case-insensitive filesystem
# macOS shares into containers.  Results come back to ./results.

DOCKER        ?= docker
DOCKER_IMAGE  ?= microblaze-v-testsuite
DOCKER_VOLUME ?= microblaze-v-testsuite-work
DOCKER_RUN     = $(DOCKER) run --rm -v $(CURDIR):/repo:ro \
	-v $(DOCKER_VOLUME):/work -v $(CURDIR)/results:/results

DOCKER_VARS = $(foreach v,JOBS TARGET MBV_ARCH MBV_ABI MBV_CMODEL \
	BINUTILS_REF GCC_REF NEWLIB_REF DEJAGNU_REF QEMU_VERSION BOARD \
	GCC_TESTS NEWLIB_TESTS RUNTESTFLAGS MBV_TIMEOUT NEWLIB_TIMEOUT MBV_RAM_MB,\
	$(if $(filter command line,$(origin $(v))),'$(v)=$($(v))'))

.PHONY: docker-image docker-shell docker-clean

docker-image:
	$(DOCKER) build -t $(DOCKER_IMAGE) $(CURDIR)

docker-%: docker-image
	mkdir -p $(CURDIR)/results
	$(DOCKER_RUN) $(DOCKER_IMAGE) \
	  make -C /repo WORK=/work RESULTS=/results $(DOCKER_VARS) $*
	$(DOCKER_RUN) $(DOCKER_IMAGE) chown -R $$(id -u):$$(id -g) /results

docker-shell: docker-image
	mkdir -p $(CURDIR)/results
	$(DOCKER_RUN) -it $(DOCKER_IMAGE) bash

docker-clean:
	-$(DOCKER) volume rm $(DOCKER_VOLUME)
