"""Build a C64 program and disk image from the pinned Spectrum source."""
import argparse
import hashlib
from pathlib import Path
import re
import struct
import subprocess

from skoolkit.skool2bin import main as skool2bin
from skoolkit.z80 import Assembler

from opcodes import generate
from monitor import BUILD, ROOT, find_program, labels, program_default

CA65 = program_default("ca65", "CA65", "CC65_ROOT")
LD65 = program_default("ld65", "LD65", "CC65_ROOT")
OD65 = program_default("od65", "OD65", "CC65_ROOT")
C1541 = program_default("c1541", "C1541", "VICE_ROOT")
GIT = program_default("git", "GIT", "GIT_ROOT")
WORK = BUILD / "work"
REFERENCE = ROOT / ".cache" / "contactsamcruise"

REVISION = "443910ecf2e8c31665690d6c4ceda89383635554"
SOURCE = "https://github.com/skoolkid/contactsamcruise.git"
HASH = "c4dbff9ea9f1f5616f9173bc37c0a724d5fe3e6279e713e4c5f0580268e8500b"
NAME = "contact-sam-cruise"
HOOKS = {
    29668: "panel_check", 29680: "panel_flags", 30989: "cutscene",
    60082: "game_controls", 61967: "schedule_actor", 62029: "continue_actor",
    61791: "get_param", 29961: "event_scan", 30220: "object_scan",
    59868: "mark_region", 28709: "icon_attr", 59148: "print_tile",
    60032: "refresh", 59418: "left_step", 59473: "right_step",
    59528: "up_step", 59587: "down_step", 60521: "footstep",
    64740: "effect", 25088: "shot_sound", 25583: "banknote_sound",
    64470: "reveal_sound", 61483: "frame_start", 30339: "object_icons",
    60152: "rdorswalk", 60179: "locdescs", 61948: "fuse_check",
    59848: "srb_update", 59858: "srb_return", 59861: "set_state",
    60347: "move_left", 60334: "move_right", 60315: "move_up", 60320: "move_down",
    61440: "loop_tasks", 61571: "tasks_mode", 61579: "tasks_sam", 61588: "tasks_found",
    29952: "events", 30211: "found_object", 61823: "get_random", 60506: "end_stride",
    61764: "shut_doors", 61770: "door_loop", 62468: "chk_fuses",
    26075: "move_bullets", 30429: "ringing", 30442: "phone_search",
    25484: "banknote_pose", 25420: "move_banknote", 63409: "bind_primary",
    62518: "by_light", 62548: "fixture_at", 62926: "walk_floor",
    62929: "walk_command", 62892: "stairs_command", 61509: "sam_timer",
    28160: "print_message", 28512: "message_chars",
    62080: "next_primary", 62084: "next_interruptible", 62088: "next_uninterruptible",
    29578: "check_region", 25434: "banknote_range",
    61492: "sam_action", 61552: "main_clock",
    61486: "frame_panel", 61489: "frame_actors", 61568: "frame_icons",
    63328: "door_walk", 63331: "door_duty", 63403: "run_subcommand",
    63128: "midstride", 63130: "stride_pose",
    62368: "window_srb", 28186: "print_num", 61809: "get_params",
    60726: "locid", 60734: "locid_z", 60743: "locid_road",
    60222: "next_location_descriptor", 60423: "move_stride",
    61838: "cycle_actors_right", 61882: "cycle_actors_left",
    62099: "door_status", 30396: "by_door", 60483: "resume_stride",
    60293: "stand_check", 60300: "stand_pose", 60720: "closed_location",
    59406: "camera_left", 59461: "camera_right", 59516: "camera_up", 59575: "camera_down",
    59454: "camera_next", 59509: "camera_next", 59568: "camera_next", 59628: "camera_next",
    64582: "mirror_table", 64618: "shake_start", 64666: "shake_fall", 64690: "shake_rise",
    61964: "schedule_second", 29004: "actor_frozen",
    25618: "prepare_roll_tiles", 25672: "rotate_roll_tiles",
    63852: "disguise_tiles",
    24951: "joystick_prompt",
}

# The fixed segments below share complete routine bodies with smaller native helpers.
RECLAIMED = ((59150, 218), (28188, 107), (62370, 98), (59870, 162), (60034, 48), (60745, 67),
             (61443, 40), (62550, 46), (60224, 69), (60425, 48), (61840, 39), (61884, 36))

# These column ranges have identical tile data in the last two rows of a
# six-row block. Each tuple gives the first index, exclusive end and alias.
TILE_ALIASES = ((32, 73, 31), (81, 106, 31), (106, 112, 73), (141, 154, 31))
# Poses 120 to 127 use a 2 by 2 sprite and leave the later page tails free.
SPRITE_PADDING = tuple((page*256+248, 8) for page in range(221, 230))

# Each retired routine or unused data range can hold resident 6510 code.
NATIVE_SLOTS = (
    # Unused Spectrum system variables below the guest stack.
    (23563, 48), (23612, 60), (23675, 105),
    (27778, 70), (56910, 48), (30341, 45), (26077, 14), (60181, 40),
    (25486, 53), (59420, 34), (59475, 34), (63333, 13), (62520, 26),
    (25436, 44), (29682, 34), (59589, 23), (30222, 22), (59530, 22),
    (62931, 21), (62894, 20), (27725, 20), (27872, 20), (27981, 20),
    (26605, 19), (29580, 17), (60523, 16), (61793, 16), (47975, 17),
    (48625, 15), (59121, 26), (48224, 14), (24819, 13), (48244, 12),
    (24534, 10), (65159, 11), (48491, 10),
    (25090, 16), (64742, 14), (61950, 14), (59850, 8), (61825, 12),
    (26360, 8), (49742, 10), (59839, 9),
    (60508, 13), (61186, 8),
    # Retired entries end at the first live guest or native continuation.
    (29670, 10), (61969, 59), (62031, 49), (28711, 11), (25585, 15),
    (64472, 40), (59863, 5), (61573, 6), (61581, 7), (61590, 7),
    (29954, 7), (30213, 7), (61772, 15), (62470, 14), (30431, 11),
    (30444, 13), (61511, 14), (61554, 13), (61811, 12), (60728, 6),
    (60736, 7), (23551, 9), (61689, 7), (60714, 6), (62363, 5), (62715, 5),
    # Bodies behind fully native hooks, up to the next entry.
    (60154, 5), (61494, 4), (61766, 4), (63132, 5),
    # Shared row copier, camera loops and movement. Preserve both shake opcodes
    # and the two writable operands of the original row copier.
    (59368, 4), (59373, 2), (59376, 30), (59408, 10), (59456, 5),
    (59463, 10), (59511, 5), (59518, 10), (59553, 15), (59570, 5),
    (59577, 10), (59613, 15), (59630, 5),
    (60295, 5), (60302, 13), (60317, 3), (60322, 12), (60336, 11),
    (60349, 74), (60473, 10), (60485, 21), (60722, 4), (62101, 19), (30398, 31),
    (64584, 15), (64620, 46), (64668, 22), (64692, 48),
    (29006, 46), (61966, 1), (62082, 2), (62086, 2), (62090, 9),
    (25600, 18), (25620, 52), (25674, 50), (63854, 100),
    (25422, 11), (63411, 12),  # 25433 remains the frozen banknote's RET.
    (29731, 84),  # Native panel_check returns to the phone icon code at 29815.
    (28034, 116),  # Unused entries in the message address table.
    (61603, 15), (31284, 5), (62966, 5),  # Unused guest routines.
    (50169, 7), (42774, 6), (48122, 6), (60141, 5), (65427, 5), (49005, 4),
) + SPRITE_PADDING + tuple(
    (page*256+start, end-start) for page in range(168, 172)
    for start, end, _ in TILE_ALIASES)
NATIVE_STORAGE = RECLAIMED + NATIVE_SLOTS


def check_reclaimed(skool):
    """Reject live references into reused guest memory or a native tag operand."""
    operands = {address + 1 for address in HOOKS}
    for line in skool.splitlines():
        m = re.match(r"^[bcgistuw* ](\d{5}) ([^;]*)", line)
        if not m:
            continue
        at = int(m.group(1))
        if at in HOOKS or at-1 in HOOKS or any(s <= at < s+n for s, n in NATIVE_STORAGE):
            continue  # The original instruction no longer runs here.
        for value in map(int, re.findall(r"\b\d{4,5}\b", m.group(2))):
            if value in operands:
                raise ValueError(f"{at} refers to the second byte of the native hook at {value-1}")
            for start, size in NATIVE_STORAGE:
                if start <= value < start+size:
                    raise ValueError(f"{at} refers to {value} in the reclaimed range at {start}")


def guest_storage(symbols):
    return NATIVE_STORAGE if "pan_display" in symbols or "cycle_actors_right" in symbols else RECLAIMED


def pack_font(rom):
    """Transpose the six full scanlines and keep the sparse outer rows."""
    glyphs = [rom[at:at+8] for at in range(0x3d00, 0x4000, 8)]
    rows = bytes(glyph[row] for row in range(1, 7) for glyph in glyphs)
    descenders = [(index, glyph[7]) for index, glyph in enumerate(glyphs) if glyph[7]]
    assert len(descenders) == 10 and descenders[-1][0] == 95
    assert all(glyph[0] == 0 for glyph in glyphs[:-1])
    return rows + bytes(index for index, _ in descenders) + bytes(row for _, row in descenders) + glyphs[-1][:1]


def tile_aliases(game, work):
    """Verify the four original tile planes and emit their shared index lookup."""
    code = []
    for index, (start, end, alias) in enumerate(TILE_ALIASES):
        for page in range(168, 172):
            plane = memoryview(game)[page*256:(page+1)*256]
            if any(value != plane[alias] for value in plane[start:end]):
                raise ValueError(f"Tile columns {start} to {end-1} differ from {alias} in page {page}")
        if index == 0 or start != TILE_ALIASES[index-1][1]:
            code.extend((f"    cpx #{start}", "    bcc @done"))
        code.extend((f"    cpx #{end}", f"    bcc @use{alias}"))
    code.extend(("@done:", "    rts"))
    for alias in sorted({alias for _, _, alias in TILE_ALIASES}):
        code.extend((f"@use{alias}:", f"    ldx #{alias}", "    rts"))
    (work / "tile_aliases.inc").write_text("\n".join(code) + "\n", encoding="ascii")


def native_layout(obj, work, reclaimed, slots, tokens):
    """Place independent native routines in retired guest code and bitmap margins."""
    ranges = sorted(reclaimed + slots + tuple((at, len(tokens[name])) for at, name in HOOKS.items()))
    for (start, size), (next_start, _) in zip(ranges, ranges[1:]):
        if start + size > next_start:
            raise ValueError(f"Overlapping native storage at {next_start}")
    dump = subprocess.check_output([find_program(OD65, "OD65", "CC65_ROOT"), "--dump-segments", str(obj)], text=True)
    sizes = {name: int(size) for name, size in re.findall(
        r'Name:\s+"(\w+)"\s+Flags:\s+\d+\s+Size:\s+(\d+)', dump)}
    config = (ROOT / "src/port.cfg").read_text()
    memory, segments = [], []
    io_areas = {f"{prefix}{i}" for prefix, ranges in (("GUEST", reclaimed), ("SLOT", slots))
                for i, (start, size) in enumerate(ranges) if start < 0xe000 and start + size > 0xd000}
    free = {f"GAP{i}": 64 - sizes.get(f"G{i}", 0) for i in range(23)}
    for i, (start, size) in enumerate(reclaimed):
        memory.append(f'    GUEST{i}: start={start}, size={size}, file="%O.guest{i}";')
        segments.append(f"    RECLAIM{i}: load=GUEST{i}, type=rw, optional=yes;")
        free[f"GUEST{i}"] = size - sizes.get(f"RECLAIM{i}", 0)
    for i, (start, size) in enumerate(slots):
        memory.append(f'    SLOT{i}: start={start}, size={size}, file="%O.slot{i}";')
        free[f"SLOT{i}"] = size
    free["LOW"] = 0x1817 - sizes["CODE"] - sizes.get("PAN", 0)
    free["HIGH"] = 0x1600 - sizes["EXT"]
    free["HIDDEN"] = 0x100 - sizes["ROWCODE"]
    free["FONTGAP"] = 0x20
    if min(free.values()) < 0:
        raise ValueError(f"Fixed code exceeds its memory area: {[(k,v) for k,v in free.items() if v<0]}")
    units = [(size, name) for name, size in sizes.items() if name.startswith(("VM_", "OP_", "PN_"))]
    used_slots = set()
    for size, name in sorted(units, key=lambda unit: (-unit[0], unit[1])):
        fits = [area for area, left in free.items() if left >= size]
        if name.startswith("PN_"):
            # The left gutter occupies the last eight bytes of gaps 0 through 18.
            fits = [area for area in fits
                    if not (area.startswith("GAP") and int(area[3:]) < 19 and free[area] - size < 8)
                    and area not in io_areas]
        if not fits:
            raise ValueError(f"No room for {name} ({size} bytes), {sum(free.values())} bytes free")
        area = min(fits, key=lambda a: (a in ("LOW", "HIGH"), free[a], a))
        free[area] -= size
        segments.append(f"    {name}: load={area}, type=rw;")
        if area.startswith("SLOT"):
            used_slots.add(int(area[4:]))
    config = config.replace("# Native memory areas", "\n".join(memory).lstrip())
    config = config.replace("# Native segments", "\n".join(segments).lstrip())
    target = work / "engine.cfg"
    target.write_text(config, encoding="ascii")
    print(f"{sum(size for _, size in reclaimed + slots)} guest bytes available for native code. "
          f"{sum(free.values())} bytes free across the linker areas, largest block {max(free.values())}.")
    return target, sorted(used_slots)


def colors(attr):
    palette = (0,14,10,4,13,3,7,1) if attr & 64 else (0,6,2,4,5,3,7,15)
    return palette[attr & 7]*16 + palette[(attr >> 3) & 7]

# Opcodes that the game writes into its own code at run time.
SELF_MODIFIED = {0x01, 0x20, 0x21, 0x28, 0x30, 0x38, 0xc3, 0xc9}


def live_instructions(skool):
    """Yield guest instruction addresses and sizes outside the native ranges."""
    assembler = Assembler()
    dead = NATIVE_STORAGE + tuple((addr, 2) for addr in HOOKS)
    code = False
    for line in skool.splitlines():
        m = re.match(r"^([bcgistuw* @])(\d{5}) ([^;]+)", line)
        if not m:
            continue
        if m.group(1) != " ":
            code = m.group(1) in "c*"
        at = int(m.group(2))
        if code and not m.group(3).startswith("DEF") and not any(s <= at < s+n for s, n in dead):
            size = assembler.get_size(m.group(3).strip(), at)
            if not size:
                raise ValueError(f"Cannot size the guest instruction at {at}")
            yield at, size


def tables(work):
    for name, values in (("vic_attr", [colors(i) for i in range(256)]),
                         ("parity", [4*(i.bit_count()%2 == 0) for i in range(16)])):
        with (work / (name + ".inc")).open("w") as out:
            print(name + ":", file=out)
            for i in range(0, len(values), 16):
                print("    .byte " + ",".join(map(str, values[i:i+16])), file=out)

def audio_tables(work):
    """Linear CIA latch descriptors for beeper half waves.

    The C64 builds the two 256-entry tables for its own video standard at
    start-up: latch(p) = base + step*p, with 16.16 fixed-point arithmetic.
    sound_period: 13*p+36 T-states, a DJNZ delay outside contended memory.
    sound_contended: 19.764*p+58.5 T-states, the average measured in the
    48K simulator for the $62xx effects while the ULA fetches the display.
    The order is NTSC then PAL, as pal_machine indexes it.
    """
    lines = ["sound_descriptors:"]
    for clock in (1022727, 985248):
        for slope, offset in ((13, 36), (19.764, 58.5)):
            scale = clock/3500000*65536
            base = round((offset*clock/3500000 - 0.5)*65536)   # rounding and the -1 latch bias
            step = round(slope*scale)
            lines.append("    .byte " + ",".join(str((base >> s) & 255) for s in (0, 8, 16, 24)) +
                         "," + ",".join(str((step >> s) & 255) for s in (0, 8, 16)))
    (work / "sound.inc").write_text("\n".join(lines) + "\n", encoding="ascii")

def pack(data):
    """Choose backward literals, runs and LZ matches by encoded size."""
    data = bytes(reversed(data))
    size = len(data)
    previous = [-1] * size
    last = {}
    for pos in range(size - 2):
        key = data[pos:pos+3]
        previous[pos] = last.get(key, -1)
        last[key] = pos

    costs = [0] * (size + 1)
    packets = [None] * size
    run = 0
    for pos in reversed(range(size)):
        limit = min(128, size-pos)
        best = costs[pos+1] + 2
        length, distance = 1, 0
        for n in range(2, limit+1):
            cost = 1 + n + costs[pos+n]
            if cost < best:
                best, length = cost, n

        run = min(run+1, 256) if pos+1 < size and data[pos] == data[pos+1] else 1
        for n in range(4, run+1):
            cost = 2 + (n >= 35) + costs[pos+n]
            if cost < best:
                best, length, distance = cost, n, -1

        limit = min(256, size-pos)
        # Newer occurrences are always cheaper or equal in encoded size.
        # A later candidate only needs testing if it extends a known match.
        matched = 2
        start = previous[pos]
        while start >= 0 and matched < limit and pos-start <= 65536:
            if data[start+matched] == data[pos+matched]:
                n = 3
                while n < limit and data[start+n] == data[pos+n]:
                    n += 1
                gap = pos - start
                for count in range(matched+1, n+1):
                    overhead = 2 if gap <= 256 or (gap <= 2304 and count <= 6) else 3
                    cost = overhead + (count >= 34) + costs[pos+count]
                    if cost < best:
                        best, length, distance = cost, count, pos-start
                matched = max(matched, n)
            start = previous[start]
        costs[pos] = best
        packets[pos] = length, distance

    encoded = bytearray()
    pos = 0
    while pos < size:
        length, distance = packets[pos]
        if distance == 0:
            encoded.append(length-1)
            encoded.extend(data[pos:pos+length])
        elif distance < 0:
            encoded.append(224 + min(length - 4, 31))
            if length >= 35:
                encoded.append(length & 255)
            encoded.append(data[pos])
        elif 256 < distance <= 2304 and length <= 6:
            offset = distance - 1
            encoded.append(192 + 4 * ((offset >> 8) - 1) + length - 3)
            encoded.append(offset & 255)
        else:
            offset = distance - 1
            header = 128 if distance <= 256 else 160
            encoded.append(header + min(length - 3, 31))
            if length >= 34:
                encoded.append(length & 255)
            encoded.append(offset & 255)
            if distance > 256:
                encoded.append(offset >> 8)
        pos += length
    return encoded[::-1]

def read_reference(filename):
    """Read a listing from the pinned revision in the local Git cache."""
    git = find_program(GIT, "GIT", "GIT_ROOT")
    if not REFERENCE.exists():
        REFERENCE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([git, "clone", SOURCE, str(REFERENCE)], check=True)
    return subprocess.check_output(
        [git, "-C", str(REFERENCE), "show", f"{REVISION}:sources/{filename}"]
    )


def build(source, stripe_camera=False):
    assembler = find_program(CA65, "CA65", "CC65_ROOT")
    linker = find_program(LD65, "LD65", "CC65_ROOT")
    work = WORK / "stripes" if stripe_camera else WORK
    name = NAME + "-stripes" if stripe_camera else NAME
    work.mkdir(parents=True, exist_ok=True)
    listing = read_reference("csc.skool") if source is None else Path(source).read_bytes()
    source = work / "csc.skool"
    source.write_bytes(listing)
    pristine = work / "spectrum.bin"
    skool2bin(["-i","-d",str(source),str(pristine)])
    raw = pristine.read_bytes()
    if hashlib.sha256(raw).hexdigest() != HASH:
        raise ValueError("The native hooks require the pinned Spectrum image")
    disassembly = listing.decode("utf-8")
    check_reclaimed(disassembly)
    hook_operands = {at+1 for at in HOOKS}
    for path in sorted((ROOT / "src").glob("*.[si]*")):
        code = "\n".join(line.split(";")[0] for line in path.read_text().splitlines())
        for value in map(int, re.findall(r"\b\d{5}\b", code)):
            if value in hook_operands or any(start <= value < start+size for start, size in NATIVE_STORAGE):
                raise ValueError(f"{path.name} refers to {value} in a reclaimed range")
    game = bytearray(20637) + raw
    assert len(game) == 65536
    # The -i option includes the original status panel. Save its pixels
    # before native code reuses the Spectrum display memory.
    for row in range(24):
        for col in range(32):
            zx = 0x4000 + (row//8)*2048 + (row%8)*32 + col
            vic = 0x2020 + row*320 + col*8
            game[vic:vic+8] = game[zx:zx+2048:256]
    from skoolkit import ROM48
    (work / "font.bin").write_bytes(pack_font(Path(ROM48).read_bytes()))
    tile_aliases(game, work)
    for start, size in NATIVE_STORAGE:
        game[start:start+size] = bytes(size)
    names = list(dict.fromkeys(HOOKS.values()))
    audio_tables(work)
    tables(work)
    remaining = list(live_instructions(disassembly))
    used = SELF_MODIFIED | {game[at] for at, _ in remaining}
    tokens = generate(work / "opcodes.inc", names, used)
    # A single-byte hook adds a byte to the retired body immediately after it.
    direct_hooks = {at for at, name in HOOKS.items() if len(tokens[name]) == 1}

    def include_spare_hook_bytes(ranges):
        return tuple((start-1, size+1) if start-2 in direct_hooks else (start, size)
                     for start, size in ranges)

    reclaimed = include_spare_hook_bytes(RECLAIMED)
    slots = include_spare_hook_bytes(NATIVE_SLOTS)
    for addr, hook in HOOKS.items():
        game[addr:addr+2] = tokens[hook].ljust(2, b"\0")
    guest_bytes = sum(size for _, size in remaining)
    print(f"{len(HOOKS)} native entry addresses. {len(remaining)} original instructions "
          f"({guest_bytes} bytes) remain outside the replaced ranges.")
    obj = work / "engine.o"
    low = work / "engine"
    defines = ["-D", "STRIPE_CAMERA=1"] if stripe_camera else []
    subprocess.run([assembler, *defines, "--bin-include-dir", str(work), "-g", "-I", str(work),
                    "-o", str(obj), str(ROOT / "src/main.s")], check=True)
    label_file = work / f"{name}.lbl"
    for index in range(len(RECLAIMED)):
        Path(f"{low}.guest{index}").unlink(missing_ok=True)
    config, used_slots = native_layout(obj, work, reclaimed, slots, tokens)
    subprocess.run([linker,"-C",str(config),"-Ln",str(label_file),
                    "-m",str(work/"memory.map"),"-o",str(low),str(obj)],check=True)
    high = Path(str(low)+".hi").read_bytes()
    assert len(high) <= 0x1800
    game[0x4000:0x5800] = high.ljust(0x1800,b"\0")
    hidden = Path(str(low)+".hidden").read_bytes()
    assert len(hidden) <= 0x100
    game[0x3e00:0x3e00+len(hidden)] = hidden
    if not stripe_camera:
        camera_init = Path(str(low)+".caminit").read_bytes()
        assert 0 < len(camera_init) <= 256
        game[0x3f00:0x3f00+len(camera_init)] = camera_init
    # Each bitmap gap holds 64 bytes of native code and data. It spans
    # columns 36 to 39 of one row and columns 0 to 3 of the next.
    gaps = Path(str(low)+".gaps")
    if gaps.exists():
        data = gaps.read_bytes()
        assert len(data) == 23*64, len(data)
        for r in range(23):
            at = 0x2000 + 320*r + 288
            game[at:at+64] = data[64*r:64*r+64]
    for index, (start, size) in enumerate(reclaimed):
        part = Path(f"{low}.guest{index}")
        if part.exists():
            data = part.read_bytes()
            assert len(data) <= size
            game[start:start+len(data)] = data
    for i in used_slots:
        start, size = slots[i]
        data = Path(f"{low}.slot{i}").read_bytes()
        assert len(data) <= size
        game[start:start+len(data)] = data
    # The loader and title execute from the PRG. Pack the resident
    # interpreter, bitmap and Spectrum image into one backward stream.
    symbols = labels(label_file)
    packed_at = symbols["packed"]
    resident_start = symbols["resident_start"]
    engine = low.read_bytes()
    load_address = 0x0801
    low_limit = 0x2018
    assert load_address <= packed_at < resident_start <= load_address + len(engine) <= low_limit
    game[load_address:low_limit] = engine.ljust(low_limit-load_address, b"\0")
    payload = pack(game[resident_start:])
    source_base = packed_at + 2
    unread = len(payload)
    target = 65536
    unpacked = bytearray(65536)
    while unread:
        header = payload[unread-1]
        if header < 128:
            count = header + 1
            unread -= count + 1
            target -= count
            unpacked[target:target+count] = payload[unread:unread+count]
        elif header < 224:
            if header >= 192:
                count = 3 + (header & 3)
                unread -= 2
                offset = (1 + ((header >> 2) & 7)) * 256 + payload[unread]
            else:
                far = header >= 160
                count = 3 + (header & 31)
                if count == 34:
                    count = payload[unread-2] or 256
                    unread -= 1
                unread -= 3 if far else 2
                offset = (payload[unread]<<8 | payload[unread+1]) if far else payload[unread]
            distance = offset + 1
            if target - 1 + distance >= 65536:
                raise ValueError("Back-reference outside the unpacked suffix")
            for _ in range(count):
                target -= 1
                unpacked[target] = unpacked[target+distance]
        else:
            count = 4 + (header & 31)
            if count == 35:
                count = payload[unread-2] or 256
                unread -= 1
            unread -= 2
            target -= count
            unpacked[target:target+count] = bytes((payload[unread],)) * count
        if unread < 0 or source_base + unread > target:
            raise ValueError("Packed input overlaps the backward decoder's output")
    if target != resident_start or unpacked[target:] != game[target:]:
        raise ValueError("Packed image did not reproduce the resident game")
    prg = (struct.pack("<H", load_address) + engine[:packed_at-load_address]
           + struct.pack("<H", len(payload)) + payload)
    if 0x0801 + len(prg)-2 > 0xd000:
        raise ValueError("The disk loader would write packed bytes into the C64 I/O area")

    dest = work / f"{name}.prg"
    dest.write_bytes(prg)
    print(f"{dest.name}  {len(prg):,} bytes  SHA256 {hashlib.sha256(prg).hexdigest()}")
    return dest, label_file

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="path to the pinned csc.skool listing")
    parser.add_argument("--stripe-camera", action="store_true", help="build the stripes variant")
    parser.add_argument("--c1541", default=C1541, help="override C1541 for this build")
    args = parser.parse_args()
    c1541 = find_program(args.c1541, "C1541", "VICE_ROOT")
    prg, label_file = build(args.source, args.stripe_camera)
    disk = prg.with_name("package.d64")
    check = prg.with_name("readback.prg")
    check.unlink(missing_ok=True)
    subprocess.run([c1541,"-format","sam cruise,64","d64",str(disk),
                    "-write",str(prg),"sam cruise","-read","sam cruise",str(check)],check=True)
    if check.read_bytes() != prg.read_bytes():
        raise ValueError("Disk readback mismatch")
    disk.replace(BUILD / prg.with_suffix(".d64").name)
    label_file.replace(BUILD / label_file.name)
    prg.replace(BUILD / prg.name)
