read_addr:
    ldy #0
    lda addr+1
    cmp #$40
    bcs :+
    jmp read_rom
:
    cmp #$58
    bcc read_pixels
read_regular:
    cmp #$ff
    bne :+
    ldx addr
    cpx #$fa
    bcc :+
    lda vector_tail-$fa,x
    rts
:   lda (addr),y
    rts
read_pixels:
    jsr pixel_address
    lda (vptr),y
    rts
write_addr:
    ldy addr+1
    cpy #$5b
    bcc @display
    cpy #$ff
    bne @ram
    ldx addr
    cpx #$fa
    bcc @ram
    sta vector_tail-$fa,x
    rts
@ram:
    ldy #0
    sta (addr),y
    rts
@display:
    cpy #$40
    bcc write_done
    sta value
    cpy #$58
    bcc write_pixels
    ldy #0
    sta (addr),y
    lda addr+1
    sec
    sbc #$58
    asl
    asl
    asl
    sta tmp
    lda addr
    lsr
    lsr
    lsr
    lsr
    lsr
    ora tmp
    tax
    lda scr_lo,x
    sta vptr
    lda scr_hi,x
    sta vptr+1
    lda addr
    and #31
    tay
    ldx value
    lda vic_attr,x
    sta (vptr),y
write_done:
    rts
write_pixels:
    jsr pixel_address
    lda value
    sta (vptr),y
    rts
pixel_address:
    lda addr+1
    and #$18
    sta tmp
    lda addr
    lsr
    lsr
    lsr
    lsr
    lsr
    ora tmp
    tax
    lda addr
    asl
    asl
    asl
    clc
    adc bmp_lo,x
    sta vptr
    lda bmp_hi,x
    adc #0
    sta vptr+1
    lda addr+1
    and #7
    tay
    rts

.macro row_table label, base, stride, selector
label:
    .repeat 24, i
        .byte selector (base+i*stride)
    .endrepeat
.endmacro
.pushseg
.segment "PN_bitmap_lo"
row_table bmp_lo, $2020,320,<
.segment "PN_bitmap_hi"
row_table bmp_hi, $2020,320,>
.segment "PN_screen_lo"
row_table scr_lo, $0404,40,<
.segment "PN_screen_hi"
row_table scr_hi, $0404,40,>
.popseg
row_table atr_lo, $5800,32,<
row_table atr_hi, $5800,32,>

.pushseg
.segment "VM_read_rom"
read_rom:
    cmp #$3d
    bcc random_rom
    sec
    sbc #$3d                    ; three pages of 32 glyphs
    .repeat 5
        asl
    .endrepeat
    sta vptr
    lda addr
    lsr
    lsr
    lsr
    ora vptr
    tax
    lda addr
    and #7
    beq glyph_top
    cmp #7
    bne :+
    jmp glyph_bottom
:   tay
    lda font_row_lo-1,y
    sta vptr
    lda font_row_hi-1,y
    sta vptr+1
    txa
    tay
    lda (vptr),y
    ldy #0
    rts
random_rom:
    ; Only the entropy routine samples other ROM addresses.
    eor addr
    rts
glyph_top:
    cpx #95                     ; only the copyright sign reaches the top
    beq :+
    lda #0
    rts
:   lda font_top_pixel
    rts

.segment "VM_font_bottom"
; X is the glyph index. Ten glyphs use the last scanline. Keep Y zero
; on return for guest ROM readers.
glyph_bottom:
    txa
    ldy #2                      ; most message letters lie between entries 2 and 3
    cmp font_descenders+2
    beq @found
    bcs @next
    ldy #255
@next:
    iny
    cmp font_descenders,y
    beq @found
    bcs @next                   ; the last entry is glyph 95
    lda #0
    ldy #0
    rts
@found:
    lda font_bottom_pixels,y
    ldy #0
    rts

.segment "VM_font_rows"
font_row_lo: .lobytes font, font+96, font+192, font+288, font+384, font_row6
font_row_hi: .hibytes font, font+96, font+192, font+288, font+384, font_row6

.segment "VM_draw_glyph"
; The six full scanlines are indexed directly while the raster window is open.
draw_glyph:
    lda za
    lsr
    sec
    sbc #32
    tax
    jsr glyph_top
    ldy #0
    sta (vptr),y
    .repeat 5, i
        iny
        lda font+96*i,x
        sta (vptr),y
    .endrepeat
    iny
    lda font_row6,x
    sta (vptr),y
    jsr glyph_bottom
    ldy #7
    sta (vptr),y
    rts
.popseg
