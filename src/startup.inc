start_game:
    lda $02a6                   ; read the KERNAL video standard flag
    sta pal_machine
    ldx #5
:   lda $fffa,x
    sta vector_tail,x
    dex
    bpl :-
    lda #107                    ; new and current games use Kempston
    sta vector_tail
    lda #<irq
    sta $fffe
    lda #>irq
    sta $ffff
    lda #<nmi
    sta $fffa
    lda #>nmi
    sta $fffb
    ldx #$fe
    lda #0
:   sta $01,x
    dex
    bne :-
    lda #$35
    sta $01
    ; Tables are installed when the title ends.
    lda $dd02
    ora #3
    sta $dd02
    lda $dd00
    ora #3
    sta $dd00
    lda #$1b
    sta $d011
    lda #8
    sta $d016
    lda #$14
    sta $d018
    lda #0
    sta $d015
    sta $d020
    sta $d021
    sta $d01a
    sta $dc0e
    sta $dd0e
    ldx #24
:   sta $d400,x
    dex
    bpl :-
    ; Raise the master volume one step per 10 ms. A jump from 0 to 15
    ; clicks on the 6581.
    ldy #1
@volume:
    sty $d418
    lda #8
    sta tmp
@delay:
    ldx #0
:   dex
    bne :-                      ; 1280 cycles, eight times per step
    dec tmp
    bne @delay
    iny
    cpy #16
    bne @volume
    lda #8
    sta $d403                   ; any nonzero width keeps the low level at 0
    lda #$f0
    sta $d406
    ; A 500 ms attack raises the 6581's DC level without an audible click.
    ; The gate then stays on at sustain 15 for the rest of the session.
    lda #$a0
    sta $d405
    lda #$49                    ; pulse, test and gate: the speaker's high level
    sta $d404
    ldx pal_machine
    lda timer_lo,x
    sta $dc04
    lda timer_hi,x
    sta $dc05
    lda #$81
    sta $dc0d
    lda #$11
    sta $dc0e
    ldx #0
:   lda #32
    .repeat 4,i
        sta $0400+i*250,x
    .endrepeat
    lda #1
    .repeat 4,i
        sta $d800+i*250,x
    .endrepeat
    inx
    cpx #250
    bne :-
    ldy #0
@line:
    ldx title,y
    iny
    inx
    beq @ready
:   lda title,y
    iny
    and #63
    beq @line
    sta $0400+40*8-1,x
    inx
    bne :-
@ready:
    cli
title_wait:
    lda key_event
    cmp #$81
    beq demo
    cmp #13
    beq start
    lda joy
    and #16
    beq title_wait
start:
    ldx #<61674
    jmp enter_game
demo:
    ldx #<61671
    jmp enter_game
.pushseg
.ifdef STRIPE_CAMERA
.segment "EXT"
.else
.segment "CAMBOOT"
.endif
title:
    .byte 11,"CONTACT SAM CRUISE",0
    .byte 86,"RETURN OR PORT 2 FIRE TO PLAY",0
    .byte 174,"F1 FOR DEMO",0,255
.popseg
