"""Emit a 6510 dispatch kernel for the Z80 instruction families used by the game."""


def generate(path, hooks, used):
    """Build the dispatch tables and return the token for each native routine."""
    code = ['.segment "EXT"']
    entries = ["unsupported"] * 256
    regs = ["zb", "zc", "zd", "ze", "zh", "zl", "(hl)", "za"]
    pairs = ["zc", "ze", "zl", "zsp"]

    def emit(op, *body, grouped=False):
        if op not in used:
            return
        name = f"op_{op:02x}"
        entries[op] = name
        if not grouped:
            code.extend((".pushseg", f'.segment "OP_{op:02x}"'))
        code.extend([name + ":", *("    " + line for line in body)])
        if not grouped:
            code.append(".popseg")

    def get(reg):
        return "jsr read_hl" if reg == "(hl)" else f"lda {reg}"

    def put(reg):
        return "jsr write_hl" if reg == "(hl)" else f"sta {reg}"

    end = "jmp dispatch"
    # Memory operands can return a mapped pixel offset in Y. The other
    # register operations preserve the zero index established at fetch.
    next_opcode = "jmp opcode_fetch"
    for dst, d in enumerate(regs):
        # Accumulator and memory loads keep their direct dispatch paths.
        for src, s in enumerate(regs):
            op = 0x40 + dst * 8 + src
            if dst != src:
                if "(hl)" in (s, d) or "za" in (s, d):
                    emit(op, get(s), put(d), end if "(hl)" in (s, d) else next_opcode)
                elif op in used:
                    entries[op] = "copy_register"
            elif op != 0x76 and op in used:
                entries[op] = "opcode_fetch"
        emit(6 + 8*dst, "fetch_operand", put(d), end if d == "(hl)" else next_opcode)

        for offset, operation in [(4, "inc"), (5, "dec")]:
            if d == "(hl)":
                update = ["clc", "adc #1"] if operation == "inc" else ["sec", "sbc #1"]
                emit(offset + 8*dst, get(d), *update, "sta fresult", put(d), end)
            else:
                emit(offset + 8*dst, f"{operation} {d}", get(d), "sta fresult", next_opcode)
    for family, name in enumerate(["add", "adc", "sub", "sbc", "and", "xor", "or", "cp"]):
        for src, reg in enumerate(regs):
            if reg == "za" and name in ("xor", "sub"):
                emit(0x80 + 8*family + src, "lda #0", "jmp logical")
            elif reg == "za" and name in ("or", "and"):
                emit(0x80 + 8*family + src, "lda za", "jmp logical_flags")
            else:
                emit(0x80 + 8*family + src, get(reg), f"jmp alu_{name}")
        emit(0xc6 + 8*family, "fetch_operand", f"jmp alu_{name}")

    for index, pair in enumerate(pairs):
        base = index * 16
        emit(0x01+base, "lda (zpc),y", f"sta {pair}", "iny", "lda (zpc),y",
             f"sta {pair}+1", "jmp skip_two")
        emit(0x03+base, f"inc {pair}", "bne :+", f"inc {pair}+1", ":", next_opcode)
        emit(0x0b+base, f"lda {pair}", "bne :+", f"dec {pair}+1", ":", f"dec {pair}", next_opcode)
        emit(0x09+base, "lda zl", "clc", f"adc {pair}", "tax", "lda zh",
             f"adc {pair}+1", "sta zh", "stx zl", "jmp save_carry")
        if index == 3:
            emit(0xf5, "jsr pack_flags", "ldx za", "jsr push_ax", end)
            emit(0xf1, "jsr pop_ax", "stx za", "jsr unpack_flags", end)
        else:
            emit(0xc5+base, f"lda {pair}", f"ldx {pair}+1", "jsr push_ax", end)
            emit(0xc1+base, "jsr pop_ax", f"sta {pair}", f"stx {pair}+1", end)

    for i, (flag, skip) in enumerate([
        ("fresult", "beq"), ("fresult", "bne"), ("fcarry", "bne"), ("fcarry", "beq"),
        ("fresult", None), ("fresult", None), ("fresult", "bmi"), ("fresult", "bpl"),
    ]):
        if skip is None:
            cond = ["jsr result_flags", "and #4"]
            skip = "bne" if i == 4 else "beq"
        else:
            cond = [f"lda {flag}"]
        # Four adjacent conditions share the short branches to each
        # continuation. No handler needs its own second absolute jump.
        group = i // 4
        if i % 4 == 0:
            trampolines = len(code)
        for base, active, inactive in [(0xc0, "ret_z80", "dispatch"),
                                       (0xc2, "jump", "skip_two"),
                                       (0xc4, "call", "skip_two")]:
            emit(base + i*8, *cond, f"{skip} cond_{group}_{inactive}", "jmp " + active, grouped=True)
        if i < 4:
            emit(0x20 + i*8, *cond, f"{skip} cond_{group}_skip_one", "jmp relative", grouped=True)
        if i % 4 == 3:
            # Emit only the continuations that a live handler branches to.
            handlers = "\n".join(code[trampolines:])
            shared = [line for dest in ("dispatch", "skip_two", "skip_one")
                      if f"cond_{group}_{dest}" in handlers
                      for line in (f"cond_{group}_{dest}:", f"    jmp {dest}")]
            code[trampolines:trampolines] = shared
    for op, name in {
        0x00:"dispatch", 0x02:"store_bc", 0x12:"store_de", 0x0a:"load_bc", 0x1a:"load_de",
        0x07:"rlca", 0x0f:"rrca", 0x17:"rla", 0x1f:"rra", 0x10:"djnz", 0x18:"relative",
        0x22:"store_hl_abs", 0x2a:"load_hl_abs", 0x32:"store_a_abs", 0x3a:"load_a_abs",
        0x2f:"cpl", 0x37:"scf", 0x3f:"ccf", 0xc3:"jump", 0xc9:"ret_z80", 0xcd:"call",
        0xcb:"prefix_cb", 0xd9:"exx", 0xdd:"native_call", 0xe3:"ex_sp_hl",
        0xe9:"jump_hl", 0xeb:"ex_de_hl", 0xed:"prefix_ed", 0xf3:"dispatch",
        0xf9:"sp_hl", 0xfb:"dispatch", 0xd3:"output_port", 0xdb:"input_port",
    }.items():
        if op in used or op == 0xdd:
            entries[op] = name

    # A vacant primary vector can call a native routine on the first fetch.
    # Preserve every live opcode, including forms installed by the game.
    free = [op for op, entry in enumerate(entries) if entry == "unsupported" and op not in used]
    tokens = {}
    for name, op in zip(hooks, free):
        entries[op] = name
        tokens[name] = bytes((op,))
    indirect = hooks[len(tokens):]
    for i, name in enumerate(indirect):
        tokens[name] = bytes((0xdd, 2*i))

    path.write_text("\n".join(code) + "\n", encoding="ascii")
    # The dispatcher jumps through this page-aligned word table: opcodes
    # 0-127 in the first page, 128-255 in the second.
    words = ["op_table:"] + ["    .word " + ",".join(entries[i:i+8]) for i in range(0, 256, 8)]
    words.append(".assert <op_table = 0, error, \"op_table must start a page\"")
    words.append("hook_table:")
    words.extend("    .word " + ",".join(indirect[i:i+8]) for i in range(0,len(indirect),8))
    words.append('.assert <hook_table = 0 && *-hook_table <= 256, error, "native vectors must fit one page"')
    words.extend(f"USE_{name.upper()} = 1" for name in ("rla", "sp_hl", "output_port") if name in entries)
    path.with_name("optable.inc").write_text("\n".join(words) + "\n", encoding="ascii")
    return tokens
