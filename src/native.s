; Native replacements for common Z80 routines. Preserve live registers,
; the sign, zero and carry flags, and the memory effects of each call.
; tools/native_test.py compares these results with the original.
.segment "CODE"

.pushseg
.segment "ROWCODE"
; PRINTMSG ($6e00). The original uses the same glyph for ASCII n and
; n+128, and stops at either $00 or $80. DE can start mid-row. Convert
; its address once per character, then write all eight contiguous bytes.
print_message:
    lda zl
    sta addr
    lda zh
    sta addr+1
    jsr read_addr
    asl
    sta za
    sta fresult
    ldx #0
    bcc :+
    inx
:   stx fcarry
    cmp #0
    bne :+
    jmp ret_z80
:   cmp #64                     ; control glyphs use the guest ROM reader
    bcc @original
    lda zd
    cmp #$58
    bcs @original
    and #$e7                    ; aligned start in $40/$48/$50
    cmp #$40
    bne @original
    lda ze
    sta addr
    lda zd
    sta addr+1
    jsr pixel_address           ; X = VIC row, vptr = first byte
    php
    jsr cell_window
    jsr draw_glyph
    plp
    lda #0
    sta zb
    inc ze                      ; INC E never carries into D
    inc zl
    bne print_message
    inc zh
    jmp print_message
@original:
    setpc 28162                 ; A and flags already match ADD A,A

; Expand ordinary letters in a single pass. The original handles nested
; messages, newlines and the rollback of the last word on buffer overflow.
message_chars:
    lda zh
    cmp #$7f
    bne @mapped
    lda alternate+5
    cmp #$7f
    beq message_next
@mapped:
    jmp message_mapped
message_next:
    lda 32641
    ora #128
    tax
    lda $7f00,x
    sta ze
    sta addr
    inc $7f00,x
    inx                         ; legal nesting depths are 0,2,4,6,8
    stx zl
    lda $7f00,x
    sta zd
    sta addr+1
    ldy ze
    iny
    bne :+
    inc $7f00,x
:   jsr read_addr
    sta za
    cmp #32
    bcs :+
    jmp message_control
:   bne :+
    jmp message_space
:
    cmp #96
    bcc :+
    jmp message_extended
:
    jmp message_store
.popseg
message_mapped:
    lda #129
    sta zl
    lda #<28514
    jmp message_resume

.pushseg
.segment "ROWCODE"
message_space:
    ldx #15                     ; original LDIR saves the word boundary
:   lda 32641,x
    sta 32512,x
    dex
    bpl :-
    inx
    stx zb
    stx zc
    lda #16
    sta ze
    lda #$7f
    sta zd
    lda #145
    sta zl
    jmp message_store
.popseg
message_store:
    inc alternate+4
    ldx alternate+4
    lda za
    sta $7f00,x
    txa
    bmi :+
    jmp message_next
:
    lda #128                    ; BIT 7,L' and carry from CP 96
    sta fresult
    lda #1
    sta fcarry
    lda #<28580
message_resume:
    ldx #>28512                 ; all parser continuations are in $6fxx
    jmp install_pc
.pushseg
.segment "G1"
message_control:
    lda za
    beq @end
    sec
    sbc #32
    sta fresult
    lda #1
    sta fcarry
    lda #<28496
    jmp message_resume
@end:
    sta fresult
    sta fcarry
    lda #<28528
    jmp message_resume
.segment "G3"
message_extended:
    bne :+
    jmp message_newline
:
    sec
    sbc #100
    sta fresult
    bcs @sub
    lda #1
    sta fcarry
    lda #<28604
    jmp message_resume
@sub:
    lda #0
    sta fcarry
    lda #<28496
    jmp message_resume
.segment "G4"
message_newline:
    lda #0
    sta fresult
    sta fcarry
    lda #<28534
    jmp message_resume
.popseg

; 26075. Move the camera-relative x coordinate even for inactive bullets.
; Active, visible shots continue in the original drawing/collision code.
move_bullets:
    lda #>32743
    sta zh
    lda #<32743
    sta zl
    dec 32743
    lda 32743
    sta fresult
    beq :+
    jmp ret_z80                 ; DEC preserves guest carry and A
:   lda 32671
    and #3
    eor #3
    clc
    adc #3
    sta 32743
    lda #3
    sta zc
    ldx #0
@bullet:
    lda 32766
    sta ze
    lda 32767
    sta zd
    lda 32704,x
    sec
    sbc ze
    clc
    adc 32705,x
    sta ze
    sta za
    sta 32705,x
    lda 32766
    sta 32704,x
    lda #0
    sta fcarry
    lda ze
    cmp #32
    bcs @inactive
    lda 32706,x
    sta za
    sta fresult
    beq @inactive
    txa
    clc
    adc #194
    sta zl
    setpc 26120
@inactive:
    lda #0
    sta 32706,x
    cpx #4
    beq @done
    ldx #4
    bne @bullet
@done:
    lda #200
    sta zl
    lda #8                      ; BIT 3,L after the second buffer
    sta fresult
    jmp ret_z80

; 30429 / 30442. Both tables have three-byte entries. Keep HL at the
; matching entry or terminator; a terminator of FE and FF differs in A.
ringing:
    lda #<32665
    sta zl
    lda #>32665
    sta zh
    lda 23673
    sec
    sbc 32665
    sta za
    sec
    sbc #3
    bcs :+
    sta fresult
    lda #1
    sta fcarry
    jmp ret_z80
:   lda #<27467
    sta zl
    lda #>27467
    sta zh
phone_search:
    ldy #0
@entry:
    lda (zl),y
    cmp ze
    beq @match
    cmp #254
    bcs @end
    iny
    iny
    iny
    bne @entry                  ; both game tables occupy less than one page
@end:
    adc #1                      ; carry is set: original ADD A,2
    ldx #1
    bne @return
@match:
    ldx #0
@return:
    sta za
    sta fresult
    stx fcarry
    tya
    clc
    adc zl
    sta zl
    bcc :+
    inc zh
:   jmp ret_z80

; CP X with A in za: S/Z from the difference, carry on borrow.
cp_x:
    stx operand
    lda za
    sec
    sbc operand
    sta fresult
    lda #0
    adc #0
    eor #1
    sta fcarry
    rts
ccf_flag:
    lda fcarry
    eor #1
    sta fcarry
    rts

; 60152: is the character in page H on the sidewalk or the road? Returns
; with E/D = x/y, L = 4 and carry reset for the sidewalk or road.
rdorswalk:
    jsr rdorswalk_sub
    jmp ret_z80
rdorswalk_sub:
    ldy #1
    sty zl
    dey
    lda (zl),y
    sta ze
    inc zl
    lda (zl),y
    sta zd
    lda #4
    sta zl
    lda zd                      ; 60159
    sta za
    ldx #34
    jsr cp_x
    lda fcarry
    bne @done                   ; RET C
    lda fresult
    bne @done                   ; RET NZ
    lda ze                      ; 60164
    sta za
    ldx #7
    jsr cp_x
    jsr ccf_flag
    lda fcarry
    beq @done                   ; RET NC
    ldx #15
    jsr cp_x
    lda fcarry
    bne @done                   ; RET C
    ldx #164
    jsr cp_x
    jsr ccf_flag
    lda fcarry
    beq @done                   ; RET NC
    ldx #199
    jsr cp_x
@done:
    rts

; 60179: location descriptors for the character in page H.
locdescs:
    jsr locdescs_sub
locdescs_return:
    bcc :+
    jsr closed_location_sub
:   jmp ret_z80
; Returns with the 6510 carry set when the original continues at 60720.
locdescs_sub:
    jsr rdorswalk_sub
    ldy #0
    lda fcarry
    bne @off_road
    lda zl                      ; LD (HL),L: z = 4 on the sidewalk
    sta (zl),y
    lda #196
    sta zd
    sta addr+1
    lda ze
    sta addr
    lda (addr),y                ; LD A,(DE) from the table at 50176
    sta zc
    lda #1
    sta za
    clc
    rts
@off_road:                      ; 60192
    lda (zl),y
    sta za
    ldx #4
    jsr cp_x
    lda fresult
    bne @y
    lda #2
    sta (zl),y
@y:                             ; 60199: B = 4*(y-4)
    lda zd
    sec
    sbc #4
    asl
    asl
    sta za
    sta zb
    sta fresult
    lda #0
    rol
    sta fcarry
    lda (zl),y                  ; BIT 0,(HL)
    and #1
    sta fresult
    bne @swap
    lda zb
    ora #128
    sta zb
@swap:                          ; 60211: EX DE,HL
    ldx zl
    lda ze
    sta zl
    stx ze
    lda zh
    sta zd
    lda #197
    sta zh
    lda (zl),y                  ; LSB from the table at 50432
    sec
    sbc #2
    sta za
    sta fresult
    lda #0
    adc #0
    eor #1
    sta fcarry
    inc zh
    lda (zl),y                  ; MSB from the table at 50688
    sta zh
    lda zl
    sta ze
    lda za
    sta zl
@inc1:                          ; 60221
    inc zl
@inc2:                          ; 60222, also entered from the closed door path
    inc zl
    lda zl
    sta fresult
    beq @none
    lda (zl),y
    clc
    adc #1
    sta fresult
    bne @found
    sta za
@none:                          ; 60229
    lda #192
    sta zc
    lda #2
    sta za
    clc
    rts
@found:                         ; 60234: DEC A: INC L: ADD A,A
    lda (zl),y
    inc zl
    asl
    sta za
    sta fresult
    bcs @bit7
    lda #0
    sta fcarry
    ldx zb
    jsr cp_x                    ; CP B
    lda fresult
    bne @inc2
    lda (zl),y
    sta zc
    lda #2
    sta za
    clc
    rts
@bit7:                          ; 60246: ADD A,A
    asl
    sta za
    sta fresult
    bcs @bit6
    lda #0
    sta fcarry
    ldx zb
    jsr cp_x
    lda fresult
    bne @inc1
    lda #5
    sta za
@pair:                          ; 60254: C = Q', B = Q''
    lda (zl),y
    sta zc
    inc zl
    lda zl
    sta fresult
    lda (zl),y
    sta zb
    clc
    rts
@bit6:                          ; at 60258, C = B AND 127 before CP C
    lda #1
    sta fcarry
    lda zb
    and #127
    sta zc
    tax
    jsr cp_x
    lda fresult
    bne @inc1
    inc zl                      ; BIT 0,(HL): a door at this entrance?
    lda (zl),y
    and #1
    sta fresult
    beq @open
    lda ze                      ; door table entry INT((x+1)/8)
    clc
    adc #1
    lsr
    lsr
    lsr
    and #31
    sta za
    lda #0
    sta fcarry
    ldx za
    lda 189*256,x
    and #4                      ; BIT 2,(HL) with HL restored by POP
    sta fresult
    beq @open
    sec                         ; the door is closed: continue at 60720
    rts
@open:                          ; 60286
    lda #3
    sta za
    dec zl
    lda zl
    sta fresult
    jmp @pair
location_scan = @inc2

; 61440: main loop tasks by the value of the task timer at 32681 mod 8.
loop_tasks:
    lda #<32681
    sta zl
    lda #>32681
    sta zh
    dec 32681
    lda 32681
    and #7
    sta za
    lsr
    bcs @odd
    tax
    lda task_lo,x
    ldy task_hi,x
    sty zpc+1
    sta zpc
    ldx #0
    stx fcarry
    stx fresult                 ; AND 7 or the matching CP returned zero
    jmp dispatch
@odd:
    ldx #6                      ; the last comparison in the original
    jsr cp_x
    jmp ret_z80
.pushseg
.segment "G0"
task_lo: .lobytes 61764,28404,62468,31414
task_hi: .hibytes 61764,28404,62468,31414
.popseg

; These fixed CALLs retain the guest return addresses. An action or a
; cutscene can still unwind the original stack and resume mid-loop.
frame_panel:
    guest_call frame_icons, 61489
frame_icons:
    guest_call panel_check, 61571
frame_actors:
    guest_call fuse_check, 61492

midstride:
    ldy #0
    sty zl
stride_pose:
    ldy #0
    lda (zl),y
    and #1
    sta fresult
    bne :+
    jmp ret_z80
:   jsr pop_ax
    sta zc
    stx zb
    setpc 60506

sam_action:
    lda 32764
    jsr flags_a
    beq :+
    setpc 61498
:   jmp sam_timer

; Wait for the same 50 Hz guest clock increment as the Spectrum.
main_clock:
    lda #<32712
    sta zl
    lda #>32712
    sta zh
:   lda 23672
    cmp 32712
    beq :-
    sta za
    sta fresult
    sta 32712
    lda #0
    adc #0
    eor #1                      ; wrapped ADD A,(HL) sets guest carry
    sta fcarry
    setpc 61483

; 61571, 61579 and 61588: the steps after each CALL in 61568.
tasks_mode:                     ; LD A,(32750): AND A: RET Z: CALL 26075
    lda 32750
    jsr flags_a
    bne :+
    jmp ret_z80
:   lda #<61579
    ldx #>61579
    jsr push_ax
    lda #<26075
    ldx #>26075
    jmp install_pc
tasks_sam:                      ; LD A,(32764): AND 129: RET NZ: CALL 29952
    lda 32764
    and #129
    jsr flags_a
    beq :+
    jmp ret_z80
:   lda #<61588
    ldx #>61588
    jsr push_ax
    ; fall into 29952
events:                         ; 29952: JP target 30051, HL = event table
    lda #<30051
    sta 29964
    lda #>30051
    sta 29965
    lda #<24544
    sta zl
    lda #>24544
    sta zh
    ldx #0
    jmp event_first_record
tasks_found:                    ; LD A,(58880): AND 29: RET NZ: JP 30211
    lda 58880
    and #29
    jsr flags_a
    beq found_object
    jmp ret_z80
found_object:                   ; 30211: C/B = Sam's x/y, HL = object table
    lda 58881
    sta zc
    lda 58882
    sta zb
    lda #2
    sta fresult                 ; INC L
    lda #<32028
    sta zl
    lda #>32028
    sta zh
    jmp object_scan
; A = AND result: set A, S/Z and reset the carry. Returns with Z from A.
.pushseg
.segment "G22"
flags_a:
    sta za
    sta fresult
    ldx #0
    stx fcarry
    tax
    rts
.popseg

.pushseg
.segment "RECLAIM6"
; 61823: add 257 to the seed at 32734, then A = LSB of FRAMES XOR (seed).
; The seed may point into the ROM, so the read goes through read_addr.
get_random:
    inc 32734
    bne :+
    inc 32735
:   inc 32735
    lda 32734
    sta addr
    lda 32735
    sta addr+1
    jsr read_addr
random_frame_read:
    eor 23672
    sta za
    sta fresult
    lda #0
    sta fcarry
    jmp ret_z80
.popseg

; 60506: finish a stride. 59848, then A/E/D from bytes 5-7, byte 7 = 0,
; then 59861.
end_stride:
    jsr srb_update_sub
    ldy #5
    lda (zl),y
    sta za
    iny
    lda (zl),y
    sta ze
    iny
    lda (zl),y
    sta zd
    lda #0
    sta (zl),y
    jsr set_state_sub
    jmp ret_z80

; 61764: every 16th task tick, count down the door close timers at
; 32752-32761. 61696 closes a door and returns to 61787, then 61770.
shut_doors:
    ldy #0
    lda (zl),y
    and #15
    jsr flags_a
    beq :+
    jmp ret_z80
:   lda #250
    sta zl
door_loop:                      ; 61770
    dec zl
    lda zl
    and #16                     ; BIT 4,L
    sta fresult
    bne :+
    jmp ret_z80
:   ldy #0
    lda (zl),y
    and #7
    jsr flags_a
    beq door_loop
    lda (zl),y
    sec
    sbc #1
    sta (zl),y                  ; DEC (HL)
    dec za                      ; DEC A
    lda za
    sta fresult
    bne door_loop
    lda zl                      ; PUSH HL: CALL 61696
    ldx zh
    jsr push_ax
    lda #<61787
    ldx #>61787
    jsr push_ax
    setpc 61696

.pushseg
.segment "RECLAIM7"
; 62468: count down the six blown-fuse delay counters at 32674-32679.
; A counter that reaches 0 continues at 62484 to fix the fuse.
chk_fuses:
    lda #<32674
    sta zl
    lda #>32674
    sta zh
@fuse:
    ldy #0
    lda (zl),y
    jsr flags_a                 ; AND A
    beq @next
    sec
    sbc #1
    sta (zl),y
    sta fresult
    bne @next
    setpc 62484
@next:
    inc zl
    lda zl
    and #8                      ; BIT 3,L
    sta fresult
    beq @fuse
    jmp ret_z80
.popseg

; 61948: OR together the blown-fuse delay counters at 32674-32679, store the
; result at 32692, then CALL 61967 (the native schedule_actor) twice.
fuse_check:
    lda 32674
    .repeat 5,i
        ora 32675+i
    .endrepeat
    sta 32692
    ldx #0
    stx zb
    guest_call schedule_actor, 61964

; 59848: D/E = the coordinates of character H, then 59868 (mark_region)
; with HL at byte 0 of the buffer and DE saved around it. Returns A = the
; animatory state.
srb_update:
    jsr srb_update_sub
    jmp ret_z80
srb_update_sub:
    ldy #0
    lda #2
    sta zl
    lda (zl),y
    sta zd
    sta saved_de+1
    dec zl
    lda (zl),y
    sta ze
    sta saved_de
    dec zl
    jsr mark_region_sub
    lda saved_de
    sta ze
    lda saved_de+1
    sta zd
    ldy #0
    lda (zl),y
    sta za
    rts
saved_de: .word 0
; 59858: POP DE: LD A,(HL): RET, after an interpreted CALL 59868.
srb_return:
    jsr pop_ax
    sta ze
    stx zd
    ldy #0
    lda (zl),y
    sta za
    jmp ret_z80
; 59861: store the new animatory state A and coordinates D/E for character
; H, then fall into 59868.
set_state:
    jsr set_state_sub
    jmp ret_z80
set_state_sub:
    ldy #0
    lda #2
    sta zl
    lda zd
    sta (zl),y
    dec zl
    lda ze
    sta (zl),y
    dec zl
    lda za
    sta (zl),y
    jmp mark_region_sub

.segment "RECLAIM0"
; 62368 WINDOWSRB. Set the SRB bit of every window tile in the 8x6 block
; that holds the window at H/L. Both early returns keep A and CP's flags.
; The loop leaves B=0, C=128, D=127, E=top SRB byte, H=192, L=Z+128,
; H'/L'=191/Z, C'=1 and RRC C's flags, as the original does.
window_srb:
    lda zl
    and #$bf                    ; RES 6,L
    sta zl
    lda 32767
    sta zb
    lda 32766
    sta zc
    .repeat 3                   ; RRCA
        lsr
        bcc :+
        ora #$80
:
    .endrepeat
    sta ze
    lda zl
    sec
    sbc ze
    sta za
    cmp #4
    bcc @on_x
    sbc #4
    bcs @off                    ; CP 4: RET NC
@on_x:
    sta ze
    lda zh
    sec
    sbc #184
    sta tmp
    asl
    clc
    adc tmp
    asl
    sta zd                      ; 6*(H-184)
    sec
    sbc zb
    clc
    adc #4
    sta za
    cmp #21
    bcc @on_y
    sbc #21
@off:                           ; CP 21: RET NC
    sta fresult
    lda #0
    sta fcarry
    jmp ret_z80
@on_y:
    asl
    asl
    clc
    adc ze
    sta ze
    lda #127
    sta zd
    ldy #0
    lda (zl),y                  ; Z
    sta alternate+4
    tax
    ora #128
    sta zl
    lda $bf00,x                 ; Z'
    sta value
    lda #191
    sta alternate+5
    lda #1
    sta alternate
    lda #184
    sta zh
    lda #128
    sta zc
@column:                        ; H = 184+column, C = the column bit
    ldy #0
    lda (zl),y                  ; Z''
    tax
    lda value
    and zc
    beq :+
    lda #12
:   clc
    adc #160
    sta @tile+2                 ; T in page 160 or 172, then every second page
    ldy ze
    lda #6
    sta tmp
@row:
@tile:
    lda $a000,x
    and #$c0
    cmp #$80
    bne @next
    lda $7f00,y
    ora zc
    sta $7f00,y
@next:
    inc @tile+2
    inc @tile+2
    lda @tile+2
    cmp #$a8                    ; the last two rows share the same aliases
    bne :+
    jsr tile_column_alias
:   iny
    iny
    iny
    iny
    dec tmp
    bne @row
    inc zh
    lsr zc
    bcc @column
    jmp window_srb_done
.segment "VM_window_done"
window_srb_done:
    lda #128
    sta zc
    sta fresult
    lda #1
    sta fcarry
    lda #0
    sta zb
    lda ze
    sta za
    jmp ret_z80

.segment "RECLAIM1"
; 28186 PRINTNUM. Right-align the decimal digits of HL in the buffer at
; 32714 with leading spaces, then print it with HL=32714 and DE unchanged.
; The original leaves A=units digit (flags from ADD A,L), B=255 and C=246.
print_num:
    lda #32
    ldx #4
:   sta 32714,x
    dex
    bpl :-
    inx
    ldy #0                      ; Y becomes nonzero at the first digit
@digit:
    lda #48
    sta tmp
@subtract:
    lda zl
    sec
    sbc @power_lo,x
    sta operand
    lda zh
    sbc @power_hi,x
    bcc @store
    sta zh
    lda operand
    sta zl
    inc tmp
    bne @subtract
@store:
    lda tmp
    cmp #48
    bne :+
    cpy #0
    beq @skip
:   ldy #1
    sta 32714,x
@skip:
    inx
    cpx #4
    bne @digit
    lda zl
    clc
    adc #48
    sta 32718
    sta za
    sta fresult
    lda #0
    sta fcarry
    lda #255
    sta zb
    lda #246
    sta zc
    lda #<32714
    sta zl
    lda #>32714
    sta zh
    jmp print_message
@power_lo: .lobytes 10000,1000,100,10
@power_hi: .hibytes 10000,1000,100,10

.segment "VM_get_params"
; 61809 GETPARAMS: copy two command-list bytes to (HL) and (HL+1). Returns
; with L at the second byte, A=0, S/Z from the final DEC L and the
; caller's carry (POP AF).
get_params:
    jsr get_params_sub
    jmp ret_z80
.segment "RECLAIM4"
get_params_sub:
    jsr param_byte
    ldy #0
    sta (zl),y
    inc zl
    jsr param_byte
    ldy #0
    sta (zl),y
    sty za
    lda zl
    sta fresult
    rts

.segment "RECLAIM3"
; 60726 LOCID with its entries at 60734 (C, D, E given) and 60743 (outside
; or indoors). Returns A=255 above the sidewalk outdoors, A=0 on the
; sidewalk or road, else the location identifier from the region tables in
; page 239 with D/E = the staircase columns. The pushed AF of 60763 supplies
; the Z and carry flags on the later exits. L is restored after 60749.
locid:
    lda #0
    sta zl
    ldy #1
    lda (zl),y
    sta ze
    iny
    lda (zl),y
    sta zd
    ldy #4
    lda (zl),y
    sta zc
    sty zl
locid_z:                        ; 60734 BIT 0,C
    lda zc
    and #1
    bne @road
    lda zd                      ; CP 31: SBC A,A: RET C
    cmp #31
    bcs @road
    lda #255
    sta za
    sta fresult
    lda #1
    sta fcarry
    jmp ret_z80
@road:
    jmp locid_road
locid_building:                 ; 60749 PUSH HL
    lda zl
    pha
    lda #37
    ldx #9
@floor:
    inx
    sec
    sbc #6
    cmp zd
    bcs @floor
    sec                         ; SUB D: ADD A,6
    sbc zd
    clc
    adc #6
    sta tmp                     ; A and the Z flag of PUSH AF
    lda #0
    rol
    sta operand                 ; its carry
    lda $ef00,x
    sta addr
    lda #$ef
    sta addr+1
    ldy #0
    lda ze
@search:                        ; the first record whose first byte > E
    cmp (addr),y
    bcc @found
    iny
    iny
    iny
    iny
    bne @search
    inc addr+1
    bne @search
@found:
    tya
    clc
    adc addr
    sta addr
    bcc :+
    inc addr+1
:   ldy #3
    lda (addr),y
    sta ze
    dey
    lda (addr),y
    sta zd
    dey
    lda (addr),y
    sta za
    pla
    sta zl                      ; POP HL
    jmp locid_result

.segment "RECLAIM5"
locid_road:                     ; 60743 CALL 60159: LD A,0: RET NC
    lda zd
    ldx #34
    cmp #34
    bcc @building
    bne @road
    lda ze
    ldx #7
    cmp #7
    bcc @road                   ; CCF
    ldx #15
    cmp #15
    bcc @building
    ldx #164
    cmp #164
    bcc @road                   ; CCF
    ldx #199
    cmp #199
    bcc @building
@road:
    stx operand
    sec
    sbc operand
    sta fresult
    lda #0
    sta za
    sta fcarry
    jmp ret_z80
@building:
    jmp locid_building

.segment "EXT"
locid_result:                   ; 60781 with the record's A, D and E
    lda za
    cmp #80
    bcc @shop
    and #15
    cmp #4
    bne @other
    lda tmp
    bne @other
@shop:                          ; 60786: BIT 0,C: RET NZ: SUB 2
    lda zc
    and #1
    beq @sub2
    sta fresult
    lda operand
    sta fcarry
    jmp ret_z80
@sub2:
    lda za
    sec
    sbc #2
    sta za
    sta fresult
    lda #0
    rol
    eor #1
    sta fcarry
    jmp ret_z80
@other:                         ; 60804: POP AF: RET Z: INC A
    lda operand
    sta fcarry
    lda tmp
    beq :+
    inc za
    lda za
:   sta fresult
    jmp ret_z80

.segment "RECLAIM2"
; Door duty and the walkabout command share the entry at 63331 with BC
; already set. Keep the knock flags and counters writable by other actors.
door_walk:
    lda #<63209
    sta zc
    lda #>63209
    sta zb
door_duty:
    lda #0
    sta zl
    ldy #11
    lda (zl),y
    sta ze
    tax
    lda #127
    sta zd
    lda $7f00,x
    bmi @knock
    iny
    lda (zl),y
    iny
    clc
    adc (zl),y
    sta (zl),y
    sta za
    sta fresult
    lda #0
    rol
    sta fcarry
    lda #10
    sta zl
    lda fresult
    beq @finished
    setpc 63373
@finished:
    setpc 63360
@knock:
    eor #$c0
    sta $7f00,x
    sta za
    sta fresult
    lda #0
    sta fcarry
    sty zl
    setpc 62080

.segment "EXT"
; PUSH BC followed by RET executes the new command with the same SP.
run_subcommand:
    lda #14
    sta zl
    ldy #0
    lda zc
    sta (zl),y
    inc zl
    lda zb
    sta (zl),y
    lda zl
    sta fresult
    lda zc
    ldx zb
    jmp install_pc

; CHKREGION. The game's region records are ordinary RAM. INC HL is a
; full word increment, and the last upper bound consumes its byte even
; when the comparison fails. INC/DEX preserve the host carry here.
check_region:
    lda #1
    sta ze
    ldy #0
@axis:
    lda (ze),y
    sta za
    sec
    sbc (zl),y
    sta fresult
    bcc @outside
    jsr @advance
    lda za
    sec
    sbc (zl),y
    sta fresult
    ldx ze
    dex
    bne @last
    bcs @outside
    jsr @advance
    inc ze
    jmp @axis
@last:
    jsr @advance
    bcc @inside
@outside:
    lda #1
    bne @return
@inside:
    lda #0
@return:
    sta fcarry
    jmp ret_z80
@advance:
    inc zl
    bne :+
    inc zh
:   rts

.pushseg
.segment "VM_move_banknote"
move_banknote:
    lda 32745
    and #64
    beq banknote_check_range
    jsr srb_update_sub
    ldx #<25433                 ; the hook takes over this character buffer
    lda #>25433
    jsr store_primary
    jmp ret_z80
banknote_check_range:
    jmp banknote_range

.segment "VM_bind_primary"
; The next instruction after the guest CALL becomes the actor's primary command.
bind_primary:
    ldy #0
    lda (zsp),y
    tax
    iny
    lda (zsp),y
    jsr store_primary
    jmp ret_z80
store_primary:
    ldy zl
    sty za
    ldy #0
    sty zl
    ldy #9
    sta (zl),y
    sty fresult                 ; INC L leaves carry intact
    dey
    txa
    sta (zl),y
    lda za
    sta zl
    rts
.popseg

; Mark the old sprite before moving it. A note that Sam landed on or that
; drifted outside the camera restarts eleven columns to the left.
banknote_range:
    ldy #0
    sty zl
    ldy #10
    lda (zl),y
    beq @test_range
    lda #0
    sta (zl),y
    beq @restart
@test_range:
    ldy #1
    lda $7ffe
    sec
    sbc #12
    bcc @add
    cmp (zl),y
    bcs @restart
@add:
    clc
    adc #60
    bcs @near
    cmp (zl),y
    bcs @near
@restart:
    jsr srb_update_sub
    ldx #34
    stx zd
    ldx #0
    lda $7ffe
    sec
    sbc #11
    bcs :+
    lda #255
    inx
:   stx fcarry
    sta ze
    sta za
    sta fresult
    setpc 25480
@near:
    jsr srb_update_sub
    setpc 25480

; The guest pushes the previous pose before calling the random routine.
; Draw again on a tie. Otherwise keep the random byte for the drift.
banknote_pose:
    lda za
    sta zc
    and #136
    clc
    adc #62
    sta zb
    jsr pop_ax
    txa
    cmp zb
    bne @move
    sta za
    lda #0
    sta fcarry
    sta fresult
    setpc 25480
@move:
    lda zb
    sta za
    ldx ze
    cpx #7
    bcc @sidewalk
    cpx #15
    bcc @road
    cpx #164
    bcc @sidewalk
    cpx #199
    bcc @road
@sidewalk:
    lda #45
    bne @index
@road:
    lda #46
@index:
    sec
    sbc zd
    sta operand
    asl
    asl
    sec
    adc operand                 ; 1+5*(45+carry-D), modulo 256
    sta addr
    lda #99
    sta addr+1
    lda zc
    ldy #0
    ldx #5
@threshold:
    cmp (addr),y
    bcc @found
    iny
    dex
    bne @threshold
@found:
    stx zb
    lda #3
    sta zc
    txa
    cmp #3
    bcc :+
    inc ze
    sbc #3
:   asl
    beq :+
    sec
    sbc #3
:   clc
    adc zd
    sta zd
    jmp set_state

; 62518 / 62548. B is the object mask, C the front column. A switch is
; checked only at the two outside columns. Other callers use the same
; fixture table for phones and blinds.
by_light:
    lda #4
    sta zl
    ldy #0
    lda (zl),y
    and #1
    sta fresult
    bne :+
    jmp ret_z80                 ; BIT preserves A and carry outdoors
:   sty zl
    lda (zl),y
    asl
    iny
    lda (zl),y
    bcc :+
    adc #1
:   sty zl
    sta zc
    ldx #128
    and #7
    beq @switch
    ldx #64
    cmp #7
    beq @switch
    stx zb
    jmp no_fixture
@switch:
    stx zb
fixture_at:
    lda zc
    lsr
    lsr
    lsr
    sta zc
    inc zl
    ldy #0
    lda (zl),y
    cmp #33
    bne :+
    lda #31
:   ldx #254
    sec
@floor:
    inx
    sbc #6
    bcs @floor
    stx zl
    cmp #251
    bne no_fixture
    cpx #5
    bcs no_fixture
    txa
    .repeat 5
        asl
    .endrepeat
    ora zc
    sta ze
    tax
    lda #245
    sta zd
    lda $f500,x
    and zb
    beq no_fixture
    lda zl
    clc
    adc #185
    sta zb
    sta fresult
    lda #0
    sta fcarry
    lda $f500,x
    sta za
    lda zc
    ora #64
    sta zc
    jmp ret_z80
no_fixture:
    lda #0
    sta za
    sta fresult
    sta fcarry
    jmp ret_z80

; 62926, 62929 and 62892 share the stride, restart and destination tests.
; The untaken branches cost no guest dispatch. Resume at PUSH AF when
; the character must call its command before moving.
walk_floor:
    lda #<62694
    sta zc
    lda #>62694
    sta zb
walk_command:
    ldx #1
    bne walk_axis
stairs_command:
    ldx #2
walk_axis:
    ldy #0
    sty zl
    lda (zl),y
    and #1
    sta fresult
    beq :+
    setpc 60506
:   lda #3
    sta zl
    lda (zl),y
    and #16
    sta fresult
    bne @end
    stx zl
    lda (zl),y
    sta za
    ldy #16
    sty zl
    ldy #0
    sec
    sbc (zl),y
    sta fresult
    lda #0
    adc #0
    eor #1
    sta fcarry
    lda fresult
    beq @end
    cpx #2
    beq :+
    setpc 62952
:   setpc 62914
@end:
    setpc 62084

; 61509. Sam's two counters are updated every pass. Keep their original
; flag and stack contracts at both action calls and at the screen refresh.
sam_timer:
    lda #>58889
    sta zh
    lda #<58889
    sta zl
    lda 58889
    sta za
    ldx #0
    stx fcarry
    cmp #0
    beq @main
    dec 58889
    lda 58889
    sta fresult
    bne @refresh
    lda #<61549
    ldx #>61549
    jsr push_ax
    setpc 60539
@main:
    dec zl
    dec 58888
    lda 58888
    sta fresult
    bne @refresh
    lda #2
    sta 58888
    lda #<61525
    ldx #>61525
    jsr push_ax
    setpc 31126
@refresh:
    setpc 61549
.pushseg
.segment "RECLAIM8"
next_location_descriptor:
    ldy #0
    jsr location_scan
    jmp locdescs_return

; Rotate five 25 byte character records before the camera crosses a block.
; The cutscene temporarily replaces the final jump with a return.
cycle_actors_right:
    ldy #1
    lda $7ffe
    sec
    sbc #8
    jmp cycle_actor_page
cycle_actors_left:
    ldy #0
    lda $7ffe
cycle_actor_page:
    sty cycle_direction
    sec
:   sbc #56
    bcs :-
    adc #56
    .repeat 3
        lsr
        bcc :+
        ora #128
:   .endrepeat
    clc
    adc #215
    sta za
    sta zh
    sta fresult
    lda #0
    rol
    sta fcarry
    jmp cycle_actor_records
.segment "RECLAIM9"
cycle_actor_records:
    lda cycle_group_end,y
    sta zl
    lda cycle_buffer_end,y
    sta ze
    lda #$7f
    sta zd
    lda #25
    jsr cycle_copy
    ldy cycle_direction
    lda cycle_group_end,y
    sta ze
    lda za
    sta zd
    lda #100
    jsr cycle_copy
    jmp cycle_last_record
.segment "RECLAIM11"
cycle_last_record:
    ldy cycle_direction
    lda cycle_buffer_end,y
    sta zl
    lda #$7f
    sta zh
    lda #25
    jmp cycle_finish
.segment "RECLAIM10"
cycle_finish:
    jsr cycle_copy
    ldy cycle_direction
    lda cycle_exit,y
    ldx #>61879
    jmp install_pc
cycle_copy:
    sta zc
    lda #0
    sta zb
    ldy cycle_direction
    ldx cycle_increment,y
    jmp block_fast
cycle_group_end:  .byte 0,124
cycle_buffer_end: .byte $60,$78
cycle_increment:  .byte 1,255
cycle_exit:       .lobytes 61920,61879
cycle_direction:  .byte 0
.popseg

move_hl=$6e                     ; character buffer pointer saved by PUSH HL
move_de=$70                     ; direction table saved by PUSH DE

; A closed door takes its direction from the following matching descriptor.
.pushseg
.segment "VM_closed"
closed_location:
    jsr closed_location_sub
    jmp ret_z80
closed_location_sub:
    ldy #0
:   jsr location_scan
    bcs :-
    lda #4
    sta za
    rts
.popseg

stand_check:
    jsr stand_state
    beq stand_pose
    jmp ret_z80
standup:
    jsr stand_state
    bne @standing
    pla                         ; the move ends after the character stands
    pla
    jmp stand_pose
@standing:
    rts
stand_state:
    ldy #0
    sty zl
    sty fcarry
    lda (zl),y
    clc
    adc #1
    and #7
    sta za
    sta fresult
    rts
stand_pose:
    jsr srb_update_sub
    lda za
    bpl :+
    inc ze
    inc ze
:   dec zd
    dec zd
    and #248
    jmp move_set_pose

move_left:                      ; 60347
    jsr standup
    lda #<40985
    sta ze
    lda #>40985
    sta zd
    jsr bit7_state
    beq move_core
    jmp move_turn
move_right:                     ; 60334
    jsr standup
    jsr bit7_state
    bne :+
    jmp move_turn
:   lda #<41241
    sta ze
    lda #>41241
    sta zd
    jmp move_core
move_up:                        ; 60315
    lda #<41496
    ldx #>41496
    bne move_vertical
move_down:                      ; 60320
    lda #<42008
    ldx #>42008
move_vertical:                  ; 60323
    sta ze
    stx zd
    jsr standup
    jsr bit7_state
    beq move_core
    inc zd                      ; INC D: the table for facing right
    lda zd
    sta fresult
    jmp move_core
; BIT 7,(HL) with L = 0. Returns Z for a character facing left.
bit7_state:
    ldy #0
    lda (zl),y
    and #128
    sta fresult
    rts

move_core:                      ; 60368
    lda zl
    sta move_hl
    lda zh
    sta move_hl+1
    lda ze
    sta move_de
    lda zd
    sta move_de+1
    jsr locdescs_sub
    bcc :+
    jsr closed_location_sub
:   lda move_de                 ; POP HL: the direction table
    sta zl
    lda move_de+1
    sta zh
    lda za
    sta ze                      ; LD E,A: location type
    ldy #0
    sty fcarry
@direction:                     ; 60375: A = C AND (HL)
    lda zc
    and (zl),y
    sta za
    sta fresult
    bne @found
    inc zl
    lda zl
    and #4                      ; BIT 2,L
    sta fresult
    beq @direction
    lda move_hl                 ; POP HL: RET with carry reset
    sta zl
    lda move_hl+1
    sta zh
    jmp ret_z80
@found:                         ; 60386
    sta zd
    lda move_hl
    sta zl
    lda move_hl+1
    sta zh
    jsr bit7_state
    ldx #84
    lda fresult
    bne :+
    ldx #168                    ; ADD A,A
:   txa
    and zd
    sta za
    sta fresult
    bne :+
    jmp move_turn
:   lda #4                      ; 60398
    sta zl
    ldx ze
    dex                         ; DEC A: the location type minus 1
    stx za
    stx fresult
    bne @not_road
    lda zd                      ; 60404: up a step on the sidewalk?
    and #48
    sta za
    sta fresult
    beq move_stride
    lsr                         ; RRCA x4 brings bits 5-4 to 1-0
    lsr
    lsr
    lsr
    and zc
    sta za
    sta fresult
    beq move_stride
    lda #2
    sta (zl),y                  ; z = 2
    jmp move_stride
@not_road:                      ; 60420: RRCA
    lda za
    lsr
    bcc :+
    ora #128
    sta za
    lda #1
    sta fcarry
    jmp move_stride
:   sta za
    jmp move_entrance

move_stride:                    ; 60423: move the character midstride
    ldy #0
    sty zl
    lda #5
    sta zc
    lda zh
    sta zb
    lda (zl),y
    eor #2
    ldy #5
    sta (zl),y                  ; LD (BC),A: byte 5
    ldx #1                      ; RLCA: SBC A,A: ADD A,A: CPL gives +1 or -1
    asl
    bcs :+
    ldx #255
:   txa
    clc
    ldy #1
    adc (zl),y
    ldy #6
    sta (zl),y                  ; byte 6: post-midstride x
    lda zd                      ; 60442: direction
    and #60
    beq @add_y
    and #48
    beq :+
    lda #254
:   clc
    adc #1
@add_y:                         ; 60454: ADD A,(HL), carry if going up
    clc
    ldy #2
    adc (zl),y
    php
    ldy #7
    sta (zl),y                  ; byte 7: post-midstride y
    lda #0
    sta zl
    lda #7
    sta zc
    jsr srb_update_sub
    plp
    bcc :+
    dec zd                      ; going up a step
:   ldy #0
    lda (zl),y
    clc
    adc #1                      ; INC A: the midstride state
    sta za
    jsr set_state_sub
    lda #1                      ; SCF: RET
    sta fcarry
    jmp ret_z80

move_turn:                      ; 60358: turn the character round
    jsr srb_update_sub
    lda za
    eor #128
move_set_pose:
    sta za
    jsr set_state_sub
    lda #1
    sta fcarry
    jmp ret_z80

.pushseg
.segment "VM_entrance"
; Preserve the guest return address while checking Sam's keys.
move_entrance:
    lsr
    bcc @special
    ldy #0
    lda (zl),y
    tax
    dex
    stx fresult
    lda #1
    sta (zl),y
    sta fcarry
    lda zd
    sta za
    lda #<60483
    ldx #>60483
    jsr push_ax
    jmp by_door
@special:
    lda zd
    asl
    bcc :+
    ora #1
:   asl
    adc #0
    and zc
    sta za
    sta fresult
    ldx #0
    stx fcarry
    cmp #0                      ; AND selects a command for this direction
    bne :+
    jmp move_stride
:   lda zb
    clc
    adc #159
    sta addr+1
    lda #0
    rol
    sta fcarry
    lda #22
    sta addr
    ldy #0
    lda (addr),y
    sta za
    iny
    lda (addr),y
    tax
    lda #23                     ; INC L leaves this result
    sta fresult
    lda za
    jmp install_pc
.popseg


.pushseg
.segment "VM_camera_entry"
; Both camera variants share the Spectrum step count and saved BC.
camera_left:
    ldx #0
    beq camera_start
camera_right:
    ldx #1
    bne camera_start
camera_up:
    ldx #2
    bne camera_start
camera_down:
    ldx #3
camera_start:
    lda camera_width,x
    sta 59372
    lda camera_copy_op,x
    sta 59375
    lda #<59375
    sta zl
    lda #>59375
    sta zh
    lda camera_steps,x
    sta zb
camera_save_step:
    lda camera_step_pc,x
    pha
    lda zc
    ldx zb
    jsr push_ax
    pla
    ldx #>59418
    jmp install_pc
camera_width:   .byte 31,31,32,32
camera_copy_op: .byte $b0,$b8,$b0,$b0
camera_steps:   .byte 8,8,6,6
camera_step_pc: .lobytes 59418,59473,59528,59587
.segment "VM_camera_next"
camera_next:
    jsr pop_ax
    sta zc
    dex
    stx zb
    beq @done
    ldx camera_direction
    jmp camera_save_step
@done:
    jmp ret_z80
.popseg

.pushseg
.segment "VM_shake_start"
shake_start:
    lda #$c9                    ; the two vertical steps return after one row
    sta 59552
    sta 59612
    lda #32
    sta 59372
    lda #$b0
    sta 59375
    lda #7
    sta shake_count
shake_cycle:
    jsr shake_save_row
    ldx #31
:   lda $5800,x
    sta $7f00,x
    dex
    bpl :-
    lda #<64666
    ldx #>64666
    jsr push_ax
    jmp up_step
shake_count: .byte 0

; The Spectrum saves the row in scanline order. The VIC stores each
; character's eight bytes together. Both views span exactly 256 bytes.
.macro shake_row load, store
    ldx #0
    ldy #0
@byte:
    load
    store
    inx
    tya
    clc
    adc #8
    tay
    bcc @byte
    iny
    cpy #8
    bne @byte
    rts
.endmacro
.segment "VM_shake_save"
shake_save_row:
    shake_row {lda $2020,y}, {sta $7e00,x}
.segment "VM_shake_restore"
shake_restore_row:
    shake_row {lda $7e00,x}, {sta $2020,y}

.segment "VM_shake_fall"
shake_fall:
    ldx #0
@line:
    lda #9
    sta $2020+19*320,x          ; the original writes pixels on the last city row
    txa
    clc
    adc #8
    tax
    bne @line
    lda #128
    ldx #192
    jsr shake_tone
    lda #<64690
    ldx #>64690
    jsr push_ax
    jmp down_step
.segment "VM_shake_tone"
shake_tone:
    sta z:tone_count
    lda #1
    sta z:tone_count+1
    lda shake_count
    sta za
    lda #$ff
    jmp const_tone
.segment "VM_shake_rise"
shake_rise:
    jsr shake_restore_row
    ldx #31
@colour:
    lda $7f00,x
    sta $5800,x
    tay
    lda vic_attr,y
    sta $0404,x
    dex
    bpl @colour
    lda #0
    ldx #96
    jsr shake_tone
    dec shake_count
    beq :+
    jmp shake_cycle
:   lda #$21
    sta 59552
    sta 59612
    lda #0
    sta zd
    sta ze
    jmp mirror_table

.segment "VM_mirror_table"
mirror_table:
    ldx #0
    stx $7e00
    inx
@byte:
    txa
    lsr
    tay
    lda $7e00,y
    ror                         ; insert the low source bit at the left of the reversed half
    sta $7e00,x
    inx
    bne @byte
    sta za
    sta zc
    stx zl
    stx zb
    stx fresult
    stx fcarry
    lda #$7e
    sta zh
    jmp ret_z80
.popseg

.pushseg
.segment "VM_door_status"
door_status:
    jsr door_status_sub
    jmp ret_z80
door_status_sub:
    ldy #0
    lda #1
    sta zl
    lda (zl),y
    ldx #<65462
:   cmp $ff00,x
    bcc :+
    inx
    jmp :-
:   txa
    adc #58                     ; the door coordinate comparison cleared carry
    sta zl
    lda #127
    sta zh
    lda (zl),y
    and #7
    sta za
    sta fresult
    sty fcarry
    rts

.segment "VM_by_door"
by_door:
    ldx fresult                 ; zero on entry for an indoor character
    lda za
    and zb
    sta za
    sta fresult
    ldy #0
    sty fcarry
    cmp #0
    beq @outside
    cpx #0
    beq :+
    jmp by_door_enter
:   jmp ret_z80
@outside:
    lda (zl),y
    clc
    adc #1
    sta (zl),y
    sta fresult
    jmp ret_z80
.segment "VM_door_enter"
by_door_enter:
    lda zh
    sta za
    ldx #230
    jsr cp_x
    lda fresult
    bne @return
    lda zb
    and #1
    sta fresult
    beq @return
    jsr door_status_sub
    lda zl
    sta za
    ldx #245
    jsr cp_x
    lda fresult
    beq @sam
    ldy #0
    lda (zl),y
    and #248
    sta za
    sta fresult
    sty fcarry
@sam:
    lda #230
    sta zh
    lda fresult
    beq @return
    setpc 31289
@return:
    jmp ret_z80
resume_stride:
    jmp move_stride
.popseg
