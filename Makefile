# spot — pure-asm presenter spotlight overlay (CHasm)

NASM    ?= nasm
LD      ?= ld
NFLAGS  := -f elf64
LFLAGS  :=

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin

all: spot

spot: spot.o
	$(LD) $(LFLAGS) $< -o $@

spot.o: spot.asm
	$(NASM) $(NFLAGS) $< -o $@

install: spot
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 spot $(DESTDIR)$(BINDIR)/spot

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/spot

clean:
	rm -f spot spot.o

.PHONY: all install uninstall clean
