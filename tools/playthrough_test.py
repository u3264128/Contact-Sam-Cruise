"""Play the Bali Budgie case with game keys, saving VICE checkpoints between chapters."""
import argparse
from collections import deque
import hashlib
from pathlib import Path
import struct

from skoolkit import CSimulator
from skoolkit.simutils import H, L, SP
from monitor import BUILD, labels, vice
from scenario_test import set_key
from story_test import next_move, trip
from vice_test import SAM, VICE, begin, original_state


def local_move(image, goal, inside):
    # The demo navigator cannot cross the lip of a roof or operate Sam's
    # keys. Find a short approach with the original movement routines on
    # copies of the state. Only four directional keys reach the live C64.
    moves = (60334,60347,60315,60320)
    for address in (59868,60032,60521):
        image[address] = 201  # skip painting and sound in the private search
    queue = deque([(bytes(image[SAM:SAM+32]),0)])
    seen = set()
    while queue:
        actor, first = queue.popleft()
        if actor[:5] in seen:
            continue
        seen.add(actor[:5])
        if goal(actor):
            return first
        if not inside(actor):
            continue
        for key, address in enumerate(moves,1):
            sim = CSimulator(image.copy(),{"SP":0x5d40,"HL":SAM})
            ram = sim.memory
            ram[SAM:SAM+32] = actor
            ram[0x5d40:0x5d42] = bytes(2)
            sim.run(address,0)
            if ram[SAM+7]:
                sim.registers[SP] = 0x5d40
                sim.registers[H], sim.registers[L] = 230,0
                sim.run(60506,0)
            queue.append((bytes(ram[SAM:SAM+32]),first or key))
    raise AssertionError(("No local path",image[SAM:SAM+5]))


class Player:
    def __init__(self, monitor, sym):
        self.m = monitor
        self.s = sym
        self.watch = None

    def switch(self, name):
        if self.watch is not None:
            self.m.request(0x13,struct.pack("<I",self.watch))
        self.watch = self.m.checkpoint(self.s[name])

    def state(self, addr):
        return self.m.read(addr,1)[0]

    def key(self, key):
        set_key(self.m,key)

    def step(self, key=None):
        if key:
            self.key(key)
        self.m.resume_to(self.s["game_controls"])

    def wait_frames(self, predicate, limit):
        for _ in range(limit):
            self.m.resume_to(self.s["frame_start"])
            if predicate():
                return
        raise AssertionError(("Wait expired", self.m.read(SAM,5), self.m.read(32745,7)))

    def walk(self, x, y, z=1, *, door=None, accept_mode=None):
        previous, stalled = None, 0
        for _ in range(1000):
            ram = self.m.read(0,65536)
            actor = ram[SAM:SAM+5]
            if (actor[1:3]==bytes((x,y)) and actor[4]==z) or ram[32750]==accept_mode:
                return
            if door and actor[1] in door[:2] and actor[2]==31 and actor[4]==2:
                move = 5
                if ram[door[2]]&7:
                    move = local_move(original_state(ram,self.s),lambda a:a[4]==1,
                                      lambda a:abs(a[1]-actor[1])<=4 and abs(a[2]-31)<=2)
            elif (x,y) in ((23,6),(206,6)) and abs(x-actor[1])<24 and actor[2]<9:
                move = local_move(original_state(ram,self.s),lambda a:a[1:3]==bytes((x,y)),
                                  lambda a:abs(a[1]-x)<26 and a[2]<10)
            else:
                move = next_move(ram,self.s,x,y,z)
            stalled = stalled+1 if actor==previous else 0
            if not 1<=move<=6 or stalled>22:
                raise AssertionError(("Route blocked",(x,y,z),actor.hex(),move))
            previous = actor
            self.step(" POQAKK"[move])
        raise AssertionError(("Route expired",x,y,z))

    def roof31(self):
        self.walk(126,7)
        for _ in range(35):
            if self.state(SAM+2)==5:
                break
            self.step("Q")
        for _ in range(35):
            self.step("O")
            if self.state(SAM+2)>=11:
                break
        self.walk(106,25)

    def drop(self, page, xpos, ypos, key):
        for _ in range(3000):
            actor = self.m.read(page*256,5)
            if actor[1] in xpos and actor[2]==ypos and actor[0]&128:
                break
            self.step()
        else:
            raise AssertionError(("Missed jumping target",page))
        self.leave_ledge(key)

    def leave_ledge(self,key):
        start_y = self.state(SAM+2)
        for _ in range(6):
            self.step(key)
            if self.state(SAM+2)>start_y+1:
                return
        raise AssertionError("Sam stayed on the ledge")

    def save(self, path):
        name = str(path).encode()
        self.m.request(0x41,bytes((0,0,len(name)))+name)

    def load(self, path):
        name = str(path).encode()
        self.m.request(0x13,struct.pack("<I",self.watch))
        self.watch = None
        self.m.request(0x42,bytes((len(name),))+name)
        self.m.events.clear()
        self.switch("game_controls")

    def call(self, number):
        for _ in range(8):
            self.key("t")
            self.switch("frame_start")
            self.wait_frames(lambda:self.state(32764)&16,100)
            ringing = self.state(32667)&128
            if ringing:
                for i in range(120):
                    if i%15==0:
                        self.key("d")
                    self.m.resume_to(self.s["frame_start"])
            else:
                for i,digit in enumerate(number):
                    for j in range(400):
                        if j%8==0:
                            self.key(digit)
                        self.m.resume_to(self.s["frame_start"])
                        if self.state(32658+i)==ord(digit):
                            break
                    else:
                        raise AssertionError(("Dialling stalled",number,i))
                for i in range(1000):
                    if number=="7162" and i%16==0:
                        self.key("s")
                    self.m.resume_to(self.s["frame_start"])
                    if ((number=="6124" and i>=100) or
                        (number=="999" and self.state(32747)) or
                        (number=="7162" and self.state(32667)&2)):
                        break
                else:
                    raise AssertionError(("Unanswered call",number))
                if number=="999" and self.state(32745)==128:
                    self.key("h")
                    return
            self.key("h")
            self.switch("game_controls")
            self.step()
            if not ringing and (number!="7162" or self.state(27527)==0):
                return
        raise AssertionError(("Call did not reach its story event",number))


def key15(p):
    p.roof31()
    assert p.state(32746)&64
    p.walk(249,29,door=(251,252,32761),accept_mode=2)
    assert p.state(32750)==2

def fire_escape(p):
    p.walk(252,13)
    assert p.state(32746)&16
    p.walk(247,25)
    p.walk(190,7)
    p.walk(177,28,2)

def fat_man(p):
    # Save just before the Fat Man passes. Try successive ordinary input
    # opportunities from this VICE snapshot until Sam lands on his head.
    for _ in range(3000):
        actor = p.m.read(57600,5)
        if actor[1] in (167,168) and actor[2]==35 and actor[0]&128:
            break
        p.step()
    else:
        raise AssertionError("Fat Man did not approach")
    ledge = BUILD/"work"/f"ledge-{p.m.process_id}.vsf"
    p.save(ledge)
    try:
        # In both regression runs the successful input was 28 input
        # opportunities after this approach. Try neighbouring timings if
        # different actor activity changes the interval.
        for attempt,delay in enumerate(sorted(range(42),key=lambda n:abs(n-28))):
            if attempt:
                p.load(ledge)
            for _ in range(delay):
                p.step()
            p.leave_ledge("O")
            if not p.state(32044)&1 or p.state(32746)&32:
                print("Fat Man jump succeeded on attempt",attempt+1,flush=True)
                break
        else:
            raise AssertionError("Missed the Fat Man")
    finally:
        ledge.unlink(missing_ok=True)
    p.walk(170,35,4)
    assert p.state(32746)&32

def hotel(p):
    p.walk(154,7,door=(155,156,32756))
    p.roof31()
    p.walk(98,13)
    for _ in range(4):
        p.step("d")
    p.walk(96,13)
    assert p.state(32036)==144
    p.walk(5,7)
    assert p.state(32750)==3

def key74(p):
    p.walk(23,6)
    p.drop(219,(26,27),13,"P")
    p.walk(34,13)
    assert p.state(32746)&120==120

def hook(p):
    p.walk(35,31,door=(42,43,32754))
    p.call("6124")
    p.walk(51,13)
    p.step("g")
    assert p.state(32745)&64

def police(p):
    p.walk(35,19)
    p.call("999")
    p.switch("frame_start")
    p.wait_frames(lambda:p.state(32747)&128,12000)
    p.wait_frames(lambda:not p.state(32747)&128,12000)
    p.switch("game_controls")
    p.step()

def budgie(p):
    p.walk(126,7)
    p.walk(154,7)
    p.walk(190,7)
    p.walk(206,6)
    p.step("c")
    for _ in range(180):
        if not p.state(47386)&2:
            break
        p.step()
    assert not p.state(47386)&2
    for _ in range(35):
        p.step("P")
        if p.state(SAM+1)>=229:
            break
    p.walk(232,13)
    p.walk(225,13)
    p.step("g")
    assert p.state(32745)==128

def solve(p):
    p.walk(228,7)
    for _ in range(25):
        p.step("O")
        if p.state(SAM+2)>=12:
            break
    p.walk(208,13)
    p.step("f")
    p.walk(228,19,door=(235,236,32759))
    p.call("7162")
    for _ in range(2000):
        lana = p.m.read(57600,5)
        if lana[2]<=25 and 225<=lana[1]<=239 and lana[4]==1:
            break
        p.step()
    else:
        raise AssertionError(("Lana did not reach the staircase",lana))
    p.call("999")
    p.switch("frame_start")
    p.wait_frames(lambda:p.state(32750)==4,5000)


CHAPTERS = (key15,fire_escape,fat_man,hotel,key74,hook,police,budgie,solve)

def run(args):
    prg = args.prg or BUILD/"contact-sam-cruise.prg"
    sym = labels(prg.with_suffix(".lbl"))
    build_id = hashlib.sha256(prg.read_bytes()).hexdigest()[:12]
    def path(stage):
        return BUILD/"work"/f"play-{args.model}-{build_id}-{stage}.vsf"
    with vice(args.vice,args.model,prg) as m:
        p = Player(m,sym)
        start = 0
        if args.resume:
            p.watch = begin(m,sym)
            p.load(path(args.resume))
            if args.resume!="released":
                start = [chapter.__name__ for chapter in CHAPTERS].index(args.resume)+1
        else:
            p.watch = trip(m,sym)
            p.switch("game_controls")
            p.step()
            p.save(path("released"))
            print(args.model,"released passed",flush=True)
        for chapter in CHAPTERS[start:]:
            chapter(p)
            p.save(path(chapter.__name__))
            print(args.model,chapter.__name__,"passed",flush=True)

if __name__=="__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model",choices=("pal","ntsc"),default="pal")
    parser.add_argument("--prg", type=Path, help="play the build with the adjacent .lbl file")
    parser.add_argument("--vice",default=VICE)
    parser.add_argument("--resume",choices=("released",*(f.__name__ for f in CHAPTERS[:-1])))
    run(parser.parse_args())
