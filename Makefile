UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(UNAME_S),Darwin)
  HOST_OS := apple-darwin
else ifeq ($(UNAME_S),Linux)
  HOST_OS := linux-gnu
else
  $(error Unsupported/undetected host OS '$(UNAME_S)' - pass TRIPLE explicitly, e.g. make TRIPLE=x86_64-linux-gnu)
endif

HOST_TRIPLE := $(UNAME_M)-$(HOST_OS)

# Override to cross-compile, e.g.:
#   make TRIPLE=aarch64-linux-gnu
#   make TRIPLE=x86_64-apple-darwin
#   make TRIPLE=arm64-apple-darwin
#   make TRIPLE=x86_64-linux-gnu
TRIPLE ?= $(HOST_TRIPLE)

SRCS=$(wildcard *.d) $(wildcard libdparse/src/dparse/*.d) $(wildcard libdparse/src/std/experimental/*.d)\
	 $(wildcard libdparse/stdx-allocator/source/stdx/allocator/*.d) \
	 $(wildcard libdparse/stdx-allocator/source/stdx/allocator/building_blocks/*.d)

DCOMPILER=ldc2
FLAGS=-g

# Cross-compilation plumbing - only active when TRIPLE != HOST_TRIPLE.
# See README for what LDC_CONF/LINKER/GCC/SYSROOT_FLAGS need to point at.
ifneq ($(TRIPLE),$(HOST_TRIPLE))
FLAGS += -mtriple=$(TRIPLE)
ifneq ($(LDC_CONF),)
FLAGS += -conf=$(LDC_CONF)
endif
ifneq ($(LINKER),)
FLAGS += -linker=$(LINKER)
endif
ifneq ($(GCC),)
FLAGS += -gcc=$(GCC)
endif
ifneq ($(SYSROOT_FLAGS),)
FLAGS += $(SYSROOT_FLAGS)
endif
endif

wedepend: ${SRCS}
	$(DCOMPILER) ${FLAGS} -d  -of=$@ -I=libdparse/src -I=libdparse/stdx-allocator/source -g $^

test: all
ifneq ($(TRIPLE),$(HOST_TRIPLE))
	$(error Cannot run "make test": TRIPLE=$(TRIPLE) is cross-compiled and cannot execute on this $(HOST_TRIPLE) host)
else
	cd tests && ./test.sh
endif

clean:
	-rm -f wedepend wedepend.o

all: wedepend

.PHONY: clean all test
