"""Reference checks for the C64 startup, controls and the four camera moves."""
import argparse
from bisect import bisect_left, bisect_right
from math import ceil
from pathlib import Path
import struct
from statistics import median

from skoolkit import CCMIOSimulator, CSimulator, ROM48
from skoolkit.simutils import SP, T
from build import HOOKS, colors, guest_storage
from monitor import BUILD, VICE, indexed_display, labels, screenshot, vice, write_png

FRAME = 61483
SAM = 58880
CAMERA = 32766

def pristine():
    source = BUILD / "work/spectrum.bin"
    if not source.is_file():
        source = BUILD / "work/stripes/spectrum.bin"
        if not source.is_file():
            raise SystemExit("Spectrum image missing. Run python tools/build.py first.")
    image = bytearray(20637) + source.read_bytes()
    image[:16384] = Path(ROM48).read_bytes()
    return image

class Controls:
    bits = 0

    def read_port(self, registers, port):
        return self.bits if port & 255 == 31 else 255

def cpu_clock(m):
    packet = m.request(0x86, struct.pack("<BI", 0, 1))
    offset = 7
    for _ in range(int.from_bytes(packet[5:7], "little")):
        offset += 1 + packet[offset]
    return struct.unpack_from("<Q", packet, offset)[0]

def original_state(live, sym):
    """Reconstruct guest RAM at a checkpoint, retaining self-modified operands."""
    original = pristine()
    image = original.copy()
    image[0x5800:] = live[0x5800:]
    for address in HOOKS:
        image[address:address+2] = original[address:address+2]
    for start, size in guest_storage(sym):
        image[start:start+size] = original[start:start+size]
    image[65530:] = live[sym["vector_tail"]:sym["vector_tail"]+6]
    for row in range(24):
        for col in range(32):
            src = 0x2020 + row*320 + col*8
            dst = 0x4000 + (row//8)*2048 + (row%8)*32 + col
            image[dst:dst+2048:256] = live[src:src+8]
    return image

def check_screen(zx, live, rows=24):
    for y in range(rows):
        for x in range(32):
            src = 0x4000 + 2048*(y//8) + 32*(y%8) + x
            dst = 0x2020 + 320*y + 8*x
            expected = bytes(zx[src:src+2048:256])
            assert expected == live[dst:dst+8], ("pixels",x,y,expected.hex(),live[dst:dst+8].hex())
            attr = 22528 + 32*y + x
            assert zx[attr] == live[attr], ("attribute",x,y)
            assert colors(zx[attr]) == live[0x404+40*y+x], ("colour",x,y)

def begin(m, sym, demo=False):
    m.stick(0)
    m.checkpoint(sym["title_wait"], True)
    m.resume_to(sym["title_wait"])
    assert m.read(sym["pal_machine"], 1) == m.read(0x02a6, 1), "incorrect video standard after unpack"
    m.checkpoint(sym["enter_game"], True)
    if demo:
        m.write(sym["key_event"], bytes((129,)))
    else:
        m.stick(16)
    m.resume_to(sym["enter_game"])
    m.stick(0)
    # An older camera build swaps part of the interpreter during a pan.
    # Its opcode trap is valid only while the interpreter owns that memory.
    trap = sym["unsupported"]
    condition = None
    if "pan_swap" in sym and sym["pan_begin"] <= trap < sym["pan_end"]:
        condition = f"@ram:${sym['decode_finish']:04x} != $60"
    m.checkpoint(trap, condition=condition)
    if "walk_flush" in sym:
        # A hardware stack growing into the refresh arrays would first
        # push through $0180. No refresh data is written at this address.
        m.checkpoint(0x0180, operation=2)
    checkpoint = m.checkpoint(sym["frame_start"])
    m.resume_to(sym["frame_start"])
    assert m.read(32750,1)[0] == int(not demo)
    return checkpoint

def original_opening(demo):
    image = pristine()
    image[65530] = 107
    cpu = CCMIOSimulator(image, {"SP":23898}, {"iff":1,"im":1})
    cpu.set_tracer(Controls())
    cpu.run(61671 if demo else 61674, FRAME, True)
    return cpu

def opening(m, sym, demo):
    live = m.read(0,65536)
    cpu = original_opening(demo)
    zx = cpu.memory
    assert live[CAMERA:CAMERA+2] == zx[CAMERA:CAMERA+2]
    assert live[SAM+2:SAM+5] == zx[SAM+2:SAM+5]
    # The timed intro can end on a different stride. Repaint the playfield
    # for the live actors. Keep the status panel from the independent boot,
    # apart from proximity-sensitive icon colours, which follow Sam and FRAMES.
    zx[SAM:SAM+5] = live[SAM:SAM+5]
    zx[0x7f10:0x7f60] = bytes([255])*80
    for y in (21,22):
        for x in range(8,20):
            addr = 22528+32*y+x
            assert live[addr] in (48,50,54,6,2), ("icon",x,y,live[addr])
            zx[addr] = live[addr]
    cpu.registers[SP] = 0x5d40
    zx[0x5d40:0x5d42] = bytes(2)
    cpu.run(60032,0)
    check_screen(zx,live)
    screenshot(m,BUILD / ("demo.png" if demo else "contact-sam-cruise.png"))

def route(m, sym, model, raster=False):
    live = m.read(0,65536)
    zx = CCMIOSimulator(original_state(live,sym), {"SP":23898}, {"iff":1,"im":1})
    controls = Controls()
    zx.set_tracer(controls)
    clocks = [cpu_clock(m)]
    previous = live[CAMERA:CAMERA+2]
    cut_points = ((sym["cut_attrs"], sym["cut_mask"], sym["cut_resume"], sym.get("pan_display"))
                  if "cut_resume" in sym else ())
    trace = RasterTrace(m, model, cut_points=cut_points) if raster else None
    if trace:
        trace.state(clocks[0], live)
    ordinary, scrolling = [], []
    zx_ordinary, zx_scrolling = [], []
    ordinary_ids = []
    for pins, bits, ticks in ((8,1,72),(4,2,72)):
        m.stick(pins)
        controls.bits = bits
        for i in range(ticks):
            if trace:
                trace.run_to(sym["frame_start"])
            else:
                m.resume_to(sym["frame_start"])
            clocks.append(cpu_clock(m))
            start_t = zx.registers[T]
            zx.run(FRAME,FRAME,True)
            assert m.read(SAM,3) == bytes(zx.memory[SAM:SAM+3]), (model,i,"Sam")
            position = m.read(CAMERA,2)
            assert position == bytes(zx.memory[CAMERA:CAMERA+2]), (model,i,"camera")
            if trace:
                trace.state(clocks[-1], m.read(0,65536))
            (ordinary if position==previous else scrolling).append(clocks[-1]-clocks[-2])
            (zx_ordinary if position==previous else zx_scrolling).append(zx.registers[T]-start_t)
            if position == previous:
                ordinary_ids.append(len(clocks)-1)
            previous = position
    clock = {"pal":985248,"ntsc":1022727}[model]
    elapsed = (clocks[-1]-clocks[0])/clock
    times = [(b-a)*1000/clock for a,b in zip(clocks,clocks[1:])]
    print(f"{model} 144 matched joystick updates: C64 {elapsed:.3f}s, ZX {zx.registers[T]/3500000:.3f}s "
          f"(C64 median {median(times):.1f} ms, max {max(times):.1f} ms)",flush=True)
    print(f"  {len(ordinary)} ordinary: {sum(ordinary)/clock:.3f}s vs ZX {sum(zx_ordinary)/3500000:.3f}s; "
          f"{len(scrolling)} scrolling: {sum(scrolling)/clock:.3f}s vs ZX {sum(zx_scrolling)/3500000:.3f}s",flush=True)
    print(f"  ordinary median: {median(ordinary)*1000/clock:.1f} ms vs ZX {median(zx_ordinary)/3500:.1f} ms; "
          f"{sum(c*50 <= clock for c in ordinary)}/{len(ordinary)} at or below 20 ms",flush=True)
    ordered = sorted(ordinary)
    slowest = ordinary.index(ordered[-1])
    print(f"  ordinary p95/max: {ordered[ceil(.95*len(ordered))-1]*1000/clock:.1f}/"
          f"{ordered[-1]*1000/clock:.1f} ms; {sum(c*25>clock for c in ordinary)} over 40 ms, "
          f"{sum(c*10>clock for c in ordinary)} over 100 ms (slowest update {ordinary_ids[slowest]}, "
          f"ZX {zx_ordinary[slowest]/3500:.1f} ms)", flush=True)
    if trace:
        trace.close()
        trace.check_walking(require_whole_sam="walk_flush" in sym)
        if cut_points:
            assert trace.moves, "joystick route did not cross a camera boundary"
            for start, old, end, new, pan in trace.moves:
                if pan is None:
                    trace.check_cut(start, old, end, new)
                else:
                    trace.check_pan(start, old, end, new, pan)
    m.stick(0)

def raster_line(m):
    """Current VIC-II raster line from the monitor's LIN register."""
    names = m.request(0x83, b"\x00")
    offset, ids = 2, {}
    for _ in range(struct.unpack_from("<H", names)[0]):
        size, rid, _, length = names[offset:offset+4]
        ids[names[offset+4:offset+4+length].decode()] = rid
        offset += size + 1
    values = m.request(0x31, b"\x00")
    for offset in range(2, 2+4*struct.unpack_from("<H", values)[0], 4):
        if values[offset+1] == ids["LIN"]:
            return struct.unpack_from("<H", values, offset+2)[0]
    raise KeyError("LIN")

def scanlines(live):
    lines = []
    for line in range(192):
        row, bitrow = divmod(line,8)
        pixels = bytearray()
        for x in range(32):
            attr = live[0x404+40*row+x]
            bits = live[0x2020+320*row+8*x+bitrow]
            pixels.extend(attr>>4 if bits & (128>>b) else attr&15 for b in range(8))
        lines.append(bytes(pixels))
    return lines

def drawn(m, margins=None):
    pixels,stride,height,x,y,_,_ = indexed_display(m)
    x += 32
    y -= int(height==312)
    if margins is not None:
        for row in range(160):
            pos = (y+row)*stride+x
            margins.extend(pixels[pos-8:pos] + pixels[pos+256:pos+264])
    return [pixels[(y+i)*stride+x:(y+i)*stride+x+256] for i in range(192)]


class RasterTrace:
    """Compare the actual scanned pixels against the states live during their scanout."""
    def __init__(self, m, model, row_probes=None, cut_points=(), band_probe=None):
        self.m = m
        self.model = model
        self.line_cycles = 63 if model == "pal" else 65
        self.period = self.line_cycles * (312 if model == "pal" else 263)
        # Line 248 is below the city and HUD. All their pixels are available.
        # Include both camera copiers in zero page and in the lower half of the
        # stack page, and the 6510 code in reclaimed guest routines up to $f483.
        self.beam = m.checkpoint(0x0080, end=0xffff, condition="(RL == $f8) && (CY < 12)")
        self.times, self.scenes, self.positions, self.frames = [], [], [], []
        self.sam = []
        self.margins = {}
        self.last = None
        self.row_probes = row_probes
        self.row_start = None
        self.row_times = []
        self.row_checks = [m.checkpoint(pc) for pc in row_probes] if row_probes else []
        self.cut_points = cut_points
        self.cut_checks = [m.checkpoint(pc) for pc in cut_points if pc is not None]
        self.band_probe = band_probe
        self.band_check = m.checkpoint(band_probe[0]) if band_probe else None
        self.band_margins = []
        self.old_view = None
        self.mask_started = False
        self.moves = []

    def close(self):
        checks = [self.beam, *self.row_checks, *self.cut_checks]
        if self.band_check is not None:
            checks.append(self.band_check)
        for check in checks:
            self.m.request(0x13, struct.pack("<I", check))

    def state(self, when, live):
        self.times.append(when)
        self.scenes.append(scanlines(live))
        self.positions.append(live[CAMERA:CAMERA+2])
        self.sam.append((live[SAM+1]-live[CAMERA],live[SAM+2]-live[CAMERA+1]))

    def run_to(self, target):
        while True:
            pc = self.m.resume_to()
            if pc == target:
                return
            if self.band_probe and pc == self.band_probe[0]:
                band = self.m.read(self.band_probe[1], 1)[0]
                lines = self.period // self.line_cycles
                margin = (50 + 16*band - raster_line(self.m)) % lines
                self.band_margins.append(margin)
                continue
            if pc in self.cut_points:
                if pc == self.cut_points[0]:
                    live = self.m.read(0,65536)
                    self.old_view = (cpu_clock(self.m), scanlines(live))
                    self.old_x = live[CAMERA]
                    self.mask_started = False
                    self.pan = None
                elif pc == self.cut_points[1]:
                    self.mask_started = True
                elif pc == self.cut_points[3]:
                    self.mask_started = True
                    self.pan = (self.m.read(CAMERA, 1)[0] - self.old_x) % 256 == 8
                elif self.mask_started:
                    self.moves.append((*self.old_view, cpu_clock(self.m), scanlines(self.m.read(0,65536)), self.pan))
                    self.mask_started = False
                continue
            if self.row_probes and pc in self.row_probes:
                if pc == self.row_probes[0]:
                    self.row_start = cpu_clock(self.m)
                else:
                    assert self.row_start is not None
                    self.row_times.append(cpu_clock(self.m) - self.row_start)
                    self.row_start = None
                continue
            assert raster_line(self.m) == 248, ("unexpected raster stop", hex(pc))
            now = cpu_clock(self.m)
            if self.last is not None:
                delta = now - self.last
                if delta < self.line_cycles:
                    continue
                assert abs(delta-self.period) < self.line_cycles, ("missing video frame", delta, self.period)
            self.last = now
            # The first bitmap scanline is raster 51. The checkpoint can be
            # a few cycles into line 248. bands() allows a line of margin.
            top = now - (248-51)*self.line_cycles
            self.margins[top] = bytearray()
            self.frames.append((top, drawn(self.m, self.margins[top])))
            if target is None:
                return

    def bands(self, top, height):
        """Yield the captured 8-line bands and their bracketing game states."""
        for y in range(0, height, 8):
            first = top + (y-1)*self.line_cycles
            last = top + (y+8)*self.line_cycles
            if self.times[0] <= first and last < self.times[-1]:
                lo = bisect_right(self.times, first)-1
                hi = bisect_left(self.times, last)
                yield y, lo, hi

    def check_stripes(self, moving_left):
        # All 160 city scanlines must share exactly the same cut. Include
        # the four HUD rows in every comparison with the displayed frame.
        widths = (0, 7, 14, 21, 28, 32) if self.model == "pal" else (0, 6, 12, 18, 24, 29, 32)
        cuts = [8*(width if moving_left else 32-width) for width in widths]
        expected = []
        for old, new in zip(self.scenes, self.scenes[1:]):
            assert old[160:] == new[160:]
            left, right = (new, old) if moving_left else (old, new)
            expected.append([b"".join(a[:cut] + b[cut:] for a, b in zip(left, right)) for cut in cuts])
        tested = mixed = 0
        previous = None
        for top, frame in self.frames:
            if top < self.times[0] or top + 192*self.line_cycles > self.times[-1]:
                continue
            lo = bisect_right(self.times, top) - 1
            hi = bisect_left(self.times, top + 192*self.line_cycles)
            seen = b"".join(frame)
            candidates = expected[lo:hi]
            progress = {i*(len(cuts)-1) + k for i, options in enumerate(candidates, lo)
                        for k, image in enumerate(options) if seen == image}
            if not progress:
                matches = [[cut for cut, image in enumerate(candidates[0])
                            if image[y*256:(y+1)*256] == frame[y]] for y in range(192)]
                raise AssertionError((self.model, "split stripe, wrong colour or HUD",
                                      tested, lo, hi, [(y, m) for y, m in enumerate(matches)
                                                       if y == 0 or m != matches[y-1]]))
            if previous is not None:
                progress &= previous | {p+1 for p in previous}
                assert progress, (self.model, "reversed or skipped stripe", tested)
            previous = progress
            mixed += not any(seen in (options[0], options[-1]) for options in candidates)
            tested += 1
        assert tested and mixed, "no visible stripe transition was captured"
        print(f"{self.model} horizontal stripes: {tested} frames, {mixed} with one vertical seam, "
              "all city and HUD pixels matched", flush=True)

    def check_pan(self, start, old, end, new, left):
        first, last = (old, new) if left else (new, old)
        panorama = [a+b[-64:] for a, b in zip(first[:160], last[:160])]
        bands = []
        for row in range(0, 160, 16):
            pictures = {}
            for step in range(65):
                offset = step if left else 64-step
                band = b"".join(line[offset:offset+256] for line in panorama[row:row+16])
                pictures.setdefault(band, set()).add(step)
            bands.append(pictures)
        positions = [{0} for _ in bands]
        midpoints = set(range(4, 64, 8))
        tested = 0
        for top, lines in self.frames:
            if top < start or top + 192*self.line_cycles > end:
                continue
            assert lines[160:] == old[160:], ("pan moved the HUD", tested)
            margin = self.margins[top]
            assert not any(margin), (self.model, "camera margin", tested,
                                     [(i//16, i%16, c) for i, c in enumerate(margin) if c][:16])
            matches = []
            for index, pictures in enumerate(bands):
                seen = b"".join(lines[index*16:index*16+16])
                valid = pictures.get(seen, set())
                valid = {s for s in valid if any(s-k in positions[index] for k in range(6))}
                if not valid:
                    row = index*16
                    offsets = [[s for s in range(65) if line[(s if left else 64-s):][:256] == lines[row+i]]
                               for i, line in enumerate(panorama[row:row+16])]
                    raise AssertionError((self.model, "pan pixels or step size", tested, index,
                                          positions[index], offsets))
                matches.append(valid)
            common = {p for p in range(65) if all(p in opts or p+1 in opts for opts in matches)}
            assert common, (self.model, "camera bands more than one pixel apart", tested)
            positions = [opts & (common | {p+1 for p in common}) for opts in matches]
            midpoints.difference_update(set.intersection(*positions))
            tested += 1
        if self.band_probe:
            assert len(self.band_margins) == 80, "missing band publications"
            margin = min(self.band_margins)
            assert margin >= 2, (self.model, "band too close to raster fetch", margin)
            print(f"{self.model} shortest band margin: {margin} raster lines", flush=True)
        assert not midpoints, (self.model, "missing four pixel midpoints", midpoints)
        assert tested and all(64 in opts for opts in positions), "pan missed its destination"
        print(f"{self.model} smooth pan: {tested} frames, city, margins and HUD matched", flush=True)

    def check_cut(self, start, old, end, new):
        assert old[160:] == new[160:]
        pictures = [b"".join(old[:160]), bytes(256*160), b"".join(new[:160])]
        order = list(dict.fromkeys(pictures))
        expected = [order.index(picture) for picture in pictures]
        # A dark room can look identical to the mask. Only transitions
        # visible in the reference frames can be required on the display.
        expected = [phase for i, phase in enumerate(expected) if not i or phase != expected[i-1]]
        observed = []
        tested = masked = 0
        for top, lines in self.frames:
            if top < start or top + 192*self.line_cycles > end:
                continue
            assert lines[160:] == old[160:], (self.model, "HUD changed during camera cut")
            city = b"".join(lines[:160])
            assert city in order, (self.model, "camera displayed a partial frame", tested)
            phase = order.index(city)
            if not observed or phase != observed[-1]:
                observed.append(phase)
            masked += city == pictures[1]
            tested += 1
        assert observed == expected, (observed, expected)
        print(f"{self.model} camera cut: {tested} scanned frames, {masked} masked, "
              "zero mixed frames, HUD matched", flush=True)

    def check_camera(self, save_example=True):
        tested = mixed = torn_lines = torn_rows = hud_errors = 0
        worst_seams = crowded_frames = 0
        example = None
        for top, frame in self.frames:
            valid = []
            split = False
            seams = {}
            for y, lo, hi in self.bands(top, 192):
                band = frame[y:y+8]
                candidates = [scene[y:y+8] for scene in self.scenes[lo:hi+1]]
                if y >= 160:
                    hud_errors += int(band not in candidates)
                    continue
                valid.append(y)
                if band not in candidates:
                    split = True
                    torn_rows += 1
                    torn_lines += sum(not any(line == old[j] for old in candidates)
                                      for j,line in enumerate(band))
                else:
                    # A plain row may fit either position. Count only changes
                    # of position that the displayed pixels actually require.
                    seams = {lo+i: min((n + (prev != lo+i) for prev,n in seams.items()), default=0)
                             for i, candidate in enumerate(candidates) if candidate == band}
            if not valid:
                continue
            tested += 1
            if split:
                continue
            minimum = min(seams.values())
            worst_seams = max(worst_seams, minimum)
            crowded_frames += minimum > 2
            lo = max(0, bisect_right(self.times, top-self.line_cycles)-1)
            hi = min(len(self.times)-1, bisect_left(self.times, top+160*self.line_cycles))
            if not any(all(frame[y:y+8] == scene[y:y+8] for y in valid) for scene in self.scenes[lo:hi+1]):
                mixed += 1
                if example is None and len(valid) == 20:
                    example = frame
        assert tested, "no scrolling video frames examined"
        print(f"{self.model} scrolling: {tested} video frames, {mixed} mixed camera frames, "
              f"{torn_rows} split 8-line rows, {torn_lines} torn scanlines, {hud_errors} wrong HUD rows", flush=True)
        print(f"  maximum visible camera seams {worst_seams}; {crowded_frames} frames with more than two", flush=True)
        if example and save_example and not self.row_probes:
            write_png(self.m, BUILD/f"raster-{self.model}.png", example)
        assert not (torn_rows or hud_errors), "camera transfer split a row or changed the HUD"
        assert worst_seams <= 2, "camera displayed more than two boundaries between positions"

    def check_walking(self, require_whole_sam=False):
        tested = examined_cells = torn_cells = changed_cells = split_sam_frames = 0
        saved_example = False
        for frame_index, (top, frame) in enumerate(self.frames):
            initial_count = examined_cells
            sam_versions = {}
            for y, lo, hi in self.bands(top, 160):
                if hi != lo+1 or self.positions[lo] != self.positions[hi]:
                    # Only compare cells scanned entirely inside one ordinary
                    # update. Camera moves have intermediate positions of their own.
                    continue
                examined_cells += 32
                before = self.scenes[lo][y:y+8]
                after = self.scenes[hi][y:y+8]
                drawn_band = frame[y:y+8]
                if before == drawn_band == after:
                    continue
                for x in range(0, 256, 8):
                    old = [line[x:x+8] for line in before]
                    new = [line[x:x+8] for line in after]
                    seen = [line[x:x+8] for line in drawn_band]
                    changed_cells += int(old != new)
                    if seen != old and seen != new:
                        torn_cells += 1
                        if not saved_example:
                            self.save_cell(frame_index, hi, x//8, y//8, old, seen, new)
                            saved_example = True
                    elif old != new and any(sx <= x//8 < sx+5 and sy <= y//8 < sy+5
                                            for sx,sy in self.sam[lo:hi+1]):
                        # Another actor may overlap Sam's screen area.
                        sam_versions.setdefault(hi, set()).add(seen == new)
            tested += examined_cells != initial_count
            split_sam_frames += any(len(versions) == 2 for versions in sam_versions.values())
        assert tested, "no ordinary video frames examined"
        print(f"{self.model} walking: {tested} video frames with ordinary playfield rows, "
              f"{torn_cells}/{examined_cells} cell observations matched neither complete update "
              f"({changed_cells} changed). {split_sam_frames} frames had both old and new cells "
              f"near Sam within one update", flush=True)
        assert torn_cells == 0, "ordinary bitmap commit split a cell"
        if require_whole_sam:
            assert not split_sam_frames, "neighbouring tiles at Sam show different animation phases"

    def save_cell(self, frame_index, update, x, y, old, seen, new):
        rows = []
        for a,b,c in zip(old,seen,new):
            if a == b == c:
                rows.append("=")
            elif a == b:
                rows.append("O")
            elif b == c:
                rows.append("N")
            else:
                rows.append("?")
        print(f"  {self.model} video frame {frame_index}, update {update}, tile ({x},{y}): "
              f"{''.join(rows)} (old/new scanlines)", flush=True)
        # Integer zoom, old / actually displayed / new, with a pixel gutter.
        strips = [a + bytes((12,)) + b + bytes((12,)) + c for a,b,c in zip(old,seen,new)]
        zoom = [bytes(p for p in row for _ in range(6)) for row in strips for _ in range(6)]
        write_png(self.m, BUILD/f"raster-cell-{self.model}.png", zoom)

def camera(m, sym, model, raster=False, stress=False):
    # Invoke the original camera entry with a synthetic return to the main
    # loop. Actors remain fixed, so every intermediate step has an oracle.
    cut = "cut_install_edge" in sym
    probes = (sym["row_check"], sym["row_published"]) if stress and not cut else None
    stripes = "stripe_pass" in sym
    per_move = cut or stripes
    trace = RasterTrace(m, model, probes) if (raster or stress) and not per_move else None
    run_to = trace.run_to if trace else m.resume_to
    if trace:
        trace.state(cpu_clock(m), m.read(0,65536))
    for addr, inner, label, steps in ((59406,59418,"left_step",8),(59461,59473,"right_step",8),
                                      (59516,59528,"up_step",6),(59575,59587,"down_step",6)):
        horizontal = label in ("left_step", "right_step")
        if per_move and (raster or stress):
            probe = ((sym["pan_publish"], sym["pan_band"])
                     if stress and horizontal and "pan_publish" in sym else None)
            trace = RasterTrace(m, model, None if horizontal else probes, band_probe=probe)
            trace.state(cpu_clock(m), m.read(0,65536))
            run_to = trace.run_to
        m.write(61440,b"\xc3"+struct.pack("<H",addr))
        m.write(sym["frame_call"]+1,bytes((FRAME & 255,)))
        watch = m.checkpoint(sym[label])
        run_to(sym[label])
        live = m.read(0,65536)
        image = original_state(live,sym)
        before_cut = scanlines(live) if cut else None
        if cut:
            borrowed = [(sym["sound_period_lo"], 512), (sym["sound_contended_lo"], 512),
                        (sym["font"], 256)]
            if horizontal and "pan_begin" in sym:
                borrowed.extend((0x2018 + 320*row, 8) for row in range(20))
                borrowed.append((sym["vic_attr"], 256))
            saved = [live[base:base+size] for base, size in borrowed]
        # Mirror the stack created by the camera entry, including its
        # saved registers. The first breakpoint is immediately before
        # either machine has moved a row.
        sp = int.from_bytes(live[11:13],"little")
        zx = CSimulator(image,{"SP":sp})
        start = cpu_clock(m)
        timings = []
        for i in range(steps):
            last = i == steps-1
            target = sym["frame_start"] if last else sym[label]
            if last and horizontal and ("pan_swap" in sym or "pan_patch_rows" in sym):
                # Compare borrowed memory at the entry and exit of the presenter.
                if "pan_swap" in sym:
                    ranges = [(sym["pan_begin"], sym["pan_end"] - sym["pan_begin"])]
                    end_of_pan = sym["cut_cleanup"]
                else:
                    ranges = [(sym[name], 512) for name in ("sound_period_lo", "sound_contended_lo")]
                    end_of_pan = sym["cut_restore_font"]
                entry = m.checkpoint(sym["pan_display"])
                exit_point = m.checkpoint(end_of_pan)
                run_to(sym["pan_display"])
                saved_ranges = [m.read(base, size) for base, size in ranges]
                run_to(end_of_pan)
                assert saved_ranges == [m.read(base, size) for base, size in ranges], "camera damaged resident tables"
                for mark in (entry, exit_point):
                    m.request(0x13, struct.pack("<I", mark))
            run_to(target)
            now = cpu_clock(m)
            timings.append((now-start)*1000/{"pal":985248,"ntsc":1022727}[model])
            start = now
            zx.run(inner,FRAME if last else inner)
            live = m.read(0,65536)
            assert live[CAMERA:CAMERA+2] == bytes(zx.memory[CAMERA:CAMERA+2])
            try:
                if not cut or last:
                    check_screen(zx.memory,live)
                    if cut:
                        assert saved == [live[base:base+size] for base, size in borrowed], "camera scratch not restored"
                else:
                    # The next edge is prepared in scratch. The displayed bitmap
                    # and its VIC colours must still hold the start of the move.
                    assert scanlines(live) == before_cut
            except AssertionError as error:
                raise AssertionError((label,i+1,live[CAMERA:CAMERA+2].hex(),*error.args)) from error
            if trace and (not cut or last):
                trace.state(cpu_clock(m), live)
        m.request(0x13,struct.pack("<I",watch))
        print(f"{model} {label}: {sum(timings):.1f} ms for {steps} steps, "
              f"first {timings[0]:.1f}, median {median(timings):.1f}, max {max(timings):.1f} ms", flush=True)
        if trace and (per_move or label == "down_step"):
            finish_camera_trace(m, sym, trace)
            if cut and horizontal and "pan_begin" in sym:
                trace.check_pan(trace.times[0], trace.scenes[0], trace.times[-1], trace.scenes[-1], label == "left_step")
            elif cut:
                trace.check_cut(trace.times[0], trace.scenes[0], trace.times[-1], trace.scenes[-1])
            elif stripes and horizontal:
                trace.check_stripes(label == "left_step")
            else:
                trace.check_camera(save_example=not stripes)
                if stress:
                    assert len(trace.row_times) == (steps if stripes else 28)*20, "missing camera row timings"
                    longest = max(trace.row_times)
                    print(f"{model} longest visible row transfer: {longest} cycles, "
                          f"{longest/trace.line_cycles:.1f} raster lines", flush=True)
                    assert longest < 72*trace.line_cycles, "camera transfer exhausted the raster guard"

def finish_camera_trace(m, sym, trace):
    # Freeze the guest until the final step has been scanned out, then
    # return through the same guest stack as the camera fixture.
    m.write(61440,b"\xc3\x00\xf0")  # JP 61440
    while not trace.frames or trace.frames[-1][0] < trace.times[-1]:
        trace.run_to(None)
    trace.state(cpu_clock(m), m.read(0,65536))
    trace.close()
    m.write(61440,b"\xc9")
    m.resume_to(sym["frame_start"])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vice",default=VICE)
    parser.add_argument("--model",choices=("pal","ntsc","both"),default="both")
    parser.add_argument("--disk", type=Path, help="boot a D64 with its adjacent .lbl file")
    parser.add_argument("--raster",action="store_true")
    args=parser.parse_args()
    sym = labels(args.disk.with_suffix(".lbl") if args.disk else None)
    for model in (("pal","ntsc") if args.model=="both" else (args.model,)):
        with vice(args.vice,model,args.disk) as m:
            begin(m,sym)
            opening(m,sym,False)
            route(m,sym,model,args.raster)
            camera(m,sym,model,args.raster)
            print(model,"four camera moves passed, including pixels, colours and HUD",flush=True)
        with vice(args.vice,model,args.disk) as m:
            begin(m,sym,True)
            opening(m,sym,True)
            print(model,"demo passed",flush=True)

if __name__=="__main__":
    main()
