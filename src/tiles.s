; Compose tiles for PRINTTILE ($e70c) from the guest's world geometry
; and live window, fuse and door state.
tr=$22
tc=$23
wx=$24
wy=$25
map=$26
block=$28
tile=$2a
pat=$2c
out=$2e
state=$30
paint=$31
fg=$32
zone=$33
side=$34
actor=$35
dx=$37
height=$38
sprite=$39
cell=$3b                       ; 8-byte composition buffer
refresh_index=$43
bits=$44
attr_col=$45
src_row=$46
dst_row=$47
src_col=$48
dst_col=$49
row_size=$4a
p1=$4b
p2=$4d
color_ptr=$4f
row_end=$6d                     ; refresh: end of the current SRB row
group_key=$72
group_index=$73
group_used=$74
cell_head=$75
cell_layers=$76
dy=$77
; Each table fits all 32 blocks in a world row. Startup clears the stamps
; before the first epoch. IRQ code uses its own scratch below these tables.
group_heads  = $a0
group_layers = $c0
group_stamp  = $e0

print_tile:
    lda #255
    sta group_key
    lda zl
    sta tc
    lda zh
    sta tr
    jsr compose
    jmp ret_z80

refresh:
    jsr refresh_sub
    jmp ret_z80
refresh_sub:
    lda #255
    sta group_key
    ldx #0
.ifndef STRIPE_CAMERA
    stx z:walk_count
.endif
@rows:
    ; Skip clean screen rows four SRB bytes at a time.
    lda $7f10,x
    ora $7f11,x
    ora $7f12,x
    ora $7f13,x
    bne @dirty_row
    txa
    clc
    adc #4
    tax
    cpx #80
    bne @rows
    jmp @finished
@dirty_row:
    stx refresh_index
    txa
    clc
    adc #4
    sta row_end
@scan:
    ldx refresh_index
    lda $7f10,x
    beq @next
    sta bits
    lda #0
    sta $7f10,x
    txa
    lsr
    lsr
    sta tr
    txa
    and #3
    asl
    asl
    asl
    sta tc
@bit:
    asl bits
    bcc :+
.ifdef STRIPE_CAMERA
    jsr compose
.else
    jsr walk_collect
.endif
:   inc tc
    lda bits
    bne @bit
@next:
    inc refresh_index
    lda refresh_index
    cmp row_end
    bne @scan
    tax
    cpx #80
    bne @rows
@finished:
.ifndef STRIPE_CAMERA
    jsr walk_flush
.endif
    lda #$60
    sta zl
    lda #$7f
    sta zh
    lda #0
    sta zb
    sta za
    sta fcarry
    lda #$60
    sta fresult
    rts

.pushseg
.segment "EXT"
compose:
    jsr compose_cell
.ifndef STRIPE_CAMERA
    jsr cell_bitmap_address
    jmp paint_cell
cell_bitmap_address:
.endif
    ldx tr
    lda tc
    asl
    asl
    asl
    clc
    adc bmp_lo,x
    sta out
    lda bmp_hi,x
    adc #0
    sta out+1
.ifndef STRIPE_CAMERA
    rts
paint_cell:
.endif
    php
    jsr cell_window
    ldy #0
    .repeat 8,i
        lda cell+i
        sta (out),y
        .if i < 7
            iny
        .endif
    .endrepeat
    lda atr_lo,x
    sta color_ptr
    lda atr_hi,x
    sta color_ptr+1
    ldy tc
    lda paint
    sta (color_ptr),y
    lda scr_lo,x
    sta color_ptr
    lda scr_hi,x
    sta color_ptr+1
    ldx paint
    lda vic_attr,x
    sta (color_ptr),y
    plp
    rts
.popseg
.pushseg
.segment "ROWCODE"
; X is the character row. Keep the bitmap writes and the VIC colour fetch
; on the same side of the beam. The caller restores P after the last store.
cell_window:
    txa
    asl
    asl
    asl
    clc
    adc #47                     ; four lines before the row's badline
    sta z:beam_start
    inc $01
    sei
@sample:
    lda $d011
    bmi @clear                  ; lines 256+ are in the border
    lda $d012
    sec
    sbc z:beam_start
    cmp #12                     ; through the last pixel line, inclusive
    bcc @sample
@clear:
    dec $01
    rts
.popseg
compose_cell:
    lda tc
    clc
    adc $7ffe
    sta wx
    lda tr
    adc $7fff
    sta wy
    jsr actor_group
.pushseg
.segment "PN_tile_alias"
; X selects a column in the last two state and foreground planes.
tile_column_alias:
    .include "tile_aliases.inc"
.popseg
compose_map:
decode_block:
    stx map                     ; actor_group selected wx / 8 in X
decode_row:
    ldx wy
    cpx #48
    bcs @divide
    lda world_block_page,x
    sta block+1
    lda world_map_page,x
    sta map+1
    jmp @column
@divide:
    txa
    ldx #184
    sec
:   cmp #6
    bcc :+
    sbc #6
    inx
    bne :-
:   asl
    clc
    adc #160
    sta block+1
    stx map+1
@column:
    ldy #0
    lda (map),y
    tax
decode_next:                    ; camera staging can stop after block selection
    lda wx
decode_column:
    and #7
    tay
    ora #184
    sta tile+1
    lda $bf00,x
    and bit_order,y
    beq :+
    lda block+1
    clc
    adc #12
    sta block+1
:   txa
    ora #128
    sta tile
    ldy #0
    lda (tile),y
    sta block
    lda block+1
    and #$fd
    cmp #$a8
    bne :+
    ldx block
    jsr tile_column_alias
    stx block
:   ldy #32
    lda (map),y
    sta tile
    ldy #0
    lda (block),y
    sta state
    and #3
    ora #168
    sta tile+1
    lda (tile),y
    sta paint
    inc block+1
    lda (block),y
    sta fg
decode_finish:                  ; camera staging can draw straight into its cache
    lda state
draw_decoded:
    bmi layered
    and #28
    asl
    ora #128
    sta pat+1
    ldx fg
    stx pat
    jsr background
    lda cell_layers
    beq @finished
    lda state
    and #64
    beq indoor
    jmp front
@finished:
    rts
layered:
    lda #128
    sta pat+1
    lda state
    and #64
    beq window
    lda state
    and #60
    lsr
    ora #128
    ldx fg
    bpl :+
    ora #1
:   sta pat
    txa
    ora #128
    sta fg
    jmp indoor_base
window:
    ldy #64
    lda (map),y
    sta side
    ldy map
    ldx $ffc0,y
    lda $7f00,x
    beq :+
    lda side
    ora #32
    sta side
:   lda state
    and #4
    beq :+
    lda side
    and #3
    tax
    lda side
    and #32
    ora decorations,x
    sta side
:   lda side
    and #224
    ora fg
    sta fg
    lda #159
    sta pat
indoor_base:
    jsr background_80
indoor:
    lda cell_layers
    and #1
    beq :+
    jsr sprites
:   lda state
    bpl front
    ldx fg
    lda $c000,x
    tay
    .repeat 4,i
        lda cell+i
        ora $8000+i*512,y
        and $8100+i*512,y
        sta cell+i
    .endrepeat
    ldy $c100,x
    .repeat 4,i
        lda cell+4+i
        ora $8000+i*512,y
        and $8100+i*512,y
        sta cell+4+i
    .endrepeat
front:
    lda cell_layers
    and #2
    beq :+
    jsr sprites
:   lda cell_layers
    and #4
    bne sprites
    rts
background:
    lda pat+1
    cmp #$80
    bne @paged
    jmp background_80
@paged:
    ldy #0
    .repeat 8,i
        lda (pat),y
        sta cell+i
        .if i < 7
            inc pat+1
        .endif
    .endrepeat
    rts

; The same actor may be in a 3x5, 5x3 or 2x2 pose. Dimensions
; and tile order depend on the low seven bits of the animatory state.
sprites:
    sta zone
    ldx cell_head
sprite_actor_loop:
    stx group_index
    lda group_actors,x
sprite_actor_operand = *-2
    sta actor+1
    ldy #4
    lda (actor),y
    and zone
    beq @outside
    ldy #1
    lda wx
    sec
    sbc (actor),y
    cmp #5
    bcs @outside
    sta dx
    iny
    lda wy
    sec
    sbc (actor),y
    cmp #5
    bcs @outside
    sta dy
    ldy #0
    lda (actor),y
    and #127
    cmp #120
    bcs @small
    and #7
    cmp #7
    beq @wide
    ldx #3
    lda #5
    bne @shape
@small:
    ldx #2
    lda #2
    bne @shape
@wide:
    ldx #5
    lda #3
@shape:
    sta height
    cmp dy
    beq @outside
    bcc @outside
    cpx dx
    beq @outside
    bcs @inside
@outside:
    jmp @next
@inside:
    lda (actor),y
    bpl :+
    txa
    sec
    sbc dx
    tax
    dex
    stx dx
:   lda dy
    ldx dx
    beq @lookup
    clc
:   adc height
    dex
    bne :-
@lookup:
    clc
    adc #215
    sta sprite+1
    lda (actor),y
    and #7
    bne :+
    lda (actor),y
    clc
    adc #2
    jmp @ref
:   lda (actor),y
@ref:
    ora #128
    sta sprite
    lda (sprite),y
    bne :+
    jmp @next
:
    tax
    ldy sprite
    cpy #248
    bcc :+
    lda $db00,y
    beq :+
    sta paint
:   ldy #0
    lda (actor),y
    bmi @mirror
    .repeat 8,i
        lda cell+i
        ora $c700+512*i,x
        and $c800+512*i,x
        sta cell+i
    .endrepeat
    jmp @next
@mirror:
    .repeat 8,i
        ldy $c700+512*i,x
        lda $7e00,y
        ora cell+i
        ldy $c800+512*i,x
        and $7e00,y
        sta cell+i
    .endrepeat
@next:
    ldx group_index
    lda group_next,x
sprite_next_operand = *-2
    beq :+
    tax
    jmp sprite_actor_loop
:   rts
decorations: .byte 0,64,128,192
bit_order: .byte 128,64,32,16,8,4,2,1


; Index the actors in an eight-row band by their eight-column world
; blocks. A five-cell-wide actor can touch two blocks. Building the
; lists backwards preserves sprite priority when walking them forwards.
; A block's list is valid only when its stamp equals group_epoch, so a new
; band needs no clearing pass.
actor_group:
    lda wy
    and #$f8
    cmp group_key
    beq @select
    sta group_key
    inc group_epoch
    bne :++
    ldx #31                     ; after 256 bands, forget every stamp
    lda #0
:   sta group_stamp,x
    dex
    bpl :-
    inc group_epoch
:   lda #0
    sta actor
    sta group_used
    lda #230
    sta actor+1
@build:
    ldy #2
    lda (actor),y
    sec
    sbc group_key
    cmp #8
    bcc @visible
    cmp #252
    bcc @skip
@visible:
    dey
    lda (actor),y
    lsr
    lsr
    lsr
    tax
    jsr link_actor
    ldy #1
    lda (actor),y
    and #4
    beq @skip
    inx
    txa
    and #31
    tax
    jsr link_actor
@skip:
    dec actor+1
    lda actor+1
    cmp #214
    bne @build
@select:
    lda wx
    lsr
    lsr
    lsr
    tax
    lda group_stamp,x
    cmp group_epoch
    bne @empty
    lda group_heads,x
    sta cell_head
    lda group_layers,x
    sta cell_layers
    rts
@empty:
    lda #0
    sta cell_head
    sta cell_layers
    rts
link_actor:
    lda group_stamp,x
    cmp group_epoch
    beq :+
    lda group_epoch
    sta group_stamp,x
    lda #0
    sta group_heads,x
    sta group_layers,x
:   inc group_used
    ldy group_used
    lda group_heads,x
    sta group_next,y
    lda actor+1
    sta group_actors,y
    tya
    sta group_heads,x
    ldy #4
    lda (actor),y
    ora group_layers,x
    sta group_layers,x
    rts
group_epoch: .byte 1
.pushseg
.segment "VM_roll_prepare"
; Copy the live disguise and tucked-leg graphics into Sam's nine roll slots.
prepare_roll_tiles:
    ldx #8
@tile:
    lda roll_sources,x
    sta src
    txa
    clc
    adc #239
    sta dst
    lda #$c7
    cpx #6
    bcc :+
    lda #$d7
:   jsr copy_sprite_tile
    dex
    bpl @tile
    lda #205
    sta src
    lda #243
    sta dst
    lda #$d7
    sta src+1
    lda #$c7
    sta dst+1
    ldx #8
@arms:
    lda (dst),y
    ora (src),y
    inc src+1
    and (src),y
    inc src+1
    sta (dst),y
    inc dst+1
    sta (dst),y
    inc dst+1
    dex
    bne @arms
    jmp rotate_roll_tiles
roll_sources: .byte 2,3,4,170,6,7,181,189,197

.segment "VM_sprite_copy"
; Copy sixteen pages of alternating pixels and masks. Keep X and return Y=0.
copy_sprite_tile:
    sta src+1
    lda #$c7
    sta dst+1
    ldy #0
:   lda (src),y
    sta (dst),y
    inc src+1
    inc dst+1
    lda dst+1
    cmp #$d7
    bne :-
    rts

.segment "VM_roll_rotate"
; Rotate each tile anticlockwise. Read all eight rows and masks into
; scratch before replacing the source. The scratch is idle between refreshes.
rotate_roll_tiles:
    lda #239
    sta src
    ldy #0
@tile:
    lda #$c7
    sta src+1
@plane:
    lda src+1
    and #1
    eor #1                      ; pixel pages are odd, mask pages are even
    tax
    lda (src),y
    .repeat 8, bit
        lsr
        rol cell+2*bit,x
    .endrepeat
    inc src+1
    lda src+1
    cmp #$d7
    bne @plane
    lda #$c7
    sta src+1
    ldx #0
@store:
    lda cell,x
    sta (src),y
    inc src+1
    inx
    cpx #16
    bne @store
    inc src
    lda src
    cmp #248
    bne @tile
    jmp roll_finish

.segment "VM_roll_finish"
roll_finish:
    lda #239                    ; the Spectrum leaves a duplicate in tile 238
    sta src
    lda #238
    sta dst
    lda #$c7
    jsr copy_sprite_tile
    lda #$c7
    sta zd
    sta zh
    lda #238
    sta ze
    lda #237
    sta zl
    sty za
    sty zb
    sty zc
    sty fresult
    iny
    sty fcarry                  ; the last mask rotation shifted out its sentinel
    jmp ret_z80

.segment "VM_disguise_tiles"
; Each disguise replaces a list of tiles in Sam's live sprite bank.
disguise_tiles:
    lda 32713
    clc
    adc #223
    sta zb
    ldy #0
    sty zc
    ldx #62
@tile:
    lda $de00,x
    beq @portrait
    sta dst
    txa
    tay
    lda (zc),y
    sta src
    cmp #126
    bcc @packed
    lda #$d7
    jsr copy_sprite_tile
    jmp @next
@packed:
    jsr copy_disguise_pair
@next:
    inx
    jmp @tile
@portrait:
    stx zc
    stx alternate+4
    lda #$de
    sta alternate+5
    jmp disguise_portrait

.segment "VM_disguise_pair"
; These tiles store the graphic and mask next to each other on each page.
copy_disguise_pair:
    lda #$df
    sta src+1
    lda #$c7
    sta dst+1
    ldy #0
@row:
    lda (src),y
    sta (dst),y
    inc dst+1
    iny
    lda (src),y
    dey
    sta (dst),y
    inc dst+1
    inc src+1
    lda dst+1
    cmp #$d7
    bne @row
    rts

.segment "VM_disguise_portrait"
; Draw the three portrait columns directly in the VIC bitmap.
disguise_portrait:
    lda #$82
    sta zl
    lda #$d7
    sta zh
    lda #$50
    sta addr+1
    sta zd
    lda #$bd
@tile:
    sta addr
    jsr pixel_address
    lda (zl),y
    sta src
    lda #$c7
    sta src+1
    ldx #0
@row:
    lda (src,x)
    sta (vptr),y
    inc src+1
    inc src+1
    iny
    cpy #8
    bne @row
    inc zh
    lda addr
    clc
    adc #32
    bcc @tile
    cmp #31
    beq @done
    sec
    sbc #95
    inc zh
    inc zh
    jmp @tile
@done:
    sta ze
    sta za
    stx fcarry
    stx fresult
    jmp ret_z80
.popseg
.pushseg
.segment "G2"
group_actors: .res 33
.segment "G3"
group_next: .res 33
.segment "G20"
world_map_page:
    .repeat 48,i
        .byte 184 + i / 6
    .endrepeat
.segment "G21"
world_block_page:
    .repeat 48,i
        .byte 160 + 2 * (i .mod 6)
    .endrepeat
.segment "G22"
background_80:
    ldx pat
    .repeat 8,i
        lda $8000+i*256,x
        sta cell+i
    .endrepeat
    rts
.popseg
