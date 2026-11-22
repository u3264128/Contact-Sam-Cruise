"""Compare interior, street and rooftop tiles with overlapping live actors."""
import argparse
import struct
from skoolkit import CSimulator
from vice_test import CAMERA, FRAME, VICE, begin, check_screen, labels, original_state, vice


def compare(m, sym):
    begin(m,sym)
    # Each pass goes through the game's normal refresh entry, with a
    # synthetic return to the frame boundary. Leave the HUD in place.
    m.write(61440,b"\xc3"+struct.pack("<H",60032))
    m.write(sym["frame_call"]+1,bytes((FRAME&255,)))
    for name,x,y in (("Hotel Royale",56,3),("street and steps",102,18),
                     ("catwalk",11,2),("Sam's office",210,12),("map rows 22 to 41",56,22)):
        m.write(CAMERA,bytes((x,y)))
        for page,pose,dx,dy,layer in ((222,0,7,5,1),(223,129,8,6,1),(224,7,8,7,2),
                                     (225,135,9,6,4),(226,14,15,10,1),(229,249,14,11,2)):
            m.write(page<<8,bytes((pose,x+dx,y+dy,0,layer)))
        m.write(0x7f10,bytes([255])*80)
        image = original_state(m.read(0,65536),sym)
        image[0x5d40:0x5d42] = bytes(2)
        reference = CSimulator(image,{"SP":0x5d40})
        reference.run(60032,0)
        m.resume_to(sym["frame_start"])
        check_screen(reference.memory,m.read(0,65536))
        print(name,"pixels and colours passed",flush=True)


if __name__=="__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model",choices=("pal","ntsc"),default="pal")
    parser.add_argument("--vice",default=VICE)
    args = parser.parse_args()
    with vice(args.vice,args.model) as monitor:
        compare(monitor,labels())
