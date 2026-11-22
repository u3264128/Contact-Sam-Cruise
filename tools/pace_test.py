"""Time the joystick route from the same Spectrum opening on every build."""
import argparse
import hashlib
import struct
from math import ceil
from pathlib import Path
from statistics import median
from skoolkit import CSimulator
from skoolkit.simutils import A, B, C, D, E, F, H, L, SP, T, xB, xC, xD, xE, xH, xL
from build import HOOKS, colors, guest_storage
from monitor import BUILD
from playthrough_test import Player
from vice_test import CAMERA, FRAME, VICE, begin, camera, check_screen, cpu_clock, labels, original_opening, original_state, route, vice


def spectrum_camera():
    """Time both 64 pixel pans with the original interrupts and ULA contention."""
    cpu = original_opening(False)
    for direction, address in (("left", 59406), ("right", 59461)):
        cpu.registers[SP] = 0x5d40
        cpu.memory[0x5d40:0x5d42] = bytes(2)
        start = cpu.registers[T]
        cpu.run(address, 0, True)
        duration = (cpu.registers[T] - start) / 3500
        print(f"Spectrum {direction}: {duration:.1f} ms for 64 pixels", flush=True)


def fixed_opening(m, sym):
    cpu = original_opening(False)
    ram, reg = bytearray(cpu.memory), cpu.registers
    # Keep the native entry tokens in the guest code, and the CPU vectors
    # and black bitmap columns owned by the 6510.
    for address in HOOKS:
        ram[address:address+2] = m.read(address, 2)
    for start, size in guest_storage(sym):
        ram[start:start+size] = m.read(start, size)
    m.write(0x5800, ram[0x5800:0xfffa])
    m.write(sym["vector_tail"], ram[0xfffa:])
    m.write(2, bytes(reg[i] for i in (C, B, E, D, L, H, A)))
    m.write(11, reg[SP].to_bytes(2, "little"))
    flags = reg[F]
    result = 0 if flags & 64 else (128 if flags & 128 else 1)
    m.write(13, bytes((result, flags & 1)))
    m.write(15, bytes(reg[i] for i in (xC, xB, xE, xD, xL, xH)))
    for row in range(24):
        addr = 0x4000 + (row//8)*2048 + (row%8)*32
        m.write(0x2020 + row*320, bytes(ram[addr+x+y*256] for x in range(32) for y in range(8)))
        m.write(0x404 + row*40, bytes(map(colors, ram[0x5800+row*32:0x5820+row*32])))


def camera_stress(m, sym, model):
    # Every pair of neighbours has different attributes. Fill the visible
    # bitmap only: the black gutters contain live 6510 routines and tables.
    for row in range(20):
        pixels = bytes((37*x + 29*row + 73*scan) & 255 for x in range(32) for scan in range(8))
        attrs = bytes(64 + ((x+row) % 7 + 1) + 8*((x+row+3) % 7) for x in range(32))
        m.write(0x2020+320*row, pixels)
        m.write(0x5800+32*row, attrs)
        m.write(0x404+40*row, bytes(map(colors, attrs)))
    # Cross the 8-bit world-X boundary. Put overlapping, mirrored actors
    # on both entering edges, including actors partly above the viewport.
    m.write(CAMERA, bytes((251, 12)))
    for page, pose, x, y, layer in ((222, 0, 26, 10, 1), (223, 129, 27, 11, 1),
                                    (224, 7, 27, 12, 2), (225, 135, 28, 13, 4),
                                    (226, 14, 252, 18, 1), (229, 249, 253, 19, 2)):
        m.write(page << 8, bytes((pose, x, y, 0, layer)))
    camera(m, sym, model, stress=True)

    # In the game's shake effect the last row stays in place and the
    # camera coordinates are unchanged, in both vertical directions.
    for inner, exit_patch in ((59528, 59552), (59587, 59612)):
        m.write(exit_patch, bytes((0xc9,)))
        m.write(61440, b"\xc3" + inner.to_bytes(2, "little"))
        image = original_state(m.read(0, 65536), sym)
        image[0x5d40:0x5d42] = bytes(2)
        zx = CSimulator(image, {"SP": 0x5d40})
        zx.run(inner, 0)
        m.resume_to(sym["frame_start"])
        live = m.read(0, 65536)
        check_screen(zx.memory, live)
        assert live[CAMERA:CAMERA+2] == bytes((251, 12))
        m.write(exit_patch, bytes((0x21,)))
    print(model, "both camera shake directions passed", flush=True)
    if "shake_start" in sym:
        shake_sequence(m, sym, model)

    if "cut_top_min" in sym:
        # Force the last raster line in each window. The camera now has the
        # least possible time before the next VIC fetch on this model.
        gates = [(sym["cut_top_min"]+1, 83), (sym["cut_reveal_min"]+1, 255)]
        saved = [m.read(address, 1) for address, _ in gates]
        try:
            for address, line in gates:
                m.write(address, bytes((line,)))
            print(model, "camera at both raster deadlines", flush=True)
            camera(m, sym, model, stress=True)
        finally:
            for (address, _), original in zip(gates, saved):
                m.write(address, original)
    if "pan_actor_pages" in sym:
        full_actor_cache(m, sym, model)


def full_actor_cache(m, sym, model):
    """Make all sixteen actors cross the same horizontal and vertical block edges."""
    m.write(CAMERA, bytes((230, 0)))
    for page in range(215, 231):
        m.write(page << 8, bytes((page % 8, 6, 6, 0, 1 << (page % 3))))
    m.write(61440, b"\xc3" + (59406).to_bytes(2, "little"))
    m.write(sym["frame_call"]+1, bytes((FRAME & 255,)))
    image = original_state(m.read(0, 65536), sym)
    image[0x5d40:0x5d42] = bytes(2)
    zx = CSimulator(image, {"SP": 0x5d40})
    zx.run(59406, 0)
    m.checkpoint(sym["pan_actor_restore"], temporary=True)
    m.resume_to(sym["pan_actor_restore"])
    expected = (bytes(range(215, 231)) + bytes(1)) * 4
    assert m.read(sym["pan_used"], 1)[0] == len(expected), "pan actor cache length"
    assert m.read(sym["pan_actor_pages"]+1, len(expected)) == expected, "pan sprite priority"
    m.resume_to(sym["frame_start"])
    check_screen(zx.memory, m.read(0, 65536))
    print(model, "64 actor entries matched sprite priority and final pixels", flush=True)


def shake_sequence(m, sym, model):
    """Compare the fourteen half shakes and the restored sprite mirror table."""
    m.write(61440, b"\xc3" + (64618).to_bytes(2, "little"))
    m.write(sym["frame_call"]+1, bytes((FRAME & 255,)))
    live = m.read(0, 65536)
    image = original_state(live, sym)
    sp = int.from_bytes(live[11:13], "little") - 2
    image[sp:sp+2] = FRAME.to_bytes(2, "little")
    zx = CSimulator(image, {"SP": sp})
    checkpoints = [m.checkpoint(sym[name]) for name in ("shake_fall", "shake_rise")]
    start = 64618
    try:
        for stop, name in [(64666, "shake_fall"), (64690, "shake_rise")] * 7 + [(FRAME, "frame_start")]:
            zx.run(start, stop)
            m.resume_to(sym[name])
            live = m.read(0, 65536)
            check_screen(zx.memory, live)
            assert live[0x7e00:0x7f60] == zx.memory[0x7e00:0x7f60], "shake row or mirror table"
            for patch in (59372, 59375, 59552, 59612):
                assert live[patch] == zx.memory[patch], ("shake patch", patch)
            start = stop
        assert live[2:9] == bytes(zx.registers[i] for i in (C, B, E, D, L, H, A))
        assert live[CAMERA:CAMERA+2] == zx.memory[CAMERA:CAMERA+2]
    finally:
        for mark in checkpoints:
            m.request(0x13, struct.pack("<I", mark))
    print(model, "all seven camera shakes match the Spectrum", flush=True)


def message_pace(m, sym, model):
    """Time complete lines, including word wrapping and nested messages."""
    m.write(61440, b"\xc3" + (28457).to_bytes(2, "little"))
    m.write(sym["frame_call"]+1, bytes((FRAME & 255,)))
    clock = {"pal": 985248, "ntsc": 1022727}[model]
    for number in (56, 57):
        m.write(32640, bytes(18))
        m.write(32695, bytes((0, 0, number)) + bytes(6))
        times = []
        for _ in range(16):
            image = original_state(m.read(0,65536), sym)
            image[0x5d40:0x5d42] = bytes(2)
            zx = CSimulator(image, {"SP": 0x5d40})
            zx.run(28457, 0)
            start = cpu_clock(m)
            m.resume_to(sym["frame_start"])
            times.append((cpu_clock(m)-start)*1000/clock)
            live = m.read(0,65536)
            check_screen(zx.memory, live)
            assert live[32608:32658] == bytes(zx.memory[32608:32658]), "message buffer or nesting"
            if live[32641] == 0:
                break
        else:
            raise AssertionError(f"Message {number} never ended")
        print(f"{model} message {number}, ms per matching line: " + ", ".join(f"{t:.1f}" for t in times), flush=True)


def actor_pace(m, sym, model):
    """Time actor commands and graphics at the frame boundary."""
    clock = {"pal": 985248, "ntsc": 1022727}[model]
    m.write(sym["frame_call"]+1, bytes((FRAME & 255,)))
    # A one-command list with a RET includes the normal indirect handoff.
    record = bytearray(29)
    record[23:25] = (0x5b60).to_bytes(2, "little")
    m.write(0x5b60, (0x5b70).to_bytes(2, "little"))
    m.write(0x5b70, bytes((0xc9,)))
    m.write(32713, bytes((1,)))
    # PUSH the old pose, load a fixed random draw and enter the banknote animation.
    banknote = 0x5b80
    m.write(banknote, bytes((0x3e, 62, 0xf5, 0x3e, 136, 0xc3)) + (25484).to_bytes(2, "little"))
    for name, address in (("new actor command", 62029), ("prepare and rotate Sam", 25618),
                          ("rotate Sam", 25672), ("disguise tiles and portrait", 63852),
                          ("banknote pose and drift", banknote)):
        m.write(61440, b"\xc3" + address.to_bytes(2, "little"))
        samples = []
        for _ in range(9):
            m.write(0xde00, record)
            m.write(6, bytes((0, 222)))
            if address == banknote:
                # DE holds the position and H selects the banknote actor.
                m.write(4, bytes((15, 34, 0, 228)))
            start = cpu_clock(m)
            m.resume_to(sym["frame_start"])
            samples.append(cpu_clock(m) - start)
        cycles = median(samples)
        print(f"{model} {name}: {cycles:,.0f} cycles, {1000*cycles/clock:.2f} ms median", flush=True)


def stage_pace(m, sym, watch, model, prg):
    build_id = hashlib.sha256(prg.read_bytes()).hexdigest()[:12]
    player = Player(m, sym)
    player.watch = watch
    clock = {"pal": 985248, "ntsc": 1022727}[model]
    for stage in ("released", "fat_man", "budgie"):
        snapshot = BUILD / "work" / f"play-{model}-{build_id}-{stage}.vsf"
        if not snapshot.is_file():
            raise FileNotFoundError(f"{snapshot.name} requires a {model} playthrough of this build")
        player.load(snapshot)
        player.switch("frame_start")
        m.resume_to(sym["frame_start"])
        previous = m.read(CAMERA, 2)
        start = cpu_clock(m)
        ordinary = []
        for tick in range(144):
            m.stick(8 if tick < 72 else 4)
            m.resume_to(sym["frame_start"])
            now = cpu_clock(m)
            position = m.read(CAMERA, 2)
            if position == previous:
                ordinary.append((now-start)*1000/clock)
            previous, start = position, now
        ordinary.sort()
        p95 = ordinary[ceil(.95*len(ordinary))-1]
        print(f"{model} {stage}: {len(ordinary)} ordinary; median/p95/max "
              f"{median(ordinary):.1f}/{p95:.1f}/{ordinary[-1]:.1f} ms; "
              f"{sum(t > 100 for t in ordinary)} over 100 ms", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=("pal", "ntsc", "both"), default="both")
    parser.add_argument("--vice", default=VICE)
    parser.add_argument("--prg", type=Path, help="compare a saved build with its adjacent .lbl file")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--messages", action="store_true", help="time two original phone messages")
    mode.add_argument("--actors", action="store_true", help="time actor commands, banknote drift, rolls and disguises")
    mode.add_argument("--camera", action="store_true", help="time and compare each camera step in four directions")
    mode.add_argument("--camera-stress", action="store_true", help="check dense colour changes, actor edges, row timing and shake")
    mode.add_argument("--stages", action="store_true", help="time ordinary updates from three playthrough saves")
    args = parser.parse_args()
    sym = labels(args.prg.with_suffix(".lbl") if args.prg else None)
    if args.camera:
        spectrum_camera()
    for model in (("pal", "ntsc") if args.model == "both" else (args.model,)):
        with vice(args.vice, model, args.prg) as m:
            watch = begin(m, sym)
            if args.stages:
                stage_pace(m, sym, watch, model, args.prg or BUILD / "contact-sam-cruise.prg")
            else:
                fixed_opening(m, sym)
                if args.camera_stress:
                    camera_stress(m, sym, model)
                elif args.camera:
                    camera(m, sym, model)
                elif args.messages:
                    message_pace(m, sym, model)
                elif args.actors:
                    actor_pace(m, sym, model)
                else:
                    route(m, sym, model)
