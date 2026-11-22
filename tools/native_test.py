"""Check native 6510 routines against the original Z80 code, call by call.

The game runs the joystick route in VICE. When a native routine is entered,
the test records the guest registers and RAM, lets the C64 run until the
interpreter resumes, and records the continuation address, registers and RAM.
SkoolKit then runs the original Z80 code from the same state to the same
address. Registers, the S, Z and C flags and guest RAM must agree. Bytes that
the 50 Hz interrupt may change and the stack below SP are left out.
"""
import argparse
import struct

from skoolkit import CSimulator
from skoolkit.simutils import A, B, C, D, E, F, H, L, SP, PC, xB, xC, xD, xE, xH, xL
from build import HOOKS, NATIVE_STORAGE
from monitor import labels, vice
from profile_test import register
from vice_test import FRAME, VICE, begin, original_state

REGS = {"za": 8, "zb": 3, "zc": 2, "zd": 5, "ze": 4, "zh": 7, "zl": 6}
# The older panel and refresh handlers leave several dead registers. Refresh
# composes tiles directly instead of using the guest buffer at $a01e.
KNOWN = dict(panel_check={"C", "D", "L"}, panel_flags={"C", "D"},
             refresh={"D", "E", "RAM", "alternate"})
IGNORE = set(range(23672, 23675)) | {23560, 23611}

def guest(m):
    zp = m.read(0, 32)
    regs = {name: zp[a] for name, a in REGS.items()}
    regs["pc"] = zp[9] | zp[10] << 8
    regs["sp"] = zp[11] | zp[12] << 8
    regs["result"], regs["carry"] = zp[13], zp[14] & 1
    regs["alt"] = zp[15:21]
    return regs

def flags_of(result, carry):
    return (result & 128) | (64 if result == 0 else 0) | carry

def replaced(address):
    """Guest bytes that hold a native hook or 6510 code on the C64."""
    return (any(h <= address < h+2 for h in HOOKS)
            or any(s <= address < s+n for s, n in NATIVE_STORAGE))

def run_original(before, live, sym, start, stop, keep=()):
    image = original_state(live, sym)
    pristine_bytes = {address: image[address] for address in keep}
    for address in keep:
        image[address] = live[address]
    # The port derives a byte from the address when the game reads the ROM
    # outside the character set (see read_rom). Give the reference the same.
    for a in range(0x3d00):
        image[a] = (a >> 8) ^ (a & 255)
    cpu = CSimulator(image, {"SP": before["sp"]})
    r = cpu.registers
    r[A], r[B], r[C], r[D], r[E], r[H], r[L] = (before[n] for n in ("za", "zb", "zc", "zd", "ze", "zh", "zl"))
    r[F] = flags_of(before["result"], before["carry"])
    # The alternate set is stored as C', B', E', D', L', H'.
    alt = before["alt"]
    for index, value in zip((xC, xB, xE, xD, xL, xH), alt):
        r[index] = value
    r[PC] = start
    if start == 61964:
        # This CALL enters 61967 and pushes that same address as its return.
        # Compare after the second actor has taken its turn.
        cpu.run()
    for _ in range(500_000):
        cpu.run()
        if r[PC] == stop:
            break
    for address, value in pristine_bytes.items():
        cpu.memory[address] = value      # only read, so RAM compares as usual
    return cpu

def compare(name, before, after, cpu, image_after, live_after, sym):
    problems = []
    r = cpu.registers
    if r[PC] != after["pc"]:
        return [f"original did not reach {after['pc']} (stopped at {r[PC]})"]
    for reg, index in (("za", A), ("zb", B), ("zc", C), ("zd", D), ("ze", E), ("zh", H), ("zl", L)):
        if r[index] != after[reg]:
            problems.append(f"{reg[1].upper()} {after[reg]} vs {r[index]}")
    if r[SP] != after["sp"]:
        problems.append(f"SP {after['sp']} vs {r[SP]}")
    if [r[i] for i in (xC, xB, xE, xD, xL, xH)] != list(after["alt"]):
        problems.append("alternate registers")
    zx_flags = r[F]
    if bool(zx_flags & 64) != (after["result"] == 0):
        problems.append("Z flag")
    if bool(zx_flags & 1) != bool(after["carry"]):
        problems.append("C flag")
    if bool(zx_flags & 128) != bool(after["result"] & 128) and after["result"] != 0:
        problems.append("S flag")
    lowest = min(after["sp"], r[SP]) - 64
    diffs = [a for a in range(0x4000, 0x10000)
             if image_after[a] != cpu.memory[a] and a not in IGNORE and not lowest <= a < min(after["sp"], r[SP])]
    if diffs:
        problems.append(f"{len(diffs)} RAM bytes, first at {diffs[:6]}")
    return problems

def stop_at(m, address):
    watch = m.checkpoint(address)
    while not (m.resume_to() == address and register(m, "PC") == address):
        pass
    m.request(0x13, struct.pack("<I", watch))

def boundary_cases(m, sym, hooks):
    """Exercise rare native exits and instructions that straddle a guest page."""
    begin(m, sym)
    m.write(sym["frame_call"] + 1, bytes((FRAME & 255,)))
    cases = 0
    vector_table = m.read(sym["op_table"], 512)
    live_register_moves = {op for op, (address,) in enumerate(struct.iter_unpack("<H", vector_table))
                           if address == sym["copy_register"]}

    def check(title, start, stop, hl=0xe601, de=0, bc=0, writes=(), handler=None, carry=1, result=0x81,
              a=0xa5, original_entry=None):
        nonlocal cases
        for address, data in writes:
            m.write(address, bytes(data))
        m.write(61440, b"\xc3" + struct.pack("<H", start))
        m.write(2, struct.pack("<HHHB", bc, de, hl, a))
        m.write(11, struct.pack("<HBB", 0x5d42, result, carry))
        entry = sym[handler or HOOKS[start]]
        watch = m.checkpoint(entry)
        m.resume_to(entry)
        before = guest(m)
        live = m.read(0, 65536)
        m.request(0x13, struct.pack("<I", watch))
        watch = m.checkpoint(sym["opcode_fetch"])
        m.resume_to(sym["opcode_fetch"])
        after = guest(m)
        assert after["pc"] == stop, (title, after["pc"], stop)
        end = m.read(0, 65536)
        cpu = run_original(before, live, sym, original_entry if original_entry is not None else start, stop)
        problems = compare(title, before, after, cpu, original_state(end, sym), end, sym)
        assert not problems, (title, problems)
        m.request(0x13, struct.pack("<I", watch))
        if stop != FRAME:
            saved = m.read(stop, 3)
            m.write(stop, b"\xc3" + struct.pack("<H", FRAME))
        m.resume_to(sym["frame_start"])
        if stop != FRAME:
            m.write(stop, saved)
        cases += 1

    check("mirrored sprite bytes", 64582, FRAME, writes=((0x7e00, bytes(256)),))
    for x in (0, 6, 7, 46, 47, 158, 159, 214, 215, 247, 254):
        check(f"door flags at {x}", 62099, FRAME, writes=((0xe601, (x,)),))
    for x, actor, indoor, direction, descriptor, flags, stop in (
            (40, 230, True, 64, 65, 0, FRAME), (40, 230, True, 16, 65, 0, FRAME),
            (40, 215, False, 64, 65, 0, FRAME), (40, 230, False, 64, 64, 0, FRAME),
            (40, 230, False, 64, 65, 0, FRAME), (40, 230, False, 64, 65, 8, 31289),
            (160, 230, False, 64, 65, 8, FRAME)):
        check("building entrance", 30396, stop, hl=actor*256+4, bc=descriptor*256,
              writes=((actor*256+1, (x, 15, 0, 1)), (32752, (flags,)*10)),
              a=direction, result=0 if indoor else 1)
    for origin in (0, 8, 48, 56, 248):
        for start, stop in ((61838, 61879), (61882, 61920)):
            check(f"rotate actors at {origin}", start, stop, writes=((32766, (origin,)),))
    for state in (0, 7, 135):
        check(f"stand from pose {state}", 60293, FRAME,
              writes=((0xe600, (state, 64, 15)), (32766, (64, 8))))
    for x, direction in ((63, 128), (64, 64), (95, 32), (220, 4)):
        check(f"stride at {x}", 60423, FRAME, de=direction*256,
              writes=((0xe600, (0, x, 15)), (32766, (64, 8))))
    for start, stop in ((59406, 59418), (59461, 59473), (59516, 59528), (59575, 59587)):
        check("camera entry", start, stop, bc=0x52a4)

    for message, target in ((b"\0", 0x5080), (b"\x80", 0x5080),
                            (b"A\xff 0\0", 0x50fe), (b" \x7f\x80", 0x4880)):
        check("print message", 28160, FRAME, hl=0x64fe, de=target, bc=0x1234,
              writes=((0x64fe, message),))
    for code in range(32, 128, 16):
        check(f"print glyphs {code} to {code+15}", 28160, FRAME, hl=0x64fe, de=0x5080,
              writes=((0x64fe, bytes(range(code, code+16)) + b"\0"),))
    for columns in ((31, 32, 72, 73, 74, 75, 80, 81), (105, 106, 111, 112, 140, 141, 153, 154)):
        writes = ((0x7ffe, (0, 0)), (0xb800, (1,)), (0xbf01, (0,)), (0x7f10, bytes(24)))
        writes += tuple((0xb881+256*x, (index,)) for x, index in enumerate(columns))
        check("window flags at shared tile boundaries", 62368, FRAME, hl=0xb800, writes=writes)
    for code, target in ((1, 0x5080), (65, 0x5180), (65, 0x5880)):
        check("print with mapped ROM or destination", 28160, 28162, hl=0x64fe, de=target,
              writes=((0x64fe, (code, 0)),))
    for token, stop in ((0, 28528), (12, 28496), (96, 28534), (97, 28604), (180, 28496)):
        check("message text and token", 28512, stop, hl=0x7f81, bc=0x1279,
              writes=((0x7f81, (2, 0xfe, 0x64)), (0x64fe, b"A BC" + bytes((token,))),
                      (0x13, (0x5f, 0x7f))))
    check("word overflow on a space", 28512, 28580, hl=0x7f81,
          writes=((0x7f81, (2, 0xfe, 0x64)), (0x64fe, b" "), (0x13, (0x7f, 0x7f))))
    check("message buffer in another page", 28512, 28514, hl=0x7f81, writes=((0x13, (0x5f, 0x65)),))
    for x, y in ((9, 15), (10, 15), (19, 15), (20, 15), (15, 9), (15, 20)):
        check("region edges across a page", 29578, FRAME, hl=0x64fe, de=0xe600,
              writes=((0x64fe, (10, 20, 10, 20)), (0xe601, (x, y))))
    for left, x, landed in ((0, 220, 0), (8, 8, 1), (24, 12, 0), (24, 49, 0),
                            (24, 73, 0), (224, 250, 0), (24, 49, 1)):
        for entry in (25420, 25434):
            check("banknote range and restart", entry, 25480, hl=0xe455,
                  writes=((32745, (0,)), (32766, (left, 20)),
                          (0xe400, (62, x, 34)), (0xe40a, (landed,))))
    check("release banknote actor for the hook", 25420, FRAME, hl=0xe555,
          writes=((32745, (64,)), (0xe500, (190, 12, 34))))
    check("bind primary command", 63409, FRAME, hl=0xdeff, de=0x5b70)
    for old, draw, x, y in ((62, 0, 7, 34), (62, 255, 6, 35), (190, 8, 164, 34),
                            (70, 128, 198, 35), (198, 136, 199, 35), (62, 8, 255, 31)):
        # The random draw is in A and the previous pose is on the guest stack.
        prefix = bytes((0x3e, old, 0xf5, 0x3e, draw, 0xc3)) + struct.pack("<H", 25484)
        stop = 25480 if old == (draw & 136)+62 else FRAME
        check("draw the banknote pose and drift", 0x5b80, stop, hl=0xe400, de=y*256+x,
              handler="banknote_pose", original_entry=25484, writes=((0x5b80, prefix),))
    for previous, now in ((15, 16), (255, 0)):
        check("frame clock", 61552, FRAME, writes=((32712, (previous,)), (23672, (now,))))
    target = 0x5b70

    def actor_record(page, fields):
        record = bytearray(29)
        record[23:25] = (0x5b60).to_bytes(2, "little")
        for field, value in fields.items():
            record[field] = value
        return ((page << 8, record), (0x5b60, target.to_bytes(2, "little")))

    for entry, field in ((62080, 9), (62084, 15), (62088, 19)):
        check("terminate actor command", entry, target,
              writes=((32763, (222,)),) + actor_record(222, {field: 37}))
    for page in (215, 222):
        for fields in ({}, {3: 16, 22: 27, 25: 0x60, 26: 0x5b},
                       {8: 0x70, 9: 0x5b}, {14: 0x70, 15: 0x5b, 9: 37}):
            check("continue actor command", 62029, target, hl=page*256+28, bc=0x1234,
                  writes=actor_record(page, fields))
    for previous, fields, stop in ((229, {3: 64}, FRAME), (221, {}, target),
                                   (221, {3: 128, 18: 0x70, 19: 0x5b}, target),
                                   (221, {3: 128, 27: 0x70, 28: 0x5b}, target)):
        page = 215 if previous == 229 else previous+1
        check("schedule next actor", 61967, stop, writes=actor_record(page, fields) +
              ((32763, (previous,)), (32692, (0,))))
    for x, y, indoor, fuse, timer in ((255, 31, 0, 162, 1), (255, 3, 1, 162, 0),
                                     (63, 0, 1, 162, 1), (64, 1, 1, 163, 255),
                                     (127, 16, 1, 164, 1), (128, 17, 1, 165, 1),
                                     (15, 9, 1, 166, 1), (16, 11, 1, 167, 1)):
        fields = {1: x, 2: y, 3: 128, 4: indoor}
        writes = actor_record(222, fields) + ((0xffc0+(((x+1) & 255) >> 3), (fuse,)),
                                               (0x7f00+fuse, (timer,)))
        check("blown fuse and roof height", 29004, FRAME, hl=0xde54, de=0x1234, writes=writes)
        roof = 0 if fuse < 164 else 16 if fuse < 166 else 10
        stop = FRAME if indoor and timer and y > roof else target
        check("schedule actor during a blackout", 61967, stop,
              writes=writes + ((32763, (221,)), (32692, (1,))))
    check("second actor pushes the third actor's turn", 61964, target,
          writes=actor_record(222, {3: 128}) + ((32763, (221,)), (32692, (0,))))
    check("second actor skips and returns to the third", 61964, 61967,
          writes=actor_record(222, {3: 64}) + ((32763, (221,)), (32692, (0,))))

    for entry in (25618, 25672):
        writes = []
        for plane in range(16):
            page = (0xc7+plane) << 8
            writes.append((page+238, bytes((29*tile + 19*plane + 7*tile*plane) & 255 for tile in range(10))))
            for tile in (2, 3, 4, 6, 7, 170):
                writes.append((page+tile, ((17*tile + 73*plane) & 255,)))
            for tile in (181, 189, 197, 205):
                writes.append((page+0x1000+tile, ((47*tile + 11*plane) & 255,)))
        check("Sam's roll graphics and masks", entry, FRAME, writes=writes, carry=0)
    for number in range(8):
        check(f"disguise {number} and portrait", 63852, FRAME, bc=0x2345, de=0x6789,
              writes=((32713, (number,)),))
    # Fetch a direct token at the last byte of a page and a prefixed token
    # whose index is on the next page. Both routines return on the guest stack.
    for entry in (62099, 25672):
        token = m.read(entry, 2)
        token = token if token[0] == 0xdd else token[:1]
        check("native token across a page", 0x64ff, FRAME, handler=HOOKS[entry], original_entry=entry,
              writes=((0x64ff, token),))
    for entry in (63328, 63331):
        for knock, step, count, stop in ((128, 0, 5, 62080), (0, 0, 5, 63373),
                                        (0, 255, 1, 63360), (0, 255, 2, 63373)):
            check("door duty", entry, stop, hl=0xde44, bc=31319,
                  writes=((0xde0b, (172, step, count)), (0x7fac, (knock,))))
    check("install actor subcommand", 63403, 63209, hl=0xde44, bc=63209)
    for entry in (63128, 63130):
        for pose, stop in ((0, FRAME), (1, 60506)):
            check("midstride", entry, stop, hl=0xde00, writes=((0xde00, (pose,)),))
    phones = ((0x64fe, (1, 0, 0, 35, 0, 0, 254)),)
    for number in (1, 35, 17, 254):
        check(f"phone {number}", hooks["phone_search"], FRAME, hl=0x64fe, de=number, writes=phones)
    check("second phone list terminator", hooks["phone_search"], FRAME, hl=0x6504,
          writes=((0x6504, (255,)),))
    for y, mask in ((7, 2), (7, 4), (8, 2), (33, 2)):
        check(f"fixture y={y} mask={mask}", hooks["fixture_at"], FRAME, bc=mask*256+24,
              writes=((0xe602, (y,)), (0xf503, (2,)), (0xf583, (2,))))
    for x1, y1, x2, y2, stop in ((7, 9, 0, 0, 26120), (32, 9, 31, 6, 26120),
                                  (255, 2, 4, 0, FRAME)):
        check("bullets", hooks["move_bullets"], stop, writes=((32743, (1,)), (32766, (64, 12)),
              (32704, (64, x1, y1, 0, 64, x2, y2, 0))))
    # Windows left, right, above and below the view, and inside it with and
    # without bit 6 of L. Camera at x=64 (column block 8), y=8.
    for h, l in ((186, 8), (186, 75), (186, 12), (186, 7), (189, 9), (185, 9), (187, 10)):
        check(f"window SRB {h}/{l}", 62368, FRAME, hl=h*256+l, writes=((32766, (64, 8)),))
    # LOCID: above the sidewalk, the sidewalk and road edges, building
    # floors and stairs indoors and outdoors, at both ends of the map.
    # No region record ends above x=254: the original search would not end.
    places = [(x, y, z) for x in (0, 6, 7, 14, 15, 60, 163, 164, 198, 199, 254)
              for y, z in ((20, 2), (31, 2), (33, 2), (34, 2), (35, 2))]
    places += [(255, 34, 2), (255, 35, 2)]
    places += [(x, y, 1) for x in (3, 40, 90, 120, 150, 200, 250) for y in (4, 7, 10, 13, 19, 22, 25, 31, 33)]
    for x, y, z in places:
        check(f"LOCID {x},{y},{z}", 60726, FRAME, hl=0xde09, bc=0x1234,
              writes=((0xde01, (x, y, 0, z)),))
    for x, y, z in ((60, 25, 1), (60, 20, 2), (100, 31, 4), (10, 34, 2)):
        check(f"LOCID at 60734 {x},{y},{z}", 60734, FRAME, hl=0xde77, bc=z, de=y*256+x)
        check(f"LOCID at 60743 {x},{y},{z}", 60743, FRAME, hl=0xde77, bc=z, de=y*256+x)
    # Use ordinary guest RAM on both sides of the page boundary.
    for offset, base in ((0, 0x7900), (255, 0x7900), (3, 0x79ff)):
        check(f"GETPARAMS {offset}", 61809, FRAME, hl=0xde10,
              writes=((0xde16, (offset,) + tuple(base.to_bytes(2, "little"))),))
    for number in (0, 9, 10, 99, 100, 1000, 9999, 10000, 40960, 65535):
        check(f"print number {number}", 28186, FRAME, hl=number, de=0x50c0)
    for dst in range(6):
        for src in range(6):
            opcode = 0x40 + 8*dst + src
            if dst != src and opcode in live_register_moves:
                check(f"register move {opcode:02x}", 0x64ff, 0x6500, bc=0x1203, de=0x4567,
                      hl=0x6789, writes=((0x64ff, (opcode,)),), handler="copy_register")
    for opcode in (0x20, 0x28, 0x30, 0x38):  # JR NZ, Z, NC, C
        for value in (14, 15, 16):
            record = (0, 10, 1, 0x10, 0x67, opcode, 15, 1, 0x11, 0x67, 99, 255)
            check(f"event {opcode:02x} with {value}", hooks["event_scan"], FRAME, hl=0x6700,
                  writes=((0x6700, record), (0x6710, (value, 0)), (29964, struct.pack("<H", 30051))))
            # Enter through EVENTS as the main loop does. The inactive entry
            # puts the next flag at offset 255. A failed condition must step
            # over the 8-bit offset limit and find the end marker.
            check(f"indexed event {opcode:02x} with {value}", hooks["events"], FRAME,
                  writes=((24544, (1, 254)), (24544+255, record), (0x6710, (value, 0))))
    record = (0, 14, 2, 0x10, 0x67, 0x28, 1, 0x11, 0x67, 0x28, 2,
              1, 0x12, 0x67, 99, 255)
    for second in (2, 3):
        check("second condition after indexed match", hooks["events"], FRAME,
              writes=((24544, record), (0x6710, (1, second, 0))))
    check("indexed event reading the guest font", hooks["events"], FRAME,
          writes=((24544, (0, 10, 1, 0, 0x3d, 0x28, 0, 1, 0x12, 0x67, 99, 255)),))
    for instruction, start, stop, handler in (
            ("21 34 12", 0x64fe, 0x6501, "op_21"), ("3e a5", 0x64fe, 0x6500, "op_3e"),
            ("c6 82", 0x64ff, 0x6501, "op_c6"), ("18 fc", 0x64ff, 0x64fd, "relative"),
            ("cb 07", 0x64fe, 0x6500, "prefix_cb"), ("ed 44", 0x64ff, 0x6501, "prefix_ed"),
            ("cd 10 65", 0x64fe, 0x6510, "call"), ("c4 10 65", 0x64ff, 0x6510, "call")):
        check(instruction, start, stop, writes=((start, bytes.fromhex(instruction)),), handler=handler)
    # Block copies: page crossings in either pointer, overlap in both
    # directions, BC=1 and 256, a source in the ROM and a mapped target.
    # Keep clear of the reclaimed areas, which hold live 6510 code.
    for opcode, hl, de, bc in ((0xb0, 0x79f0, 0x6900, 40), (0xb0, 0x6900, 0x68f8, 20),
                               (0xb0, 0x6900, 0x6901, 30), (0xb0, 0x6900, 0x6a00, 1),
                               (0xb0, 0x6900, 0x6b00, 256), (0xb0, 0x3d00, 0x6900, 768),
                               (0xb0, 0x6900, 0x5af8, 16), (0xb8, 0x6910, 0x6920, 40),
                               (0xb8, 0x6920, 0x6910, 40), (0xb8, 0x6905, 0x6a08, 12),
                               (0xb8, 0x6900, 0x6a00, 1), (0xb8, 0xfe03, 0x6a03, 8)):
        first = de if opcode == 0xb0 else de-bc+1
        assert all(first+bc <= s or s+n <= first for s, n in NATIVE_STORAGE)
        check(f"ED {opcode:02x} {hl:04x}->{de:04x} x{bc}", 0x79fe, 0x7a00, hl=hl, de=de, bc=bc,
              writes=((0x79f0, bytes(range(1, 0x91))), (0x79fe, (0xed, opcode))),
              handler="prefix_ed")
    # A is $a5. Exercise zero, negative results and borrow at equality,
    # including a guest instruction whose operand starts on the next page.
    # The build leaves out handlers for opcodes the game never runs.
    for opcode in (op for op in (0xd6, 0xde, 0xfe) if f"op_{op:02x}" in sym):  # SUB, SBC A, CP
        for value in (0x25, 0xa5, 0xa6):
            for carry in ((0, 1) if opcode == 0xde else (1,)):
                check(f"{opcode:02x} {value:02x} carry={carry}", 0x64ff, 0x6501,
                      writes=((0x64ff, (opcode, value)),), handler=f"op_{opcode:02x}", carry=carry)
    for carry in (0, 1):
        check("SBC HL,BC across the low-byte borrow", 0x64ff, 0x6501,
              hl=0x8100, bc=0x8100, writes=((0x64ff, (0xed, 0x42)),),
              handler="prefix_ed", carry=carry)
    print(f"{cases} boundary cases matched guest registers, flags, stack, continuation and RAM")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vice", default=VICE)
    parser.add_argument("--model", choices=("pal", "ntsc"), default="pal")
    parser.add_argument("--calls", type=int, default=20, help="calls to check per routine")
    parser.add_argument("--updates", type=int, default=288)
    parser.add_argument("--demo", action="store_true", help="let the original demo move Sam")
    parser.add_argument("--boundaries", action="store_true", help="test rare exits and page boundaries")
    parser.add_argument("names", nargs="*", help="native hook names (default: all)")
    args = parser.parse_args()
    sym = labels()
    hooks = {name: addr for addr, name in HOOKS.items()}
    if args.boundaries:
        with vice(args.vice, args.model) as m:
            boundary_cases(m, sym, hooks)
        return
    names = args.names or sorted(set(hooks) - {"frame_start", "left_step", "right_step", "up_step",
                                              "down_step", "cutscene", "effect", "footstep",
                                              "shot_sound", "banknote_sound", "reveal_sound", "main_clock"})
    entries = {sym[n]: n for n in names}
    counts = dict.fromkeys(names, 0)
    outcomes = {name: set() for name in names}
    failures = {}
    with vice(args.vice, args.model) as m:
        begin(m, sym, args.demo)
        points = {pc: m.checkpoint(pc) for pc in entries}
        updates = 0
        if not args.demo:
            m.stick(8)
        while updates < args.updates and points:
            pc = m.resume_to()
            if pc == sym["frame_start"]:
                updates += 1
                if not args.demo:
                    m.stick(4 if updates % 144 >= 72 else 8)
                continue
            name = entries.get(pc)
            if name is None or counts[name] >= args.calls:
                continue
            before = guest(m)
            live = m.read(0, 65536)
            # One native routine may enter another, for example panel_check
            # and panel_flags. Run on to the interpreter.
            if register(m, "PC") != pc:
                continue                # a stale stop event, not a live entry
            entry = (before["pc"] - 1) & 0xffff
            if HOOKS.get(entry) != name:
                entry = (entry - 1) & 0xffff
                if live[entry] != 0xdd or HOOKS.get(entry) != name:
                    continue            # entered from other native code
            keep = ()
            if name == "get_random":
                # The CIA can tick between the entry checkpoint and the XOR.
                # Give the Z80 oracle the exact FRAMES byte the 6510 reads.
                frame_read = sym["random_frame_read"]
                stop_at(m, frame_read)
                live = bytearray(live)
                live[23672] = m.read(23672, 1)[0]
                # The seed walks all of memory. Where the port keeps a hook
                # or 6510 code, both machines must XOR the same byte.
                seed = (int.from_bytes(live[32734:32736], "little") + 257) & 0xffff
                keep = (seed,) if replaced(seed) else ()
            panel_call = name in ("frame_panel", "frame_icons")
            if panel_call:
                # These hooks push the original return addresses and jump
                # straight into panel_check. Verify the actual handoff in full.
                stop_at(m, sym["panel_check"])
                handoff = guest(m)
                handoff["pc"] = hooks["panel_check"]  # direct native jump bypasses guest fetch
                at_panel = m.read(0, 65536)
                reference = run_original(before, live, sym, hooks[name], handoff["pc"])
                issues = compare(name, before, handoff, reference, original_state(at_panel, sym), at_panel, sym)
                assert not issues, (name, "panel_check entry", issues)
            stop_at(m, sym["opcode_fetch"])
            after = guest(m)
            live_after = m.read(0, 65536)
            cpu = run_original(before, live, sym, entry, after["pc"], keep)
            problems = compare(name, before, after, cpu, original_state(live_after, sym), live_after, sym)
            counts[name] += 1
            outcomes[name].add((after["pc"], after["za"]))
            if problems:
                # Only the verified call returning from the panel to $f083
                # can inherit that callee's existing dead-register differences.
                owner = "panel_check" if panel_call and after["pc"] == 61571 else name
                failures.setdefault(name, []).append((owner, problems))
            if counts[name] >= args.calls and pc in points:
                m.request(0x13, struct.pack("<I", points.pop(pc)))
    new = []
    for name in names:
        bad = failures.get(name, [])
        differences = [(owner, p.split(" ")[0] if not p[0].isdigit() else "RAM")
                       for owner, problems in bad for p in problems]
        kinds = {kind for _, kind in differences}
        unexpected = {kind for owner, kind in differences if kind not in KNOWN.get(owner, set())}
        if not counts[name]:
            status = "not reached on this route"
        elif not bad:
            status = "ok"
        elif not unexpected:
            status = f"ok apart from the known {sorted(kinds)} in {len(bad)} calls"
        else:
            status = f"{len(bad)} mismatches in {sorted(kinds)}, e.g. {bad[0][1]}"
            new.append(name)
        print(f"{name:15} {counts[name]:3} calls, {len(outcomes[name]):2} distinct exits (PC, A)  {status}")
    if new:
        raise SystemExit(f"native routines differ from the original: {new}")
    print("all sampled calls match the original apart from the known differences")

if __name__ == "__main__":
    main()
