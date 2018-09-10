; This file bootstraps enough code to start a STC Forth
; for the 6502 system. It will allow programming NES programs
; using Forth. It's modelled using a NES-like memory
; map:
;   00-FF: zero page
;   100-1FF: hardware stack
;   200-7FF: User RAM
;   8000-FFFF: Cartridge space
;
; Unlike a NES cartridge, initially the cartridge space is
; RAM. The code will run in the simulator, and the user can
; interact with it, test functions, etc. Once they execute
; The word FREEZE, however, the contents of RAM from 8000-FFFF
; will be extracted and put into a .nes file with an appropriate
; header.
;
; The implementation loosely follows Jones Forth.
;
; Specifics:
;
; - The data stack is stored in the zero page with the x register
; as the stack pointer.
; - Words are compiled to a series of jsr instructions, or to inline
; code.
; - The words are relocatable. The entry point for each word is the same
; as the dictionary entry.

.macpack generic

; The simulator uses this address as the IO port.
; A write to this address will output that character
; to stdout, and a read will read the next character from
; stdin, possibly blocking, since the simulator reads line-by-
; line.
IO_PORT := $401C
.export IO_PORT
; Flags for the dictionary entries.
; The word should execute immediately even in compile mode
F_IMMED = $80
; The word should not be found in a dictionary search.
F_HIDDEN = $20
; Always inline the word
F_INLINE = $40

.segment "DICT"
; Reserve space to push the dictionary to the end of the memory
; space, since it now grows down.
.res $E00

.segment "ZEROPAGE": zeropage
.exportzp TMP1, TMP2, TMP3, TMP4, TMP5, TMP6, TMP7, TMP8
TMP1: .res 1
TMP2: .res 1
TMP3: .res 1
TMP4: .res 1
TMP5: .res 1
TMP6: .res 1
TMP7: .res 1
TMP8: .res 1

Stack: .res 40
.exportzp Stack
Stack_End: .res 8 ; buffer zone

ControlFlowSP: .res 1
ControlFlowStack: .res 10
ControlFlowStackEnd:

.segment "RAM"
; Reserve the hardware stack.
RStack: .res $100

; Pushes the given value onto the stack.
.macro push val
  dex
  dex
  lda #<val
  sta Stack, x
  lda #>val
  sta Stack+1, x
.endmacro

; Removes the top of stack.
.macro pop
  inx
  inx
.endmacro

.macro toTMP1
  lda Stack, x
  sta TMP1
  lda Stack+1, x
  sta TMP2
.endmacro

.macro fromTMP1
  lda TMP1
  sta Stack, x
  lda TMP2
  sta Stack+1, x
.endmacro

; The structure of a dictionary entry.
.struct DictEntry
  Jmp .byte
  CodePtr .word
  Flags2 .byte
  ; The length of the name. Also includes the flags
  Len .byte
  ; The entry name
  Name .byte
.endstruct

; The simulator treats $FF as a command to start
; logging each instruction for debugging.
.macro DEBUG_START
  .byte $FF
.endmacro

; The simulator treats $EF as a command to stop
; logging each instruction.
.macro DEBUG_END
  .byte $EF
.endmacro

; The simulator treats $DF as a command to print
; out the next bytes until a zero character.
.macro DEBUG_TRACE str
   .byte $DF
   .asciiz str
.endmacro

; New dictionary format, unifying xt and dictionary entry.
; jmp CODE_IMPL
; .word LINK
; .word IMMEDIATE | HIDDEN | LEN
; .byte "DUP"
; 
; The dictionary entry length does not change - once it is created
; with a name, it is fixed. However, we can update the jmp CODE_IMPL
; instruction to move the code around.
.macro defword name, flags, label
  .segment "DICT"
    label:
    .export label
    jmp .ident(.concat(.string(label), "_IMPL"))
    ; length and name
    .byte 0
    .byte .strlen(name) | flags
    .byte name
  .segment "DICT_CODE"
    .ident(.concat(.string(label), "_IMPL")):
.endmacro

; Variables are a special kind of word which reserve
; two bytes of space in the VARIABLES segment, and when
; executed, push that address on the stack.
.macro defvar name, init, label
  defword name, 0, label
    push .ident(.concat(.string(label), "_VALUE"))
    rts
  .segment "VARIABLES"
  .ident(.concat(.string(label), "_VALUE")):
  .word init
.endmacro

; The same as a variable, except it is allocated in the zero
; page.
.macro defvarzp name, init, label
  defword name, 0, label
    push .ident(.concat(.string(label), "_VALUE"))
    rts
  .segment "ZEROPAGE": zeropage
  .ident(.concat(.string(label), "_VALUE")):
  .word init
.endmacro

; A constant is a word which pushes its value onto the stack
; when it is executed.
.macro defconst name, value, label
  defword name, 0, label
    push value
    rts
.endmacro

defconst "dict::impl", DictEntry::CodePtr, DictEntryCodePtr
defconst "dict::len", DictEntry::Len, DictEntryLen
defconst "dict::name", DictEntry::Name, DictEntryName

defconst "c-sp", ControlFlowSP, C_SP
defconst "cstack", ControlFlowStack, CSTACK

; ( a -- )
defword "drop", F_INLINE, DROP
  pop
  rts

; ( a b -- b a )
defword "swap", 0, SWAP
  lda Stack, x
  ldy Stack+2, x
  sty Stack, x
  sta Stack+2, x
  lda Stack+1, x
  ldy Stack+3, x
  sty Stack+1, x
  sta Stack+3, x
  rts

; ( a -- a a )
defword "dup", 0, DUP
  dex
  dex
  lda Stack+2, x
  sta Stack, x
  lda Stack+3, x
  sta Stack+1, x
  rts

; ( a -- a + 1 )
defword "1+", 0, INCR
  inc Stack, x
  beq @hi
  rts
@hi:
  inc Stack+1, x
  rts

defword "1-", 0, DECR
  sec
  lda Stack, x
  sbc #1
  sta Stack, x
  lda Stack+1, x
  sbc #0
  sta Stack+1, x
  rts

defword "+", 0, ADD
  clc
  lda Stack, x
  adc Stack+2, x
  sta Stack+2, x
  lda Stack+1, x
  adc Stack+3, x
  sta Stack+3, x
  pop
  rts

; Divides a single byte by 3, truncating:
defword "3/", 0, DIV3
  ldy #$FF
  lda #$FD
:
  clc
  adc #3
  iny
  cpy #86
  bge @done
  cmp Stack, x
  beq @exact
  blt :-
@done:
  dey
@exact:
  sty Stack, x
  lda #0
  sta Stack+1, x
  rts

defword "-", 0, SUB
  sec
  lda Stack+2, x
  sbc Stack, x
  sta Stack+2, x
  lda Stack+3, x
  sbc Stack+1, x
  sta Stack+3, x
  pop
  rts

DEX_OP = $CA
LDA_IMM_OP = $A9
STA_ZP_X_OP = $95

defword "!", 0, STORE
  toTMP1
  ldy #0
  lda Stack+2, x
  sta (TMP1), y
  lda Stack+3, x
  iny
  sta (TMP1), y
  pop
  pop
  rts

defword "c!", 0, CSTORE
  lda Stack+2, x
  sta (Stack, x)
  pop
  pop
  rts

defword "@", 0, FETCH
  toTMP1

  ldy #0
  lda (TMP1), y
  sta Stack, x
  iny
  lda (TMP1), y
  sta Stack+1, x
  rts

defword "c@", 0, CFETCH
  lda (Stack, x)
  sta Stack, x
  lda #0
  sta Stack+1, x
  rts

; ( ptr1 ptr2 n -- )
defword "cmove", 0, CMOVE

defword "key", 0, KEY
  dex
  dex
  lda IO_PORT
  ldy #0
  sta Stack, x
  sty Stack+1, x
  rts

; ( -- str-ptr len )
defword "word", 0, WORD
  lda #0
  sta TMP1
  jsr KEY
  lda Stack, x
  pop
  cmp #'\'
  beq @skipComment
  cmp #' ' + 1
  bcc WORD_IMPL

@loop:
  ldy TMP1
  sta word_buffer, y
  inc TMP1
  jsr KEY
  lda Stack, x
  pop
  cmp #' ' + 1
  bge @loop

  ldy TMP1
  ; iny
  lda #0
  sta word_buffer, y ; zero terminate

  push word_buffer
  dex
  dex
  lda TMP1
  sta Stack, x
  lda #0
  sta Stack+1, x
  rts

@skipComment:
  jsr KEY
  lda Stack, x
  pop
  cmp #$A ; \n
  bne @skipComment
  beq WORD_IMPL ; bra

.segment "VARIABLES"
  word_buffer: .res 32

defvar "base", 10, BASE

; ( str len -- parsed-number )
; or ( str len -- str len 0 ) on error
; Also, carry is set if there's an error.
defword "number", 0, NUMBER

  Str := TMP1
  Result := TMP3
  Len := TMP5
  ResultAcc := TMP6
  
  lda Stack, x
  sta Len ; save string length

  lda Stack+2, x
  sta Str
  lda Stack+3, x
  sta Str+1 ; save str pointer

  lda #0
  sta Result
  sta Result+1

  txa
  pha ; save the stack pointer
  
  ldy #0
@eachDigit:
  lda (Str), y
  cmp #'A'
  bcc @digit ; if ascii < 'A', treat is as a decimal digit
  and #<~$20 ; convert to uppercase letter.
  sbc #'A' - '9' - 1 ; move it to the range $3A+, right after '9'.
@digit:
  sec
  sbc #'0' ; now it should be in a range of 0-BASE-1
  cmp BASE_VALUE
  bcs @invalid ; if digit >= BASE
  pha ; save the digit

    ldx BASE_VALUE ; loop BASE times, to multiply Result by BASE using repeated addition
    lda #0
    sta ResultAcc
    sta ResultAcc+1 ; reset ResultAcc
  @multLoop:
    clc
    lda ResultAcc
    adc Result
    sta ResultAcc
    lda ResultAcc+1
    adc Result+1
    sta ResultAcc+1 ; add Result to ResultAcc
    dex
    bne @multLoop

  pla ; get the digit
  clc
  adc ResultAcc
  sta Result
  lda ResultAcc+1
  adc #0
  sta Result+1 ; Result = ResultAcc + Digit

  iny
  cpy Len
  bne @eachDigit ; loop again for the next digit until we've exhausted the string.

  pla
  tax
  pop ; drop the string length
  lda Result
  sta Stack, x
  lda Result+1
  sta Stack+1, x ; put parsed number of the stack.

  push -1
  clc ; signal OK
  rts

@invalid:
  pla
  tax ; restore stack pointer
  lda #0
  dex
  dex
  sta Stack, x
  sta Stack+1, x 
  sec ; signal the error
  rts

defvarzp "latest", DictEntryCodePtr, LATEST

; ( str-ptr len -- dictionary-pointer )
; or ( str-ptr len -- str-ptr len 0 ) if it wasn't found
; Searches the dictionary for a definition of the given word.
defword "find", 0, FIND

  LPointer := TMP1
  MyStr := TMP3

  lda LATEST_VALUE
  sta LPointer
  lda LATEST_VALUE+1
  sta LPointer+1 ; load LATEST into LPointer

  sec
  lda Stack+2, x
  sbc #<(DictEntry::Name)
  sta MyStr
  lda Stack+3, x
  sbc #>(DictEntry::Name)
  sta MyStr+1 ; put the string pointer - name offset in MyStr
              ; that way we can use lda (MyStr), y to read
              ; MyStr using the same offset that we do from LPointer

; check if LPointer matches
@loop:
  ldy #(DictEntry::Len)
  lda (LPointer), y ; get length from dictionary entry
  and #$1F | F_HIDDEN ; mask to get length, allowing hidden to change length.
  cmp Stack, x ; compare to the length on the stack
  bne @next ; if lengths don't match, follow the next pointer.

  ; now compare the strings.
  lda Stack, x
  clc
  adc #(DictEntry::Name) - 1
  tay ; Init y to check the end of the string

@strcmpLoop:
  lda (LPointer), y
  cmp (MyStr), y
  bne @next
  dey
  cpy #(DictEntry::Len)
  beq @found
  bne @strcmpLoop ; bra

@next:

  ldy #(DictEntry::Len)
  lda (LPointer), y
  and #$1F ; TODO - magic constant
  clc
  adc LPointer
  sta LPointer
  lda #0
  adc LPointer + 1
  sta LPointer + 1 ; add string length to LPointer

  lda #DictEntry::Name
  clc
  adc LPointer
  sta LPointer
  lda #0
  adc LPointer + 1
  sta LPointer + 1 ; add the other bytes of the header.

  ; Check if current is past the end.
  lda LPointer + 1
  cmp #>SAVE_RAM ; SAVE_RAM is last in the dictionary.
  blt @loop
  lda LPointer
  cmp #<SAVE_RAM
  ble @loop

@notFound:
  dex
  dex
  lda #0
  sta Stack, x
  sta Stack+1, x
  rts
@found:
  pop
  lda LPointer
  sta Stack, x
  lda LPointer+1
  sta Stack+1, x
  rts

; Given a pointer, gets the name of the dictionary entry,
; or an empty string if it's not in the dictionary.
; ( addr -- addr len )
defword "rfind", 0, RFIND
  @LPointer := TMP1

  lda LATEST_VALUE
  sta @LPointer
  lda LATEST_VALUE+1
  sta @LPointer+1

@loop:
  lda @LPointer
  cmp Stack, x
  bne @ne
  lda @LPointer+1
  cmp Stack+1, x
  bne @ne
  ; We've found the dictionary entry, now return the string.
  ldy #DictEntry::Len
  lda (@LPointer), y
  and #$1F ; mask just the length, no flags.
  dex
  dex
  sta Stack, x
  lda #0
  sta Stack+1, x
  lda @LPointer
  clc
  adc #DictEntry::Name
  sta Stack+2, x
  lda @LPointer+1
  adc #0
  sta Stack+3, x
  rts
@ne:
  ldy #DictEntry::Len
  lda (@LPointer), y
  and #31 ; TODO - magic number
  clc
  adc @LPointer
  sta @LPointer
  lda #0
  adc @LPointer+1
  sta @LPointer+1

  lda #DictEntry::Name
  clc
  adc @LPointer
  sta @LPointer
  lda #0
  adc @LPointer+1
  sta @LPointer+1

  lda @LPointer+1
  cmp #>SAVE_RAM ; assumes SAVE_RAM is the last entry in the dictionary
  blt @loop
  lda @LPointer
  cmp #<SAVE_RAM
  beq @loop
  blt @loop
@notFound:
  ; Didn't find anything, so return 0 len string and the original address.
  dex
  dex
  lda #0
  sta Stack, x
  sta Stack+1, x
  rts

; Code Here pointer
; Points to the next free byte in the code area.
defvarzp "chere", CHERE_INIT, CHERE

; Dictionary Here pointer
; The dictionary grows downward, so this points to the
; first used byte in dictionary memory.
; This must be initialized to the first dict entry.
defvarzp "dhere", DictEntryCodePtr, DHERE

JMP_OP = $4C

; ( str-ptr len -- )
; Creates a new dictionary entry
defword "create", 0, CREATE
  ; The dict entry needs str-len + DictEntry::Name bytes of space.
  ; Subtract from DHERE to allocate the space.
  jsr DUP ; str length
  push DictEntry::Name
  jsr ADD
  jsr DHERE
  jsr FETCH
  jsr SWAP
  jsr SUB
  jsr DHERE
  jsr STORE

  ; Set the new entry's previous pointer
  ; LATEST @ DHERE @ PreviousPtr + !
  ; jsr LATEST
  ; jsr FETCH
  ; jsr DHERE
  ; jsr FETCH
  ; push DictEntry::PreviousPtr
  ; jsr ADD
  ; jsr STORE

  ; Update LATEST to the new entry
  ; DHERE @ LATEST !
  jsr DHERE
  jsr FETCH
  jsr LATEST
  jsr STORE

  ; ( stack is now string-ptr len )
  ; Store length in new entry
  ; DUP DHERE Len + C!
  jsr DUP
  jsr DHERE
  jsr FETCH
  push DictEntry::Len
  jsr ADD
  jsr CSTORE

  ; Write jmp CHERE to the dictionary entry.
  ; JMP_OP dhere @ Jmp + c!
  push JMP_OP
  jsr DHERE
  jsr FETCH
  push DictEntry::Jmp
  jsr ADD
  jsr CSTORE
  ; chere @ dhere @ codeptr + !
  jsr CHERE
  jsr FETCH
  jsr DHERE
  jsr FETCH
  push DictEntry::CodePtr
  jsr ADD
  jsr STORE  
  
  ; Move DHERE past the Len byte and pointers
  clc
  lda #<(DictEntry::Name)
  adc DHERE_VALUE
  sta TMP3
  lda #>(DictEntry::Name)
  adc DHERE_VALUE+1
  sta TMP4

  ; now we need to copy the name string.
  lda Stack, x ; get length
  tay
  dey

  lda Stack+2, x
  sta TMP1
  lda Stack+3, x
  sta TMP2 ; copy str pointer into TMP1

@loop:
  lda (TMP1), y
  sta (TMP3), y
  dey
  bpl @loop

  pop
  pop
  rts

defword ",", 0, COMMA
  ldy #0
  lda Stack, x
  sta (CHERE_VALUE), y
  lda Stack+1, x
  iny
  sta (CHERE_VALUE), y

  clc
  lda CHERE_VALUE
  adc #<2
  sta CHERE_VALUE
  lda CHERE_VALUE+1
  adc #>2
  sta CHERE_VALUE+1
  pop
  rts

defword "c,", 0, CCOMMA
  lda Stack, x
  ldy #0
  sta (CHERE_VALUE), y
  
  inc CHERE_VALUE
  bne @done
  inc CHERE_VALUE+1
@done:
  pop
  rts

defvar "state", 0, STATE

defword "[", F_IMMED, LSQUARE
  lda #0
  sta STATE_VALUE
  sta STATE_VALUE+1
  rts

defword "]", 0, RSQUARE
  lda #1
  sta STATE_VALUE
  lda #0
  sta STATE_VALUE+1
  rts

defword ":", 0, COLON
  jsr WORD
  jsr CREATE ; create the dictionary entry
  jsr LATEST
  jsr FETCH
  jsr HIDDEN ; toggle hidden in the entry
  jmp RSQUARE ; enter compile mode

RTS_OP = $60

defword ";", F_IMMED, SEMICOLON
  push RTS_OP
  jsr CCOMMA ; append rts to code

  jsr LATEST
  jsr FETCH
  jsr HIDDEN ; toggle hidden flag
  jmp LSQUARE ; go back to immediate mode

; ( dict-ptr -- )
; Marks the dictionary entry as hidden
defword "hidden", 0, HIDDEN
  toTMP1

  ldy #(DictEntry::Len)
  lda #F_HIDDEN
  eor (TMP1), y
  sta (TMP1), y

  pop
  rts

defword "hide", 0, HIDE
  jsr WORD
  jsr FIND
  jmp HIDDEN

CLV_OP = $B8
BVC_OP = $50

BEQ_OP = $F0
JSR_OP = $20

defword "[asm]", 0, RUN_ASM
  pla
  sta TMP1
  pla
  sta TMP2
  
  lda TMP1
  clc
  adc #2
  tay

  lda TMP2
  adc #0
  pha ; add 2 to the return address because there are 2 bytes of parameters.
  tya
  pha

  ; Move the two parmeters to the stack.
  ldy #2
  lda (TMP1), y
  dex
  dex
  sta Stack, x
  lda #0
  sta Stack+1, x

  dey
  lda (TMP1), y
  dex
  dex
  sta Stack, x
  lda #0
  sta Stack+1, x

  jmp AsmCompExec
  

; ( arg? instruction n-bytes -- )
; Given an optional argument, the number
; of bytes in the instruction, and the instruction
; number, compiles the instruction and arg to
; the code space.
defword "asm-comp", 0, ASM_COMP
  lda STATE_VALUE
  beq AsmCompExec
@compile:
  push JSR_OP
  jsr CCOMMA
  push RUN_ASM
  jsr COMMA
  jsr CCOMMA
  jsr CCOMMA
  rts
AsmCompExec:
  lda Stack, x
  pha
    pop
    jsr CCOMMA ; write instruction byte
  pla
  cmp #2
  beq @two
  blt @one
@three:
  jmp COMMA
@two:
  jmp CCOMMA
@one:
  rts
  
defword "quit", 0, QUIT
  stx TMP1
    cpx #Stack_End
    bcs @underflow
    ldx #$FF
    txs
  ldx TMP1
  jsr INTERPRET
  jmp QUIT
@underflow:
  jsr DODOTQUOTE
  .asciiz "Stack underflow detected!"
  ldx #Stack_End-1
  jmp QUIT

defword "interpret", 0, INTERPRET
  jsr WORD
  jsr FIND
  lda Stack, x
  ora Stack+1, x
  beq @notFound
  
  ; now that we have the dictionary entry, check if it's immediate.
  toTMP1
  ldy #(DictEntry::Len)
  lda (TMP1), y
  and #F_IMMED
  bne @execute

  lda STATE_VALUE
  beq @execute
@compiling:
  lda (TMP1), y
  and #F_INLINE
  bne @inline
  push JSR_OP
  jsr CCOMMA
  
  fromTMP1
  jsr COMMA
  rts

@inline: ; simple inlining -- just copy until you see an rts.
  ; dict::code + @
  push DictEntry::CodePtr
  jsr ADD
  jsr FETCH
  toTMP1
  pop
  ldy #0
@loop:
  lda (TMP1), y
  cmp #$60 ; if it's an RTS instruction
  beq @return
  dex
  dex
  sta Stack, x
  lda #0
  sta Stack+1, x
  tya
  pha
  jsr CCOMMA ; write the next byte
  pla
  tay
  iny
  bne @loop ; bra 
  rts

@execute:
  pop ; drop dictionary pointer
  jmp (TMP1) ; tailcall to the word, which will return to QUIT

@notFound:
  pop ; drop 0 error
  ; Didn't find the word in the dictionary, maybe it's a literal.
  jsr NUMBER ; parse as number 
  bcs @nan ; if error code set
  pop ; drop the truth value on the stack.
  ; Now we have a number on the top of stack.
  lda STATE_VALUE
  beq @executeLiteral
@compileLiteral:
  push (DEX_OP | (DEX_OP << 8))
  jsr COMMA ; compile dex; dex
  jsr DUP
  lda Stack, x
  sta Stack+1, x
  lda #LDA_IMM_OP
  sta Stack, x
  jsr COMMA ; compile LDA #lo
  push ((STA_ZP_X_OP) | (Stack << 8))
  jsr COMMA ; compile sta Stack, x
  lda #LDA_IMM_OP
  sta Stack, x
  jsr COMMA ; compile LDA #hi
  push ((STA_ZP_X_OP) | ((Stack+1) << 8))
  jsr COMMA ; compile sta Stack+1, x
  rts
@executeLiteral:
@return:
  rts

@nan:
  pop
  ; It's not a number
  lda Stack+2, x
  sta TMP1
  lda Stack+3, x
  sta TMP2
  jsr ParseInstruction
  lda Stack, x ; check the length of the instruction parsed.
  beq :+
  ; Remove the string
  lda Stack, x
  sta Stack+4, x
  lda Stack+1, x
  sta Stack+5, x
  lda Stack+2, x
  sta Stack+6, x
  lda Stack+3, x
  sta Stack+7, x
  inx
  inx
  inx
  inx
  jsr SWAP
  jsr DUP
  jsr DIV3
  jsr ADD
  jsr SWAP
  jsr ASM_COMP
  rts
:
  ; It's not in the dictionary, it's not a number, and not an instruction.
  ; Show the error message.
  pop ; drop 0
  lda Stack+2, x
  sta TMP1
  lda Stack+3, x
  sta TMP2 ; TMP12 = str-pointer

  ldy #0
@messageLoop:
  lda @errorMessage, y
  beq @printWord
  sta IO_PORT
  iny 
  bne @messageLoop ; bra
@printWord:
  ldy #0
@printWordLoop:
  lda (TMP1), y
  sta IO_PORT
  iny
  tya
  cmp Stack, x
  bne @printWordLoop; if y != string length
  pop
  pop ; discard string length and pointer.
  rts ; return to QUIT

@errorMessage:
  .byte $A, "ERROR: Couldn't find word: ", 0

defword ".", 0, DOT
  ; Set the V flag. While v is set, we will skip
  ; leading 0s. Once we see a digit which is non-zero, clv.
  bit @setV
  pop

  lda Stack-1, x
  ora Stack-2, x
  bne @nonZero
  jsr @zero
@nonZero:

  lda Stack-1, x
  jsr @digit
  lda Stack-2, x
  jsr @digit
@ending:
  lda #' '
  sta IO_PORT
  rts

@digit:
  sta TMP1
  lsr
  lsr
  lsr
  lsr
  beq :+
  clv
: bvs :+
  tay
  lda HexDigits, y
  sta IO_PORT
: lda TMP1
  and #$F
  beq :+
  clv
: bvs @setV
@zero:
  tay
  lda HexDigits, y
  sta IO_PORT
@setV:
  rts

HexDigits: .byte "0123456789ABCDEF"


; Variable which points to the next free variable RAM space.
defvar "vhere", VHERE_VALUE+2, VHERE

; Prints out the following bytes as a zero-terminated string.
; Use like:
;   jsr DODOTQUOTE
;   .asciiz "Some string"
defword "(.')", 0, DODOTQUOTE
  pla
  sta TMP1
  pla
  sta TMP2

  ldy #1 ; add 1 because the jsr pushes the last byte of the jsr
@loop:
  lda (TMP1), y
  beq @done
  sta IO_PORT
  iny
  bne @loop  
@done:
  clc ; fix up the return address to the address after the
  tya ; string
  adc TMP1
  sta TMP1
  lda TMP2
  adc #0
  pha
  lda TMP1
  pha
  rts

; ( addr -- addr+1 c )
defword "c@1+", 0, FETCH_INC
  jsr DUP
  jsr INCR
  jsr SWAP
  jmp CFETCH 

defword "see", 0, SEE
  .import Instruction
  jmp Instruction

defword "ins", 0, INS
  jsr WORD
  pop ; drop string length
  toTMP1
  pop
  .import ParseInstruction
  jsr ParseInstruction
  beq :+
  jsr SWAP
  jsr DUP
  jsr DIV3
  jsr ADD
  jsr SWAP
: rts

defword "thaw", 0, THAW
  Source := TMP1
  Target := TMP3

  ; Basic setup
  sei
  cld

  ; Set source pointer
  ; (Self-modifying code set by freeze)
SourcePtrLo:
  lda #<0000
  sta Source
SourcePtrHi:
  lda #>0000
  sta Source+1

  ; Set target pointer (just after TMP1-8)
  lda #<Stack
  sta Target
  lda #>Stack
  sta Target+1

SrcAgain:
  ldy #0
  lda (Source), y ; read byte
  iny
  cmp (Source), y ; peek a comparison with next byte
  beq @run
@single:
  ; it's a single byte, not a run
  ldy #0
  sta (Target), y
  ldx #1 ; signal to increment source by 1
  bne @then ; bra
@run:
  ; It's a run of the same byte
  sta TMP6
    iny
    lda (Source), y ; read run length
    sta TMP5
    tay
  lda TMP6
  iny
  iny ; add 2 to run length
@loop:
  dey
  sta (Target), y
  bne @loop

  ldy TMP5
  iny
  ldx #3 ; signal to increment source by 3
@then:
  ; Now we need to increment source and target
  ; y+1 tells us how much to increment target
  ; x tells us how much to increment source
  sty TMP5
  lda Target
  sec ; adjust +1
  adc TMP5
  sta Target

  lda Target+1
  adc #0
  sta Target+1 ; adjusted target

  stx TMP5
  lda Source
  clc
  adc TMP5
  sta Source

  lda Source+1
  adc #0
  sta Source+1 ; adjusted source

  lda EndPtrLo+1
  lda Source
EndPtrLo:
  cmp #<0000
  bne SrcAgain

  lda Source+1
EndPtrHi:
  cmp #>0000
  bne SrcAgain

  ; Source has now reached the end, so we've restored all of RAM.
@restoreRegs:
  ; Restore the register states (self-modifying code -- modified in freeze)
SPSave:
  ldx #0
  txs

  ; We're going to finish with an rti,
  ; but rts pushes return-1, while an interrupt
  ; pushes the return address directly. So,
  ; we need to increment our return address by 1.
  inc $101, x
  bne :+
  inc $102, x
:

PSave:
  lda #0
  pha ; store processor flag on stack
ASave:
  lda #0
XSave:
  ldx #0
YSave:
  ldy #0
  rti

defword "freeze", 0, FREEZE
  @source := TMP1
  @target := TMP3

  ; Save register states.
  sta ASave+1

  php
  pla
  sta PSave+1
  stx XSave+1
  sty YSave+1
  tsx
  stx SPSave+1

  ; Set source pointer
  lda #<Stack
  sta @source
  lda #>Stack
  sta @source+1

  ; Set target pointer, and source pointer of decompress
  lda CHERE_VALUE
  sta SourcePtrLo+1
  sta @target
  lda CHERE_VALUE+1
  sta SourcePtrHi+1
  sta @target+1

@again:
  ; Encode a single run
  lda @source+1
  cmp #>$800
  beq @done
  ldy #0
  lda (@source), y
@loop:
  iny
  beq @loopEnd
  cmp (@source), y
  beq @loop
@loopEnd:
  ; Now we've found the end of the run, or found 256 in a row.
  sta TMP6
    dey ; adjust y to 0-FF range
    ; Increment source to the byte after the run.
    sty TMP5
    lda @source
    sec ; add a plus 1 adjustment
    adc TMP5
    sta @source
    lda @source+1
    adc #0
    sta @source+1
  lda TMP6

  cpy #0
  bne @multiple
@single:
  ; A run of a single byte is encoded as itself.
  ldy #0
  sta (@target), y
  beq @incrementTarget ; bra
@multiple:
  ; A run of multiple is encoded as 2 repeated bytes, followed by a
  ; byte indicating the remaining repeats. So 5 0 bytes is encoded as 0 0 3
  ldy #0
  sta (@target), y
  iny
  sta (@target), y
  lda TMP5 ; load repeat count - 1
  sec
  sbc #1 ; subtract 1 from it 
  iny
  sta (@target), y

@incrementTarget:
  ; y now tells us how far to increment target
  sty TMP5
  lda @target
  sec ; adjust +1, since y is either 0 or 2.
  adc TMP5
  sta @target
  lda @target+1
  adc #0
  sta @target+1

  clv
  bvc @again ; bra

@done:
  lda @source
  beq @noOvershoot

  ; The last run has a length that takes it past
  ; the end of RAM.
  lda @target
  sec
  sbc #1
  sta @target
  lda @target+1
  sbc #0
  sta @target+1
  
  ldy #0
  lda (@target), y ; get the length of the last one
  sec
  sbc @source ; subtract by the overshoot amount
  sta (@target), y

  inc @target
  bne @noOvershoot
  inc @target+1

@noOvershoot:
  ; Save end pointer
  lda @target
  sta EndPtrLo+1
  lda @target+1
  sta EndPtrHi+1

  jmp 0 ; signal emulator to stop

defword "save-ram", 0, SAVE_RAM
  ; TODO - remove this word

.segment "DICT_CODE"
CHERE_INIT:

.segment "CODE"

reset:
  sei
  cld
  ldx #$FF
  txs

  ldx #Stack_End - Stack - 1
  lda #ControlFlowStackEnd - ControlFlowStack - 1
  sta ControlFlowSP

  jmp QUIT

.segment "VECTORS"
.word 0
.word reset
.word 0
