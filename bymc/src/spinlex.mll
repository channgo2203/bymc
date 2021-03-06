{
    open Printf

    open SpinTypes
    open Spin

    exception Unexpected_token of string
    let string_chars s = String.sub s 1 ((String.length s) - 2)
    let strip_last_n s n = String.sub s 0 ((String.length s) - n)
    let pp_word s = String.sub s 1 ((String.length s) - 1)
    let strip_leading s = Str.global_replace (Str.regexp "^[ \t]+") "" s

    let new_line lexbuf =
        (* backport of Lexing.new_line to ocaml 3.10.2 *)
        (* this function is copied from the implementation found in 3.12.1 *)
        let lcp = lexbuf.Lexing.lex_curr_p in
        lexbuf.Lexing.lex_curr_p <- { lcp with
          Lexing.pos_lnum = lcp.Lexing.pos_lnum + 1;
          Lexing.pos_bol = lcp.Lexing.pos_cnum;
        }
}

rule token = parse
   [' ' '\t']+           { token lexbuf } (* skip spaces *)
 | '\n'                  { new_line lexbuf; token lexbuf }
 | "/*"                  { comment lexbuf }
 | "!="                  { NE }
 | "!!"                  { O_SND }
 | '!'                   { SND }
 | "??"                  { R_RCV }
 | '?'                   { RCV }
 | "=="                  { EQ }
 | '='                   { ASGN }
 | "&&"                  { AND }
 | '&'                   { BITAND }
 | "||"                  { OR }
 | '|'                   { BITOR }
 | '^'                   { BITXOR }
 | '~'                   { BITNOT }
 | '@'                   { AT }
 | '%'                   { MOD }
 | '+'                   { PLUS }
 | "--"                  { DECR }
 | "++"                  { INCR }
 | "<<"                  { LSHIFT }
 | ">>"                  { RSHIFT }
 | "->"                  { IMPLIES }
 | ';'                   { SEMI }
 | '-'                   { MINUS }
 | '*'                   { MULT }
 | '/'                   { DIV }
 | "::"                  { SEP }
 | ':'                   { COLON }
 | '<'                   { LT }
 | '>'                   { GT }
 | "<="                  { LE }
 | ">="                  { GE }
 | ".."                  { DOTDOT }
 | '.'                   { DOT }
 | ','                   { COMMA }
 | '('                   { LPAREN }
 | ')'                   { RPAREN }
 | '['                   { LBRACE }
 | ']'                   { RBRACE }
 | '{'                   { LCURLY }
 | '}'                   { RCURLY }
 | '''                   { PRIME }
 | "[]"                  { ALWAYS }
 | "always"              { ALWAYS }
 | "<>"                  { EVENTUALLY }
 | "eventually"          { EVENTUALLY }
 | "U"                   { UNTIL }
 | "until"               { UNTIL }
 | "V"                   { RELEASE }
 | "W"                   { WEAK_UNTIL }
 | "not"                 { NEG }
 | "<->"                 { EQUIV }
 | "equivalent"          { EQUIV }
 | "implies"             { IMPLIES }
 | "active"              { ACTIVE }
 | "assert"              { ASSERT }
 | "atomic"              { ATOMIC }
 | "bit"                 { TYPE TBIT }
 | "bool"                { TYPE TBIT }
 | "break"               { BREAK }
 | "byte"                { TYPE TBYTE }
 | "c_code"              { C_CODE }
 | "c_decl"              { C_DECL }
 | "c_expr"              { C_EXPR }
 | "c_state"             { C_STATE }
 | "c_track"             { C_TRACK }
 | "D_proctype"          { D_PROCTYPE }
 | "do"                  { DO }
 | "chan"                { TYPE TCHAN }
 | "else"                { ELSE }
 | "empty"               { EMPTY }
 | "enabled"             { ENABLED }
 | "eval"                { EVAL }
 | "false"               { CONST 0 }
 | "fi"                  { FI }
 | "for"                 { FOR }
 | "full"                { FULL }
 | "goto"                { GOTO }
 | "hidden"              { HIDDEN }
 | "if"                  { IF }
 | "in"                  { IN }
 | "init"                { INIT }
 | "inline"              { INLINE }
 | "int"                 { TYPE TINT }
 | "len"                 { LEN }
 | "local"               { ISLOCAL }
 | "ltl"                 { LTL }
 | "mtype"               { TYPE TMTYPE }
 | "nempty"              { NEMPTY }
 | "never"               { NEVER }
 | "nfull"               { NFULL }
 | "notrace"             { NOTRACE }
 | "np_"                 { NONPROGRESS }
 | "od"                  { OD }
 | "of"                  { OF }
 | "pc_value"            { PC_VAL }
 | "pid"                 { TYPE TSHORT }
 | "printf"              { PRINT }
 | "printm"              { PRINTM }
 | "priority"            { PRIORITY }
 | "proctype"            { PROCTYPE }
 | "provided"            { PROVIDED }
 | "run"                 { RUN }
 | "d_step"              { D_STEP }
 | "select"              { SELECT }
 | "short"               { TYPE TSHORT }
 | "skip"                { CONST 0 }
 | "timeout"             { TIMEOUT }
 | "trace"               { TRACE }
 | "true"                { CONST 1 }
 | "show"                { SHOW }
 | "typedef"             { TYPEDEF }
 | "unless"              { UNLESS }
 | "unsigned"            { TYPE TUNSIGNED }
 | "xr"                  { XU XR }
 | "xs"                  { XU XS }
 (* FORSYTE extensions { *)
 | "assume"              { ASSUME } 
 | "symbolic"            { SYMBOLIC } 
 | "all"                 { ALL } 
 | "some"                { SOME } 
 | "card"                { CARD } 
 | "and"                 { PAND } 
 | "or"                  { POR } 
 | "havoc"               { HAVOC } 
 (* end of FORSYTE extensions } *)
 (* threshold automata extensions (see the explanation in spin.mly) { *)
 | "skel"                { SKEL }
 | "when"                { WHEN }
 | "parameters"          { PARAMS }
 | "shared"              { SHARED }
 | "inits"               { INITS }
 | "locations"           { LOCATIONS }
 | "rules"               { RULES }
 | "assumptions"         { ASSUMES }
 (* end of threshold automata extensions } *)
 | ['0'-'9']+            { CONST (int_of_string (Lexing.lexeme lexbuf)) }
 | ['_' 'A'-'Z' 'a'-'z']['_' 'A'-'Z' 'a'-'z' '0'-'9']*
    {
        NAME (Lexing.lexeme lexbuf)
    }
 | '"' [^ '"']* '"'      { STRING (string_chars (Lexing.lexeme lexbuf)) }
 | '#' ['_' 'A'-'z']['_' 'A'-'z' '0'-'9']*
    {
        let macro = (Lexing.lexeme lexbuf) in
        match macro with
        | "#include" -> INCLUDE (parse_include lexbuf)

        | "#define" ->
            let name = parse_name lexbuf in
            let text = strip_leading (parse_define lexbuf) in
            DEFINE(name, text)

        | "#pragma" ->
            let name = parse_name lexbuf in
            let text = strip_leading (parse_pragma lexbuf) in
            PRAGMA(name, text)

        | "#ifdef" ->
            MACRO_IFDEF (parse_name lexbuf)

        | "#ifndef" ->
            MACRO_IFNDEF (parse_name lexbuf)

        | "#if" -> MACRO_IF
        | "#else" -> MACRO_ELSE
        | "#endif" -> MACRO_ENDIF
        | _ -> MACRO_OTHER macro
    }
 | eof                   { EOF }
 | _ as c { raise (Unexpected_token (sprintf "Unrecognized char: %c" c)) }

and parse_name = parse
   [' ' '\t']+    { parse_name lexbuf } (* skip spaces *)
 | ['_' 'A'-'Z' 'a'-'z']['_' 'A'-'Z' 'a'-'z' '0'-'9']*
    { Lexing.lexeme lexbuf }

and comment = parse
 | "*/"                 { token lexbuf }
 | '\n'                 { new_line lexbuf; comment lexbuf }
 | _                    { comment lexbuf }
 | eof                  { raise End_of_file }

and parse_include = parse
   [' ' '\t']+    { parse_include lexbuf } (* skip spaces *)
 | '"' [^ '"']* '"'
    {
        (* include it (string_chars (Lexing.lexeme lexbuf)) *)
        (string_chars (Lexing.lexeme lexbuf))
    }
 | '\n'           { raise (Unexpected_token "End-of-line in #include") }
 | eof            { raise End_of_file }
 | _ as c
    { raise (Unexpected_token
        (sprintf "Unrecognized char %c in #include after %s" c
            (Lexing.lexeme lexbuf))) }

and parse_pragma = parse
   [' ' '\t']+    { parse_pragma lexbuf } (* skip spaces *)
 | '"' [^ '"']* '"'
    { (string_chars (Lexing.lexeme lexbuf)) }
 | '\n'           { raise (Unexpected_token "End-of-line in #pragma") }
 | eof            { raise End_of_file }
 | _ as c
    { raise (Unexpected_token
        (sprintf "Unrecognized char %c in #pragma after %s" c
            (Lexing.lexeme lexbuf))) }

and parse_define = parse
 [' ' '\t']+      { parse_define lexbuf } (* skip spaces *)
 | [^ '\n']* '\\' '\n'
    {
        new_line lexbuf;
        let line = (Lexing.lexeme lexbuf) in
        (strip_last_n line 2) ^ (parse_define lexbuf)
    }
 | [^ '\n' '\\']* '\n'
    {
        new_line lexbuf;
        (strip_last_n (Lexing.lexeme lexbuf) 1)
    }
 | eof            { raise End_of_file }
 | _ as c
    { raise (Unexpected_token (sprintf "Unrecognized char in #define: %c" c)) }

