.setcpu "6502"
; Z80 register pairs are stored in little-endian order.
zc=$02
zb=$03
ze=$04
zd=$05
zl=$06
zh=$07
za=$08
zpc=$09
zsp=$0b
fresult=$0d
fcarry=$0e
alternate=$0f
addr=$15
vptr=$17
tmp=$19
operand=$1a
value=$1b
aux=$1c
dst=$1d
src=$1f
camera_direction=$52
.segment "GLYPHS"
font: .incbin "font.bin", 0, 5*96
.segment "VM_font_row6"
font_row6: .incbin "font.bin", 5*96, 96
.segment "VM_font_edges"
font_descenders: .incbin "font.bin", 6*96
font_bottom_pixels = font_descenders+10
font_top_pixel = font_bottom_pixels+10
.assert * = font_top_pixel+1, error, "unexpected font size"
.segment "EXT"                  ; from $4200, so the tables are aligned
.ifndef STRIPE_CAMERA
    .include "vic_attr.inc"
    .assert <vic_attr = 0, error, "palette fetch must be four cycles"
.endif
.include "optable.inc"
.segment "CODE"
    .word basic_end,10
    .byte $9e,"2061",0
basic_end: .word 0
; The two contended-sound tables are populated after the player leaves the
; title. Until then their 512 bytes hold the loader and title setup.
sound_contended_lo:
boot:
    sei
    cld
    ldx #$ff
    txs
    lda #$7f
    sta $dc0d
    sta $dd0d
    lda $dc0d
    lda $dd0d
    lda #$34
    sta $01
    lda #<(packed+2)
    clc
    adc packed
    sta src
    lda #>(packed+2)
    adc packed+1
    sta src+1
    lda #0
    sta dst
    sta dst+1
    tay
unpack:
    jsr prev_byte
    cmp #128
    bcc :+
    cmp #192
    bcc backref
    cmp #224
    bcs repeat
    sta tmp
    and #3
    adc #3                      ; CMP left carry clear
    tax
    lda tmp
    lsr
    lsr
    and #7
    clc
    adc #1                      ; distance pages 1 through 8
    sta tmp
    jsr prev_byte
    clc
    adc dst
    sta addr
    lda tmp
    bne backref_high
:   tax
literal:
    jsr prev_byte
    jsr write_prev
    dex
    bpl literal
    bmi packet_done
backref:
    sta tmp
    and #31
    cmp #31
    bne :+
    jsr prev_byte               ; extended length, zero copies 256 bytes
    bcs @count                  ; prev_byte preserves carry
:   adc #3                      ; CMP cleared carry for a short match
@count:
    tax
    jsr prev_byte
    clc
    adc dst
    sta addr
    lda tmp
    and #32
    beq backref_high
    jsr prev_byte               ; the byte reader preserves carry
backref_high:
    adc dst+1
    sta addr+1
@copy:
    lda (addr),y
    jsr write_prev
    lda addr
    bne :+
    dec addr+1
:   dec addr
    dex
    bne @copy
    beq packet_done
repeat:
    and #31
    cmp #31
    bne :+
    jsr prev_byte
    bcs @count
:   adc #4
@count:
    tax
    jsr prev_byte
:   jsr write_prev
    dex
    bne :-
packet_done:
    lda dst+1
    cmp #>resident_start
    bne @next
    lda dst
    cmp #<resident_start
    beq start_game
@next:
    jmp unpack
prev_byte:
    lda src
    bne :+
    dec src+1
:   dec src
    lda (src),y
    rts
write_prev:
    pha
    lda dst
    bne :+
    dec dst+1
:   dec dst
    pla
    sta (dst),y
    rts
.include "startup.inc"
packed:                         ; length word followed by the on-disk packets
    .assert *-sound_contended_lo <= 512, error, "startup exceeds sound table storage"
    .res 512-(*-sound_contended_lo)
sound_contended_hi = sound_contended_lo+256

resident_start:                 ; first byte restored by the backward decoder
.include "cpu.s"
.include "video.s"
.include "tiles.s"
.ifdef STRIPE_CAMERA
    .include "camera.s"
.else
    .include "camera_cut.s"
    .include "camera_pan.s"
    .include "walking.s"
.endif
.include "game.s"
.include "native.s"
.segment "CODE"
.include "platform.s"
.segment "EXT"
.include "opcodes.inc"
