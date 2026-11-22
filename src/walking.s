; Queue changed tiles before writing them during the raster window.
; Refresh shares scratch memory with camera staging.
walk_count = $52
walk_top = $53
walk_bottom = $54
walk_start = $55
walk_span = $56
walk_i = $57
walk_pixels = $3f00
; Use the lower half of page 1 for the queue. The 6510 stack grows down
; from $01ff. Z80 CALL and PUSH use the guest stack in high RAM.
walk_blo = $0100
walk_bhi = $0120
walk_slo = $0140
walk_shi = $0160
walk_colour = $3de0

.segment "CODE"
walk_collect:
    jsr compose_cell
    jsr cell_bitmap_address
    lda atr_lo,x
    sta color_ptr
    lda atr_hi,x
    sta color_ptr+1
    ldy tc
    lda (color_ptr),y
    cmp paint
    bne @changed
    ldy #7
:   lda (out),y
    cmp cell,y
    bne @changed
    dey
    bpl :-
    rts
@changed:
    ldy tc
    lda paint
    sta (color_ptr),y
    tay
    lda vic_attr,y
    ldy walk_count
    sta walk_colour,y
    lda out
    sta walk_blo,y
    lda out+1
    sta walk_bhi,y
    clc
    lda scr_lo,x
    adc tc
    sta walk_slo,y
    lda scr_hi,x
    adc #0
    sta walk_shi,y
    stx walk_bottom
    cpy #0
    bne :+
    stx walk_top
:   tya
    asl
    asl
    asl
    tax
    ldy #0
:   lda cell,y
    sta walk_pixels,x
    inx
    iny
    cpy #8
    bne :-
    inc walk_count
    lda walk_count
    cmp #32
    bne :+
    jmp walk_flush
:   rts

.segment "EXT"
walk_flush:
    lda walk_count
    bne :+
    rts
:   lda walk_bottom
    asl
    asl
    clc
    adc #30
    sta walk_start               ; first two-line tick after the last dirty row
    lda walk_top
    asl
    asl
    clc
    adc #24
    sec
    sbc walk_start
    ldx pal_machine
    clc
    adc walk_period,x
    sec
    sbc walk_count
    sta walk_span
    lda walk_count
    lsr
    sta walk_i
    lda walk_span
    sec
    sbc walk_i                  ; reserve three lines per queued tile
    sta walk_span
@again:
    php
    sei
    inc $01
@sample:
    lda $d012
    ldy $d011
    cmp $d012
    bne @sample
    cpy #$80
    ror
    sec
    sbc walk_start
    bcs :+
    adc walk_period,x
:   cmp walk_span
    bcc @ready
    dec $01
    plp
    jmp @again
@ready:
    dec $01
    ldx #0
@tile:
    stx walk_i
    lda walk_blo,x
    sta out
    lda walk_bhi,x
    sta out+1
    lda walk_slo,x
    sta color_ptr
    lda walk_shi,x
    sta color_ptr+1
    ldy #0
    lda walk_colour,x
    sta (color_ptr),y
    txa
    asl
    asl
    asl
    tax
    .repeat 8,i
        lda walk_pixels+i,x
        sta (out),y
        .if i<7
            iny
        .endif
    .endrepeat
    ldx walk_i
    inx
    cpx walk_count
    bne @tile
    lda #0
    sta walk_count
    plp
    rts
walk_period: .byte 132,156
