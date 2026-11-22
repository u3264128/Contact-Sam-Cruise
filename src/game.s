; Native game routines. The event scan reads the writable JR opcode at
; 29986 and the jump target at 29964 before applying the POKEs.
.segment "EXT"
; All fourteen built-in records start within 256 bytes of EVENT01. Keep
; their offset in X until a condition passes. Read lengths, predicates and
; addresses live, so an event can still enable or rewrite a later record.
event_table = 24544
.pushseg
.segment "G0"
event_first_record:
    lda event_table,x
    clc
    adc #1
    beq @generic
    and #2
    beq :+
    jmp event_fast_next
:   lda event_table+4,x
    cmp #$58
    bcc @generic                ; bitmap, ROM and vector tail use the guest reader
    cmp #$ff
    beq @generic
    sta event_first_read+2
    lda event_table+3,x
    sta event_first_read+1
    ldy event_table+5,x
    sty 29986
    lda event_branch-$20,y
    sta event_first_predicate
    jmp event_first_compare
@generic:
    jmp event_at_offset
.segment "G1"
event_first_compare:
    lda event_table+2,x
    sta zb
event_first_read:
    lda a:$ffff
    cmp event_table+6,x
event_first_predicate:
    beq @passed
    jmp event_fast_next
@passed:
    jmp event_first_pass
.popseg

event_fast_next:
    lda event_table+1,x
    sta ze
    stx operand
    sec                         ; the length excludes the flag byte
    adc operand
    tax
    ldy #0
    sty zd
    sty fcarry
    bcs :+
    jmp event_first_record
:   inc zh                      ; finish with the unrestricted pointer walker
event_at_offset:
    jsr event_address
    jmp event_scan
event_first_pass:
    jsr event_address
    ldy #6                      ; first comparison already passed
    jmp event_pass
event_address:
    txa
    clc
    adc zl
    sta zl
    bcc :+
    inc zh
:   rts

event_scan:
    ldy #0
    lda (zl),y
    clc
    adc #1                      ; INC A: AND 2, as at 29962
    bne :+
    jmp event_done
:
    and #2
    beq :+
    jmp event_next
:   ldy #2
    lda (zl),y
    sta zb
event_condition:
    iny
    lda (zl),y
    sta addr
    iny
    lda (zl),y
    sta addr+1
    iny
    lda (zl),y
    sta 29986
    tax
    lda event_branch-$20,x
    sta @predicate
    iny
    lda addr+1
    cmp #$58
    bcc @mapped
    cmp #$ff
    beq @mapped
    ldx #0
    lda (addr,x)                ; read guest RAM without disturbing Y
    jmp @compare
@mapped:
    sty event_offset
    jsr read_addr
    ldy event_offset
@compare:
    cmp (zl),y
@predicate:
    beq event_pass              ; patched from the record's Z80 JR cc
    jmp event_next
event_pass:
    dec zb
    bne event_condition
    ; 29998: B = number of POKEs, then (DE) = A for each address and value.
    iny
    lda (zl),y
    sta zb
@poke:
    iny
    lda (zl),y
    sta addr
    iny
    lda (zl),y
    sta addr+1
    iny
    lda (zl),y
    sta za
    sty event_offset
    jsr write_addr
    ldy event_offset
    dec zb
    bne @poke
    lda addr
    sta ze
    lda addr+1
    sta zd
    ; 30010: keep the entry active if bit 6 is set, otherwise INC (HL).
    ldy #0
    lda (zl),y
    and #64
    bne event_next
    lda (zl),y
    clc
    adc #1
    sta (zl),y
event_next:
    ldy #1
    lda (zl),y
    sta ze
    ldx #0
    stx zd
    stx fcarry                  ; ADD HL,DE within the table
    sec
    adc zl
    sta zl
    bcc :+
    inc zh
:
    jmp event_scan
event_done:
    lda #0
    sta fresult
    sta za
    lda 29964
    ldx 29965
    cmp #<30051
    bne :+
    cpx #>30051
    bne :+
    jmp ret_z80                 ; JP Z,30051 reaches RET
:   jmp install_pc
event_offset: .byte 0
.pushseg
.segment "G2"
event_branch:                   ; JR NZ,Z,NC,C after unsigned CP
    .byte $d0
    .res 7
    .byte $f0
    .res 7
    .byte $b0
    .res 7
    .byte $90
.popseg

object_scan:
    ldy #0
    lda (zl),y
    clc
    adc #1                      ; INC A: AND 2, as at 30221
    beq @end
    and #2
    bne @next
    iny
    lda (zl),y
    cmp zc
    bne @next
    iny
    lda (zl),y
    cmp zb
    bne @next
    inc zl
    lda #0
    sta fresult
    sta fcarry
    lda zb
    sta za
    setpc 30244
@next:
    clc
    lda zl
    adc #4
    sta zl
    bcc object_scan
    inc zh
    jmp object_scan
@end:
    lda #0
    sta za
    sta fresult
    ; JR Z,30268 and JR 30339 lead to the icon update.

; 30339: colour the budgie and hook icons, then the four keys.
object_icons:
    lda 32680
    sta zl                      ; L = ID of the object beside Sam
    lda #0
    sta 32680
    lda 32745
    sta zh                      ; H = object inventory
    lda #176
    sta ze
    lda #6
    sta zb
    lda #2
    sta zc
@object:
    lsr fcarry                  ; RL L: RL H
    rol zl
    rol zh
    lda #48
    bcs @show                   ; Sam has this object
    lda zh
    lsr                         ; BIT 0,H
    lda #54                     ; ADD A,B clears the carry
    bcc @show
    lda #6                      ; Sam is next to it
    clc
@show:
    rol fcarry                  ; fcarry was shifted out above, so this is C
    sta za
    jsr show_icon
    lda #178
    sta ze
    dec zc
    bne @object
    ; At 30376, each ADD A,A tests one key. Carry makes its icon visible.
    lda 32746
    asl
    sta za
    ldx #0
@key:
    lda #54
    asl za
    bcc :+
    lda #48
:   sta 23280,x
    tay
    lda vic_attr,y
    sta $0404+23*40+16,x
    inx
    cpx #4
    bne @key
    lda 32746
    lsr
    lsr
    lsr
    and #1                      ; carry from the fourth ADD A,A
    sta fcarry
    lda #$f4
    sta zl
    sta fresult                 ; INC L
    lda #$5a
    sta zh
    lda #0
    sta zb
    lda #48
    sta zc
    jmp ret_z80

mark_height = $94
mark_bit = $95
column_step = $96
pose = $97

.pushseg
.segment "G20"
; NEXTCMD has three entries for the three levels of actor commands.
next_primary:
    ldy #9
    bne :+
next_interruptible:
    ldy #15
    bne :+
next_uninterruptible:
    ldy #19
:   sty zl
    jmp next_command
.segment "G21"
next_command:
    lda 32763
    sta za
    sta zh
    lda #0
    tay
    sta (zl),y
    jmp continue_actor
.popseg

; Attribute pairs at top/bottom of a panel icon are 32 bytes apart.
icon_attr:
    jsr show_icon
    jmp ret_z80
show_icon:
    ldx ze
    lda za
    sta $5a00,x
    sta $5a01,x
    tay
    lda vic_attr,y
    sta $0404+21*40-$a0,x
    sta $0405+21*40-$a0,x
    txa
    ora #64
    and #$df
    sta ze
    tax
    lda za
    sta $5a00,x
    sta $5a01,x
    lda vic_attr,y
    sta $0404+22*40-$c0,x
    sta $0405+22*40-$c0,x
    lda #90
    sta zd
    lda ze
    sta fresult
    rts
.segment "EXT"
schedule_second:
    guest_call schedule_actor, 61967
schedule_actor:
    ldx 32763
    inx
    cpx #230
    bne :+
    ldx #215
:   stx 32763
    stx zh
    lda 32692
    sta za
    sta fresult
    lda #0
    sta fcarry
    lda za
    beq @move
    jsr actor_frozen_sub
    lda fcarry
    beq @move
    jmp ret_z80
@move:
    lda #0
    sta zl
    ldy #3
    lda (zl),y
    bmi @ready
    eor #64
    sta (zl),y
    and #64
    bne @ready
    sta za
    sta fresult
    sty zl
    jmp ret_z80
@ready:
    ldy #19
    lda (zl),y
    bne run_command
    ldx zh
    cpx #222
    bcc commands
    ldy #28
    lda (zl),y
    beq commands
    jmp actor_continual
continue_actor:
    lda #0
    sta zl
commands:
    ldy #15
    lda (zl),y
    bne run_command
    sta za
    sta fcarry                  ; AND A with no interruptible subcommand
    ldy #3
    lda (zl),y
    and #16
    beq :+
    jmp actor_restart
:   ldy #9
    lda (zl),y
    bne run_command
    jmp actor_new_command
run_command:
    tax
    sta zb
    sta za
    dey
    lda (zl),y
    sta zc
    sty zl
    sty fresult
    ldy #0
    sty fcarry
    jmp install_pc

.pushseg
.segment "VM_actor_continual"
; The continual command returns to the original POP HL at 62028.
actor_continual:
    sta za
    tya
    ldx zh
    jsr push_ax
    lda #<62028
    ldx #>62028
    jsr push_ax
    ldy #28
    lda za
    jmp run_command

.segment "VM_actor_restart"
actor_restart:
    lda (zl),y                  ; byte 3 requests a fresh command list
    and #$ef
    sta (zl),y
    ldx #2
    ldy #26
:   lda (zl),y
    dey
    dey
    sta (zl),y
    iny
    dex
    bne :-                      ; bytes 25 and 26 became bytes 23 and 24
    txa
    ldy #22
    sta (zl),y
    sty ze
    lda zh
    sta zd
    jmp actor_new_command

.segment "VM_actor_new"
actor_new_command:
    lda zh
    cmp #222
    ldx #1
    bcc :+
    dex
    txa
    ldy #28
    sta (zl),y                  ; cancel the continual command
:   stx fcarry
    lda #8
    sta zl
    jsr get_params_sub
    ldy #0
    lda (zl),y
    tax
    stx zb
    dec zl
    lda zl
    sta fresult
    lda (zl),y
    sta zc
    jmp install_pc

.segment "VM_actor_frozen"
actor_frozen:
    jsr actor_frozen_sub
    jmp ret_z80
actor_frozen_sub:
    lda #4
    sta zl
    ldy #0
    lda (zl),y
    and #1
    sta fresult                 ; BIT preserves A and carry outdoors
    bne :+
    rts
:   sta zl
    lda (zl),y
    clc
    adc #1
    lsr
    lsr
    lsr
    tax
    lda $ffc0,x                 ; fuse timer for this column block
    sta ze
    lda #$7f
    sta zd
    lda (ze),y
    sta za
    sta fresult
    sty fcarry
    beq :+
    jmp actor_fuse_height
:   rts
.segment "VM_actor_fuse_height"
actor_fuse_height:
    inc zl
    lda ze
    ldx #0
    cmp #164
    bcc :+
    ldx #16
    cmp #166
    bcc :+
    ldx #10
:   stx ze
    txa
    sta za
    sec
    sbc (zl),y
    bcs @roof
    sta fresult
    inc fcarry
    rts
@roof:
    sty za
    sty fresult
    rts
.popseg

; Preserve HL and DE, including the caller's original L. The command
; list offset wraps as an 8-bit counter.
get_param:
    jsr param_byte
    sta za
    ; INC L in the source finally leaves the result byte 24.
    lda #24
    sta fresult
    lda #0
    rol
    sta fcarry
    jmp ret_z80
; A = the next byte of character H's command list, 6510 carry = the carry
; of the original ADD HL,DE. L is unchanged.
param_byte:
    lda zl
    pha
    lda #0
    sta zl
    ldy #22
    lda (zl),y
    tax
    clc
    adc #1
    sta (zl),y
    iny
    lda (zl),y
    sta addr
    iny
    lda (zl),y
    sta addr+1
    txa
    tay
    clc
    adc addr
    lda addr+1
    adc #0
    lda (addr),y
    tax
    pla
    sta zl
    txa
    rts
game_controls:
    ; Preserve the keyboard's priority at the game's input boundary.
    lda #<60085
    ldx #>60085
    jsr push_ax
    setpc 60121
; Dirty-region setup. Return early for an actor completely outside the
; camera. The visible path shares the paged mask walker with $ea56.
; mark_region_sub returns with rts so that native movers can call it.
mark_region:
    jsr mark_region_sub
    jmp ret_z80
mark_region_sub:
    ldy #0
    lda (zl),y
    sta pose
    and #127
    ldx #2
    ldy #2
    cmp #120
    bcs @shape
    and #7
    ldx #5
    ldy #3
    cmp #7
    bne @shape
    ldx #3
    ldy #5
@shape:
    stx zb
    stx mark_height
    sty zc
    lda $7fff
    sec
    sbc zb
    bcc @bottom
    cmp zd
    bcc :+
    jmp cmp_y
:
@bottom:
    lda $7fff
    clc
    adc #19
    sec
    sbc zd
    bcs :+
    jmp mark_borrow
:
    eor #255
    clc
    adc #24
    asl
    asl
    sta zd
    lda $7ffe
    sec
    sbc zc
    bcc @right
    cmp ze
    bcc :+
    jmp cmp_x
:
@right:
    lda $7ffe
    clc
    adc #31
    sec
    sbc ze
    bcs :+
    jmp mark_borrow
:
    lda ze
    sec
    sbc $7ffe
    sta dx
    lda pose
    and #7
    bne :+
    inc pose
    inc pose
:   lda pose
    ora #128
    sta sprite
    lda #215
    sta sprite+1
    lda zb
    sta column_step
    lda pose
    bpl @clip
    ldx zc
    dex
    lda sprite+1
    clc
:   adc zb
    dex
    bne :-
    sta sprite+1
    lda #0
    sec
    sbc zb
    sta column_step
@clip:
    lda dx
    bpl @visible
:   lda sprite+1
    clc
    adc column_step
    sta sprite+1
    dec zc
    inc dx
    bmi :-
@visible:
    lda dx
    and #7
    tax
    lda bit_order,x
    sta mark_bit
    lda dx
    sta ze
    lsr
    lsr
    lsr
    clc
    adc zd
    sta zb
    lda #127
    sta zd
    lda column_step
    sec
    sbc mark_height             ; the unrolled reader consumes height pages
    sta column_step
@column:
    ldx zb
    ldy #0
    ; X stays at the top SRB byte. Rows are four bytes apart, including
    ; the padding above and below the playfield used by clipped actors.
    ; Read live sprite references: costumes and animations can replace them.
    .repeat 5,row
        lda (sprite),y
        beq :+
        lda $7f00+4*row,x
        ora mark_bit
        sta $7f00+4*row,x
        .if row = 0
            stx ze
        .else
            txa
            clc
            adc #4*row
            sta ze
        .endif
:       inc sprite+1
        .if row = 1 || row = 2
            lda mark_height
            cmp #row+1
            beq @next_column
        .endif
    .endrepeat
@next_column:
    lda sprite+1
    clc
    adc column_step
    sta sprite+1
    lsr mark_bit
    bcc @more
    ror mark_bit
    inc zb
    lda zb
    and #3
    beq @end
@more:
    dec zc
    beq @end
    jmp @column
@end:
    jmp mark_finished
.pushseg
.segment "G15"
mark_finished:
    sta za
    lda zc                      ; sprite columns left when the right edge clips
    sta alternate
    lda mark_height
    sta alternate+1
    sta alternate+2
    clc
    adc column_step             ; restore the signed page stride
    sta alternate+3
    lda sprite
    sta alternate+4
    lda sprite+1
    sta alternate+5
    lda mark_bit
    sta zc
    lda #0
    sta fresult
    sta fcarry
    rts
.popseg
cmp_y:
    sta za
    sec
    sbc zd
    jmp mark_difference
cmp_x:
    sta za
    sec
    sbc ze
mark_difference:
    sta fresult
    lda #0
    sta fcarry
    rts
mark_borrow:
    sta za
    sta fresult
    lda #1
    sta fcarry
    rts
; Draw four status icons from the current proximity flags. Other callers
; enter show_icon directly to colour an individual icon such as the hook.
panel_flags:
    ldx #0
@icon:
    lda 32680
    and panel_masks,x
    beq :+
    lda #48
    bne :++
:   lda #54
:   sta za
    lda panel_offsets,x
    sta ze
    txa
    pha
    jsr show_icon
    pla
    tax
    inx
    cpx #4
    bne @icon
    lda #0
    sta 32680
    sta za
    sta zb
    sta fresult
    sta fcarry
    lda #174
    sta ze
    jmp ret_z80
panel_offsets: .byte 168,170,172,174
panel_masks: .byte 128,64,32,16

panel_check:
    lda #0
    sta zl
    lda #230
    sta zh
    lda 58880
    and #1
    beq :+
    sta fresult
    jmp ret_z80
:   lda 32764
    beq :+
    jmp panel_flags
:
    lda 32747
    bmi @door
    lda 58882
    cmp #31
    beq @house
    cmp #33
    bne @indoor
    ldx #13
    bne @doors
@house:
    ldx #0
@doors:
    lda 29647,x
    cmp #255
    beq @indoor
    cmp 58881
    beq @door
    inx
    bne @doors
@door:
    lda 32680
    ora #64
    sta 32680
@indoor:
    lda 58884
    and #1
    bne :+
    jmp panel_flags
:
    ldx 58882
    cpx #33
    beq @shop
    cpx #32
    bcc :+
    jmp panel_flags
:
    lda floor_bits,x
    cmp #255
    bne :+
    jmp panel_flags
:
@on_floor:
    sta fixture_row
    ldx #10
    ldy #5
@fuses:
    lda 29635,x
    cmp 58882
    bne @next
    lda 29636,x
    cmp 58881
    bne @next
    lda masks,y
    and 32694
    bne @furniture
    lda 32680
    ora #128
    sta 32680
    bne @furniture
@next:
    dex
    dex
    dey
    bpl @fuses
    bmi @furniture
@shop:
    lda #128
    sta fixture_row
@furniture:
    lda 58880
    asl
    lda 58881
    bcc :+
    adc #1
:   tax
    lsr
    lsr
    lsr
    ora fixture_row
    tay
    txa
    and #7
    beq @left
    cmp #7
    beq @right
    lda $f500,y
    and #2
    beq @finish
    ; BYPHONE reaches RINGING through 62596. Recreate its successful
    ; fixture lookup, including the window pointer and ADD A,185 flags.
    lda $f500,y
    sta za
    tya
    and #31
    ora #64
    sta zc
    lda fixture_row
    .repeat 5
        lsr
    .endrepeat
    sta zl
    clc
    adc #185
    sta zb
    sta fresult
    lda #0
    sta fcarry
    sty ze
    lda #245
    sta zd
    lda #<29815
    ldx #>29815
    jsr push_ax
    setpc 30429
@left:
    lda #128
    bne @switch
@right:
    lda #64
@switch:
    and $f500,y
    beq @finish
    lda 32680
    ora #32
    sta 32680
@finish:
    jmp panel_flags
fixture_row: .byte 0
floor_bits:
    .repeat 32,i
        .if (i >= 7) && ((i .mod 6) = 1)
            .byte ((i-7)/6)*32
        .else
            .byte 255
        .endif
    .endrepeat
