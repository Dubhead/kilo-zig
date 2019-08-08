# Makefile

all: kilo

kilo: $(wildcard *.zig)
	zig build-exe kilo.zig --library c

clean:
	rm -fr kilo *.o zig-cache

# eof
