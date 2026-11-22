"""Record one horizontal camera move as an animated PNG.

The joystick route from Sam's office walks right until the camera moves.
Every video frame is read from VICE when the beam reaches line 248, below
the city and the status panel. Playback uses the video model's frame rate.
"""
import argparse
from collections import deque
from pathlib import Path
import struct
import zlib

from monitor import BUILD, labels, vice
from vice_test import CAMERA, VICE, begin, cpu_clock, drawn


def write_apng(m, filename, frames, fps):
    entries = m.request(0x91, b"\x01")
    palette = b"".join(entries[i+1:i+4] for i in range(2, len(entries), 4))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag+data))

    width, height = len(frames[0][0]), len(frames[0])
    out = [b"\x89PNG\r\n\x1a\n",
           chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0)),
           chunk(b"PLTE", palette),
           chunk(b"acTL", struct.pack(">II", len(frames), 0))]
    sequence = 0
    for index, lines in enumerate(frames):
        out.append(chunk(b"fcTL", struct.pack(">IIIIIHHBB", sequence, width, height, 0, 0, 1, fps, 0, 0)))
        sequence += 1
        data = zlib.compress(b"".join(b"\0" + bytes(line) for line in lines), 9)
        if index == 0:
            out.append(chunk(b"IDAT", data))
        else:
            out.append(chunk(b"fdAT", struct.pack(">I", sequence) + data))
            sequence += 1
    out.append(chunk(b"IEND", b""))
    filename.write_bytes(b"".join(out))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vice", default=VICE)
    parser.add_argument("--model", choices=("pal", "ntsc"), default="pal")
    parser.add_argument("--before", type=int, default=10, help="frames before the move")
    parser.add_argument("--after", type=int, default=12, help="frames after the move")
    parser.add_argument("--prg", type=Path, help="record another build, such as the stripes variant")
    parser.add_argument("--out", default=None)
    args = parser.parse_args()
    if args.before < 0 or args.after < 1:
        parser.error("Use --before >= 0 and --after >= 1.")
    sym = labels(args.prg.with_suffix(".lbl") if args.prg else None)
    fps = 50 if args.model == "pal" else 60
    with vice(args.vice, args.model, args.prg) as m:
        begin(m, sym)
        m.stick(8)
        beam = m.checkpoint(0x0080, end=0xffff, condition="(RL == $f8) && (CY < 12)")
        entries = {sym["left_step"], sym["right_step"]}
        for entry in entries:
            m.checkpoint(entry, temporary=True)
        before = deque(maxlen=args.before)
        during, after = [], []
        start = m.read(CAMERA, 2)
        moving = finished = False
        last = None
        line_cycles = 63 if args.model == "pal" else 65
        while len(after) < args.after:
            pc = m.resume_to()
            if pc in entries:
                moving = True
                continue
            if pc == sym["frame_start"]:
                if moving and m.read(CAMERA, 2) != start:
                    finished = True
                continue
            # The checkpoint can stop at several instructions in the first
            # cycles of line 248. Keep one capture per video frame.
            now = cpu_clock(m)
            if last is not None and now - last < line_cycles:
                continue
            last = now
            frames = after if finished else during if moving else before
            frames.append(drawn(m))
        m.request(0x13, struct.pack("<I", beam))
        m.stick(0)
        kind = "stripes" if "stripe_pass" in sym else "smooth"
        out = BUILD / (args.out or f"camera-{kind}-{args.model}.png")
        write_apng(m, out, list(before) + during + after, fps)
        print(f"{out.name}: {len(during)} frames during the move, {fps} Hz")


if __name__ == "__main__":
    main()
