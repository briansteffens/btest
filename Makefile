.PHONY: install uninstall clean

bin/btest: src/*.d
	dub

install:
	ln -s $(CURDIR)/bin/btest /usr/local/bin/btest

uninstall:
	rm /usr/local/bin/btest

clean:
	rm -rf bin
