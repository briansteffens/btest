default: src/btest.cr
	mkdir -p bin
	crystal build -o bin/btest src/btest.cr

symlink:
	ln -sf `pwd`/bin/btest /usr/local/bin/btest

install:
	mkdir -p ${DESTDIR}/usr/local/bin
	cp bin/btest ${DESTDIR}/usr/local/bin/btest

uninstall:
	rm -f ${DESTDIR}/usr/local/bin/btest

clean:
	rm -rf bin
