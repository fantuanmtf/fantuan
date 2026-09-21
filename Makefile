NASM     := nasm
CC       := gcc
CFLAGS   := -O2 -Wall -Wextra -fno-pie -Iinclude
LDFLAGS  := -no-pie

OBJDIR   := obj
BINDIR   := bin

CORE_ASM := src/core/ftcore.asm src/core/elf.asm
CORE_OBJ := $(CORE_ASM:src/core/%.asm=$(OBJDIR)/%.o)
CLI_OBJ  := $(OBJDIR)/main.o

.PHONY: all clean test

all: $(BINDIR)/fantuan

$(OBJDIR)/%.o: src/core/%.asm | $(OBJDIR)
	$(NASM) -f elf64 $< -o $@

$(OBJDIR)/main.o: src/cli/main.c include/fantuan.h | $(OBJDIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(BINDIR)/fantuan: $(CORE_OBJ) $(CLI_OBJ) | $(BINDIR)
	$(CC) $(LDFLAGS) $^ -o $@

$(OBJDIR) $(BINDIR):
	mkdir -p $@

test: all
	./tests/run_tests.sh

clean:
	rm -rf $(OBJDIR) $(BINDIR)
