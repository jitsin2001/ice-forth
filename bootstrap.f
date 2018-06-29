: '\n' 10 ;
: bl 32 ;

: space bl emit ;

: negate 0 swap - ;

: true 0 1 - ;
: false 0 ;
: not 0= ;

: hex 16 base ! ;
: decimal 10 base ! ;

: jsr, 32 c, , ;

\ Recursively call the current word
: recurse immediate
  latest @
  jsr,
;

\ Takes the next word and compiles it even if it's immediate
: [compile] immediate
  word
  find
  jsr,
;


: 2- 2 - ;
: 2+ 2 + ;

hex
  : lda.i 0A9 c, c, ;
  : lda.zx 0B5 c, c, ;
  : sta.zx 095 c, c, ;
  : beq 0F0 c, c, ;
  : bne 0D0 c, c, ;
  : ora.zx 015 c, c, ;
  : pop 0E8E8 , ;
  : dex;dex 0CACA , ;
  : clv;bvc 050B8 , c, ;
  : rts 060 c, ;

  : debug_start immediate 0FF c, ;
  : debug_end immediate 0FE c, ;

  : stack 8 ;
decimal

\ Save branch instruction address
: if immediate
  \ [compile] debug
  pop
  stack 2- lda.zx
  stack 1- ora.zx
  chere @
  0 beq
;

: unless immediate
  ['] not jsr,
  [compile] if
;

\ Write the branch target to here.
: then immediate
  dup
  chere @ swap - 2-
  swap 1+ c! 
;

: else immediate
  chere @ 1+
  swap
  0 clv;bvc
  dup
  chere @ swap - 2-
  swap 1+ c!
;

: begin immediate
  \ [compile] debug
  chere @
;

\ ( branch-target -- )
: until immediate
  pop
  stack 2- lda.zx
  stack 1- ora.zx
  chere @ - 2- beq
;

: while
  pop
  stack 2- lda.zx
  stack 1- ora.zx
  chere @ - 2- bne
;

: literal immediate
  dex;dex
  dup
  <byte lda.i
  stack sta.zx
  >byte lda.i
  stack 1+ sta.zx
;

: '(' [ char ( ] literal ;
: ')' [ char ) ] literal ;
: '"' [ char " ] literal ;


: ( immediate
  1
  begin
    key
    dup '(' = if
      drop
      1+
    else
      ')' = if
        1-
      then
    then
  dup 0= until
  drop
;

( Now I can write comments using (nested) parens )

: allot
  vhere +!
;

( Declares a constant value. Use like `10 constant VariableName`)
: constant immediate
  word
  create
  [compile] literal
  rts
;

( Declares an uninitialized variable, giving it space
  after vhere )
: variable immediate
  vhere @
  2 allot
  [compile] constant
;

( Takes a dictionary entry and prints the name of the word )
: id.
  dict::len +    ( Skip the pointers )
  dup c@ ( get the length )
  31 and ( Mask the flags )
  
  begin
    swap 1+ ( addr len -- len addr+1 )
    dup c@ ( len addr -- len addr char )
    emit
    swap 1- ( len addr -- addr len-1 )

    dup 0=
  until 
  drop
  drop
;

: ?hidden
  dict::len +
  c@
  32 and
;

: ?immediate
  dict::len +
  c@
  128 and
;

: words
  latest @ ( read latest entry )
  begin
    dup ?hidden not if
      dup id.
      space
    then
    dict::prev + @ ( read previous pointer )
    dup 0=
  until
  drop ( drop null pointer )
  cr
;

: compiling state @ ;

( -- )
: ." immediate
  compiling if
    [ ['] (.') ] literal jsr, ( compile jsr (.") )

    begin
      key
      dup '"' <> if
        c,
        0
      then
    until
    0 c,
  else
    begin
      key
      dup '"' <> if
        emit
        0
      then
    until
  then
;

: welcome
  ." Welcome to Forth!" cr
;

welcome

( A jump to 0 is treated as a signal to
  the emulator to stop execution and freeze
  the ROM )
: freeze
  [ 0 jsr, ] 
;

hex
( xt -- )
: set-reset! 0FFFC ! ;
( xt -- )
: set-nmi! 0FFFA ! ;
( xt -- )
: set-irq! 0FFFE ! ;

( Ends an interrupt handler definiton )
: ;int immediate
  40 c, \ append rti
  latest @ hidden \ unhide
  [compile] [
;
decimal

: int-handle ;int
['] int-handle set-reset!
['] int-handle set-nmi!
['] int-handle set-irq!

