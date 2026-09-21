NASM     := nasm
LD       := ld
NASMFLAG := -f elf64 -i include/
LDFLAGS  := -m elf_x86_64
SRCDIR   := src
INCDIR   := include
OBJDIR   := obj
BINDIR   := bin
ifdef DEBUG
    NASMFLAG += -DDEBUG
endif

.PHONY: all
all: $(BINDIR)/compiler $(BINDIR)/assembler $(BINDIR)/fantuanrun

$(BINDIR)/compiler: $(OBJDIR)/main.o $(OBJDIR)/cpuhdr.o $(OBJDIR)/decode.o $(OBJDIR)/codegen.o $(OBJDIR)/input.o $(OBJDIR)/util.o | $(BINDIR)
	$(LD) $(LDFLAGS) $^ -o $@
	@echo "[OK] compiler"

$(BINDIR)/assembler: $(OBJDIR)/assembler.o $(OBJDIR)/cpuhdr.o $(OBJDIR)/util.o | $(BINDIR)
	$(LD) $(LDFLAGS) $^ -o $@
	@echo "[OK] assembler"

$(BINDIR)/fantuanrun: $(OBJDIR)/interpreter.o $(OBJDIR)/util.o | $(BINDIR)
	$(LD) $(LDFLAGS) $^ -o $@
	@echo "[OK] fantuanrun"

$(OBJDIR)/main.o: $(SRCDIR)/main.asm $(INCDIR)/config.inc $(INCDIR)/ir_defs.inc | $(OBJDIR)
	$(NASM) $(NASMFLAG) $< -o $@
$(OBJDIR)/cpuhdr.o: $(SRCDIR)/cpuhdr.asm $(INCDIR)/config.inc $(INCDIR)/cpu_defs.inc | $(OBJDIR)
	$(NASM) $(NASMFLAG) $< -o $@
$(OBJDIR)/decode.o: $(SRCDIR)/decode.asm $(INCDIR)/config.inc $(INCDIR)/cpu_defs.inc $(INCDIR)/ir_defs.inc | $(OBJDIR)
	$(NASM) $(NASMFLAG) $< -o $@
$(OBJDIR)/codegen.o: $(SRCDIR)/codegen.asm $(INCDIR)/config.inc $(INCDIR)/ir_defs.inc | $(OBJDIR)
	$(NASM) $(NASMFLAG) $< -o $@
$(OBJDIR)/input.o: $(SRCDIR)/input.asm $(INCDIR)/config.inc | $(OBJDIR)
	$(NASM) $(NASMFLAG) $< -o $@
$(OBJDIR)/assembler.o: $(SRCDIR)/assembler.asm $(INCDIR)/config.inc $(INCDIR)/cpu_defs.inc | $(OBJDIR)
	$(NASM) $(NASMFLAG) $< -o $@
$(OBJDIR)/interpreter.o: $(SRCDIR)/interpreter.asm $(INCDIR)/config.inc | $(OBJDIR)
	$(NASM) $(NASMFLAG) $< -o $@
$(OBJDIR)/util.o: $(SRCDIR)/util.asm $(INCDIR)/config.inc | $(OBJDIR)
	$(NASM) $(NASMFLAG) $< -o $@

$(OBJDIR) $(BINDIR):
	mkdir -p $@

.PHONY: clean distclean debug release test
clean:
	rm -rf $(OBJDIR)
distclean: clean
	rm -rf $(BINDIR) output.asm
debug:
	$(MAKE) DEBUG=1
release:
	$(MAKE) clean all
test: $(BINDIR)/compiler $(BINDIR)/fantuanrun
	@echo "=== Compiler ==="
	$(BINDIR)/compiler -c cpu_defs/8bit_example.hdr tests/test_binary.bin
	@echo "=== Interpreter ==="
	printf '\x00\x00' > /tmp/fantuan_test.bin && $(BINDIR)/fantuanrun /tmp/fantuan_test.bin
	@echo "=== All OK ==="
