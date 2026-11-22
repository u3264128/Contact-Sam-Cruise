"""Compare the C64 sound effects with the Spectrum 48K reference.

Each effect is started from the main loop with fixed registers. The Spectrum
reference is SkoolKit's cycle-accurate simulator with memory contention and
the 50 Hz ROM interrupt. It records the T-state of every OUT to port 254. On
the C64 a store checkpoint on the SID control register of voice 1 gives the
emulated cycle of each speaker edge.

Edges are grouped into tones at gaps longer than 3 ms, which separates the
rows of the wake-up sequence. The reference's first OUT is aligned to the
first SID edge, so both sweeps begin at the same display phase.
Check edge counts, total tone length and the median relative error between
matching half waves. The timing tolerance is 6%. Exclude half waves around
interrupts from the timing comparison.
"""
import argparse
import struct
from statistics import median

from skoolkit import CCMIOSimulator
from skoolkit.simutils import T
from monitor import labels, vice
from vice_test import FRAME, VICE, begin, check_screen, cpu_clock, original_state

CLOCK = {"pal": 985248, "ntsc": 1022727}
FRAME_LATCH = {"pal": 19672, "ntsc": 20420}
# Name and the Z80 code placed at 61440. The main loop's call returns to FRAME.
EFFECTS = (
    ("footstep", "c3 69 ec"),                       # JP 60521
    ("fall", "3e 03 11 80 01 0e c0 c3 e4 fc"),      # LD A,3: LD DE,384: LD C,192: JP 64740
    ("scroll beep", "3e 03 11 00 01 0e 60 c3 e4 fc"),
    ("sniper", "3e 00 11 a2 01 c3 00 62"),          # LD A,0: LD DE,418: JP 25088
    ("shot", "c3 f0 66"),                           # JP 26352
    ("banknote", "c3 eb 63"),                       # JP 25579
    ("wake up", "c3 d6 fb"),                        # JP 64470: 20 rows, 12.8 kHz to 1.3 kHz
)
GAP = 0.003

class Speaker:
    def __init__(self):
        self.times = []

    def read_port(self, registers, port, *_):
        return 0 if port & 255 == 31 else 255

    def write_port(self, registers, port, value, *_):
        if port & 255 == 254:
            self.times.append(registers[T]/3500000)

def spectrum(live, sym, code, phase, reveal=None):
    """Edges and interrupts in seconds from the start of the current frame."""
    image = original_state(live, sym)
    image[61440:61440+len(code)] = code
    sp = 23896
    image[sp:sp+2] = struct.pack("<H", FRAME)
    cpu = CCMIOSimulator(image, {"SP": sp}, {"iff": 1, "im": 1})
    # Begin at the C64's position in its emulated frame, so contention and
    # the ULA interrupt line up with the C64 IRQ.
    cpu.registers[T] = round(phase*69888)
    speaker = Speaker()
    cpu.set_tracer(speaker)
    cpu.run(61440, FRAME, True)
    if reveal is not None:
        check_screen(cpu.memory, reveal)
        assert reveal[0x7f10:0x7f60] == bytes(80), "wake up left dirty rows"
        assert reveal[6:8] == bytes((0x10, 0x7f)), "wake up returned the wrong row pointer"
    frames = range(69888, cpu.registers[T]+1, 69888)
    return speaker.times, [t/3500000 for t in frames]

def wait_for_phase(m, sym, model, phase):
    """Let the live CIA run to a phase before invoking the effect."""
    entry = sym["frame_start"]
    scratch = 0x5b00  # the guest printer buffer is unused during this probe
    high = int((1 - phase) * FRAME_LATCH[model]) >> 8
    # SEI / expose I/O / poll CIA1 timer A high / restore RAM / CLI / JMP entry.
    # The keyboard IRQ can otherwise cover an entire high-byte interval.
    loop = bytes.fromhex("78 e6 01 ad 05 dc c9") + bytes((high,))
    loop += bytes.fromhex("d0 f9 c6 01 58 4c") + struct.pack("<H", entry)
    saved, first = m.read(scratch, len(loop)), m.read(entry, 3)
    m.write(scratch, loop)
    m.write(entry, b"\x4c" + struct.pack("<H", scratch))
    check = m.checkpoint(scratch)
    m.resume_to(scratch)
    m.write(entry, first)
    m.request(0x13, struct.pack("<I", check))
    m.resume_to(entry)
    m.write(scratch, saved)


def c64(m, sym, code, model):
    """Edges and IRQs in seconds from the start of the current frame.

    The IRQ times follow from CIA1 timer A, so no IRQ checkpoint can merge
    with a SID store stop.
    """
    m.write(61440, code)
    m.write(sym["frame_call"]+1, bytes((FRAME & 255,)))
    io = m.request(1, struct.pack("<BHHBH", 0, 0xdc04, 0xdc05, 0, 3))[2:]
    latch = FRAME_LATCH[model]
    period = (latch+1)/CLOCK[model]
    phase = (latch - int.from_bytes(io, "little"))/(latch+1)
    origin = cpu_clock(m)/CLOCK[model] - phase*period
    edge = m.checkpoint(0xd404, operation=2)
    times = []
    while m.resume_to() != sym["frame_start"]:
        times.append(cpu_clock(m)/CLOCK[model] - origin)
    m.request(0x13, struct.pack("<I", edge))
    interrupts = [k*period for k in range(1, int(times[-1]/period)+2)]
    return phase, times, interrupts

def tones(times):
    groups = [[times[0]]]
    for a, b in zip(times, times[1:]):
        if b-a > GAP:
            groups.append([])
        groups[-1].append(b)
    return groups

def interrupted(edges, interrupts):
    """Indexes of the half waves around an interrupt.

    After a late edge the C64's free-running timer returns to its grid, so
    the following half waves are short. Leave out the next two as well.
    """
    hit, k = set(), 0
    for i, (start, end) in enumerate(zip(edges, edges[1:])):
        while k < len(interrupts) and interrupts[k] < start:
            k += 1
        if k < len(interrupts) and interrupts[k] < end:
            hit.update((i, i+1, i+2))
    return hit

def compare(zx, zx_irq, live, live_irq):
    """Return the worst timing errors and interrupt counts for matching tones."""
    a, b = tones(zx), tones(live)
    if [len(t) for t in a] != [len(t) for t in b]:
        return None
    length = pitch = 0
    hits = [0, 0]
    for x, y in zip(a, b):
        if len(x) < 3:
            continue
        hx = [q-p for p, q in zip(x, x[1:])]
        hy = [q-p for p, q in zip(y, y[1:])]
        ix, iy = interrupted(x, zx_irq), interrupted(y, live_irq)
        hits[0] += len(ix)
        hits[1] += len(iy)
        keep = [i for i in range(len(hx)) if i not in ix | iy]
        if keep:
            length = max(length, sum(hy[i] for i in keep)/sum(hx[i] for i in keep) - 1, key=abs)
            # Compare the same edges in each sweep. Separate medians can
            # select different pitches when the tone changes over time.
            pitch = max(pitch, median(hy[i]/hx[i] - 1 for i in keep), key=abs)
    return length, pitch, len(a), hits

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vice", default=VICE)
    parser.add_argument("--model", choices=("pal", "ntsc", "both"), default="both")
    parser.add_argument("--sniper-phases", type=int, metavar="N",
                        help="test only the sniper sweep at N evenly spaced game-clock phases")
    args = parser.parse_args()
    if args.sniper_phases is not None and not 1 <= args.sniper_phases <= 64:
        parser.error("--sniper-phases must be between 1 and 64")
    sym = labels()
    failures = []
    for model in (("pal", "ntsc") if args.model == "both" else (args.model,)):
        cases = [(name, code, None) for name, code in EFFECTS]
        if args.sniper_phases:
            cases = [(name, code, (i + 0.5) / args.sniper_phases) for name, code in EFFECTS
                     if name == "sniper" for i in range(args.sniper_phases)]
        for name, code, start_phase in cases:
            code = bytes.fromhex(code)
            # A store checkpoint every few dozen cycles can stall the VICE
            # binary monitor. Give each effect a fresh session and retry.
            for attempt in range(3):
                try:
                    with vice(args.vice, model) as m:
                        m.conn.settimeout(20)
                        begin(m, sym)
                        if start_phase is not None:
                            wait_for_phase(m, sym, model, start_phase)
                        if name == "wake up":
                            # A missed row must remain visible after the reveal.
                            for row in range(20):
                                m.write(0x2020 + 320*row, bytes((0xa5,)) * 256)
                        memory = m.read(0, 65536)
                        phase, live, live_irq = c64(m, sym, code, model)
                        reveal = m.read(0, 65536) if name == "wake up" else None
                    break
                except (TimeoutError, OSError) as error:
                    print(f"{model} {name}: VICE monitor stalled ({error}); retrying", flush=True)
            else:
                raise SystemExit(f"VICE monitor stalled three times during {name}")
            zx, zx_irq = spectrum(memory, sym, code, phase)
            # A guest CALL and the SID timer setup have different costs on
            # the two CPUs. Measure that delay separately. Compare the tones
            # at their actual display phase, including subsequent interrupts.
            delay = live[0] - zx[0]
            edge_phase = (phase + delay * 3500000 / 69888) % 1
            zx, zx_irq = spectrum(memory, sym, code, edge_phase, reveal)
            result = compare(zx, zx_irq, live, live_irq)
            if result is None:
                print(f"{model} {name:11} edge counts differ: ZX {[len(t) for t in tones(zx)]} "
                      f"C64 {[len(t) for t in tones(live)]}", flush=True)
                failures.append((model, name))
                continue
            length, pitch, count, hits = result
            short = min((q-p for p, q in zip(zx, zx[1:])))*1e6
            print(f"{model} {name:11} first edge delay {delay*1e6:+.0f} us, "
                  f"phase {phase:.3f}, {count:2} tone(s), {len(zx):4} edges, shortest ZX half wave "
                  f"{short:4.0f} us, worst tone length {length:+.1%}, median half wave error {pitch:+.1%}, "
                  f"half waves skipped near interrupts ZX {hits[0]}, C64 {hits[1]}", flush=True)
            if abs(length) > .06 or abs(pitch) > .06:
                failures.append((model, name))
    if failures:
        raise SystemExit(f"Audio timing differs from the original: {failures}")
    print("all effect timings match the 48K original")

if __name__ == "__main__":
    main()
