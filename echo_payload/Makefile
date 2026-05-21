CC = riscv64-unknown-elf-gcc
OBJCOPY = riscv64-unknown-elf-objcopy

all: payload.bin

payload.elf: payload.S link.ld
	$(CC) -nostdlib -T link.ld -o payload.elf payload.S -march=rv32ima -mabi=ilp32

payload.bin: payload.elf
	$(OBJCOPY) -O binary payload.elf payload.bin

clean:
	rm -f payload.elf payload.bin
