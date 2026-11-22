"""Check the joystick prompt, phone input, inventory and story events in VICE."""
import argparse
import struct
from vice_test import FRAME, SAM, VICE, begin, cpu_clock, labels, vice

def set_key(m, key):
    m.write(23560,key.encode("ascii"))
    m.write(23611,bytes((m.read(23611,1)[0] | 32,)))

def frame(m,sym):
    m.resume_to(sym["frame_start"])

def until(m,sym,addr,test,limit=160):
    for _ in range(limit):
        frame(m,sym)
        if test(m.read(addr,1)[0]):
            return
    raise AssertionError((addr,m.read(addr,1),m.read(SAM,5)))

def place(m,x,y):
    m.write(SAM,bytes((128,x,y,0,1)))
    m.write(SAM+8,b"\x01\x00")
    m.write(32764,b"\x00")

def joystick_prompt(m, sym, frame_check):
    m.request(0x13, struct.pack("<I", frame_check))
    for key, device in (("n", b"\x00"), ("k", b"\x6b")):
        m.checkpoint(sym["game_controls"], True)
        m.resume_to(sym["game_controls"])
        scan = m.checkpoint(sym["irq"])
        set_key(m, "j")
        for _ in range(160):
            m.resume_to(sym["irq"])
            guest_pc = int.from_bytes(m.read(9, 2), "little")
            if 24969 <= guest_pc <= 24974 and 96 not in m.read(32696, 8):
                break
        else:
            raise AssertionError("The joystick prompt did not reach its key wait")
        assert b"JOYSTICK?" in m.read(32608, 32), "the joystick prompt was not printed"
        set_key(m, key)
        for _ in range(40):
            m.resume_to(sym["irq"])
            if m.read(sym["clock_budget"], 1)[0] < 128:
                break
        else:
            raise AssertionError(f"The game did not resume after {key.upper()}")
        assert m.read(32762, 1) == device, ("wrong joystick mode", key)
        m.request(0x13, struct.pack("<I", scan))

def play_fixtures(m,sym):
    # Let the guest phone handler read the dialled digits.
    place(m,226,19)
    set_key(m,"t")
    until(m,sym,32764,lambda v:v==16)
    set_key(m,"7")
    until(m,sym,32658,lambda v:v==ord("7"))
    set_key(m,"h")
    until(m,sym,32764,lambda v:v==0)
    set_key(m,"d")
    until(m,sym,32713,lambda v:v==1)

    # Use the keyboard on the road, with the new disguise still active.
    for key, table in (("r", 25724), ("s", 25748)):
        place(m, 214, 35)
        m.write(SAM+4, bytes((4,)))
        set_key(m, key)
        until(m, sym, 32764, lambda flags: flags & 8)
        assert int.from_bytes(m.read(SAM+12, 2), "little") == table+4
        until(m, sym, 32764, lambda flags: flags == 0)
        assert m.read(SAM, 1)[0] & 127 == 0

    # Collect a key at its actual world position via the object scan.
    place(m,106,25)
    until(m,sym,32746,lambda v:v & 64)
    place(m,249,29)
    until(m,sym,32750,lambda v:v==2)
    # The hotel recognises the female disguise. The following stairs trigger mode 3.
    m.write(32713,b"\x04")
    place(m,98,13)
    until(m,sym,32036,lambda v: not (v & 1))
    place(m,10,8)
    until(m,sym,32750,lambda v:v==3)
    # All four locks opened. Collect the budgie using the G action.
    m.write(32746,b"\x78")
    place(m,232,13)
    until(m,sym,32032,lambda v:v==192)
    place(m,225,13)
    set_key(m,"g")
    until(m,sym,32745,lambda v:v==128)
    # Recreate Lana's arrival once Sam has called 7162 and 999. The live
    # encounter must recognise the police and start the case-solved cutscene.
    place(m,228,19)
    until(m,sym,27527,lambda v:v==36)
    m.write(27527,b"\x00")
    until(m,sym,24792,lambda v:v==128)
    m.write(57622,b"\x08")
    for base in (0xde00,0xdf00):
        m.write(base+1,bytes((228,19)))
    until(m,sym,32750,lambda v:v==4,limit=1800)

def audio(m,sym,model):
    # Run the real variable-duration effect with known pitch and length:
    # C=192 and DE=320 give 64 speaker edges 2529 T-states apart. The edges
    # are stores to the SID control register. tools/audio_test.py compares
    # every edge of all the effects with the 48K original.
    m.write(61440,bytes.fromhex("01 c0 00 11 40 01 3e 02 c3")+struct.pack("<H",64740))
    m.write(sym["frame_call"]+1,bytes((FRAME & 255,)))
    edge = m.checkpoint(0xd404,operation=2)
    clocks = []
    while m.resume_to() != sym["frame_start"]:
        clocks.append(cpu_clock(m))
    m.request(0x13,struct.pack("<I",edge))
    clock={"pal":985248,"ntsc":1022727}[model]
    duration=(clocks[-1]-clocks[0])/clock
    hz=(len(clocks)-1)/2/duration
    # Monitor bank 3 reads the emulated I/O registers with RAM banked in.
    def io(addr,n):
        return m.request(1,struct.pack("<BHHBH",0,addr,addr+n-1,0,3))[2:]
    assert len(clocks)==64,len(clocks)
    assert io(0xd020,1)[0]&15==2
    assert io(0xd404,1)[0]&0xf7==0x41      # pulse wave with the gate held on
    assert io(0xdd0e,1)[0]&1==0             # CIA2 timer A stopped
    assert 675<hz<710 and .044<duration<.048,(hz,duration)
    print(f"{model} SID square {hz:.1f} Hz, 64 edges over {duration*1000:.1f} ms; "
          "timer stopped and red border verified",flush=True)

def restart_after_bankruptcy(m,sym):
    # Mode four continues after the case is solved. Leave one dollar
    # and let the ordinary score update spend it.
    m.write(32670,struct.pack("<H",1))
    now = int.from_bytes(m.read(23672,2),"little")
    m.write(32724,struct.pack("<H",(now-512)&65535))
    until(m,sym,32750,lambda mode:mode==0,limit=1200)
    set_key(m,"p")
    until(m,sym,32750,lambda mode:mode==1,limit=100)
    assert m.read(32746,1)==bytes(1)
    assert int.from_bytes(m.read(32670,2),"little")>1

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--model",choices=("pal","ntsc"),default="pal")
    p.add_argument("--vice",default=VICE)
    args=p.parse_args()
    s=labels()
    with vice(args.vice,args.model) as m:
        frame_check = begin(m,s)
        joystick_prompt(m,s,frame_check)
        print(args.model, "joystick prompt accepted N and K and returned to play", flush=True)
    with vice(args.vice,args.model) as m:
        begin(m,s)
        play_fixtures(m,s)
        print(args.model,"phone, disguise, roll, somersault, key, budgie and case-solved mode passed",flush=True)
        restart_after_bankruptcy(m,s)
        print(args.model,"bankruptcy, demo and new game passed",flush=True)
        audio(m,s,args.model)
