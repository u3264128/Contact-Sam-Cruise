.segment "EXT"

.ifdef STRIPE_CAMERA
.include "vic_attr.inc"
.endif
.include "parity.inc"
.ifdef STRIPE_CAMERA
.segment "CODE"
.else
.segment "CAMBOOT"              ; reused after the title screen
.endif

enter_game:
    stx zpc
    lda #>61671
    sta zpc+1
    jsr make_sound_tables
    lda #$3b
    sta $d011
    lda #$18
    sta $d018
    lda #0
    tax
:   sta $0400,x
    sta $0500,x
    sta $0600,x
    sta $0700,x
    inx
    bne :-
    lda #0
    sta addr
    lda #$58
    sta addr+1
@attributes:
    ldy #0
    lda (addr),y
    jsr write_addr
    inc addr
    bne @attributes
    inc addr+1
    lda addr+1
    cmp #$5b
    bne @attributes
.ifndef STRIPE_CAMERA
    jsr save_camera_tables      ; bitmap mode has released the title's colour RAM
.endif
    lda #$34
    sta $01
    lda #<23898
    sta zsp
    lda #>23898
    sta zsp+1
    cli
    jmp dispatch
.segment "CODE"
; Do not charge the player for 6510 interpreter overhead. Ordinary
; updates get one 48K tick, while scrolling and cutscenes have their own
; budgets. CIA keyboard repeat always uses real 50 Hz ticks.
.pushseg
.segment "VM_joystick_prompt"
joystick_prompt:
    ; Keep the guest clock running while the prompt waits for its message.
    lda #$ff
    sta clock_budget
    lda #96                     ; newline message from the original LD A,96
    sta za
    setpc 24953
.popseg

cutscene:
    lda #$ff
    sta clock_budget
    lda za
    sta 32722
    setpc 30992
clock_budget: .byte $ff
frame_start:
    lda #1
    sta clock_budget
frame_call:
    ; Original CALL 61440 at the head of the main loop.
    lda #<61486
    ldx #>61486
    jsr push_ax
    setpc 61440

nmi:
    rti
irq:
    pha
    txa
    pha
    tya
    pha
    lda $01
    pha
    lda #$35
    sta $01
irq_sources:
    lda $dc0d
    lsr
    bcc @exit
    lda clock_budget
    beq @keyboard
    bmi :+
    dec clock_budget
:   inc 23672
    bne :+
    inc 23673
    bne :+
    inc 23674
:
@keyboard:
    jsr scan_keyboard
@exit:
    pla
    sta $01
    pla
    tay
    pla
    tax
    pla
    rti
.include "keyboard.s"
; Kempston reverses the C64's up, down, left and right bits and keeps fire.
input_port:
    jsr fetch
    lda joy
    sta tmp
    ldx #4
    lda #0
:   lsr tmp
    rol
    dex
    bne :-
    lsr tmp
    bcc :+
    ora #16
:   jmp put_a
.ifdef USE_OUTPUT_PORT
; The Spectrum speaker bit drives the test bit of SID voice 1. The voice
; plays a pulse wave at frequency 0 with gate and sustain 15. A set test bit
; outputs the high level, so every OUT gives an instant square-wave edge at
; any pitch, on 6581 and 8580 alike.
output_port:
    jsr fetch
    lda za
    and #7
    tax
    inc $01
    lda border_colors,x
    sta $d020
    lda za
    and #16
    lsr
    ora #$41
    sta $d404
    dec $01
    jmp dispatch
.endif

; CIA2 timer A runs continuously and times each half wave. A sweep writes
; the next latch value during the current half wave, so the reload happens
; on the underflow without loop overhead. tone_adjust adds the routine's
; own loop cost in C64 cycles beyond the table's 13*p+36 T-states.
tone_adjust=$5f
tone_contended=$60              ; nonzero for delay loops in $4000-$7fff
tone_count=$61                  ; half waves left in const_tone, E then D
shot_sound:                     ; 13*E+56 T-states per half wave
    ldx #<set_period
    ldy #>set_period
    lda zd
    cmp #1                      ; the sniper's long, slowly rising delay sweep
    bne :+
    ldx #<sniper_period
    ldy #>sniper_period
:   stx @period+1
    sty @period+2
    lda #6
    sta tone_adjust
    sta tone_contended
    lda ze
    jsr start_tone
@loop:
    lda za
    clc
    adc #1
    and #23
    sta za                      ; ADD A,17: AND 23 with the toggle below
    jsr toggle
    lda ze
    clc
    adc zd
    sta ze
    beq @last
@period:                        ; keep the fast shot loop at one JSR
    jsr set_period
    jsr wait_half
    jmp @loop
@last:
    lda #0
    rol
    sta fcarry
    jsr wait_half
    lda za
    sta zb
    jmp finish_effect
banknote_sound:                 ; 13*E+44 T-states per half wave
    lda #2
    sta tone_adjust
    sta tone_contended
    lda ze
    jsr start_tone
@loop:
    inc za
    lda za
    and #23
    sta za
    jsr toggle
    dec ze
    bne :+
    dec zd
    beq @last
:   lda ze
    jsr set_period
    jsr wait_half
    jmp @loop
@last:
    jsr wait_half
    lda #0
    sta fcarry
    sta zb
    jmp finish_effect
.pushseg
.segment "VM_reveal"
reveal_sound:
    ldx #20
@row:
    txa
    pha
    jsr reveal_mark
    lda #$ff
    jsr const_tone
    jsr refresh_sub
    pla
    tax
    dex
    bne @row
    lda #$10
    sta zl
    lda #0
    sta zc
    sta fresult
    jmp ret_z80

.segment "VM_reveal_mark"
reveal_mark:
    asl
    asl
    tax
    lda #$ff
    .repeat 4, col
        sta $7f0c+col,x         ; four refresh bytes cover one city row
    .endrepeat
    txa
    asl
    sta za
    sta tone_count
    lda #1
    sta tone_count+1
    txa
    eor #$ff
    clc
    adc #89                     ; pitch = 88 - 4 * rows remaining
    tax
    stx ze
    rts
.popseg
finish_effect:
    jsr end_tone
    lda #0
    sta fresult
    jmp ret_z80

; DE counts E half waves then another 256 for each remaining D.
effect:                         ; 13*C+33 T-states per half wave
    lda ze
    sta tone_count
    lda zd
    sta tone_count+1
    lda #$ff
    ldx zc
    jsr const_tone
    sta ze
    sta zd
    sta fcarry
    sta zb
    sta fresult
    jmp ret_z80
footstep:                       ; 13*192+36 T-states per half wave
    lda #1
    sta za
    lda #7
    sta tone_count
    lda #1
    sta tone_count+1
    lda #0
    ldx #192
    jsr const_tone
    sta fresult
    sta fcarry
    jmp ret_z80

; A constant pitch only flips the speaker bit, so the border is set once and
; the two SID levels sit in X and Y. Each half wave then costs about 20
; cycles and pitches up to the original's 12.8 kHz keep their timing.
; A = tone_adjust, X = pitch, tone_count = half waves as E then D.
; Returns A = 0 with za holding the original's final speaker state.
const_tone:
    sta tone_adjust
    lda #0
    sta tone_contended
    txa
    jsr set_period
    inc $01
    lda za
    and #7
    tay
    lda border_colors,y
    sta $d020
    lda za
    eor #16
    and #16
    lsr
    ora #$41
    tax                         ; level after the first toggle
    eor #8
    tay                         ; level after the second
    lda $dd0d                   ; clear stale flags before the first edge
    lda #$11
    sta $dd0e                   ; start at the first SID write
    lda #1
@first:
    stx $d404
:   bit $dd0d
    beq :-
    dec tone_count
    bne @second
    dec tone_count+1
    beq @odd
@second:
    sty $d404
:   bit $dd0d
    beq :-
    dec tone_count
    bne @first
    dec tone_count+1
    bne @first
    beq @done
@odd:
.ifndef STRIPE_CAMERA
    .assert >@first = >@odd, error, "constant SID toggle loop crosses a page"
.endif
    lda za
    eor #16
    sta za
@done:
    lda #0
    sta $dd0e
    dec $01
    rts

; A = pitch parameter (0 means 256). Write the timer latch only.
; Delay loops in $4000-$7fff run slower while the ULA fetches the display,
; from T-state 14335 to 57343 of each frame. CIA1 timer A counts the
; emulated frame. The new latch applies once CIA2 timer A underflows, so
; the frame position of that moment, CIA1 minus CIA2, selects the table.
set_period:
    tay
    ldx pal_machine
    lda tone_contended
    beq @border
    inc $01
    lda $dc05
    sec
    sbc $dd05                   ; a negative result means the next frame
    dec $01
    cmp display_first,x
    bcc @border
    cmp display_end,x
    bcs @border
    lda sound_contended_lo,y
    ldx sound_contended_hi,y
    jmp adjust_period
@border:
    lda sound_period_lo,y
    ldx sound_period_hi,y
adjust_period:
    clc
    adc tone_adjust
    bit tone_adjust
    bmi @negative
    bcc @store
    inx
    bne @store
@negative:
    bcs @store
    dex
@store:
    inc $01
    sta $dd04
    stx $dd05
    dec $01
    rts
; CIA1 timer A high bytes for the contended part of the frame, indexed by
; pal_machine (NTSC latch 20420, PAL latch 19672).
display_first: .byte 15,14
display_end:   .byte 63,61
.pushseg
.segment "EXT"
; The sniper's half waves can cross the start or end of the Spectrum's
; contended display interval. CIA1 at CIA2's next underflow gives the
; start of the upcoming half wave. Adjust only the part across a boundary.
; The six scratch bytes are free after the boot-time sound tables are built.
wave_start=$63
boundary_distance=$65
wave_remainder=$67
sniper_period:
    tay
    inc $01
    lda $dc04
    sec
    sbc $dd04
    sta wave_start
    lda $dc05
    sbc $dd05
    sta wave_start+1
    dec $01
    bcc @border
    ldx pal_machine
    lda wave_start
    sec
    sbc @enter_l,x
    sta boundary_distance
    lda wave_start+1
    sbc @enter_h,x
    bcc @active
    sta boundary_distance+1
    ; A wave entering the display takes about 50% longer over its remaining part.
    lda sound_period_lo,y
    sec
    sbc boundary_distance
    sta wave_remainder
    lda sound_period_hi,y
    sbc boundary_distance+1
    bcc @border
    lsr
    ror wave_remainder
    tax
    clc
    lda wave_remainder
    adc sound_period_lo,y
    pha
    txa
    adc sound_period_hi,y
    tax
    pla
    jmp adjust_period
@border:
    lda sound_period_lo,y
    ldx sound_period_hi,y
    jmp adjust_period
@active:
    lda wave_start
    sec
    sbc @end_l,x
    sta boundary_distance
    lda wave_start+1
    sbc @end_h,x
    bcc @frame_end
    sta boundary_distance+1
    lda sound_contended_lo,y
    sec
    sbc boundary_distance
    sta wave_remainder
    lda sound_contended_hi,y
    sbc boundary_distance+1
    bcc @full_active
    ; Outside the display the remaining delay shrinks by about one third.
    ; Use 1/4 + 1/16 + 1/64 of that remainder.
    lsr
    ror wave_remainder
    lsr
    ror wave_remainder
    sta boundary_distance+1
    sta wave_remainder+1
    lda wave_remainder
    sta boundary_distance
    lsr boundary_distance+1
    ror boundary_distance
    lsr boundary_distance+1
    ror boundary_distance
    clc
    adc boundary_distance
    sta wave_remainder
    lda boundary_distance+1
    adc wave_remainder+1
    sta wave_remainder+1
    lsr boundary_distance+1
    ror boundary_distance
    lsr boundary_distance+1
    ror boundary_distance
    clc
    lda boundary_distance
    adc wave_remainder
    sta wave_remainder
    lda boundary_distance+1
    adc wave_remainder+1
    sta wave_remainder+1
    lda sound_contended_lo,y
    sec
    sbc wave_remainder
    pha
    lda sound_contended_hi,y
    sbc wave_remainder+1
    tax
    pla
    jmp adjust_period
@full_active:
    lda sound_contended_lo,y
    ldx sound_contended_hi,y
    jmp adjust_period
@frame_end:
    ; The Spectrum's keyboard interrupt pauses DJNZ for 955 T-states.
    ; CIA2 keeps running during the C64 interrupt. Add this once if the next
    ; half wave spans the start of a Spectrum frame.
    lda sound_period_lo,y
    sec
    sbc wave_start
    lda sound_period_hi,y
    sbc wave_start+1
    bcs :+
    jmp @border
:   lda sound_period_lo,y
    clc
    adc @irq_lo,x
    pha
    lda sound_period_hi,y
    adc #1
    tax
    pla
    jmp adjust_period
@irq_lo: .byte <279,<269        ; high byte is 1 on both models
; CIA1 counts down. Spectrum display contention begins at T-state 14335
; and ends at 57343. These are the corresponding NTSC and PAL counters.
@enter_l: .byte <16231,<15637
@enter_h: .byte >16231,>15637
@end_l: .byte <3664,<3530
@end_h: .byte >3664,>3530
.popseg
start_tone:
    ; The timer is stopped. Zero its counter: the first half wave starts now.
    tay
    inc $01
    lda #0
    sta $dd04
    sta $dd05
    dec $01
    tya
    jsr set_period
    inc $01
    lda #$11                    ; start, continuous, force load
    sta $dd0e
    lda $dd0d                   ; discard a stale underflow
    dec $01
    rts
; Flip the speaker bit in za, then show its border colour. Keeps X.
toggle:
    lda za
    eor #16
    sta za
    inc $01
    and #16
    lsr
    ora #$41
    sta $d404
    lda za
    and #7
    tay
    lda border_colors,y
    sta $d020
    dec $01
    rts
wait_half:
    inc $01
:   lda $dd0d
    and #1
    beq :-
    dec $01
    lda #0
    rts
end_tone:
    inc $01
    lda #0
    sta $dd0e                   ; the speaker keeps its last level
    dec $01
    rts
pal_machine: .byte 0
timer_lo: .byte <20420,<19672
timer_hi: .byte >20420,>19672
joy: .byte 0
held_key: .byte 0
key_event: .byte 0
shifted: .byte 0
sampled_key: .byte 0
scan_bits: .byte 0
repeat_delay: .byte 0
vector_tail: .res 6
border_colors: .byte 0,6,2,4,5,3,7,15
; The descriptors stay resident. Vertical cuts rebuild the four table pages.
.ifndef STRIPE_CAMERA
.pushseg
.segment "EXT"
.endif
.include "sound.inc"
.ifndef STRIPE_CAMERA
.popseg
.endif
sound_acc=$63
sound_step=$67
.ifndef STRIPE_CAMERA
.segment "CAMBOOT"               ; used once, before $3f00 becomes walking/camera scratch
; Keep the first font page in Colour RAM for the camera cleanup. The
; camera keeps its column flags in $da00-$dbff.
save_camera_tables:
    ldy #0
:   lda font,y
    sta $d800,y
    lsr
    lsr
    lsr
    lsr
    sta $d900,y
    iny
    bne :-
    ; Black mask sprites at $0140 for the smooth pan. VIC keeps these
    ; settings. The pan only fills the sprite and enables it.
    ldx #7
:   lda #5
    sta $07f8,x
    lda #0
    sta $d027,x
    lda pan_xy,x
    sta $d000,x
    lda pan_xy+8,x
    sta $d008,x
    dex
    bpl :-
    lda #$aa
    sta $d010
    lda #255
    sta $d017
    lda #0
    sta $d01b
    sta $d01c
    sta $d01d
    rts
pan_xy: .byte 32,50,56,50,32,92,56,92,32,134,56,134,32,176,56,176
.segment "CODE"
.endif
; Build the latch tables from four bytes of 16.16 base and three of step.
make_sound_tables:
    ldx #0
    lda pal_machine
    beq :+
    ldx #14
:   lda #<sound_period_lo
    ldy #>sound_period_lo
    jsr make_table
    lda #<sound_contended_lo
    ldy #>sound_contended_lo
make_table:                     ; A/Y points to the low-byte table, then the high bytes
    sta @lo+1
    sta @hi+1
    sty @lo+2
    iny
    sty @hi+2
    ldy #0
:   lda sound_descriptors,x
    sta sound_acc,y
    inx
    iny
    cpy #7
    bne :-
    ldy #1                      ; p = 1..255, then 0 standing for 256
@entry:
    clc
    lda sound_acc
    adc sound_step
    sta sound_acc
    lda sound_acc+1
    adc sound_step+1
    sta sound_acc+1
    lda sound_acc+2
    adc sound_step+2
    sta sound_acc+2
@lo:
    sta $ffff,y
    lda sound_acc+3
    adc #0
    sta sound_acc+3
@hi:
    sta $ffff,y
    iny
    cpy #1
    bne @entry
    rts
.segment "TABLES"
sound_period_lo: .res 256
sound_period_hi: .res 256
.segment "CODE"
