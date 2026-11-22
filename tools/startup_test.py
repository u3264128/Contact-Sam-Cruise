"""Compare the packed startup data with the original Spectrum loader."""
import argparse
from pathlib import Path
import re
from skoolkit import CCMIOSimulator
from skoolkit.skool2bin import BinWriter
from build import WORK, read_reference
from vice_test import Controls, pristine

def verify(source=None):
    image = pristine()
    listing = (read_reference("start.skool").decode("utf-8") if source is None
               else source.read_text(encoding="utf-8"))
    # Give each loader section its original load address.
    listing = re.sub(r"(?m)^@org\n","",listing)
    listing = re.sub(r"(?m)^([bc])(\d+) ",r"@org=\2\n\1\2 ",listing)
    overlay_path = WORK / "startup-overlay.skool"
    overlay_path.write_text(listing, encoding="utf-8")
    overlay = BinWriter(str(overlay_path))
    expected = image.copy()
    # Restore the staging data so the original loader can move it
    # from screen memory to its final addresses.
    for start,size in ((32972,13),(33224,34),(55040,126),(55296,126),(55552,126),
                       (55808,126),(56064,72),(56576,100)):
        offset = int(overlay.address_map[start])
        image[start:start+size] = overlay.snapshot[offset:offset+size]
    image[32256:32768] = expected[32768:33280]
    for row,dst in ((16384,23904),(20704,24160)):
        for line in range(8):
            image[row+line*256:row+line*256+32] = expected[dst+32*line:dst+32*line+32]
    image[23904:24416] = bytes(512)
    sim=CCMIOSimulator(image)
    sim.set_tracer(Controls())
    sim.run(33224,61671,True)
    ram=sim.memory
    assert ram[23904:24416]==expected[23904:24416]
    assert ram[32768:33280]==expected[32768:33280]
    # Compare the static logo and the original panel colours.
    for line in range(24):
        addr=0x5000+32*(5+line//8)+(line%8)*256
        assert ram[addr:addr+8]==expected[addr:addr+8], (line,bytes(ram[addr:addr+8]),expected[addr:addr+8])
    assert ram[23168:23200]==bytes([15])*32
    for row in range(3):
        assert ram[23200+32*row:23232+32*row]==bytes([23]*8+[54]*12+[32]*9+[23]*3)
    print("48K loader: messages, tile pages, logo and colour layout passed")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="path to the pinned start.skool listing")
    verify(parser.parse_args().source)
