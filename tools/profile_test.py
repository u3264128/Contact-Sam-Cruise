"""Sample where the C64 spends its time on the 144-update joystick route.

Each sample stops the CPU at the first instruction on a random raster line,
so the samples are independent of the 50 Hz game clock. A sample records the
6510 routine and the guest routine that holds the Z80 program counter. Time
in the instruction interpreter is charged to the guest routine.
"""
import argparse
import bisect
import collections
import random
import re
import struct
from pathlib import Path

from monitor import BUILD, labels, vice
from vice_test import VICE, begin

INTERPRETER = re.compile(r"^(op_[0-9a-f]{2}|dispatch|opcode_fetch|execute|fetch|fetch_addr|skip_one|skip_two|jump\w*|"
                         r"install_pc|relative|djnz|push_ax|pop_ax|call|ret_z80|ex_\w+|sp_hl|exx|"
                         r"pack_flags|result_flags|flags_zero|unpack_flags|alu_\w+|save_carry|subtract|"
                         r"borrow\w*|logical(?:_flags)?|cond_[01]_\w+|cpl|scf|ccf|set_c|rlca|rrca|rla|rra|rotated|read_\w+|"
                         r"write_\w+|pixel_address|random_rom|store_\w+|load_\w+|put_a|next_addr|"
                         r"prefix_\w+|ed_\w+|negate|sbc_\w+|block_\w+|single_\w+|copy_register|copy_mode|copy_loop|"
                         r"copy_down|count_copy|cb_\w+|modify_bit|set_bit|native_call)$")

def guest_routines():
    text = (BUILD / "work/csc.skool").read_text(encoding="utf-8")
    entries = []
    label = None
    for line in text.splitlines():
        if line.startswith("@label="):
            label = line[7:].strip()
        elif re.match(r"^[bcgistuw]\d{5}", line):
            entries.append((int(line[1:6]), label or line[1:6]))
            label = None
    entries.sort()
    return entries

def register(m, name, ids={}):
    if not ids:
        names = m.request(0x83, b"\x00")
        offset = 2
        for _ in range(struct.unpack_from("<H", names)[0]):
            size, rid, _, length = names[offset:offset+4]
            ids[names[offset+4:offset+4+length].decode()] = rid
            offset += size + 1
    values = m.request(0x31, b"\x00")
    for offset in range(2, 2+4*struct.unpack_from("<H", values)[0], 4):
        if values[offset+1] == ids[name]:
            return struct.unpack_from("<H", values, offset+2)[0]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vice", default=VICE)
    parser.add_argument("--model", choices=("pal", "ntsc"), default="pal")
    parser.add_argument("--prg", type=Path, help="profile a saved build with its adjacent .lbl file")
    parser.add_argument("--top", type=int, default=25)
    parser.add_argument("--passes", type=int, default=1, help="repeat the left/right route")
    parser.add_argument("--ordinary", action="store_true", help="leave out camera scrolling")
    args = parser.parse_args()
    sym = labels(args.prg.with_suffix(".lbl") if args.prg else None)
    native = sorted((a, n) for n, a in sym.items())
    guests = guest_routines()
    rng = random.Random(1)
    by_native, by_guest, guest_interp = collections.Counter(), collections.Counter(), collections.Counter()
    by_instruction = collections.Counter()
    samples = updates = 0
    lines = 312 if args.model == "pal" else 263
    scrolling = {59406, 59461, 59516, 59575}
    with vice(args.vice, args.model, args.prg) as m:
        begin(m, sym)
        m.stick(8)
        probe = None
        while updates < 144*args.passes:
            if probe is None:
                line = rng.randrange(lines)
                probe = m.checkpoint(0x0080, end=0xffff,
                                     condition=f"(RL == ${line:x}) && (CY < 10)")
            pc = m.resume_to()
            if pc == sym["frame_start"]:
                updates += 1
                m.stick(4 if updates % 144 >= 72 else 8)
                continue
            m.request(0x13, struct.pack("<I", probe))
            probe = None
            zpc = int.from_bytes(m.read(9, 2), "little")
            guest = guests[bisect.bisect_right(guests, (zpc-1, "~"))-1]
            if args.ordinary and guest[0] in scrolling:
                continue
            samples += 1
            name = native[bisect.bisect_right(native, (pc, "~"))-1][1]
            gname = f"{guest[1]} ({guest[0]})"
            by_native[name] += 1
            if INTERPRETER.match(name):
                by_native["[interpreter total]"] += 1
                guest_interp[gname] += 1
                by_instruction[zpc] += 1
            by_guest[gname] += 1
    print(f"{samples} samples over {updates} updates on {args.model}")
    print("\n6510 routines:")
    for name, n in by_native.most_common(args.top):
        print(f"  {n/samples:6.1%}  {name}")
    print("\nGuest routine holding the Z80 PC (interpreted share in brackets):")
    for name, n in by_guest.most_common(args.top):
        print(f"  {n/samples:6.1%}  [{guest_interp[name]/samples:5.1%}]  {name}")
    print("\nInterpreted guest addresses (Z80 PC after the opcode fetch):")
    for zpc, n in by_instruction.most_common(args.top):
        guest = guests[bisect.bisect_right(guests, (zpc-1, "~"))-1]
        print(f"  {n/samples:6.1%}  {zpc:5}  {guest[1]}")

if __name__ == "__main__":
    main()
