"""Start VICE and connect to its binary monitor."""
from contextlib import contextmanager
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import time
import zlib


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"


def program_default(name, variable, root_variable):
    """Choose an executable override, an installation root or a PATH name."""
    override = os.environ.get(variable)
    if override:
        return override
    root = os.environ.get(root_variable)
    if not root:
        return name
    directory = Path(root).resolve()
    filename = f"{name}.exe" if os.name == "nt" else name
    in_bin = directory / "bin" / filename
    in_root = directory / filename
    return str(in_root if not in_bin.is_file() and in_root.is_file() else in_bin)


VICE = program_default("x64sc", "X64SC", "VICE_ROOT")


def find_program(program, variable, root_variable):
    path = shutil.which(str(program))
    if path is None:
        raise SystemExit(f"Executable not found: {program}. Set {variable} to its full path, "
                         f"set {root_variable} to its installation directory, or check PATH.")
    return path


class Monitor:
    def __init__(self, conn, process_id):
        self.conn = conn
        self.process_id = process_id
        self.stream = conn.makefile("rb")
        self.sequence = 0
        self.events = []

    def receive(self):
        header = self.stream.read(12)
        if len(header) != 12:
            raise IOError("VICE disconnected")
        start, version, length, kind, error, seq = struct.unpack("<BBIBBI", header)
        assert (start, version, error) == (2, 2, 0), (kind, error, seq)
        return kind, seq, self.stream.read(length)

    def request(self, kind, data=b""):
        self.sequence += 1
        self.conn.sendall(struct.pack("<BBIIB", 2, 2, len(data), self.sequence, kind) + data)
        while True:
            response, seq, body = self.receive()
            if seq == self.sequence:
                return body
            self.events.append((response, body))

    def checkpoint(self, addr, temporary=False, *, end=None, operation=4, condition=None):
        limit = addr if end is None else end
        result = self.request(0x12, struct.pack("<HHBBBB", addr, limit, 1, 1, operation, temporary))
        check = int.from_bytes(result[:4], "little")
        if condition:
            test = condition.encode("ascii")
            self.request(0x22, struct.pack("<IB", check, len(test)) + test)
        return check

    def resume_to(self, pc=None):
        # A monitor command can arrive on the same cycle as a breakpoint.
        # Consume its pending stop before requesting another resume.
        already_hit = any(k == 0x11 and b[4] for k, b in self.events)
        if not already_hit:
            self.events.clear()
            self.request(0xaa)
        hit = False
        while True:
            if self.events:
                kind, body = self.events.pop(0)
            else:
                kind, _, body = self.receive()
            if kind == 0x11 and body[4]:
                hit = True
            if kind == 0x62 and hit:
                actual = int.from_bytes(body[:2], "little")
                if pc is not None:
                    assert actual == pc, (hex(actual), hex(pc), self.read(9, 2).hex())
                return actual

    def read(self, addr, size):
        return self.request(1, struct.pack("<BHHBH", 0, addr, addr+size-1, 0, 1))[2:]

    def write(self, addr, data):
        self.request(2, struct.pack("<BHHBH", 0, addr, addr+len(data)-1, 0, 1)+data)

    def stick(self, mask):
        self.request(0xa2, struct.pack("<HH", 1, 31 ^ mask))


@contextmanager
def vice(executable, model, disk_image=None):
    program = disk_image or BUILD / "contact-sam-cruise.prg"
    if not program.is_file():
        raise SystemExit(f"C64 image not found: {program}. Build the variant or specify an existing image.")
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    work = BUILD / "work"
    work.mkdir(parents=True, exist_ok=True)
    args = [find_program(executable, "X64SC", "VICE_ROOT"), "-default", "-"+model, "-warp", "+sound", "-silent",
            "-controlport2device", "37",
            "-binarymonitor", "-binarymonitoraddress", f"ip4://127.0.0.1:{port}",
            "-autostartprgmode", "1", "-autostart", str(program)]
    startup = None
    if hasattr(subprocess, "STARTUPINFO"):
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
    with (work / f"vice-{model}-{port}.log").open("w") as log:
        proc = subprocess.Popen(args, stdout=log, stderr=log, startupinfo=startup)
        try:
            for _ in range(100):
                if proc.poll() is not None:
                    raise RuntimeError(f"VICE exited with {proc.returncode}. See {log.name}")
                try:
                    conn = socket.create_connection(("127.0.0.1", port), timeout=0.5)
                    break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError("VICE monitor did not open")
            with conn:
                conn.settimeout(60)
                yield Monitor(conn, proc.pid)
        finally:
            if proc.poll() is None:
                proc.terminate()
            proc.wait(5)


def labels(path=None):
    path = path or BUILD / "contact-sam-cruise.lbl"
    if not path.is_file():
        raise SystemExit(f"VICE label file not found: {path}. Use the labels from the same build as the image.")
    return {n: int(a, 16) for a, n in re.findall(r"al ([0-9A-Fa-f]+) \.(\w+)",
            path.read_text(encoding="ascii"))}


def indexed_display(m):
    display = m.request(0x84, bytes((1, 0)))
    fields, stride, height, x, y, width, rows = struct.unpack_from("<I6H", display)
    size, = struct.unpack_from("<I", display, 4+fields)
    pixels = display[8+fields:]
    assert size == stride*height
    return pixels, stride, height, x, y, width, rows


def screenshot(m, filename):
    """Write VICE's actual VIC-II output as an indexed PNG."""
    pixels, stride, _, x, y, width, rows = indexed_display(m)
    # VICE omits the final four debug-border pixels from its packet.
    assert (y+rows-1)*stride + x+width <= len(pixels)
    lines = [pixels[i*stride+x:i*stride+x+width] for i in range(y, y+rows)]
    write_png(m, filename, lines)

def write_png(m, filename, lines):
    width, rows = len(lines[0]), len(lines)
    entries = m.request(0x91, b"\x01")
    palette = b"".join(entries[i+1:i+4] for i in range(2, len(entries), 4))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag+data))

    scanlines = b"".join(b"\0" + line for line in lines)
    filename.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB",
                         width, rows, 8, 3, 0, 0, 0)) + chunk(b"PLTE", palette)
                         + chunk(b"IDAT", zlib.compress(scanlines)) + chunk(b"IEND", b""))
