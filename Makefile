.PHONY: btest test clean
default: bin/btest

bin/btest: src/btest.cr
	mkdir -p bin
	crystal build -o bin/btest src/btest.cr

install:
	ln -sf $(shell pwd)/bin/btest /usr/local/bin

clean:
	rm -rf bin
