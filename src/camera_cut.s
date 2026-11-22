; Move the camera eight columns or six rows while actors are frozen.
; Stream one column per horizontal step. For a vertical cut, stage six
; rows before masking the city. The status panel stays in place.
.segment "EXT"
beam_start = $58
cut_dir = camera_direction
cut_count = $53
cut_slot = $54
cut_plane = $56
cut_row = $57
cut_emit = $78
cut_nrows = $7a
cut_attr = $59
cut_cache = $5b
cut_kernel = $0100              ; shared with the walking queue between refreshes
.assert cut_kernel+20*6+6 <= $0180, error, "camera copier overlaps the hardware stack"
cut_src_off = $6e
cut_dst_off = $6f
cut_width = $70

left_step:
    lda #0
    beq cut_start
right_step:
    lda #1
    bne cut_start
up_step:
    lda #2
    bne cut_start
down_step:
    lda #3
cut_start:
    sta cut_dir
    tax
    cpx #2
    bcc @normal
    bne :+
    lda 59552
    bne @check
:   lda 59612
@check:
    cmp #$c9
    bne @normal
    lda #4
    sta clock_budget
    txa
    clc
    adc #2
    sta cut_dir
    jsr cut_attrs
    jsr cut_pixels
    jsr cut_mask
    jsr cut_run
    jsr cut_reveal
    lda #0
    sta zb
    sta zc
    sta za
    sta fresult
    sta fcarry
    jmp ret_z80
@normal:
    ldy #1
    lda (zsp),y                 ; step count on the guest stack
    sta cut_count
    cmp cut_steps,x
    bne :+
    asl                         ; four timer ticks per original step in the batch
    asl
    sta clock_budget
    jsr cut_attrs               ; guest palette can move while VIC colours hold
:   lda cut_dir
    lsr                         ; low bit selects decrement, X selects the axis
    tax
    bcs @decrement
    inc $7ffe,x
    bcc @step
@decrement:
    dec $7ffe,x
@step:
    dec cut_count
    bne cut_resume
    lda cut_dir
    cmp #2
    bcs :+
    jmp pan_display
:   jsr cut_stage
    jsr cut_pixels              ; generate the overlap copier with the old view visible
    jsr cut_mask
    jsr cut_run
    jsr cut_install_edge
    jsr cut_reveal
cut_cleanup:
    jsr cut_restore
cut_resume:
    ldx cut_dir
    lda cut_pc_lo,x
    ldx #>59454
    jmp install_pc

; No actors or map objects advance between the original PUSH/DJNZ steps.
; Compose the entire entering rectangle in world-row order, reusing one
; actor index per eight-row band. The guest still observes every camera step.
cut_stage:
    lda #$60                    ; RTS at each decoder boundary during staging
    jsr cut_decode_mode
    lda #255
    sta group_key
    ldx cut_dir
    lda cut_edge_first,x
    sta tr
    clc
    adc cut_edge_height,x
    sta cut_last_row+1
    lda #0
    sta cut_slot
    sta cut_page+1
cut_stage_row:
    ldx tr
    lda atr_lo,x
    sta cut_attr
    lda atr_hi,x
    sta cut_attr+1
    lda #0
    sta tc
cut_stage_tile:
    clc
    lda $7ffe
    adc tc
    sta wx
    lda $7fff
    adc tr
    sta wy
    jsr actor_group
    jsr decode_block
    stx cut_block_id+1
    lda block+1
    sta cut_block_page+1
cut_compose:
    ldy cut_slot
    bne cut_decode
cut_page:
    ldx #0
    inc cut_page+1
    lda cache_lo,x
    sta cut_cache
    lda cache_hi,x
    sta cut_cache+1
cut_decode:
    ; The geometry block and the floor page are shared by this run.
    ; A fresh selection at the world carry also handles a change of floor.
cut_block_page:
    lda #0
    sta block+1
cut_block_id:
    ldx #0
    lda wx
    jsr decode_column
    lda state
    bmi cut_layers
    ldx cell_layers
    bne cut_layers
    jmp cut_plain
cut_layers:
    jsr cut_composed_tile
cut_stored:
    sty cut_slot
    ldy tc
    lda paint
    sta (cut_attr),y
    inc tc
    lda tc
    cmp #32
    beq cut_stage_row_done
    ; A new block can also cross world column zero and change the Y carry.
    inc wx
    lda wx
    and #7
    bne cut_compose
    jmp cut_stage_tile
cut_stage_row_done:
    inc tr
    lda tr
cut_last_row:
    cmp #0
    beq :+
    jmp cut_stage_row
:   lda #$a5                    ; restore both LDA zp instructions
cut_decode_mode:
    ; The main thread owns tile composition. IRQ only scans inputs and
    ; advances the clock, so walking always sees the straight-through path.
    sta decode_next
    sta decode_finish
    rts

.pushseg
.segment "VM_composed_tile"
; A is the tile state. A pan uses slot zero. A cut advances Y by eight.
cut_composed_tile:
    jsr draw_decoded
    ldy cut_slot
    .repeat 8, i
        lda cell+i
        sta (cut_cache),y
        iny
    .endrepeat
    rts
.segment "CODE"
; Unobstructed tiles go straight from the pattern pages into the staged edge.
cut_plain:
    jsr cut_plain_tile
    jmp cut_stored
cut_plain_tile:
    and #28
    asl
    ora #$80
cut_bank:
    cmp #$80
    beq cut_plain_ready
    sta cut_bank+1
    tax
    .repeat 8,i
        stx cut_scan+6*i+2
        .if i < 7
            inx
        .endif
    .endrepeat
cut_plain_ready:
    ldx fg
    ldy cut_slot
cut_scan:
    .repeat 8,i
        lda $8000+256*i,x
        sta (cut_cache),y
        iny
    .endrepeat
    rts
.popseg

.pushseg
.segment "RECLAIM5"
cut_steps: .byte 8,8,6,6
cut_pc_lo: .byte <59454,<59509,<59568,<59628
.popseg
.assert >59454 = >59628, error, "camera exits span two pages"

; Set up a rectangle in the guest attribute plane or in the VIC bitmap.
; The same direction/order protects overlapping source and destination.
cut_attrs:
    lda #0
    jsr cut_rectangle
    jmp cut_run
cut_pixels:
    lda #1
cut_rectangle:
    sta cut_plane
    ldx cut_dir
    lda cut_first_row,x
    sta cut_row
    lda cut_rows,x
    sta cut_nrows
    lda cut_col_from,x
    jsr cut_units
    sta cut_src_off
    lda cut_col_to,x
    jsr cut_units
    sta cut_dst_off
    lda cut_columns,x
    jsr cut_units
    sta cut_width
    lda #0
    sta cut_emit
cut_rectangle_row:
    ldx cut_dir
    clc
    lda cut_row
    adc cut_from_row,x
    tax
    jsr cut_row_ptr
    clc
    adc cut_src_off
    sta p1
    tya
    adc #0
    sta p1+1
    ldx cut_row
    jsr cut_row_ptr
    jsr cut_emit_pair
    ldx cut_dir
    clc
    lda cut_row
    adc cut_next_row,x
    sta cut_row
    dec cut_nrows
    bne cut_rectangle_row
    ; For a right shift, traverse the source from its high end.
    ldx #$e8                    ; INX
    lda #0
    ldy cut_dir
    cpy #1
    bne cut_finish
    ldx #$ca                    ; DEX
    ldy cut_width
    dey
    sty cut_begin+1
    lda #255
    bne cut_tail
cut_finish:
    sta cut_begin+1
    lda cut_width
cut_tail:
    pha
    ldy #0
    sty cut_jump+1
    ldy cut_emit
    txa
    sta cut_kernel,y
    lda #$e0                    ; CPX #limit / BNE cut_kernel / RTS
    sta cut_kernel+1,y
    pla
    sta cut_kernel+2,y
    lda #$d0
    sta cut_kernel+3,y
    tya
    eor #255
    sec
    sbc #4
    sta cut_kernel+4,y
    lda #$60
    sta cut_kernel+5,y
    rts
cut_run:
cut_begin:
    ldx #0
cut_jump:
    jmp cut_kernel

; Each row contributes LDA src,X / STA dst,X. At most 20 pairs plus
; the six-byte tail fit below the native stack guard at $0180.
cut_emit_pair:
    ldx cut_emit
    clc
    adc cut_dst_off
    sta cut_kernel+4,x
    tya
    adc #0
    sta cut_kernel+5,x
    lda #$bd
    sta cut_kernel,x
    lda p1
    sta cut_kernel+1,x
    lda p1+1
    sta cut_kernel+2,x
    lda #$9d
    sta cut_kernel+3,x
    txa
    clc
    adc #6
    sta cut_emit
    rts
cut_units:
    ldy cut_plane
    beq :+
    asl
    asl
    asl
:   rts
cut_row_ptr:
    lda cut_plane
    beq :+
    lda bmp_lo,x
    ldy bmp_hi,x
    rts
:   lda atr_lo,x
    ldy atr_hi,x
    rts
.segment "CODE"
.segment "G1"
cut_first_row: .byte 0,0,0,19,0,19
cut_from_row:  .byte 0,0,6,$fa,1,$ff
cut_next_row:  .byte 1,1,1,$ff,1,$ff
.segment "ROWCODE"
cut_rows:      .byte 20,20,14,14,19,19
.segment "G22"
.byte 0
cut_col_from:  .byte 8,0,0,0,0,0
cut_col_to = cut_col_from-1
.segment "G2"
cut_columns:   .byte 24,24,32,32,32,32

.segment "CODE"
; Use the end of the last intact view for real bitmap work. At line 76
; the first three rows have completely scanned on both video standards.
cut_early = $80                 ; 18 address bytes plus a six-byte loop tail
.assert cut_early+24 <= $98, error, "early copier overlaps keyboard IRQ scratch"
cut_mask:
    php
    ldx cut_dir
    cpx #4
    bcs cut_shake_window         ; a single-step shake has no staged edge
    cpx #3
    bne :+
    jmp cut_swap_top
:
    ldx #17
:   lda cut_kernel,x
    sta cut_early,x
    dex
    bpl :-
    ldx cut_emit
    ldy #0
:   lda cut_kernel,x
    sta cut_early+18,y
    inx
    iny
    cpy #6
    bne :-
    lda #<(-23)
    sta cut_early+22
    ldx cut_emit
    clc
    lda cut_kernel+4,x
    adc #18
    sta cut_kernel+4,x
    lda #18
    sta cut_jump+1
    jsr cut_top_window
    ldx cut_begin+1
    jsr cut_early
    jmp cut_wait_bottom
.segment "EXT"
cut_swap_top:
    ; Exchange the first incoming row with its old bitmap while the beam
    ; is farther down. The last pair in the overlap still needs old row 0.
    lda #<sound_period_lo
    sta cut_kernel+13*6+1
    lda #>sound_period_lo
    sta cut_kernel+13*6+2
    jsr cut_top_window
    ldx #0
:   ldy $2020,x
    lda sound_period_lo,x
    sta $2020,x
    tya
    sta sound_period_lo,x
    inx
    bne :-
    jmp cut_wait_bottom
.segment "CODE"
cut_wait_bottom:
    inc $01
:   lda $d012
    cmp #76
    bcc cut_hide
    cmp #204
    bcc :-
    bcs cut_hide
cut_shake_window:
    inc $01
:   lda $d012
    cmp #212                    ; wait below the complete city for a shake
    bne :-
cut_hide:
    dec $01
    lda #0
    ldx #31
:   .repeat 20,r
        sta $0404+40*r,x
    .endrepeat
    dex
    bpl :-
    plp
    rts
cut_top_window:
    inc $01
cut_top_sample:
    php
    sei
    lda $d012
cut_top_min:
    cmp #76
    bcc @outside
    cmp #84
    bcs @outside
    pla                         ; cut_mask restores P after the last matrix store
    dec $01
    rts
@outside:
    plp
    jmp cut_top_sample

; Only vertical cuts stage an edge: six full rows, four slots apart.
cut_install_edge:
    ldx cut_dir
    lda cut_edge_first,x
    sta cut_row
    lda cut_edge_height,x
    sta cut_nrows
    lda #0
    sta cut_dst_off
    sta cut_width               ; 256 pixel bytes per row
    sta cut_emit
    sta cut_slot
    cpx #3
    bne @row
    inc cut_row
    dec cut_nrows
    lda #4
    sta cut_slot
@row:
    lda cut_slot
    lsr
    lsr
    tax
    lda cut_slot
    ror                         ; offset within the cache page = (cut_slot & 3) * 64
    ror
    ror
    and #$c0
    clc
    adc cache_lo,x
    sta p1
    lda cache_hi,x
    adc #0
    sta p1+1
    ldx cut_row
    lda bmp_lo,x
    ldy bmp_hi,x
    jsr cut_emit_pair
    inc cut_row
    lda cut_slot
    clc
    adc #4
    sta cut_slot
    dec cut_nrows
    bne @row
    lda #0
    ldx #$e8
    jsr cut_finish
    jmp cut_run
.segment "G10"
cut_edge_first:  .byte 0,0,14,0
.segment "PN_cut_height"
cut_edge_height: .byte 20,20,6,6
.segment "CODE"
cut_reveal:
    ; The aligned palette gives exactly four cycles for every colour. Start
    ; behind the current scan and meet all 20 badlines of the next frame,
    ; even at the last cycle of line 255 on NTSC. Defer the keyboard IRQ
    ; only for publication (less than its 20 ms period).
    inc $01
cut_reveal_sample:
    php
    sei
    lda $d012
cut_reveal_min:
    cmp #64
    bcs @ready
    plp
    jmp cut_reveal_sample
@ready:
    dec $01
    ldx #0
cut_palette_row:
    stx cut_row
    lda atr_lo,x
    sta cut_raw+1
    lda atr_hi,x
    sta cut_raw+2
    lda scr_lo,x
    sta cut_matrix+1
    lda scr_hi,x
    sta cut_matrix+2
    ldy #31
cut_raw:
    ldx $ffff,y
    lda vic_attr,x
cut_matrix:
    sta $ffff,y
    dey
    bpl cut_raw
cut_row_done:
    ldx cut_row
    inx
    cpx #20
    bne cut_palette_row
    plp
    rts
.assert >cut_raw = >cut_row_done, error, "palette loop must stay on one page"

.segment "PN_cache_pages"
cache_lo: .lobytes sound_period_lo,sound_period_hi,sound_contended_lo,sound_contended_hi,$3f00,font
cache_hi: .hibytes sound_period_lo,sound_period_hi,sound_contended_lo,sound_contended_hi,$3f00,font

.segment "VM_cut_restore"
cut_restore:
    jsr cut_restore_font
    jmp make_sound_tables
.segment "PN_restore_font"
cut_restore_font:
    inc $01
    ldx #0
@font:
    lda $d900,x
    asl
    asl
    asl
    asl
    sta tmp
    lda $d800,x
    and #15
    ora tmp
    sta font,x
    inx
    bne @font
    dec $01
    rts
.segment "EXT"
