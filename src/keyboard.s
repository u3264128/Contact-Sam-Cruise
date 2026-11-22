column_mask = $98               ; IRQ scratch, overwritten on each scan
multiple_rows = $99
scan_keyboard:
    lda #0
    sta $dc02
    sta $dc03
    lda $dc00
    eor #255
    and #31
    sta joy
    ; Sample the columns with all row drivers released. A pressed key
    ; pulls its column low if the joystick grounds its row. Decode that
    ; key if exactly one row is grounded. Mask those columns on other rows.
    lda $dc01
    sta column_mask
    ; Drive all rows low to check for a press. Scan individual rows
    ; when any column reads low.
    ldx #0
    stx $dc00
    lda #$ff
    sta $dc02
    cmp $dc01
    bne scan_pressed
    stx $dc02
    stx held_key
    rts
scan_pressed:
    lda joy
    sec
    sbc #1
    and joy
    sta multiple_rows
scan_rows:
    ldx #0
    stx shifted
    stx sampled_key
row_scan:
    lda masks,x
    and joy
    beq @drive
    lda multiple_rows
    bne next_row
    lda column_mask
    eor #255
    jmp columns
@drive:
    lda masks,x
    sta $dc02
read_columns:
    lda $dc01
    eor #255
    and column_mask
columns:
    beq next_row
    sta scan_bits
    txa
    asl
    asl
    asl
    tay
key_bit:
    lsr scan_bits
    bcc next_bit
    lda key_matrix,y
    cmp #1
    bne :+
    sta shifted
    jmp next_bit
:   cmp #0
    beq next_bit
    sta sampled_key
next_bit:
    iny
    lda scan_bits
    bne key_bit
next_row:
    inx
    cpx #8
    bne row_scan
    lda #0
    sta $dc02
    lda sampled_key
    cmp #$82
    bne :+
    lda #'P'
    ldx shifted
    beq sampled
    lda #'O'
    bne sampled
:   cmp #$83
    bne :+
    lda #'A'
    ldx shifted
    beq sampled
    lda #'Q'
    bne sampled
:   ldx shifted
    beq sampled
    cmp #'a'
    bcc sampled
    cmp #'z'+1
    bcs sampled
    and #$df
sampled:
    cmp held_key
    bne transition
    cmp #0
    beq scan_done
    dec repeat_delay
    bne scan_done
    ldx #4
    bne publish_key
transition:
    sta held_key
    beq scan_done
    ldx #17
publish_key:
    stx repeat_delay
    sta key_event
    sta 23560
    lda 23611
    ora #32
    sta 23611
scan_done:
    rts
key_matrix:
    .byte 12,13,$82,0,$81,0,0,$83
    .byte "3wa4zse",1
    .byte "5rd6cftx"
    .byte "7yg8bhuv"
    .byte "9ij0mkon"
    .byte "+pl-.:@,"
    .byte 0,"*",0,0,1,"=",0,"/"
    .byte "1",0,0,"2 ",0,"q",0
