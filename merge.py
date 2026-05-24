import os

with open("opensbi/build/platform/triathlon/firmware/fw_jump.bin", "rb") as f:
    opensbi_bin = f.read()

with open("linux_workspace/linux/arch/riscv/boot/Image", "rb") as f:
    payload_bin = f.read()

pad_len = 0x400000 - len(opensbi_bin)
if pad_len < 0:
    raise ValueError("OpenSBI binary too large!")

combined = opensbi_bin + (b'\0' * pad_len) + payload_bin

with open("fw_combined.bin", "wb") as f:
    f.write(combined)

print("fw_combined.bin generated successfully.")
