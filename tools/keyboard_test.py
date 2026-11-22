"""Send real Windows key events to the VICE window and check the CIA scanner."""
import argparse
import ctypes
import struct
import sys
from ctypes import wintypes
from vice_test import VICE, labels, vice


def emulator_window(m):
    user = ctypes.windll.user32
    found = []
    callback = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

    @callback
    def inspect(window, _):
        pid = wintypes.DWORD()
        user.GetWindowThreadProcessId(window, ctypes.byref(pid))
        if pid.value == m.process_id:
            title = ctypes.create_unicode_buffer(256)
            user.GetWindowTextW(window, title, 256)
            if "VICE" in title.value:
                found.append(window)
        return True

    user.EnumWindows(inspect, 0)
    if len(found) != 1:
        raise RuntimeError(f"Expected the test VICE window, found {len(found)}")
    return found[0]


def press(window, key, down):
    user = ctypes.windll.user32
    scan = user.MapVirtualKeyW(key,0)
    state = (scan << 16) | 1
    if not down:
        state |= 0xc0000000
    if not user.PostMessageW(window, 0x100 if down else 0x101, key, state):
        raise OSError("Could not post key to the test emulator")


def test(m, sym):
    m.checkpoint(sym["title_wait"],True)
    m.resume_to(sym["title_wait"])
    window = emulator_window(m)
    scan = m.checkpoint(sym["irq"])
    for joystick in (0,8,4):
        # T is on row 2, so holding joystick left grounds its own row.
        m.stick(joystick)
        for down in (True,False):
            press(window,ord("T"),down)
            expected = ord("t") if down else 0
            for _ in range(40):
                m.resume_to(sym["irq"])
                if m.read(sym["held_key"],1)[0]==expected and m.read(sym["joy"],1)[0]==joystick:
                    break
            else:
                raise AssertionError(("T",down,joystick))
    m.request(0x13,struct.pack("<I",scan))
    m.stick(0)
    m.checkpoint(sym["enter_game"],True)
    press(window,13,True)
    m.resume_to(sym["enter_game"])
    press(window,13,False)
    m.checkpoint(sym["frame_start"],True)
    m.resume_to(sym["frame_start"])
    assert m.read(32750,1)==bytes((1,))
    print("Return started the game. CIA keyboard input passed with and without joystick movement.")


if __name__=="__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model",choices=("pal","ntsc"),default="pal")
    parser.add_argument("--vice",default=VICE)
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("This test requires Windows desktop key events.")
    with vice(args.vice,args.model) as monitor:
        test(monitor,labels())
