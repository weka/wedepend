SRCS=$(wildcard *.d) $(wildcard libdparse/src/dparse/*.d) $(wildcard libdparse/src/std/experimental/*.d)\
	 $(wildcard libdparse/stdx-allocator/source/stdx/allocator/*.d) \
	 $(wildcard libdparse/stdx-allocator/source/stdx/allocator/building_blocks/*.d)

FLAGS=-g

wedepend: ${SRCS}
	ldc2 ${FLAGS} -d  -of=$@ -I=libdparse/src -I libdparse/stdx-allocator/source -g $^

clean:
	-rm -f wedepend wedepend.o

all: wedepend

.PHONY: clean all
