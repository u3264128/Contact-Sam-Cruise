; Copy each row's pixels and both colour matrices together.
; Stage incoming tiles while the raster beam is outside the target row.
.segment "EXT"
attr_ptr=$59
direction=camera_direction                   ; 0 left, 1 right, 2 up, 3 down
camera_row=$53
first_col=$54
last_col=$55
shake=$57
beam_start=$58
stage_top=$78
stage_end=$79                   ; unprepared horizontal interval [top,end)
stripe_y=$7a
stripe_layers=$80               ; one layer mask per row of the entering column
; Edge colours occupy the black right margin of row 23. The 256 pixels
; occupy the end of black row 24 and the unused tail of the bitmap.
edge_pixels=$3f00
edge_attr=$3de0
left_step:
    lda #0
    beq scroll_step
right_step:
    lda #1
    bne scroll_step
up_step:
    lda #2
    bne scroll_step
down_step:
    lda #3
scroll_step:
    sta direction
.ifndef STRIPE_CAMERA
    jsr order_pixels
    ldx direction
    lda atr_start,x
    sta attr_y+1
    lda atr_op,x
    sta attr_step
    lda atr_end,x
    sta attr_end+1
    lda pixel_bias,x
    sta pixel_source_add+1
.endif
    lda #4
    sta clock_budget
    lda #255
    sta group_key
    lda #0
    sta shake
    sta camera_row
.ifndef STRIPE_CAMERA
    sta pending_top
    sta stage_top
    lda #19
    sta pending_bottom
    lda #20
    sta stage_end
    ldx direction
    cpx #2
    bcs vertical
    lda #1
    sta first_col
    lda #0
    sta last_col
    cpx #0
    beq @left
    dec $7ffe
    dec first_col
    inc last_col
    bne @columns
@left:
    inc $7ffe
@columns:
    lda last_col
    eor #1
    beq :+
    lda #31
:   sta tc
    jsr index_column
    lda #20
    sta camera_row
@rows:
    jsr pick_row
    stx src_row
    stx dst_row
    cpx stage_top
    bcc @ready
    cpx stage_end
    bcs @ready
    cpx stage_top
    bne @from_bottom
    inc stage_top
    bne @compose
@from_bottom:
    dec stage_end
@compose:
    jsr stage_horizontal
@ready:
    jsr transfer_row
    dec camera_row
    bne @rows
    ldx direction
    bne :+
    setpc 59454
:   setpc 59509
.else
    ldx direction
    cpx #2
    bcs vertical
    jmp stripe_scroll
.endif

vertical:
.ifndef STRIPE_CAMERA
    lda #0
    sta first_col
    sta last_col
.endif
    cpx #2
    bne @down
    lda #19
    sta tr
    lda 59552                   ; original shake changes LD HL to RET
    cmp #$c9
    beq @shake
    inc $7fff
    jmp @prepare
@down:
    lda #18
    sta camera_row
    lda #0
    sta tr
    lda 59612
    cmp #$c9
    beq @shake
    dec $7fff
@prepare:
    lda #0
    sta tc
    beq @rows
@shake:
    inc shake
    lda #32
    sta tc
@rows:
    ldx camera_row
    stx src_row
    stx dst_row
    lda direction
    cmp #2
    bne :+
    inc src_row
    jsr transfer_row
    inc camera_row
    lda camera_row
    cmp #19
    bne @rows
    beq @edge
:   inc dst_row
    jsr transfer_row
    dec camera_row
    bpl @rows
@edge:
    lda shake
    bne @return
@finish_edge:
    lda tc
    cmp #32
    beq :+
    jsr stage_vertical
    jmp @finish_edge
:   ldx tr
    stx dst_row
    lda #<edge_pixels
    sta p1
    lda #>edge_pixels
    sta p1+1
    lda bmp_lo,x
    sta p2
    lda bmp_hi,x
    sta p2+1
    lda #<edge_attr
    sta copy_attr_src
    lda #>edge_attr
    sta copy_attr_src+1
    jsr color_addresses
    ldx #2
    jsr fast_copy
    lda direction
    cmp #2
    bne :+
    setpc 59568
:   setpc 59628                  ; POP BC restores the saved step counter
@return:
    lda #0
    sta zb
    sta zc
    sta za
    sta fresult
    sta fcarry
    jmp ret_z80

; Wait until the beam has left destination row X and cannot reach it again
; within COPY_LINES raster lines. The full 9-bit raster position is used, so
; a copy may begin as soon as the beam has passed the row.
; Two raster lines per unit fit the full beam position into a byte. Round
; the busy window outwards, including the unpaired last line on NTSC.
COPY_LINES = 72
safe_row:
    jsr row_limit
    inc $01
wait_row:
    jsr row_is_clear
    bcc prepare_while_waiting
    php
    sei
row_check:
    jsr row_is_clear            ; account for an IRQ between the sample and SEI
    bcc retry_row
    pla                         ; leave IRQs masked until both matrices are current
    dec $01
    rts
retry_row:
    plp
    jmp wait_row
prepare_while_waiting:
.ifndef STRIPE_CAMERA
    lda direction
    cmp #2
    bcs @vertical
    ldx stage_top
    cpx stage_end
    bcs wait_row
    dec $01
    inc stage_top
    jsr stage_horizontal
    inc $01
    jmp wait_row
@vertical:
.endif
    lda tc
    cmp #32
    bcs wait_row
    dec $01
    jsr stage_vertical
    inc $01
    jmp wait_row
row_limit:
    txa
    asl
    asl
    clc
    adc #30                     ; first full two-line unit beyond raster 58+8*row
    sta beam_start
    rts
row_is_clear:
@sample:
    lda $d012
    ldy $d011
    cmp $d012
    bne @sample
    cpy #$80
    ror
    sec
    sbc beam_start
    ldy pal_machine
    bcs :+
    adc half_frame,y
:   cmp clear_span,y
    bcs @busy
    sec
    rts
@busy:
    clc
    rts
half_frame: .byte 132,156
clear_span: .byte 131-5-COPY_LINES/2,156-5-COPY_LINES/2

transfer_row:
    ldx src_row
    lda bmp_lo,x
.ifndef STRIPE_CAMERA
    clc
pixel_source_add:
    adc #0                      ; bitmap row lows $20,$60,$a0,$e0 allow +/-8
.endif
    sta p1
    lda bmp_hi,x
    sta p1+1
    lda atr_lo,x
.ifndef STRIPE_CAMERA
    clc
    adc first_col
.endif
    sta copy_attr_src
    lda atr_hi,x
    sta copy_attr_src+1
    ldx dst_row
    lda bmp_lo,x
    sta p2
    lda bmp_hi,x
    sta p2+1
    jsr color_addresses
; Neither the 32-byte attribute rows nor the centred VIC matrix row
; bases can cross a page when adjusted by one column.
fast_copy:
    lda attr_ptr
.ifndef STRIPE_CAMERA
    clc
    adc last_col
.endif
    sta copy_attr_dst
    sta compare_attr_dst
    lda attr_ptr+1
    sta copy_attr_dst+1
    sta compare_attr_dst+1
    lda color_ptr
.ifndef STRIPE_CAMERA
    clc
    adc last_col
.endif
    sta copy_scr_dst
    lda color_ptr+1
    sta copy_scr_dst+1
    jsr pixel_pages
    ldx dst_row
    php
    jsr safe_row
    jsr copy_row_pixels
attr_y:
    ldy #0
attr_loop:
copy_attr_src=*+1
    lda a:$0000,y
compare_attr_dst=*+1
    cmp a:$0000,y
    beq attr_step               ; its VIC colour is already correct too
copy_attr_dst=*+1
    sta a:$0000,y
    tax
    lda vic_attr,x
copy_scr_dst=*+1
    sta a:$0000,y
attr_step:
    iny
attr_end:
.ifdef STRIPE_CAMERA
    cpy #32
    bne attr_loop
.else
    cpy #31
    bne attr_loop
    lda direction
    cmp #2
    bcs row_published
    ldy tc
    ldx dst_row
    lda edge_attr,x
    sta (attr_ptr),y
    tax
    lda vic_attr,x
    sta (color_ptr),y
.endif
row_published:
    plp
    rts
; Indexed by direction: left, right, then vertical rows and the new edge.
.ifndef STRIPE_CAMERA
atr_start: .byte 0,30,0,0
atr_op:    .byte $c8,$88,$c8,$c8   ; INY or DEY
atr_end:   .byte 31,$ff,32,32
pixel_bias: .byte 8,$f8,0,0
.endif
color_addresses:
    ldx dst_row
    lda atr_lo,x
    sta attr_ptr
    lda atr_hi,x
    sta attr_ptr+1
    lda scr_lo,x
    sta color_ptr
    lda scr_hi,x
    sta color_ptr+1
    rts
; Advance from the top whenever its row can be written, otherwise from
; the bottom. The untouched rows always form a single contiguous band.
; safe_row checks the selected row again after the operands are patched.
.ifndef STRIPE_CAMERA
pick_row:
    ldx pending_top
    jsr row_limit
    inc $01
    jsr row_is_clear
    bcs @top
    ldx pending_bottom
    jsr row_limit
    jsr row_is_clear
    bcs @bottom
    ; If both ends are busy, the beam clears the top row first.
@top:
    dec $01
    ldx pending_top
    inc pending_top
    rts
@bottom:
    dec $01
    ldx pending_bottom
    dec pending_bottom
    rts
    .pushseg
    .segment "G1"
pending_top: .res 1
pending_bottom: .res 1
    .popseg
.else
    .include "camera_stripes.inc"
.endif

stage_horizontal:
    stx tr
    lda stripe_layers,x
    sta cell_layers
    txa
    clc
    adc stripe_y
    sta wy
    jsr decode_row              ; stripe's world column is fixed for all rows
    ldx tr
    jmp stage_cell
stage_vertical:
    jsr compose_cell
    ldx tc
    inc tc
stage_cell:
    lda paint
    sta edge_attr,x
    txa
    asl
    asl
    asl
    tax
    .repeat 8,i
        lda cell+i
        sta edge_pixels+i,x
    .endrepeat
    rts

; Transfer an entire bitmap scanline with one absolute-indexed load/store
; per cell. X/Y provide the source and destination row's low byte and
; raster offset. Hardware indexing handles the page crossing within a row.
.ifndef STRIPE_CAMERA
order_pixels:
    cmp #2
    bcc :+
    ldx #248
    stx last_pixel+1
:
    cmp #1
    beq :+
    lda #0
:   cmp last_order
    bne :+
    rts
:   sta last_order
    ldy #0
    ldx #0
    cmp #1
    bne :+
    ldy #248
:   sty pixel_order+1
    lda #8
    cpy #0
    beq :+
    lda #$f8
:   sta order_add+1
pixel_order:
    lda #0
:   sta copy_pixels+1,x
    sta copy_pixels+4,x
    clc
order_add:
    adc #8
    tay
    txa
    clc
    adc #6
    tax
    tya
    cpx #192
    bne :-
    rts
last_order: .byte 0             ; initial operands are in ascending order
.endif
.segment "CODE"
pixel_pages:
    ldx #0
.ifdef STRIPE_CAMERA
    camera_page_pairs = 4
.else
    camera_page_pairs = 16
.endif
@pages:
    lda p1+1
    .repeat camera_page_pairs,i
        sta copy_pixels+i*6+2,x
    .endrepeat
    lda p2+1
    .repeat camera_page_pairs,i
        sta copy_pixels+i*6+5,x
    .endrepeat
    txa
    clc
    adc #6*camera_page_pairs
    tax
    cpx #192
    bne @pages
.ifndef STRIPE_CAMERA
    lda direction
    cmp #2
    bcs :+
    ; The final pair is always the entering column. X starts at p1.low
    ; on every scanline pass. Bias this load to fetch the staged edge.
    lda dst_row
    asl
    asl
    asl
    sec
    sbc p1
    sta last_pixel+1
    lda #>edge_pixels
    sbc #0
    sta last_pixel+2
:
.endif
    rts
copy_row_pixels:
    ldy p2
    ldx p1
copy_pixels:
    .repeat 32,i
        lda a:8*i,x
        sta a:8*i,y
    .endrepeat
last_pixel = copy_pixels+31*6
    inx
    iny
    tya
    and #7
    beq :+
    jmp copy_pixels
:   rts

; The camera's entering column has a fixed world X. Test the sixteen
; actors once. Reuse the sprite compositor's ordering and exact pose
; clipping, and visit a layer only in rows an actor could reach.
index_column:
    lda #0
    sta actor
    sta cell_head
    ldx #19
:   sta stripe_layers,x
    dex
    bpl :-
    lda tc
    clc
    adc $7ffe
    sta wx
    lda $7fff
    adc #0
    sta stripe_y
    lda wx
    lsr
    lsr
    lsr
    sta map
    lda #230
    sta actor+1
@actor:
    ldy #1
    lda wx
    sec
    sbc (actor),y
    cmp #5
    bcs @next
    ldy #4
    lda (actor),y
    and #7
    beq @next
    sta zone
    ldx cell_head
    inx
    lda cell_head
    sta group_next,x
    lda actor+1
    sta group_actors,x
    stx cell_head
    ldy #2
    lda (actor),y
    sec
    sbc stripe_y
    tax
    ldy #5
@row:
    cpx #20
    bcs :+
    lda stripe_layers,x
    ora zone
    sta stripe_layers,x
:   inx
    dey
    bne @row
@next:
    dec actor+1
    lda actor+1
    cmp #214
    bne @actor
    rts
