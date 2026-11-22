"""Drive Sam from his office to the hotel, take the call, and get out of jail."""
import argparse
import struct

from skoolkit import CSimulator
from skoolkit.simutils import A, C, D, E, H, L, SP
from monitor import labels, vice
from scenario_test import set_key
from vice_test import SAM, VICE, begin, original_state


def next_move(live, sym, x, y, z):
    # Ask the Spectrum demo pathfinder on a private copy. Only the
    # resulting keypress is sent back to the running C64.
    sim = CSimulator(original_state(live, sym))
    ram, reg = sim.memory, sim.registers

    def call(address):
        ram[0x5d40:0x5d42] = bytes(2)
        reg[SP] = 0x5d40
        reg[H], reg[L] = 230, 0
        sim.run(address, 0)
        return reg[A]

    reg[C], reg[D], reg[E] = z, y, x
    ram[SAM+10:SAM+12] = bytes((x,y))
    ram[SAM+12] = call(60734)
    return call(60812)


def trip(m, sym):
    frame = begin(m, sym)
    m.request(0x13, struct.pack("<I",frame))
    controls = m.checkpoint(sym["game_controls"])
    m.resume_to(sym["game_controls"])
    for attempts in range(600):
        live = m.read(0,65536)
        if live[SAM+1:SAM+3] == bytes((58,7)) and live[SAM+4] == 1:
            break
        move = next_move(live, sym, 58, 7, 1)
        assert 1 <= move <= 6, ("hotel route", live[SAM:SAM+5], move)
        set_key(m, " POQAKK"[move])
        m.resume_to(sym["game_controls"])
    else:
        raise AssertionError("Sam did not reach the hotel")
    assert live[32052]&1 and live[32068]&1, "Body and cash events"
    set_key(m,"t")
    m.request(0x13, struct.pack("<I",controls))
    frame = m.checkpoint(sym["frame_start"])
    phone = False
    for i in range(3500):
        m.resume_to(sym["frame_start"])
        phone |= bool(m.read(32764,1)[0]&16)
        if i==80:
            set_key(m,"h")
        if m.read(32747,1)[0]&128:
            break
    else:
        raise AssertionError("Missing arrest")
    assert phone
    for _ in range(12000):
        m.resume_to(sym["frame_start"])
        if not m.read(32747,1)[0]&128:
            assert m.read(32750,1)==b"\x01"
            print(f"Hotel reached in {attempts} moves. Body, $100, telephone, arrest and release passed.")
            return frame
    raise AssertionError(("Sam still in jail",m.read(32747,1).hex(),m.read(32670,2).hex()))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=("pal","ntsc"), default="pal")
    parser.add_argument("--vice", default=VICE)
    args = parser.parse_args()
    with vice(args.vice,args.model) as monitor:
        trip(monitor,labels())
