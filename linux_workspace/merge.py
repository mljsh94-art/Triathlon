import shutil
import struct
import subprocess
from pathlib import Path


WORKSPACE = Path(__file__).resolve().parent
REPO_ROOT = WORKSPACE.parent
PMEM_BASE = 0x80000000
PMEM_SIZE = 0x08000000
LINUX_LOAD_ADDR = 0x80400000
LINUX_VISIBLE_MEM_SIZE = 0x04000000
DTB_LOAD_ADDR = 0x83F00000

FW_JUMP_BIN = REPO_ROOT / "opensbi/build/platform/triathlon/firmware/fw_jump.bin"
LINUX_IMAGE = WORKSPACE / "linux/arch/riscv/boot/Image"
DTS_PATH = REPO_ROOT / "opensbi/platform/triathlon/triathlon.dts"
DTB_PATH = WORKSPACE / "build/triathlon.dtb"
OUT_PATH = REPO_ROOT / "fw_combined.bin"


def read_binary(path: Path) -> bytes:
    if not path.exists():
        raise FileNotFoundError(f"Missing required input: {path}")
    return path.read_bytes()


def build_dtb() -> bytes:
    dtc = shutil.which("dtc")
    DTB_PATH.parent.mkdir(parents=True, exist_ok=True)
    if dtc is not None:
        subprocess.run(
            [dtc, "-I", "dts", "-O", "dtb", "-o", str(DTB_PATH), str(DTS_PATH)],
            check=True,
        )
        return read_binary(DTB_PATH)

    dtb = make_builtin_dtb()
    DTB_PATH.write_bytes(dtb)
    return dtb


def make_builtin_dtb() -> bytes:
    # Small FDT equivalent to opensbi/platform/triathlon/triathlon.dts.
    FDT_MAGIC = 0xD00DFEED
    FDT_VERSION = 17
    FDT_LAST_COMP_VERSION = 16
    FDT_BEGIN_NODE = 1
    FDT_END_NODE = 2
    FDT_PROP = 3
    FDT_END = 9

    strings = bytearray()
    string_offsets: dict[str, int] = {}
    struct_block = bytearray()

    def align4(buf: bytearray) -> None:
        while len(buf) % 4:
            buf.append(0)

    def string_offset(name: str) -> int:
        if name not in string_offsets:
            string_offsets[name] = len(strings)
            strings.extend(name.encode("ascii") + b"\0")
        return string_offsets[name]

    def token(value: int) -> None:
        struct_block.extend(struct.pack(">I", value))

    def begin_node(name: str) -> None:
        token(FDT_BEGIN_NODE)
        struct_block.extend(name.encode("ascii") + b"\0")
        align4(struct_block)

    def end_node() -> None:
        token(FDT_END_NODE)

    def prop_raw(name: str, value: bytes) -> None:
        token(FDT_PROP)
        struct_block.extend(struct.pack(">II", len(value), string_offset(name)))
        struct_block.extend(value)
        align4(struct_block)

    def prop_empty(name: str) -> None:
        prop_raw(name, b"")

    def prop_string(name: str, value: str) -> None:
        prop_raw(name, value.encode("ascii") + b"\0")

    def prop_cells(name: str, *cells: int) -> None:
        prop_raw(name, b"".join(struct.pack(">I", cell) for cell in cells))

    begin_node("")
    prop_cells("#address-cells", 1)
    prop_cells("#size-cells", 1)
    prop_string("compatible", "triathlon,npc")
    prop_string("model", "Triathlon NPC")

    begin_node("chosen")
    prop_string("stdout-path", "/soc/uart@a00003f8")
    end_node()

    begin_node("cpus")
    prop_cells("#address-cells", 1)
    prop_cells("#size-cells", 0)
    prop_cells("timebase-frequency", 10000000)

    begin_node("cpu@0")
    prop_string("device_type", "cpu")
    prop_cells("reg", 0)
    prop_string("status", "okay")
    prop_string("compatible", "riscv")
    prop_string("riscv,isa", "rv32imac")
    prop_string("mmu-type", "riscv,sv32")

    begin_node("interrupt-controller")
    prop_cells("#interrupt-cells", 1)
    prop_empty("interrupt-controller")
    prop_string("compatible", "riscv,cpu-intc")
    prop_cells("phandle", 1)
    end_node()

    end_node()
    end_node()

    begin_node("memory@80000000")
    prop_string("device_type", "memory")
    prop_cells("reg", PMEM_BASE, LINUX_VISIBLE_MEM_SIZE)
    end_node()

    begin_node("soc")
    prop_cells("#address-cells", 1)
    prop_cells("#size-cells", 1)
    prop_string("compatible", "simple-bus")
    prop_empty("ranges")

    begin_node("clint@2000000")
    prop_string("compatible", "riscv,clint0")
    prop_cells("interrupts-extended", 1, 3, 1, 7)
    prop_cells("reg", 0x02000000, 0x10000)
    end_node()

    begin_node("plic@c000000")
    prop_string("compatible", "riscv,plic0")
    prop_empty("interrupt-controller")
    prop_cells("#interrupt-cells", 1)
    prop_cells("reg", 0x0C000000, 0x04000000)
    prop_cells("riscv,ndev", 31)
    prop_cells("interrupts-extended", 1, 9)
    prop_cells("phandle", 2)
    end_node()

    begin_node("uart@a00003f8")
    prop_string("compatible", "ns8250")
    prop_cells("reg", 0xA00003F8, 0x8)
    prop_cells("clock-frequency", 10000000)
    prop_cells("current-speed", 115200)
    prop_cells("interrupt-parent", 2)
    prop_cells("interrupts", 1)
    end_node()

    end_node()
    end_node()
    token(FDT_END)

    align4(strings)
    reserve_map = struct.pack(">QQ", 0, 0)
    off_mem_rsvmap = 40
    off_dt_struct = off_mem_rsvmap + len(reserve_map)
    off_dt_strings = off_dt_struct + len(struct_block)
    total_size = off_dt_strings + len(strings)

    header = struct.pack(
        ">IIIIIIIIII",
        FDT_MAGIC,
        total_size,
        off_dt_struct,
        off_dt_strings,
        off_mem_rsvmap,
        FDT_VERSION,
        FDT_LAST_COMP_VERSION,
        0,
        len(strings),
        len(struct_block),
    )
    return header + reserve_map + struct_block + strings


def place_blob(image: bytearray, blob: bytes, addr: int, name: str) -> None:
    offset = addr - PMEM_BASE
    end = offset + len(blob)
    if offset < 0 or end > PMEM_SIZE:
        raise ValueError(f"{name} does not fit in simulated PMEM at 0x{addr:08x}")
    image[offset:end] = blob


opensbi_bin = read_binary(FW_JUMP_BIN)
linux_bin = read_binary(LINUX_IMAGE)
dtb_bin = build_dtb()

opensbi_end = len(opensbi_bin)
linux_offset = LINUX_LOAD_ADDR - PMEM_BASE
linux_end = linux_offset + len(linux_bin)
dtb_offset = DTB_LOAD_ADDR - PMEM_BASE

if opensbi_end > linux_offset:
    raise ValueError("OpenSBI binary overlaps Linux load address")
if linux_end > dtb_offset:
    raise ValueError("Linux Image overlaps DTB load address")

combined = bytearray(dtb_offset + len(dtb_bin))
place_blob(combined, opensbi_bin, PMEM_BASE, "OpenSBI")
place_blob(combined, linux_bin, LINUX_LOAD_ADDR, "Linux Image")
place_blob(combined, dtb_bin, DTB_LOAD_ADDR, "DTB")

OUT_PATH.write_bytes(combined)

print(f"fw_combined.bin generated successfully.")
print(f"  OpenSBI: 0x{PMEM_BASE:08x} ({len(opensbi_bin)} bytes)")
print(f"  Linux:   0x{LINUX_LOAD_ADDR:08x} ({len(linux_bin)} bytes)")
print(f"  DTB:     0x{DTB_LOAD_ADDR:08x} ({len(dtb_bin)} bytes)")
