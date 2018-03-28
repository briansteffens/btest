.PHONY: install uninstall clean

DC=$(shell [ -f dmd ] && dmd || ldc)

bin/btest: src/*.d
	$(DC) -of $@ $^

install:
	ln -s $(CURDIR)/bin/btest /usr/local/bin/btest

uninstall:
	rm /usr/local/bin/btest

clean:
	rm -rf bin
