.pushseg
.segment "RECLAIM4"
pan_display:
    jsr pan_begin
    jsr cut_restore_font
    jmp pan_finish_frame
.segment "PAN"
.export pan_publish
.exportzp pan_band
pan_band = $80
pan_band_irq = $81
pan_phase = $82                 ; ten city bands and the fixed panel
pan_frame = $8d
pan_step = $8e
pan_column = $8f
pan_colour = $90
pan_limit = $91
pan_remaining = $92
pan_pending = $93
pan_scan = $94                  ; bands left to check in this search
pan_wy0 = $95                   ; world row of screen row 0 for staging
pan_staged = $0120              ; the step whose edge tiles each band holds
pan_offsets = $3de0             ; walking queue, idle during camera moves
pan_counts = font+240           ; safe start window for each band
pan_flags = cut_attr            ; Colour RAM flags of one band
pan_mask_bit = cut_slot
pan_program = cut_cache
pan_edge_lo = font+160
pan_edge_hi = font+180
pan_ink = font+200
pan_same = font+220
; Each row has eight bitmap transfers and one colour transfer. The upper
; row of a pair ends in a BCC over the lower row. The lower row jumps back
; to the column loop.
pan_colour_pair = 8*6
pan_row_bytes = pan_colour_pair+6
pan_lower_row = pan_row_bytes+2
pan_pair_size = pan_lower_row+pan_row_bytes+3
pan_kernels = $3f00             ; walking tile queue, idle while the camera runs
.assert 2*pan_pair_size <= 256, error, "row programs cross a page"
; Staged left-pan edge tiles: rows 0-15 in the duplicate upper palette,
; rows 16-19 in the idle walking queue at $0100.
.assert .lobyte(vic_attr) = 0, lderror, "edge tiles need a page-aligned palette"
; Two bits per column boundary, one Colour RAM nibble each: bit 1 for the
; upper row, bit 0 for the lower row. Bands 0-4 start at $da00 and bands
; 5-9 at $db00, 48 nibbles apart.

pan_begin:
    lda #$60
    sta decode_finish
    ldx cut_dir
    lda pan_after,x
    eor #7
    sta pan_aligned+1
    txa
    asl
    asl
    asl
    sta cut_src_off
    inc $01
    ldx #62
    lda #255
:   sta $0140,x                 ; opaque black sprite for both side masks
    dex
    bpl :-
    lda #0
    sta pan_band_irq
    sta pan_pending
    sta pan_step
    lda #8
    jsr pan_uniform
    sta pan_phase+10
    ldx #9
    lda #255                    ; no band has staged edge tiles yet
:   sta pan_staged,x
    dex
    bpl :-
    jsr pan_gutters
    jsr pan_actor_init
    jsr pan_classify
    jsr pan_build_rows
    ; Arm the next raster band before the copier can publish a new position.
    sei
    lda #1
    sta $dc0d                   ; service CIA ticks from the panel interrupt
    lda #<pan_irq
    sta $fffe
    lda #>pan_irq
    sta $ffff
    jsr pan_arm_first
    sta $d012
    lda #1
    sta $d019
    sta $d01a
    lda #255
    sta $d015
    cli
pan_cell:
    lda pan_step
    ldx cut_dir
    beq :+
    eor #7
:   sta pan_column
    ; Stage the edge tiles that the idle copier did not prepare. A left
    ; pan does this while its midpoint field is pending. A right pan shows
    ; each gutter from its midpoint field on. The frame IRQ can start that
    ; field once gutters 0-7 are ready. Bands 8 and 9 are staged before the
    ; beam reaches them.
    ldx cut_dir
    beq :+
    lda #2
    sta pan_pending
:   jsr pan_find_current
    beq :+
    jsr pan_stage_band
    jmp :-
:   ldx cut_dir
    beq pan_copy
    lda pan_pending
    beq pan_copy
    jsr pan_midpoint_now
pan_copy:
    lda pan_pending
    bne pan_copy
    lda #10
    sta pan_remaining
pan_choose:
    ; Search backwards from the most recently scanned band. It has the
    ; longest time until its next fetch.
    ldx #9
    bit $d011
    bmi @start
    lda $d012
    sec
    sbc #68
    cmp #144
    bcs @start
    lsr
    lsr
    lsr
    lsr
    tax
@start:
    stx pan_band
    lda #10
    sta pan_scan
@band:
    ldx pan_band
    ldy cut_dir
    lda pan_phase,x
    cmp #12
    beq @next_band
    cmp pan_after,y
    beq @next_band
    txa
    asl
    sta cut_row
    ; Start after both rows have been scanned. Reserve time for the copy,
    ; sprite DMA and keyboard scans before this band's next fetch.
    asl
    asl
    clc
    adc #34
    sta pan_limit
@wait:
    lda $d012
    ldy $d011
    cmp $d012
    bne @wait
    cpy #128
    ror
    sec
    sbc pan_limit
    bcs :+
    ldy pal_machine
    adc pan_period,y
:   ldx pan_band
    cmp pan_counts,x
    bcs @next_band
    jsr pan_move_band
    lda cut_dir
    bne @publish
    jsr pan_edge
    inc cut_row
    jsr pan_edge
@publish:
    ldx pan_band
    ldy cut_dir
    lda pan_after,y
    sta pan_phase,x
    dec pan_remaining
    beq @complete
    jmp pan_choose
@next_band:
    dec pan_scan
    bne :+
    jsr pan_fill                ; no band can start yet
    jmp pan_choose
:   dec pan_band
    bpl @band
    lda #9
    sta pan_band
    bne @band
@complete:
    lda cut_dir
    bne :+
    jsr pan_midpoint
:   inc pan_step
    lda pan_step
    cmp #8
    beq :+
    jmp pan_cell
:   lda pan_pending
    bne :-
    lda pan_frame
:   cmp pan_frame
    beq :-
    sei
    lda #0
    sta $d01a
    lda #8
    sta $d016
    lda #<irq
    sta $fffe
    lda #>irq
    sta $ffff
    lda #$81
    sta $dc0d
    cli
    jsr pan_gutters
    ldx #127
@palette:
    lda vic_attr,x
    sta vic_attr+128,x
    dex
    bpl @palette
    jsr pan_actor_restore
    lda #255
    sta group_key
    lda #0
    sta $d015
    dec $01
    lda #$a5
    sta decode_finish
    rts

pan_publish = @publish

.pushseg
.segment "RECLAIM4"
pan_lines:  .byte 50,66,82,98,114,130,146,162,178,194,210,50
.segment "RECLAIM5"
pan_after:  .byte 15,8
pan_period: .byte 132,156
.segment "RECLAIM2"
pan_row_offsets: .byte 0,pan_lower_row,pan_pair_size,pan_pair_size+pan_lower_row
pan_mask_start: .byte 1,8
pan_first: .byte 0,31
.popseg
.pushseg
.segment "RECLAIM11"
; Reserve half scanlines for fixed work. Each dirty row cell adds one more.
pan_guard:   .byte 31,24
pan_advance: .byte $c8,$88      ; INY or DEY
pan_stop:    .byte 32,255
pan_flag_lo: .byte 0,48,96,144,192,0,48,96,144,192
; Set pan_flags to the selected band's Colour RAM flags. Preserve X.
.segment "CODE"
pan_flag_ptr:
    lda pan_flag_lo,x
    sta pan_flags
    cpx #5                      ; carry selects $db00 for bands 5-9
    lda #$da
    adc #0
    sta pan_flags+1
    rts
.popseg

; Swap the gutter code with the first font page. The cut cleanup restores
; that page from its copy in colour RAM. The gutter colours are normally zero.
pan_gutters:
    ldx #19
@row:
    jsr pan_pointers
    txa
    asl
    asl
    asl
    sta @font+1
    sta @store+1
    ldy #7
@byte:
    lda (p2),y
    pha
@font:
    lda font,y
    sta (p2),y
    pla
@store:
    sta font,y
    dey
    bpl @byte
    ldy #0
    tya
    sta (color_ptr),y
    dex
    bpl @row
    rts

; Compare adjacent cells once while the original bitmap is still visible.
pan_classify:
    ldx cut_dir
    lda pan_guard,x
    sta pan_reserve+1
    ldy pal_machine
    lda pan_period,y
    sec
    sbc pan_guard,x
    sec
    sbc #61
    sta pan_dense_limit+1
    ldx #31
@offset:
    txa
    asl
    asl
    asl
    sta pan_offsets,x
    dex
    bpl @offset
    ldx #9
:   jsr pan_class_band
    dex
    bpl :-
    rts

; X selects a band. Mark its boundaries dirty and set its start window.
pan_class_dirty:
    stx pan_band
    jsr pan_flag_ptr
    ldy #39
    lda #3                      ; incoming edges and the initial gutter
:   sta (pan_flags),y
    dey
    bpl :-
    lda #64
    sta pan_limit
pan_class_window:
    ldx pan_band
    ldy pal_machine
    lda pan_period,y
    sec
pan_reserve:
    sbc #42
    sbc pan_limit
    sta pan_counts,x
    rts

; X selects a band. The two bits say which rows must move, including a
; change of colour only.
.pushseg
.segment "EXT"
pan_class_band:
    jsr pan_class_dirty
    ldy cut_dir
    lda pan_mask_start,y
    clc
    adc pan_flags
    sta pan_flag_read+1
    sta pan_flag_write+1
    lda pan_flags+1
    sta pan_flag_read+2
    sta pan_flag_write+2
    txa
    asl
    sta cut_row
    lda #2
    sta pan_mask_bit
pan_class_row:
    ldx cut_row
    ldy #56
@high:
    lda bmp_hi,x
    sta pan_compare+2,y
    sta pan_compare+5,y
    tya
    sec
    sbc #8
    tay
    bpl @high
    lda bmp_lo,x
    tax
    clc
    adc #8
    tay
    .repeat 8, i
        stx pan_compare+8*i+1
        sty pan_compare+8*i+4
        .if i < 7
            inx
            iny
        .endif
    .endrepeat
    ldx cut_row
    lda scr_lo,x
    sta pan_class_colour+1
    clc
    adc #1
    sta pan_neighbour+1
    lda scr_hi,x
    sta pan_class_colour+2
    sta pan_neighbour+2
    ldx #30
pan_class_cell:
pan_class_colour:
    lda $ffff,x
pan_neighbour:
    cmp $ffff,x
    bne pan_different
    lda pan_offsets,x
    tay
pan_compare:
    .repeat 8
        lda $ffff,y
        cmp $ffff,y
        bne pan_different
    .endrepeat
    dec pan_limit
pan_flag_read:
    lda $ffff,x
    eor pan_mask_bit
pan_flag_write:
    sta $ffff,x
pan_different:
    dex
    bpl pan_class_cell
    inc cut_row
    lsr pan_mask_bit
    beq :+
    jmp pan_class_row
:
    jmp pan_class_window
.popseg

; The two rows share a column index. X selects eight bitmap bytes and Y
; selects their colour. The left gutter participates in the same copy.
.pushseg
.segment "EXT"
pan_move_band:
    ldx pan_band
    jsr pan_flag_ptr
    lda pan_flags
    clc
    adc pan_column
    sta pan_pair+1
    lda pan_flags+1
    sta pan_pair+2
    jsr pan_patch_rows
    ldx cut_row
    jsr pan_row_ptr
    sta pan_run_top+1
    sty pan_run_top+2
    clc
    adc #pan_lower_row
    sta pan_run_bottom+1
    sty pan_run_bottom+2
    ldx cut_dir
    ldy pan_first,x
    ldx pan_band
    lda pan_counts,x
pan_dense_limit:
    cmp #0
    bcs pan_sparse_start
    lda #<(pan_dense_column-pan_repeat-2)
    sta pan_repeat+1
pan_dense_column:
    ; At most two row cells match. Copying them costs less than checking
    ; all 32 flags. Carry makes the generated upper row enter the lower row.
    ldx pan_offsets,y
    sec
    jmp pan_run_top
pan_sparse_start:
    lda #<(pan_copy_column-pan_repeat-2)
    sta pan_repeat+1
pan_copy_column:
pan_pair:
    lda $ffff,y
    and #3
    beq pan_next_column
    ldx pan_offsets,y
    lsr                         ; carry: lower row, A: upper row
    beq pan_run_bottom
pan_run_top:
    jmp $ffff
pan_run_bottom:
    jmp $ffff
pan_next_column:
pan_advance_op:
    iny
pan_stop_at:
    cpy #32
pan_repeat:
    bne pan_copy_column
    .assert pan_repeat+2-pan_dense_column <= 128, error, "dense column branch out of range"
pan_band_done:
    ; Both incoming cells may need copying. Shorten the next start window
    ; for each outgoing cell that was previously skipped.
    ldx cut_dir
    lda pan_first,x
    clc
    adc pan_column
    tay
    lda (pan_flags),y
    and #3
    ldx pan_band
    lsr
    bcs :+
    dec pan_counts,x
:   cmp #0
    bne :+
    dec pan_counts,x
:   rts

.popseg

.pushseg
.segment "RECLAIM3"
; X selects a row. Return its program pointer in Y:A.
pan_row_ptr:
    txa
    and #3
    tax
    lda pan_row_offsets,x
    ldy #>pan_kernels
    rts
.popseg

pan_build_rows:
    ldy cut_dir
    lda pan_advance,y
    sta pan_advance_op
    lda pan_stop,y
    sta pan_stop_at+1
    ldx #19
@row:
    stx cut_row
    ldy cut_dir
    beq @cached_edge
    jsr pan_pointers            ; right shifts draw straight into the gutter
    jmp @edge
@cached_edge:
    txa                         ; staged left-pan edge tile
    asl
    asl
    asl
    eor #$80                    ; rows 0-15 at $80-$f8, rows 16-19 at 0-$18
    sta p2
    lda #>vic_attr
    cpx #16
    bcc :+
    lda #1
:   sta p2+1
@edge:
    lda p2
    sta pan_edge_lo,x
    lda p2+1
    sta pan_edge_hi,x
    cpx #4
    bcc :+
    jmp @next
:   jsr pan_row_ptr
    sta pan_program
    sty pan_program+1
    ldx cut_row
    lda bmp_hi,x
    sta p1+1
    lda bmp_lo,x
    sec
    sbc cut_src_off
    sta p1
    eor #$38                    ; bitmap base and gutter end in $20 and $18
    sta p2
    ldy #0
@byte:
    lda #$bd                    ; LDA abs,X / STA abs,X
    ldx #$9d
    jsr pan_emit
    inc p1
    inc p2
    cpy #8*6
    bne @byte
    ldx cut_row
    lda scr_hi,x
    sta p1+1
    lda scr_lo,x
    sec
    sbc cut_dir
    sta p1
    eor #7                      ; matrix base and gutter end in 100 and 011
    sta p2
    lda #$b9                    ; LDA abs,Y / STA abs,Y
    ldx #$99
    jsr pan_emit
    ldx cut_row
    txa
    lsr
    bcs @last_row
    lda #$90                    ; BCC skips the lower row and lands on its JMP
    sta (pan_program),y
    iny
    lda #pan_row_bytes
    sta (pan_program),y
    bne @next
@last_row:
    lda #$4c                    ; JMP pan_next_column
    sta (pan_program),y
    iny
    lda #<pan_next_column
    sta (pan_program),y
    iny
    lda #>pan_next_column
    sta (pan_program),y
@next:
    ldx cut_row
    dex
    bmi :+
    jmp @row
:   rts
pan_emit:
    sta (pan_program),y
    iny
    lda p1
    sta (pan_program),y
    iny
    lda p1+1
    sta (pan_program),y
    iny
    txa
    sta (pan_program),y
    iny
    lda p2
    sta (pan_program),y
    iny
    lda p1+1
    sta (pan_program),y
    iny
    rts

pan_edge:
    ldx cut_row
    lda pan_same,x
    beq :+
    rts
:   jsr pan_pointers
    lda pan_edge_lo,x
    sta p1
    lda pan_edge_hi,x
    sta p1+1
    inc p2+1                    ; right edge is 32 cells beyond the gutter
    ldy #32
    lda pan_ink,x
    sta (color_ptr),y
    ldy #0
    .repeat 8, i
        lda (p1),y
        sta (p2),y
        .if i < 7
            iny
        .endif
    .endrepeat
    rts

; pan_staged holds the step whose edge tiles each band has staged.
; Return the first band without this step's tiles in X, with Z clear.
; Z is set when every band is ready.
pan_find_current:
    ldx #255
:   inx
    cpx #10
    beq :+
    lda pan_staged,x
    cmp pan_step
    beq :-
:   rts

; While no band can start, stage the next step's tiles for a band that is
; already copied. Its edge tiles or gutter are free again.
pan_fill:
    lda pan_step
    cmp #7
    bcs @done
    ldx #9
@find:
    lda pan_staged,x
    cmp pan_step
    bne @next
    ldy cut_dir
    lda pan_phase,x
    cmp pan_after,y
    beq @found
@next:
    dex
    bpl @find
@done:
    rts
@found:
    lda pan_step
    clc
    adc #1
    sta pan_staged,x
    ldy cut_dir
    beq pan_stage_pair
    eor #7
    bpl pan_stage_pair

; X selects a band. Stage both of its tiles for the current step.
pan_stage_band:
    lda pan_step
    sta pan_staged,x
    lda pan_column
; A is a column and X a band. Stage the band's two edge tiles.
pan_stage_pair:
    tay
    txa
    asl
    pha
    tya
    jsr pan_stage_setup
    pla
    tax
    jsr pan_stage_tile
    inx
    ; fall through for the lower row

; X selects a row. Stage its tile for the column from pan_stage_setup.
pan_stage_tile:
    dec $01
    stx tr
    txa
    clc
    adc pan_wy0
    sta wy
    lda pan_edge_lo,x
    sta cut_cache
    lda pan_edge_hi,x
    sta cut_cache+1
    jsr pan_actors
    jsr compose_map
    lda state
    bmi @layers
    ldx cell_layers
    bne @layers
    jsr cut_plain_tile
    jmp @colour
@layers:
    jsr cut_composed_tile
@colour:
    ldx tr
    lda atr_lo,x
    sta p1
    lda atr_hi,x
    sta p1+1
    ldy tc
    lda paint
    sta (p1),y
    and #127
    tay
    lda vic_attr,y
    sta pan_ink,x
    inc $01
    jsr pan_check_edge
    ldy cut_dir
    beq :+
    jsr pan_pointers
    lda pan_ink,x
    ldy #0
    sta (color_ptr),y
:   rts

.pushseg
.segment "PN_midpoint"
; Show the midpoint now if the beam is outside the city. Otherwise the
; frame IRQ applies the pending request. Applying it twice before the
; first band IRQ is harmless.
pan_midpoint:
    inc pan_pending
pan_midpoint_now:
    bit $d011
    bmi @apply
    lda $d012
    cmp #32
    bcc @apply
    cmp #216
    bcs @apply
    rts
@apply:
    lda #0
    sta pan_pending
    lda #12
pan_uniform:
    ldx #9
:   sta pan_phase,x
    dex
    bpl :-
    rts

.segment "EXT"
; Band interrupts keep Y. Arming the next band also delays the $d016
; write to cycle 45, past the visible end of the previous band.
pan_irq:
    pha
    txa
    pha
    lda $01
    pha
    lda #$35
    sta $01
    ldx a:pan_band_irq
    lda pan_lines+1,x
    sta $d012
    lda #1
    sta $d019
    lda pan_phase,x
    sta $d016
    ; Once this midpoint is on the beam, the copier can prepare the band
    ; behind it. All ten bands still show the midpoint in the same field.
    cmp #12
    bne :+
pan_aligned:
    lda #8
    sta pan_phase,x
:   inx
    cpx #11
    beq @frame
    stx pan_band_irq
    pla
    sta $01
    pla
    tax
    pla
    rti
@frame:
    ; The panel interrupt also services the 50 Hz CIA tick. A frame is
    ; shorter than a tick on both models.
    ldx #0
    stx pan_band_irq
    inc pan_frame
    lda pan_pending
    beq @tick
    lsr
    bcs @apply                  ; 1: requested by the copier
    ldx #7                      ; 2: right pan, wait for gutters 0-7
:   lda pan_staged,x
    cmp pan_step
    bne @tick
    dex
    bpl :-
@apply:
    lda #0
    sta pan_pending
    lda #12
    jsr pan_uniform
@tick:
    pla                         ; insert Y below $01 for irq_sources
    tax
    tya
    pha
    txa
    pha
    jmp irq_sources

pan_pointers:
    lda bmp_lo,x
    sec
    sbc #8
    sta p2
    lda bmp_hi,x
    sta p2+1
    lda scr_lo,x
    sec
    sbc #1
    sta color_ptr
    lda scr_hi,x
    sta color_ptr+1
    rts

.segment "G13"
; A is the column of a step. Set tc, wx and the world row base with the
; vertical carry that the original's intermediate camera positions give.
pan_stage_setup:
    ldx cut_dir
    bne :+
    clc
    adc #24
:   sta tc
    clc
    adc $7ffe
    sta wx
    txa
    bne @right
    lda wx
    eor #255
    cmp #225                    ; original left shift draws column 31
    jmp @world_y
@right:
    clc                         ; original right shift draws column zero
@world_y:
    lda #0
    adc $7fff
    sta pan_wy0
    rts
; The last eight bytes of a gap are the left gutter of the next row,
; which the pan swaps with the font.
.assert * <= $3198, lderror, "pan_stage_setup reaches the swapped gutter"
.popseg
.segment "PN_finish"
; Cleanup runs while the first fully aligned field is on the beam.
; Release the actors once the panel in that field has been scanned.
pan_finish_frame:
    inc $01
:   bit $d011
    bmi :-
    lda $d012
    cmp #246
    bne :-
    dec $01
    jmp cut_resume

.segment "PN_first_irq"
; Arm the next visible band even when setup ends halfway down the city.
; The first copy may publish a later band in this same video field.
pan_arm_first:
    ldx #0
    bit $d011
    bmi @arm
    lda $d012
    cmp #206
    bcs @arm
    clc
    adc #4
:   cmp pan_lines,x
    bcc @arm
    inx
    bne :-
@arm:
    stx pan_band_irq
    lda pan_lines,x
    rts

.segment "PN_patch_rows"
; A bitmap row is $140 bytes wide. Its low address repeats every four
; rows. The two kernel pairs keep those low bytes for the entire pan.
pan_patch_rows:
    ldx cut_row
    jsr pan_patch_row
    ldx cut_row
    inx
pan_patch_row:
    txa
    and #3
    tay
    lda pan_row_offsets,y
    tay
    lda bmp_hi,x
    .repeat 4, i
        sta pan_kernels+6*i+2,y
        sta pan_kernels+6*i+5,y
    .endrepeat
    jmp pan_patch_lower
.segment "PN_patch_lower"
pan_patch_lower:
    .repeat 4, i
        sta pan_kernels+6*(i+4)+2,y
        sta pan_kernels+6*(i+4)+5,y
    .endrepeat
    lda scr_lo,x
    sec
    sbc cut_dir
    sta pan_kernels+pan_colour_pair+1,y
    eor #7
    sta pan_kernels+pan_colour_pair+4,y
    lda scr_hi,x
    sta pan_kernels+pan_colour_pair+2,y
    sta pan_kernels+pan_colour_pair+5,y
    rts

.segment "PN_edge_check"
; Compare each incoming tile with the adjacent city cell before shifting.
; A matching edge also widens this band's next safe start window.
pan_check_edge:
    ldy cut_dir
    lda edge_pixel_offset,y
    clc
    adc bmp_lo,x
    sta p2
    lda bmp_hi,x
    adc #0
    sta p2+1
    lda scr_lo,x
    sta color_ptr
    lda scr_hi,x
    sta color_ptr+1
    lda #0
    sta pan_same,x
    lda edge_column,y
    tay
    lda (color_ptr),y
    cmp pan_ink,x
    bne @done
    ldy #7
@byte:
    lda (cut_cache),y
    cmp (p2),y
    bne @done
    dey
    bpl @byte
    jmp pan_edge_equal
@done:
    rts
.segment "PN_edge_equal"
pan_edge_equal:
    inc pan_same,x
    txa
    lsr
    tax
    jsr pan_flag_ptr
    ldy cut_dir
    lda edge_flag_offset,y
    clc
    adc tc
    tay
    lda tr
    and #1
    tax
    lda (pan_flags),y
    and edge_keep,x
    sta (pan_flags),y
    lda tr
    lsr
    tax
    inc pan_counts,x
    ldx tr
    rts
edge_pixel_offset: .byte 248,0
edge_column:       .byte 31,0
edge_flag_offset:  .byte 8,0
edge_keep:         .byte 1,2

; The walking index is idle during a pan. Its zero page holds up to
; 64 actor entries and one terminator for each of the eight groups.
pan_actor_pages = group_heads
pan_heads = $e9
pan_layers = pan_heads+8
pan_group = pan_layers+8
pan_used = pan_group+1
.exportzp pan_actor_pages, pan_used
.assert pan_actor_pages+1+64+8 <= pan_heads && pan_used <= $ff, error, "pan actor lists overlap"
.segment "PN_actor_init"
pan_actor_init:
    ldx #7
    lda #255
:   sta pan_heads,x
    dex
    bpl :-
    lda #0
    sta pan_used
    lda #<pan_actor_pages
    ldx #>pan_actor_pages
    sta sprite_actor_operand
    stx sprite_actor_operand+1
    lda #$4c                    ; JMP to the next packed actor
    sta sprite_next_operand-1
    lda #<pan_actor_advance
    sta sprite_next_operand
    lda #>pan_actor_advance
    sta sprite_next_operand+1
    rts
.segment "PN_actor_restore"
pan_actor_restore:
    lda #<group_actors
    sta sprite_actor_operand
    lda #>group_actors
    sta sprite_actor_operand+1
    lda #$bd                    ; restore LDA group_next,X for walking
    sta sprite_next_operand-1
    lda #<group_next
    sta sprite_next_operand
    lda #>group_next
    sta sprite_next_operand+1
    lda #0
    ldx #31
:   sta group_stamp,x
    dex
    bpl :-
    rts
pan_actor_advance:
    inx
    lda pan_actor_pages,x
    beq :+
    jmp sprite_actor_loop
:   rts
.segment "PN_actors"
pan_actors:
    lda wx
    lsr
    lsr
    lsr
    tax
    and #1
    sta pan_group
    lda wy
    lsr
    lsr
    and #6
    ora pan_group
    tay
    lda pan_heads,y
    bmi pan_actor_miss
    sta cell_head
    lda pan_layers,y
    sta cell_layers
    rts
pan_actor_miss:
    sty pan_group
    lda wy
    and #$f8
    sta group_key
    lda wx
    and #$f8
    sta map
    lda #0
    sta actor
    sta cell_layers
    ldx pan_used
    inx
    stx cell_head
    lda #215                    ; ascending page order preserves sprite priority
    sta actor+1
    jmp pan_actor_scan
.segment "PN_actor_scan"
pan_actor_scan:
    ldy #2
    lda (actor),y
    sec
    sbc group_key
    cmp #8
    bcc :+
    cmp #252
    bcc @next
:   dey
    lda (actor),y
    sec
    sbc map
    cmp #8
    bcc :+
    cmp #252
    bcc @next
:   lda actor+1
    sta pan_actor_pages,x
    inx
    ldy #4
    lda (actor),y
    ora cell_layers
    sta cell_layers
@next:
    inc actor+1
    lda actor+1
    cmp #231
    bne pan_actor_scan
    jmp pan_actor_store
.segment "PN_actor_store"
pan_actor_store:
    ldy pan_group
    lda cell_layers
    sta pan_layers,y
    lda #0
    cpx cell_head
    beq :+
    sta pan_actor_pages,x
    stx pan_used
    lda cell_head
:   sta cell_head
    sta pan_heads,y
    lda wx
    lsr
    lsr
    lsr
    tax
    rts
.popseg
