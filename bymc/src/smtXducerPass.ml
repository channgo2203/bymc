(* Translate a program to an SSA representation and then construct
   SMT assumptions.

   Igor Konnov, 2012
 *)

open Printf

open Accums
open Cfg
open CfgSmt
open Debug
open SpinIr
open SpinIrImp
open Ssa

let write_exprs name stmts =
    let mul = 1 + (List.length stmts) in
    (* assign new ids to expression in a way that keeps the order between
       old ids and blocks of statements between them *)
    let num_stmt (num, lst) = function
        | MExpr (id, e) ->
                ((id + 1) * mul + 1, (MExpr ((id + 1) * mul, e)) :: lst)
        | _ ->
                raise (Failure "Expected Expr (_, _)")
    in
    let _, numbered = (List.fold_left num_stmt (0, []) stmts) in
    let sorted_stmts = List.sort cmp_m_stmt numbered in
    let out = open_out (sprintf "%s.xd" name) in
    let write_e s = fprintf out "%s\n" (expr_s (expr_of_m_stmt s)) in
    List.iter write_e sorted_stmts;
    close_out out


let to_xducer solver caches prog new_type_tab p =
    let reg_tbl = (caches#find_struc prog)#get_regions p#get_name in
    let loop_prefix = reg_tbl#get "loop_prefix" p#get_stmts in
    let loop_body = reg_tbl#get "loop_body" p#get_stmts in
    let lirs = mir_to_lir (loop_body @ loop_prefix) in
    let globals =
        (Program.get_shared prog) @ (Program.get_instrumental prog) in
    let locals = (Program.get_all_locals prog) in
    let new_sym_tab = new symb_tab "tmp" in
    let cfg = Cfg.remove_ineffective_blocks (mk_cfg lirs) in
    let ssa = mk_ssa solver true globals locals new_sym_tab new_type_tab cfg in
    if may_log DEBUG
    then print_detailed_cfg ("Loop of " ^ p#get_name ^ " in SSA: " ) ssa;
    Cfg.write_dot (sprintf "ssa_%s.dot" p#get_name) ssa;
    let transd =
        cfg_to_constraints p#get_name new_sym_tab new_type_tab ssa in
    write_exprs p#get_name transd;
    let new_proc = proc_replace_body p transd in
    new_proc#add_all_symb new_sym_tab#get_symbs;
    new_proc


let do_xducers solver caches prog =
    let new_type_tab = (Program.get_type_tab prog)#copy in
    let new_procs = List.map
        (to_xducer solver caches prog new_type_tab) (Program.get_procs prog) in
    let new_prog =
        (Program.set_type_tab new_type_tab
            (Program.set_procs new_procs prog)) in
    (* uncomment to deep debug:
    let p s =
        if s#get_sym_type = SymVar
        then printf "%s:%d\n" s#as_var#qual_name s#as_var#id
        else () in
    List.iter p (Program.get_sym_tab new_prog)#get_symbs_rec;
    new_type_tab#print;
    *)

    new_prog


let to_xducer_interleave solver caches prog =
    let new_type_tab = (Program.get_type_tab prog)#copy in
    let each_proc (ol, pl) p =
        let reg_tbl = (caches#find_struc prog)#get_regions p#get_name in
        let loop_prefix = reg_tbl#get "loop_prefix" p#get_stmts in
        let loop_body = reg_tbl#get "loop_body" p#get_stmts in
        ((MOptGuarded loop_body) :: ol, loop_prefix @ pl)
    in
    let procs = Program.get_procs prog in
    let opts, suffix = List.fold_left each_proc ([], []) procs in
    let lirs = mir_to_lir ((MIf (fresh_id (), opts)) :: suffix) in
    let globals = (Program.get_shared prog) @ (Program.get_instrumental prog) in
    let locals = Program.get_all_locals prog in
    let new_name = "P" in
    let new_sym_tab = new symb_tab new_name in
    let cfg = Cfg.remove_ineffective_blocks (mk_cfg lirs) in
    let ssa = mk_ssa solver true globals locals new_sym_tab new_type_tab cfg in
    if may_log DEBUG
    then print_detailed_cfg ("Loop of P in SSA: " ) ssa;
    Cfg.write_dot "ssa_P.dot" ssa;
    let transd = cfg_to_constraints new_name new_sym_tab new_type_tab ssa in
    write_exprs new_name transd;
    let new_proc = new proc new_name (IntConst 1) in
    new_proc#add_all_symb new_sym_tab#get_symbs;
    new_proc#set_stmts transd;
    let new_prog =
        Program.set_procs [new_proc] prog
        |> Program.set_type_tab new_type_tab 
        |> Program.set_params (Program.get_params prog)
    in
    new_prog

