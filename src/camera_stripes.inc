; PAL stripes use widths of 7, 7, 7, 7 and 4 columns. NTSC uses
; 6, 6, 6, 6, 5 and 3. The VIC has fetched the first five tile rows
; by line 91. Follow the beam for later rows with the IRQ enabled.
stripe_index = stage_top
stripe_band_row = stage_end

.macro stripe_addresses rowlo, rowhi, target
    lda rowlo,y
    sta target+1,x
    sta target+4,x
    lda rowhi,y
    sta target+2,x
    sta target+5,x
.endmacro

stripe_scroll:
    ldy pal_machine
    cpx #0
    bne @right
    inc $7ffe
    lda stripe_left_index,y
    tay
    lda #31
    bne @edge
@right:
    dec $7ffe
    lda stripe_right_index,y
    tay
    lda #0
@edge:
    sta tc
    sty stripe_index
    ; Read each source before its neighbour is overwritten in this bitmap.
    ; Leftward travel uses INX/INY, rightward travel uses DEX/DEY.
    lda stripe_xop,x
    sta stripe_pixel_x
    sta stripe_colour_x
    lda stripe_yop,x
    sta stripe_pixel_y
    sta stripe_colour_y
    jsr index_column
    ldx #0
@compose:
    jsr stage_horizontal
    ldx tr
    inx
    cpx #20
    bne @compose
stripe_pass:
    ldx stripe_index
    lda stripe_start,x
    sta stripe_colour_dest+1
    lda stripe_start+1,x
    sta stripe_colour_end+1
    ldx direction
    asl
    asl
    asl
    ora stripe_scan,x
    sta stripe_pixel_end+1
    lda stripe_colour_dest+1
    clc
    adc stripe_dx,x
    sta stripe_colour_src+1
    lda stripe_colour_dest+1
    asl
    asl
    asl
    ora stripe_scan,x
    sta stripe_pixel_dest+1
    clc
    adc stripe_pixel_dx,x
    sta stripe_pixel_src+1
    lda #0
    sta stripe_band_row
    inc $01
@beam:
    lda $d012
    ; This window leaves time for the last group before its next scanout.
    cmp #92
    bcc @beam
    cmp #125
    bcs @beam
    ; The high-raster portion ends at low byte 55 (PAL) or 6 (NTSC).
    dec $01
stripe_band:
    ldy stripe_band_row
    ldx #0
@patch:
    stripe_addresses bmp_lo, bmp_hi, stripe_pixels
    stripe_addresses atr_lo, atr_hi, stripe_raw
    stripe_addresses scr_lo, scr_hi, stripe_vic
    iny
    txa
    clc
    adc #6
    tax
    cpx #30
    bne @patch
stripe_pixel_src:
    ldx #0
stripe_pixel_dest:
    ldy #0
stripe_pixels:
    .repeat 5
        lda a:$0000,x
        sta a:$0000,y
    .endrepeat
stripe_pixel_x:
    inx
stripe_pixel_y:
    iny
stripe_pixel_end:
    cpy #0
    bne stripe_pixels
stripe_colour_src:
    ldx #0
stripe_colour_dest:
    ldy #0
stripe_raw:
    .repeat 5
        lda a:$0000,x
        sta a:$0000,y
    .endrepeat
stripe_vic:
    .repeat 5
        lda a:$0000,x
        sta a:$0000,y
    .endrepeat
stripe_colour_x:
    inx
stripe_colour_y:
    iny
stripe_colour_end:
    cpy #0
    bne stripe_raw
    lda stripe_colour_end+1
    cmp #32
    bcc @next
    ; The outer column has no neighbour in the old viewport. Replace it
    ; with the composed map and actors before the VIC reads this group.
    jsr stripe_edge
@next:
    lda stripe_band_row
    clc
    adc #5
    sta stripe_band_row
    cmp #20
    beq :+
    jmp stripe_band
:   inc stripe_index
    lda stripe_colour_end+1
    cmp #32
    bcs :+
    jmp stripe_pass
:   jmp stripe_exit

.pushseg
.segment "G1"
stripe_exit:
    lda #<59454
    ldx direction
    beq :+
    lda #<59509
:   ldx #>59454
    .assert >59454 = >59509, error, "camera exits span two pages"
    jmp install_pc

.segment "CODE"
stripe_edge:
    lda stripe_band_row
    sta dst_row
    clc
    adc #5
    sta row_size
@row:
    jsr color_addresses
    lda bmp_lo,x
    sta p2
    lda bmp_hi,x
    sta p2+1
    lda edge_attr,x
    ldy tc
    sta (attr_ptr),y
    tax
    lda vic_attr,x
    sta (color_ptr),y
    tya
    asl
    asl
    asl
    tay
    lda dst_row
    asl
    asl
    asl
    tax
@pixel:
    lda edge_pixels,x
    sta (p2),y
    inx
    iny
    tya
    and #7
    bne @pixel
    inc dst_row
    lda dst_row
    cmp row_size
    bne @row
    rts
; Strip starts in copy order. The last entry in each run is its exclusive end.
stripe_start:
pal_left_strip:   .byte 0,7,14,21,28,32
pal_right_strip:  .byte 31,24,17,10,3,$ff
ntsc_left_strip:  .byte 0,6,12,18,24,29,32
ntsc_right_strip: .byte 31,25,19,13,7,2,$ff
.segment "G10"
stripe_xop:      .byte $e8,$ca
stripe_yop:      .byte $c8,$88
stripe_dx:       .byte 1,$ff
.segment "G22"
stripe_left_index:  .byte ntsc_left_strip-stripe_start,pal_left_strip-stripe_start
stripe_right_index: .byte ntsc_right_strip-stripe_start,pal_right_strip-stripe_start
.segment "CODE"
stripe_pixel_dx: .byte 8,$f8
stripe_scan:     .byte 0,7
.popseg
