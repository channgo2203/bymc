/*
 * A lexer for threshold automata (see CONCUR'14, CAV'15 papers).
 * This is a temporary language that will most likely be replaced by
 * something more appropriate in the future.
 *
 * We need this parser to encode simple Paxos, which otherwise
 * explodes when encoding in Promela.
 *
 * Igor Konnov, 2015
 */

%{

open Printf
open Lexing

open Accums
open TaIr

let error message =
    raise (TaErr.SyntaxErr message)

(*
   Check that all locations have have an associated list of integers that
   contains exactly the number of local variables.
 *)
let check_locations decls locs =
    let rec count_locals n = function
        | (Local _) :: tl -> (count_locals (n + 1) tl)
        | _ :: tl -> count_locals n tl
        | [] -> n
    in
    let nlocals = count_locals 0 decls in
    let check_one (loc_name, vals) =
        let nvals = List.length vals in
        if nlocals <> nvals
        then let m =
            sprintf "All locations must contain the list of %d integer values, found %d in %s"
                nlocals nvals loc_name in
            raise (TaErr.SemanticErr m)
    in
    List.iter check_one locs


let loc_tbl = ref (Hashtbl.create 10)

let reset_locs () =
    Hashtbl.clear !loc_tbl

let put_loc name =
    let j = Hashtbl.length !loc_tbl in
    Hashtbl.add !loc_tbl name j

let find_loc name =
    try Hashtbl.find !loc_tbl name
    with Not_found ->
        raise (TaErr.SemanticErr (sprintf "location %s not found" name))

%}

%token  SKEL THRESHAUTO PARAMETERS UNKNOWNS LOCAL SHARED
%token	SEMI
%token	WHEN DO
%token	<int> CONST
%token	<string> NAME
%token	<string> MACRO

%token  INITS ASSUME LOCATIONS RULES SPECIFICATIONS DEFINE
%token  TRUE
%token  LTLF LTLG
%token  IMPLIES
%token  OR
%token  AND
%token  NE EQ LT GT LE GE
%token  NOT
%token  PLUS MINUS
%token  MULT
%token  COLON COMMA LPAREN RPAREN LBRACE RBRACE LCURLY RCURLY
%token  PRIME UNCHANGED
%token  EOF

%left IMPLIES
%left OR
%left AND
%right NOT LTLF LTLG
%left PLUS MINUS
%left MULT

%start  start
%type   <TaIr.Ta.ta_t> start

%%

start
    : header n = NAME LCURLY
        ds = decls
        defs = defines
        ass = assumptions
        locs = locations
        is = inits
        rs = rules
        specs = specifications
      RCURLY EOF
        {
            check_locations ds locs;
            TaIr.mk_ta n (List.rev ds) defs ass locs is rs specs
        }
    (* error handling *)
    | header NAME LCURLY decls defines assumptions locations inits rules specifications error
        { error "expected: '}' after specifications {..}" }
    | header NAME LCURLY decls defines assumptions locations inits rules error
        { error "expected: specifications after rules {..}" }
    | header NAME LCURLY decls defines assumptions locations inits error
        { error "expected: rules {..} after inits {..}" }
    | header NAME LCURLY decls defines assumptions locations error
        { error "expected: inits {..} after locations {..}" }
    | header NAME LCURLY decls defines assumptions error
        { error "expected: locations {..} after assumptions {..}" }
    | header NAME LCURLY decls defines error
        { error "expected: [defines] assumptions {..} after declarations" }
	;

header
    :
    | SKEL          {}
    | THRESHAUTO    {}
    ;

decls
    :                           { reset_locs (); [] }
    | tl = decls ds = decl      { ds @ tl }
    ;

decl
    : LOCAL ls = locals SEMI        { ls }
    | SHARED sh = shared SEMI       { sh }
    | PARAMETERS ps = params SEMI   { ps }
    | UNKNOWNS us = unknowns SEMI   { us }
    ;

locals
    : n = NAME
        { [ (Local n) ] }

    | ns = locals COMMA n = NAME
        { (Local n) :: ns }
    ;

shared
    : n = NAME
        { [ (Shared n) ] }

    | ns = shared COMMA n = NAME
        { (Shared n) :: ns }
    ;

params
    : n = NAME
        { [ (Param n) ] }

    | ns = params COMMA n = NAME
        { (Param n) :: ns }
    ;

unknowns
    : n = NAME
        { [ (Unknown n) ] }

    | ns = unknowns COMMA n = NAME
        { (Unknown n) :: ns }
    ;

defines
    : { StrMap.empty }

    | DEFINE n = MACRO EQ e = arith_expr SEMI defs = defines
        { StrMap.add n e defs }
    ;

assumptions
    : ASSUME LPAREN CONST RPAREN LCURLY es = bool_expr_list RCURLY
        { es }
    ;

inits
    : INITS LPAREN CONST RPAREN LCURLY es = rel_expr_list RCURLY
        { es }
    ;

rules
    : RULES LPAREN CONST RPAREN LCURLY rs = rule_list RCURLY
        { rs }
    ;

guard
    : WHEN LPAREN g = bool_expr RPAREN   { g }
    | WHEN LPAREN i = CONST RPAREN       {
        if i = 1
        then True
        else error "expected when (1)"
    }

rule_list
    : { [] }

    | CONST COLON src = NAME IMPLIES dst = NAME
        grd = guard
        DO LCURLY acts = act_list RCURLY SEMI rs = rule_list
        {
            let r = TaIr.mk_rule (find_loc src) (find_loc dst) grd acts in
            r :: rs
        } 
    
    | error { error "expected '<num>: <loc> -> <loc> when (..) do {..};" }
    ;


names
    : n = NAME
        { [ n ] }

    | ns = names COMMA n = NAME
        { n :: ns }
    ;

act_list
    : { [] }

    | n = NAME PRIME EQ e = arith_expr SEMI acts = act_list
        { (n, e) :: acts }

    | UNCHANGED LPAREN ns = names RPAREN SEMI acts = act_list
        { (List.map (fun n -> (n, Var n)) ns) @ acts }

    | error { error "expected var' == arith_expr OR unchanged(var, ..., var)" }


rel_expr_list
    : { [] }

    | e = rel_expr SEMI es = rel_expr_list
        { e :: es }
    ;

(* we need this to deal with parentheses *)
rel_expr
    : e = cmp_expr
        { e }

    | LPAREN e = rel_expr RPAREN
        { e }
    ;

locations
    : LOCATIONS LPAREN CONST RPAREN LCURLY ls = locs RCURLY
        { ls }
    ;

locs
    : { [] }
    | l = one_loc SEMI ls = locs
        { l :: ls }
    ;

one_loc
    : n = NAME COLON LBRACE l = int_list RBRACE
        { put_loc n; (n, l) }
    | error { error "expected '<name>: [ int(; int)* ]'" }
    ;

int_list
    : i = CONST { [i] }
    | i = CONST SEMI { [i] }
    | i = CONST SEMI is = int_list
        { i :: is }
    ;

bool_expr
    : e = cmp_expr
        { Cmp e }

    | TRUE
        { True }

    | NOT e = bool_expr
        { Not e }

    | l = bool_expr OR r = bool_expr
        { Or (l, r) }

    | l = bool_expr AND r = bool_expr
        { And (l, r) }

    | LPAREN e = bool_expr RPAREN
        { e }
    ;

bool_expr_list
    : { [] }

    | e = bool_expr SEMI es = bool_expr_list
        { e :: es }
    ;

cmp_expr
    : l = arith_expr GT r = arith_expr  { Gt (l, r) }
    | l = arith_expr GE r = arith_expr  { Geq (l, r) }
    | l = arith_expr LT r = arith_expr  { Lt (l, r) }
    | l = arith_expr LE r = arith_expr  { Leq (l, r) }
    | l = arith_expr EQ r = arith_expr  { Eq (l, r) }
    | l = arith_expr NE r = arith_expr  { Neq (l, r) }
    ;

arith_expr
    : i = CONST                             { Int i }
    | n = NAME                              { Var n }
    | n = NAME PRIME                        { NextVar n }
    | n = MACRO                             { Macro n }
    | LPAREN e = arith_expr RPAREN          { e }
    | i = arith_expr PLUS j = arith_expr    { Add (i, j) }
    | i = arith_expr MINUS j = arith_expr   { Sub (i, j) }
    | MINUS j = arith_expr                  { Sub (Int 0, j) }
    | i = arith_expr MULT j = arith_expr    { Mul (i, j) }
    /*| LPAREN error                          { error "expected (arith_expr)" }*/
    ;


specifications
    : SPECIFICATIONS LPAREN CONST RPAREN LCURLY forms = form_list RCURLY
    { forms } 

form_list
    : { Accums.StrMap.empty }

    | n = NAME COLON f = ltl_expr SEMI fs = form_list
        { Accums.StrMap.add n f fs }
    ;

ltl_expr
    : e = cmp_expr
        { LtlCmp e }

    | NOT e = ltl_expr
        { LtlNot e }

    | LTLF e = ltl_expr
        { LtlF e }

    | LTLG e = ltl_expr
        { LtlG e }

    | l = ltl_expr IMPLIES r = ltl_expr
        { LtlImplies (l, r) }

    | l = ltl_expr OR r = ltl_expr
        { LtlOr (l, r) }

    | l = ltl_expr AND r = ltl_expr
        { LtlAnd (l, r) }

    | LPAREN e = ltl_expr RPAREN { e }
    ;

