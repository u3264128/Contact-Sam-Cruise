; Fetch instructions from guest RAM so patched operands take effect.
; The guest stack also holds continuations for indirect command lists.
install_pc:
    sta zpc
    stx zpc+1
dispatch:
    ldy #0
opcode_fetch:                   ; register-only handlers already have Y=0
    lda (zpc),y
    inc zpc
    beq @page
@decode:
    asl                         ; double the index and select the page with carry
    bcs @high
    sta @low_entry+1
@low_entry:
    jmp (op_table)
@high:
    sta @high_entry+1
@high_entry:
    jmp (op_table+256)
@page:
    inc zpc+1
    jmp @decode
.macro fetch_operand
    ; Dispatch enters an opcode with Y=0. INC leaves A (the operand)
    ; intact even when the guest instruction crosses a page boundary.
    lda (zpc),y
    inc zpc
    bne :+
    inc zpc+1
:
.endmacro
; A holds the doubled opcode on dispatch. The less common register moves
; share this decoder. The accumulator and memory moves use direct handlers.
.segment "VM_copy_register"
copy_register:
    tax
    lsr
    and #7
    tay
    lda cb_regs,y
    tay
    lda $0000,y
    sta tmp
    txa
    .repeat 4
        lsr
    .endrepeat
    and #7
    tay
    ldx cb_regs,y
    lda tmp
    sta $00,x
    jmp dispatch
.segment "VM_fetch"
fetch:
    ldy #0
    fetch_operand
    rts
.segment "VM_fetch_addr"
fetch_addr:
    ldy #1
    lda (zpc),y
    sta addr+1
    dey
    lda (zpc),y
    sta addr
    lda zpc
    clc
    adc #2
    sta zpc
    bcc :+
    inc zpc+1
:
    rts
.segment "VM_native_call"
native_call:
    fetch_operand
    sta @entry+1
@entry:
    jmp (hook_table)
.segment "CODE"
unsupported:
    lda #$35
    sta $01
    lda #2
    sta $d020
    sei
:   jmp :-

.macro setpc target
    lda #<target
    ldx #>target
    jmp install_pc
.endmacro
.macro guest_call routine, return_pc
    lda #<return_pc
    ldx #>return_pc
    jsr push_ax
    jmp routine
.endmacro
.segment "VM_skip"
skip_two:
    inc zpc
    bne skip_one
    inc zpc+1
skip_one:
    inc zpc
    bne :+
    inc zpc+1
:   jmp dispatch
.segment "VM_jump"
jump:
    ldy #1
    lda (zpc),y
    tax
    dey
    lda (zpc),y
    jmp install_pc
jump_hl:
    lda zl
    ldx zh
    jmp install_pc
.segment "VM_relative"
relative:
    fetch_operand                ; all JR and DJNZ handlers preserve Y=0
    tax
    bpl :+
    dec zpc+1
:   clc
    adc zpc
    sta zpc
    bcc :+
    inc zpc+1
:   jmp opcode_fetch
djnz:
    dec zb
    bne relative
    jmp skip_one
.segment "VM_push"
push_ax:
    pha
    lda zsp
    sec
    sbc #2
    sta zsp
    bcs :+
    dec zsp+1
:   ldy #1
    txa
    sta (zsp),y
    dey
    pla
    sta (zsp),y
    rts
.segment "VM_pop"
pop_ax:
    ldy #1
    lda (zsp),y
    tax
    dey
    lda (zsp),y
    inc zsp
    bne :+
    inc zsp+1
:   inc zsp
    bne :+
    inc zsp+1
:   rts
.segment "VM_call"
call:
    ; Read both target bytes before pushing, even if the guest stack
    ; overlaps the instruction. The return address is PC + 2.
    ldy #0
    lda (zpc),y
    sta addr
    iny
    lda (zpc),y
    tax
    lda zsp
    sec
    sbc #2
    sta zsp
    bcs :+
    dec zsp+1
:   dey
    lda zpc
    clc
    adc #2
    sta (zsp),y
    iny
    lda zpc+1
    adc #0
    sta (zsp),y
    lda addr
    jmp install_pc
.segment "VM_return"
ret_z80:
    ldy #1
    lda (zsp),y
    sta zpc+1
    dey
    lda (zsp),y
    sta zpc
    clc
    lda zsp
    adc #2
    sta zsp
    bcc :+
    inc zsp+1
:   jmp opcode_fetch
.segment "VM_ex_sp"
ex_sp_hl:
    jsr pop_ax
    pha
    txa
    pha
    lda zl
    ldx zh
    jsr push_ax
    pla
    sta zh
    pla
    sta zl
    jmp dispatch
.ifdef USE_SP_HL
.segment "VM_sp_hl"
sp_hl:
    lda zl
    sta zsp
    lda zh
    sta zsp+1
    jmp dispatch
.endif
.segment "VM_exx"
exx:
    ldx #5
:   lda zc,x
    ldy alternate,x
    sta alternate,x
    tya
    sta zc,x
    dex
    bpl :-
    jmp dispatch
.segment "VM_ex_de"
ex_de_hl:
    ldx zl
    ldy zh
    lda ze
    sta zl
    lda zd
    sta zh
    stx ze
    sty zd
    jmp dispatch

; Branches in this program test S, Z, C and logical parity. S/Z are retained
; as a result byte.
.segment "VM_flags"
pack_flags:
    jsr result_flags
    ora fcarry
    rts
result_flags:
    ldx fresult
    beq flags_zero
    txa
    and #128
    sta tmp
    txa
    lsr
    lsr
    lsr
    lsr
    eor fresult
    and #15
    tax
    lda parity,x
    ora tmp
    rts
flags_zero:
    lda #$44
    rts
.segment "VM_unpack_flags"
unpack_flags:
    tax
    and #1
    sta fcarry
    txa
    and #$40
    bne :+
    txa
    and #$80
    ora #1
    bne :++
:   lda #0
:   sta fresult
    rts
.segment "VM_alu_add"
alu_adc:
    ldx fcarry
    cpx #1
    jmp :+
alu_add:
    clc
:   adc za
    sta za
    sta fresult
save_carry:
    lda #0
    rol
    sta fcarry
    jmp dispatch
.segment "VM_alu_sub"
alu_sub:
    sec
    bcs subtract
alu_sbc:
    ldx #0
    cpx fcarry                  ; incoming C = 1 - guest borrow
subtract:
    eor #$ff
    adc za                      ; A - operand - borrow
    sta za
    jmp borrow
alu_cp:
    sec
    eor #$ff
    adc za
borrow:
    sta fresult
    lda #1
    sbc #0
    eor #1
    sta fcarry
    jmp dispatch
.segment "VM_logical"
alu_xor:
    eor za
    jmp logical
alu_or:
    ora za
    jmp logical
alu_and:
    and za
logical:
    sta za
logical_flags:
    sta fresult
    lda #0
    sta fcarry
    jmp dispatch
.segment "VM_cpl"
cpl:
    lda za
    eor #255
    sta za
    jmp opcode_fetch
.segment "VM_carry"
scf:
    lda #1
    bne set_c
ccf:
    lda fcarry
    eor #1
set_c:
    sta fcarry
    jmp opcode_fetch
.segment "VM_rotate"
rlca:
    lda za
    cmp #128
    rol
    jmp rotated
rrca:
    lda za
    lsr
    lda za
    ror
    jmp rotated
.ifdef USE_RLA
rla:
    lsr fcarry
    lda za
    rol
    jmp rotated
.endif
rra:
    lsr fcarry
    lda za
    ror
rotated:
    sta za
    jmp save_carry

.macro pair_addr pair
    lda pair
    sta addr
    lda pair+1
    sta addr+1
.endmacro
.segment "VM_mem_hl"
read_hl:
    ldy #0
    lda zh
    cmp #$58
    bcc :+
    cmp #$ff
    beq :+
    lda (zl),y
    rts
:   pair_addr zl
    jmp read_addr
write_hl:
    ldy zh
    cpy #$5b
    bcc :+
    cpy #$ff
    beq :+
    ldy #0
    sta (zl),y
    rts
:   ldx zl
    stx addr
    sty addr+1                 ; Y still holds the mapped page, A the value
    jmp write_addr
.segment "VM_pair_access"
; BC and DE share the mapped guest address path. HL keeps its fast load
; and store for the register and arithmetic instruction families.
store_bc:
    ldx #zc
    bne store_pair_a
store_de:
    ldx #ze
store_pair_a:
    lda za
    jsr write_guest_pair
    jmp dispatch
write_de:
    ldx #ze
write_guest_pair:
    ldy $00,x
    sty addr
    ldy $01,x
    sty addr+1
    jmp write_addr
load_bc:
    ldx #zc
    bne load_pair_a
load_de:
    ldx #ze
load_pair_a:
    lda $00,x
    sta addr
    lda $01,x
    sta addr+1
    jsr read_addr
put_a:
    sta za
    jmp dispatch
.segment "VM_load_a_abs"
load_a_abs:
    jsr fetch_addr
    jsr read_addr
    jmp put_a
.segment "VM_store_a_abs"
store_a_abs:
    jsr fetch_addr
    lda za
    jsr write_addr
    jmp dispatch
.segment "VM_load_pair"
load_bc_abs:
    ldx #zc
    bne load_pair
load_hl_abs:
    ldx #zl
    bne load_pair
load_de_abs:
    ldx #ze
load_pair:
    stx aux
    jsr fetch_addr
    jsr read_addr
    ldx aux
    sta $00,x
    jsr next_addr
    jsr read_addr
    ldx aux
    sta $01,x
    jmp dispatch
.segment "VM_store_pair"
store_hl_abs:
    ldx #zl
    bne store_pair
store_de_abs:
    ldx #ze
store_pair:
    stx aux
    jsr fetch_addr
    ldx aux
    lda $00,x
    jsr write_addr
    jsr next_addr
    ldx aux
    lda $01,x
    jsr write_addr
    jmp dispatch
.segment "VM_next_addr"
next_addr:
    inc addr
    bne :+
    inc addr+1
:   rts

.segment "VM_ed"
; Look up the second opcode byte and enter its handler through RTS.
prefix_ed:
    fetch_operand
    ldx #ed_count-1
:   cmp ed_ops,x
    beq :+
    dex
    bpl :-
    jmp unsupported
:   lda ed_hi,x
    pha
    lda ed_lo,x
    pha
    rts
.segment "VM_ed_table"
ed_ops: .byte $4b,$a8,$b0,$b8,$a0,$53,$5b,$44,$42,$52
ed_count = * - ed_ops
.define ED_HANDLERS load_bc_abs-1, single_back-1, block_forward-1, block_backward-1, single_copy-1, store_de_abs-1, load_de_abs-1, negate-1, sbc_bc-1, sbc_de-1
ed_lo: .lobytes ED_HANDLERS
ed_hi: .hibytes ED_HANDLERS
.undefine ED_HANDLERS
.segment "VM_negate"
negate:
    lda za
    ldx #0
    stx za
    jmp alu_sub
.segment "VM_sbc"
sbc_bc:
    ldx #zc
    bne sbc_pair
sbc_de:
    ldx #ze
sbc_pair:
    lda #0
    cmp fcarry
    lda zl
    sbc $00,x
    sta zl
    lda zh
    sbc $01,x
    sta zh
    bne borrow16
    ldx zl
    beq borrow16
    lda #1
borrow16:
    jmp borrow
.segment "VM_block"
block_forward:
    ldx #1
    bne :+
block_backward:
    ldx #255
:   jsr block_fast
    jmp dispatch
single_back:
    ldx #$80
    bne copy_mode
single_copy:
    ldx #0
copy_mode:
    stx copy_step
    jsr copy_loop
    jmp dispatch
copy_loop:
    jsr read_hl
    jsr write_de
    lda copy_step
    bmi copy_down
    inc zl
    bne :+
    inc zh
:   inc ze
    bne count_copy
    inc zd
    jmp count_copy
copy_down:
    lda zl
    bne :+
    dec zh
:   dec zl
    lda ze
    bne :+
    dec zd
:   dec ze
count_copy:
    lda zc
    bne :+
    dec zb
:   dec zc
    lda zc
    ora zb
    beq :+
    lda copy_step
    cmp #$80
    beq :+
    cmp #0
    bne copy_loop
:   rts
copy_step: .byte 0
; LDIR and LDDR byte by byte, as the original, while both pointers stay in
; RAM that needs no mapping: reads from $5800-$FEFF, writes to $5B00-$FEFF.
; Y becomes nonzero when a pointer changes page, which repeats the check.
; S, Z and C are unchanged.
.segment "CODE"
block_fast:
    stx copy_step
@check:
    lda zh
    cmp #$58
    bcc @slow
    cmp #$ff
    beq @slow
    lda zd
    cmp #$5b
    bcc @slow
    cmp #$ff
    beq @slow
    ldy #0
@byte:
    lda (zl),y
    sta (ze),y
    lda copy_step
    bmi @down
    inc zl
    bne :+
    inc zh
    dey
:   inc ze
    bne @count
    inc zd
    dey
    jmp @count
@down:
    lda zl
    bne :+
    dec zh
    dey
:   dec zl
    lda ze
    bne :+
    dec zd
    dey
:   dec ze
@count:
    lda zc
    bne :+
    dec zb
:   dec zc
    bne :+
    lda zb
    beq @done
:   tya
    beq @byte
    bne @check
@done:
    rts
@slow:
    jmp copy_loop

.segment "CODE"
prefix_cb:
    fetch_operand
    sta cb_op
    and #7
    tax
    ldy cb_regs,x
    sty cb_reg
    beq cb_mem
    lda $00,y
    jmp cb_decode
cb_mem:
    jsr read_hl
cb_decode:
    sta cb_value
    lda cb_op
    lsr
    lsr
    lsr
    and #7
    tax
    lda cb_op
    cmp #$40
    bcc cb_shift
    cmp #$80
    bcs modify_bit
    lda masks,x
    and cb_value
    sta fresult
    jmp dispatch
modify_bit:
    cmp #$c0
    lda masks,x
    bcs set_bit
    eor #255
    and cb_value
    jmp cb_write
set_bit:
    ora cb_value
    jmp cb_write
cb_shift:
    lda cb_value
    cpx #0
    beq cb_rlc
    cpx #1
    beq cb_rrc
    cpx #2
    beq cb_rl
    cpx #3
    beq cb_rr
    cpx #4
    beq cb_sla
    lsr
    jmp cb_flags
cb_rlc:
    cmp #128
    rol
    jmp cb_flags
cb_rrc:
    lsr
    lda cb_value
    ror
    jmp cb_flags
cb_rl:
    lsr fcarry
    rol
    jmp cb_flags
cb_rr:
    lsr fcarry
    ror
    jmp cb_flags
cb_sla:
    asl
cb_flags:
    sta fresult
    ldx #0
    bcc :+
    inx
:   stx fcarry
cb_write:
    ldy cb_reg
    beq :+
    sta $00,y
    jmp dispatch
:   jsr write_hl
    jmp dispatch
cb_regs: .byte zb,zc,zd,ze,zh,zl,0,za
cb_op: .byte 0
cb_reg: .byte 0
cb_value: .byte 0
masks: .byte 1,2,4,8,16,32,64,128
