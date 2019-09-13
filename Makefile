SRCS=$(wildcard *.d) $(wildcard libdparse/src/dparse/*.d) $(wildcard libdparse/src/std/experimental/*.d)\
	 $(wildcard libdparse/stdx-allocator/source/stdx/allocator/*.d) \
	 $(wildcard libdparse/stdx-allocator/source/stdx/allocator/building_blocks/*.d)

DCOMPILER=ldc2
FLAGS=-g

wedepend: ${SRCS}
	$(DCOMPILER) ${FLAGS} -d  -of=$@ -I=libdparse/src -I=libdparse/stdx-allocator/source -g $^

test: all
	cd tests && ./test.sh

clean:
	-rm -f wedepend wedepend.o

all: wedepend

.PHONY: clean all test``
