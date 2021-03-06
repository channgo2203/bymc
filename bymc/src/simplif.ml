(*
 * Simplify MIR statements, i.e. convert array access to a variable access.
 * I would call it 'stupidify' as in many cases this transformation makes
 * the program more complicated. Usually, one needs such a transformation
 * to do a SAT/BDD encoding.
 *
 * Array expansion proved to produce really dumb results.
 * However, constant propagation is quite useful.
 *
 * Igor Konnov, 2013
 *)

open Printf

open Accums
open Spin
open SpinIr
open SpinIrEval
open SpinIrImp

type expr_kind = OnlyConst | ConstOrParam | ConstOrParamOrVar

let expr_kind_less l r =
    match l, r with
    | OnlyConst, OnlyConst -> false
    | OnlyConst, _ -> true
    | ConstOrParam, ConstOrParamOrVar -> true
    | ConstOrParam, _ -> false
    | _ -> false


let rec classify_expr = function
    | Var v ->
            if v#is_symbolic
            then ConstOrParam
            else ConstOrParamOrVar

    | UnEx (_, e) ->
            classify_expr e

    | BinEx (_, l, r) ->
            let kl, kr = classify_expr l, classify_expr r in
            if expr_kind_less kl kr then kr else kl

    | _ -> OnlyConst


(* construct a somewhat canonical expression w.r.t. commutativity or duality *)
let rec canonical = function
    | BinEx (LT as t, l, r)
    | BinEx (LE as t, l, r)
    | BinEx (EQ as t, l, r)
    | BinEx (NE as t, l, r)
    | BinEx (GT as t, l, r)
    | BinEx (GE as t, l, r) ->
        begin
            match classify_expr l, classify_expr r with
            | OnlyConst, ConstOrParamOrVar
            | ConstOrParam, ConstOrParamOrVar ->
                    BinEx (symm_of_arith_rel t, canonical r, canonical l)

            | ConstOrParamOrVar, OnlyConst
            | ConstOrParamOrVar, ConstOrParam ->
                    BinEx (t, canonical l, canonical r)

            | _ -> if (expr_s l) < (expr_s r)
                then BinEx (t, canonical l, canonical r)
                else BinEx (symm_of_arith_rel t, canonical r, canonical l)
        end

    | BinEx (MULT as t, l, r) ->
            (* especially for FAST that report syntax error on x * 2 *)
        begin
            match classify_expr l, classify_expr r with
            | OnlyConst, ConstOrParamOrVar
            | ConstOrParam, ConstOrParamOrVar ->
                    BinEx (t, canonical l, canonical r)

            | _, OnlyConst
            | ConstOrParamOrVar, ConstOrParam ->
                    BinEx (MULT, canonical r, canonical l)

            | _ -> if (expr_s l) < (expr_s r)
                then BinEx (t, canonical l, canonical r)
                else BinEx (MULT, canonical r, canonical l)
        end

    | BinEx (t, l, r) ->
        BinEx (t, canonical l, canonical r)

    | UnEx (t, e) -> UnEx (t, canonical e)

    | _ as e -> e


module VarMap = Map.Make (struct
    type t = var
    let compare a b = a#id - b#id
end)

module StringSet = Set.Make(String)

exception Simplif_error of string

(* propagate negations of the tokens we know *)
let propagate_not ?negate:(init_neg=false) exp =
    let rec prop neg = function
    | UnEx (NEG, e) ->
        if neg then prop false e else prop true e

    | BinEx (OR, l, r) ->
        BinEx ((if neg then AND else OR), prop neg l, prop neg r)

    | BinEx (AND, l, r) ->
        BinEx ((if neg then OR else AND), prop neg l, prop neg r)

    | BinEx (IMPLIES, l, r) ->
        if neg
        then BinEx (AND, prop false l, prop true r)
        else BinEx (IMPLIES, prop false l, prop false r)

    | BinEx (EQUIV, l, r) ->
        if neg
        then BinEx (OR,
                BinEx (AND, prop false l, prop true r),
                BinEx (AND, prop true l, prop false r))
        else BinEx (EQUIV, l, r)

    | BinEx (EQ as t, l, r)
    | BinEx (NE as t, l, r)
    | BinEx (GT as t, l, r)
    | BinEx (LT as t, l, r)
    | BinEx (GE as t, l, r)
    | BinEx (LE as t, l, r) ->
        BinEx ((if neg then not_of_arith_rel t else t), l, r)

    | UnEx (ALWAYS, e) ->
        UnEx ((if neg then EVENTUALLY else ALWAYS), prop neg e)

    | UnEx (EVENTUALLY, e) ->
        UnEx ((if neg then ALWAYS else EVENTUALLY), prop neg e)

    | UnEx (NEXT, e) ->
        UnEx (NEXT, prop neg e)

    | BinEx (UNTIL, l, r) ->
        if neg
        then BinEx (OR,
                UnEx (ALWAYS, prop true r),
                BinEx (UNTIL, prop true r, prop true l))
        else BinEx (UNTIL, l, r)

    | _ as e ->
        if neg then UnEx (NEG, e) else e
    in
    prop init_neg exp


let compute_consts exp =
    let int_of_bool b = if b then 1 else 0 in
    let rec fold = function
    | BinEx (PLUS, IntConst l, IntConst r) -> IntConst (l + r)
    | BinEx (MINUS, IntConst l, IntConst r) -> IntConst (l - r)
    | BinEx (MULT, IntConst l, IntConst r) -> IntConst (l * r)
    | BinEx (DIV, IntConst l, IntConst r) -> IntConst (l / r)
    | BinEx (LT, IntConst l, IntConst r) -> IntConst (int_of_bool (l < r))
    | BinEx (LE, IntConst l, IntConst r) -> IntConst (int_of_bool (l <= r))
    | BinEx (GT, IntConst l, IntConst r) -> IntConst (int_of_bool (l > r))
    | BinEx (GE, IntConst l, IntConst r) -> IntConst (int_of_bool (l >= r))
    | BinEx (NE, IntConst l, IntConst r) -> IntConst (int_of_bool (l != r))
    | BinEx (EQ, IntConst l, IntConst r) -> IntConst (int_of_bool (l == r))
    | BinEx (AND, IntConst 0, _) -> IntConst 0
    | BinEx (AND, _, IntConst 0) -> IntConst 0
    | BinEx (AND, IntConst 1, r) -> r
    | BinEx (AND, l, IntConst 1) -> l
    | BinEx (AND, l, r) as e ->
            if l = r then l else e 
    | BinEx (OR, IntConst 1, _) -> IntConst 1
    | BinEx (OR, _, IntConst 1) -> IntConst 1
    | BinEx (OR, IntConst 0, r) -> r
    | BinEx (OR, l, IntConst 0) -> l
    | BinEx (OR, l, r) as e ->
            if l = r then l else e 
    | BinEx (IMPLIES, IntConst 0, _) -> IntConst 1
    | BinEx (IMPLIES, IntConst 1, r) -> r
    | BinEx (IMPLIES, l, IntConst 1) -> IntConst 1
    | BinEx (IMPLIES, l, IntConst 0) -> UnEx (NEG, l)
    | BinEx (EQUIV, IntConst 0, r) -> IntConst 0
    | BinEx (EQUIV, l, IntConst 0) -> IntConst 0
    | BinEx (EQUIV, IntConst 1, r) -> r
    | BinEx (EQUIV, l, IntConst 1) -> l
    | UnEx (NEG, IntConst 1) -> IntConst 0
    | UnEx (NEG, IntConst 0) -> IntConst 1

    | UnEx (ALWAYS, IntConst 0) -> IntConst 0
    | UnEx (ALWAYS, IntConst 1) -> IntConst 1
    | UnEx (EVENTUALLY, IntConst 0) -> IntConst 0
    | UnEx (EVENTUALLY, IntConst 1) -> IntConst 1
    | UnEx (NEXT, IntConst 0) -> IntConst 0
    | UnEx (NEXT, IntConst 1) -> IntConst 1
    | BinEx (UNTIL, _, IntConst 0) -> IntConst 0
    | BinEx (UNTIL, _, IntConst 1) -> IntConst 1
    | BinEx (UNTIL, IntConst 0, _) -> IntConst 0
    | BinEx (UNTIL, IntConst 1, r) -> fold (UnEx (EVENTUALLY, r))
    | Nop _ -> IntConst 1
    | _ as e -> e
    in
    let rec explore = function
    | BinEx (t, l, r) ->
            let nl, nr = explore l, explore r in
            fold (BinEx (t, nl, nr))

    | UnEx (t, e) ->
            fold (UnEx (t, explore e))

    | _ as e -> e
    in
    explore exp

(* Find all possible bindings for all variables used in an expression.
 * Yes, it blows up for large ranges as well as many variables.
 *)
let mk_expr_bindings type_tab exp =
    let not_array v = not (type_tab#get_type v)#is_array in
    let used_vars = List.filter not_array (expr_used_vars exp) in
    let get_var_range v =
        let tp = type_tab#get_type v in
        if tp#is_array
        then raise (Simplif_error
            (sprintf "Expression %s has an array access %s"
                (expr_s exp) v#get_name))
        else if not tp#has_range
        then raise
            (Simplif_error (sprintf "%s does not have range assigned" v#get_name))
        else let l, r = tp#range in
            range l r
    in
    let mk_var_map tuple =
        let bind map var value = VarMap.add var value map in
        List.fold_left2 bind VarMap.empty used_vars tuple
    in
    let var_ranges = List.map get_var_range used_vars in
    if used_vars = []
    then []
    else
        let all_tuples = mk_product_of_lists var_ranges in
        List.map mk_var_map all_tuples


(* propagate constants *)
let prop_const exp binding =
    let map v = 
        if VarMap.mem v binding
        then IntConst (VarMap.find v binding)
        else Var v
    in
    compute_consts (map_vars map exp)


let prop_const_in_stmt stmt binding =
    let propagate = function
    | MExpr (id, e) ->
        MExpr (id, prop_const e binding)
    | _ as s -> s
    in
    sub_basic_stmt propagate stmt


let binding_to_eqs binding =
    let eq var value = BinEx (EQ, Var var, IntConst value) in
    (* backport to ocaml 3.10.2: *)
    VarMap.fold (fun k v a -> (eq k v) :: a) binding []
    (* the new code:
    List.map eq (VarMap.bindings binding) *)


(* replace array accesses like  a[x+y] == i by a conjunction:
    (x == 0 && y == 0 && a[0] == i) || ... || (x == m && y == n && a[m+n] == i)
 *)
let expand_array_access type_tab stmt =
    let is_arr_access = function
    | BinEx (ARR_ACCESS, _, _) -> true
    | _ -> false
    in
    let rec expand = function
    | MExpr (id, BinEx (EQ, _, _))
    | MExpr (id, BinEx (NE, _, _))
    | MExpr (id, BinEx (GT, _, _))
    | MExpr (id, BinEx (GE, _, _))
    | MExpr (id, BinEx (LT, _, _))
    | MExpr (id, BinEx (LE, _, _)) as s ->
        let prop e binding =
            list_to_binex
                AND ((prop_const e binding) :: binding_to_eqs binding)
        in
        let e = expr_of_m_stmt s in
        if expr_exists is_arr_access e
        then
            let bindings = mk_expr_bindings type_tab e in
            if bindings <> []
            then let instances = List.map (prop e) bindings in
                MExpr (id, list_to_binex OR instances)
            else s
        else s

    | MExpr (id, BinEx (ASGN, _, _)) as s ->
        let mk_opt e binding =
            let guard =
                MExpr(fresh_id (),
                      (list_to_binex AND (binding_to_eqs binding))) in
            MOptGuarded [guard; MExpr(fresh_id (), (prop_const e binding))]
        in
        let e = expr_of_m_stmt s in
        if expr_exists is_arr_access e
        then
            let bindings = mk_expr_bindings type_tab e in
            if bindings <> []
            then let options = List.map (mk_opt e) bindings in
                MIf (id, options) (* many options *)
            else s (* constant indices *)
        else s
            
    | MExpr (id, UnEx (t, e)) ->
        let sube = expr_of_m_stmt (expand (MExpr (fresh_id (), e))) in
        MExpr (id, UnEx (t, sube))

    | MExpr (id, BinEx (t, l, r)) ->
        let le = expr_of_m_stmt (expand (MExpr (fresh_id (), l))) in
        let re = expr_of_m_stmt (expand (MExpr (fresh_id (), r))) in
        MExpr (id, BinEx (t, le, re))

    | _ as s -> s
    in
    expand stmt


(* Function expand_array_access usually causes blow up when used with multiple
   non-deterministic choices that are using array accesses inside.
   To workaround this we choose a cut point before branching. This must be a
   good heuristic.

   TODO: if one has many nested ifs, it may explode.
 *)
let expand_array_access_struc type_tab stmt =
    let cache = Hashtbl.create 10 in
    let points = ref [] in

    let rec gather_idx_exprs set = function
    | BinEx (ARR_ACCESS, _, IntConst _) ->
        set
    | BinEx (ARR_ACCESS, _, e) ->
        let e_s = expr_s e in
        Hashtbl.replace cache e_s e;
        StringSet.add e_s set
    | BinEx (_, l, r) ->
        gather_idx_exprs (gather_idx_exprs set r) l
    | UnEx (_, e) ->
        gather_idx_exprs set e
    | _ -> set
    in
    let rec find_expansion_points = function
    | MExpr (_, e) ->
        gather_idx_exprs StringSet.empty e
    | MAtomic (_, seq)
    | MD_step (_, seq) ->
        List.fold_left StringSet.union StringSet.empty
            (List.map find_expansion_points seq)
    | MIf (id, opts) ->
        let first = find_in_option (List.hd opts) in
        let common = List.fold_left StringSet.inter first
            (List.map find_in_option (List.tl opts)) in
        let united = List.fold_left StringSet.union StringSet.empty
            (List.map find_in_option opts) in
        if not (StringSet.is_empty common)
        then begin
            let decode_exp exp_str lst =
                (Hashtbl.find cache exp_str) :: lst in
            let idx_exprs = StringSet.fold decode_exp common [] in
            points := (id, idx_exprs) :: !points;
            StringSet.diff united common
        end
        else united
    | _ -> StringSet.empty
    and find_in_option = function
    | MOptGuarded seq
    | MOptElse seq ->
        List.fold_left StringSet.union StringSet.empty
            (List.map find_expansion_points seq)
    in
    (* find good expansion sets *)
    let _ = find_expansion_points stmt in
    (* expand arrays in expansion points, or fall back to the naive version *)
    let rec expand = function
    | MExpr (_, _) as s ->
        s (* TODO: expand arrays for individual expressions *)
    | MAtomic (id, seq) ->
        MAtomic (id, List.map expand seq)
    | MD_step (id, seq) ->
        MD_step (id, List.map expand seq)
    | MIf (id, opts) as s ->
        let guard_opt opt binding =
            let guard = list_to_binex AND (binding_to_eqs binding) in
            match opt with
            | MOptGuarded seq ->
                let ps = List.map (fun s -> prop_const_in_stmt s binding) seq in
                let g = MExpr (fresh_id (),
                    BinEx (AND, guard, (expr_of_m_stmt (List.hd ps)))) in
                MOptGuarded (g :: (List.tl ps))
            | MOptElse _ ->
                raise (Simplif_error "MOptElse is not supported")
        in
        let is_point (pid, exp) = (pid = id) in
        begin
            try
                let _, idx_exprs = List.find is_point !points in
                let one_expr = list_to_binex AND idx_exprs in
                let bindings = mk_expr_bindings type_tab one_expr in
                if bindings <> []
                then
                    let transform lst b =
                        List.fold_left
                            (fun l o -> (guard_opt o b) :: l) lst opts
                    in
                    let options = List.fold_left transform [] bindings in
                    MIf (id, options) (* many options *)
                else s (* constant indices *)
            with Not_found ->
                MIf (id, List.map expand_opt opts)
        end

    | _ as s -> s
    
    and expand_opt = function
    | MOptGuarded seq -> MOptGuarded (List.map expand seq)
    | MOptElse seq -> MOptElse (List.map expand seq)
    in
    expand stmt


(* replace arr[c] by arr_c for a constant c *)
let replace_arr_elem_with_var sym_tab exp =
    let rec embed_rec = function
    | BinEx (ARR_ACCESS, Var arr, IntConst i) ->
        let new_name = sprintf "%s_%dI" arr#get_name i in
        let sym = sym_tab#lookup new_name in
        let v = sym#as_var in
        Var v

    | BinEx (tok, l, r) ->
        BinEx (tok, embed_rec l, embed_rec r)

    | UnEx (tok, e) ->
        UnEx (tok, embed_rec e)

    | _ as e -> e
    in
    embed_rec exp


let replace_arr_elem_with_var_in_stmt sym_tab m_stmt =
    let sub_var = function
    | MExpr (id, e) ->
        MExpr (id, replace_arr_elem_with_var sym_tab e)

    | MAssert (id, e) ->
        MAssert (id, replace_arr_elem_with_var sym_tab e)

    | MAssume (id, e) ->
        MAssume (id, replace_arr_elem_with_var sym_tab e)

    | MPrint (id, s, es) ->
        MPrint (id, s, List.map (replace_arr_elem_with_var sym_tab) es)

    | _ as s -> s
    in
    sub_basic_stmt sub_var m_stmt


let flatten_array_decl type_tab new_type_tab stmts =
    let redecl_arr_var v =
        let tp = type_tab#get_type v in
        let mk_elem_var i =
            let nv = v#fresh_copy (sprintf "%s_%d" v#get_name i) in
            let nt = tp#copy in
            nt#set_nelems 1;
            new_type_tab#set_type nv nt;
            nv
        in
        if tp#is_array
        then List.map mk_elem_var (range 0 tp#nelems)
        else begin
            new_type_tab#set_type v (type_tab#get_type v);
            [v]
        end
    in
    let flatten_rev collected = function
    | MDecl (id, v, _) ->
        let to_decl v =
            if (new_type_tab#get_type v)#is_array
            then MDecl (fresh_id (), v, Nop "")
            else MDecl (id, v, Nop "") (* no expansion, keep the id *)
        in
        (List.map to_decl (redecl_arr_var v)) @ collected

    | _ as s -> s :: collected
    in
    List.rev (List.fold_left flatten_rev [] stmts)


let eliminate_arrays prog =
    let repl_glob_expr =
        replace_arr_elem_with_var (Program.get_sym_tab prog) in
    let rec sub_atomic = function
    | PropAll e -> PropAll (repl_glob_expr e)
    | PropSome e -> PropSome (repl_glob_expr e)
    | PropGlob e -> PropGlob (repl_glob_expr e)
    | PropAnd (l, r) -> PropAnd ((sub_atomic l), (sub_atomic r))
    | PropOr (l, r) -> PropOr ((sub_atomic l), (sub_atomic r))
    in
    let elim_in_unit = function
    | Proc p ->
        let repl_stmt = replace_arr_elem_with_var_in_stmt (p :> symb_tab) in
        Proc (proc_replace_body p (List.map repl_stmt p#get_stmts))
        
    | Stmt (MDeclProp (id, v, ae)) ->
        Stmt (MDeclProp (id, v, sub_atomic ae))

    | _ as u -> u
    in
    Program.program_of_units
        (Program.get_type_tab prog)
        (List.map elim_in_unit (Program.units_of_program prog))


let simplify_prog caches prog =
    let type_tab = Program.get_type_tab prog in
    let new_type_tab = type_tab#copy in
    let simp_unit_rev collected = function
    | Proc p ->
        let flat_decls = flatten_array_decl type_tab new_type_tab p#get_stmts
        in
        let simple_stmts =
            List.map (expand_array_access_struc type_tab) flat_decls in
        (Proc (proc_replace_body p simple_stmts)) :: collected

    | Stmt (MDecl (_, _, _) as d) ->
        let new_decls = flatten_array_decl type_tab new_type_tab [d] in
        (List.map (fun d -> Stmt d) new_decls) @ collected
    (* TODO: replace array accesses in LTL formulas *)
    | _ as u ->
        u :: collected
    in
    let new_units = List.rev
        (List.fold_left simp_unit_rev [] (Program.units_of_program prog))
    in
    (* update variable sets (shared, params, etc.) from units *)
    let new_prog = Program.program_of_units new_type_tab new_units in
    (* now, array variables were redefined, replace arrays with variables *)
    eliminate_arrays new_prog

