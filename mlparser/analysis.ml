(* Analysis based on abstract interpretation *)

open Printf;;

open Cfg;;
open Spin;;
open Spin_ir;;
open Spin_ir_imp;;
open Debug;;

(* general analysis *)
let mk_bottom_val () = Hashtbl.create 10 ;;

let visit_basic_block transfer_fun bb in_vals =
    List.fold_left (fun res stmt -> transfer_fun stmt res) in_vals bb#get_seq
;;

let visit_cfg visit_bb_fun join_fun cfg entry_vals =
    (* imperative because of Hahstbl :-( *)
    let bb_vals = Hashtbl.create 10 in
    let visit_once (basic_blk, in_vals) = 
        let id = basic_blk#get_lead_lab in
        let old_vals =
            try Hashtbl.find bb_vals id with Not_found -> mk_bottom_val ()
        in
        let new_vals = join_fun old_vals
            (visit_bb_fun basic_blk (join_fun old_vals in_vals))
        in
        if not (Accums.hashtbl_eq old_vals new_vals)
        then begin
            Hashtbl.replace bb_vals id new_vals;
            List.map (fun s -> (s, new_vals)) basic_blk#get_succ
        end
        else []
    in
    let rec visit = function
        | [] -> ()
        | hd :: tl ->
            let next_open = visit_once hd in
            visit tl; visit next_open
    in
    let entry = Hashtbl.find cfg 0 in
    Hashtbl.add bb_vals entry#get_lead_lab entry_vals;
    visit (Hashtbl.fold (fun _ bb lst -> (bb, mk_bottom_val ()) :: lst) cfg []);
    bb_vals
;;

let join_all_blocks join_fun init_vals bb_vals =
    Hashtbl.fold (fun _ vals sum -> join_fun sum vals) bb_vals init_vals 
;;

(* special kind of analysis *)

(* int or bounded int *)
type int_role = IntervalInt of int * int | UnboundedInt | Undefined;;

let int_role_s = function
    | IntervalInt (a, b) -> sprintf "[%d, %d]" a b
    | UnboundedInt -> "unbounded"
    | Undefined -> "undefined"
;;

let lub_int_role x y =
    match x, y with
    | Undefined, d -> d
    | d, Undefined -> d
    | UnboundedInt, _ -> UnboundedInt
    | _, UnboundedInt -> UnboundedInt
    | (IntervalInt (a, b)), (IntervalInt (c, d)) ->
        IntervalInt ((min a c), (max b  d))
;;

let print_int_roles head vals =
    if may_log DEBUG
    then begin
        printf " %s { " head;
        Hashtbl.iter
            (fun var aval -> printf "%s: %s; "
                var#get_name (int_role_s aval))
            vals;
        printf "}\n";
    end
;;

let join_int_roles lhs rhs =
    let res = Hashtbl.create (Hashtbl.length lhs) in
    Hashtbl.iter
        (fun var value ->
            if Hashtbl.mem rhs var
            then Hashtbl.replace res var (lub_int_role value (Hashtbl.find rhs var))
            else Hashtbl.add res var value)
        lhs;
    Hashtbl.iter
        (fun var value ->
            if not (Hashtbl.mem res var) then Hashtbl.add res var value)
        rhs;
    print_int_roles " join = " res;
    res
;;

let transfer_roles stmt input =
    log DEBUG (sprintf "  %%%s;" (stmt_s stmt));
    let output = Hashtbl.copy input
    in
    let rec eval = function
        | Const v -> IntervalInt (v, v)
        | Var var ->
            if Hashtbl.mem input var then Hashtbl.find input var else Undefined
        | UnEx (_, _) -> Undefined
        | BinEx (ASGN, Var var, rhs) ->
            let rhs_val = eval rhs in
            Hashtbl.replace output var rhs_val;
            rhs_val
        | BinEx (PLUS, lhs, rhs) -> UnboundedInt (* we are interested in == and != *)
        | BinEx (MINUS, lhs, rhs) -> UnboundedInt
        | BinEx (_, _, _) -> Undefined
        | _ -> Undefined       
    in
    begin
        match stmt with
        | Decl (var, init_expr) -> Hashtbl.replace output var (eval init_expr)
        | Expr expr -> let _ = eval expr in ()
        | _ -> ()
    end;
    print_int_roles "input = " input;
    print_int_roles "output = " output;
    output
;;

