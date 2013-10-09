open Printf

open Accums
open Debug
open Options
open Plugin
open Program
open Runtime
open Serialize
open SpinIr
open SpinIrImp
open Writer

class spin_plugin_t (plugin_name: string) (out_name: string) =
    object(self)
        inherit transform_plugin_t plugin_name

        method is_disabled (rt: runtime_t) =
            rt#caches#options.Options.mc_tool <> Options.ToolSpin

        method transform rtm prog =
            let filename = out_name ^ ".prm" in
            log INFO (sprintf "> Writing Promela model %s..." out_name);
            let f_prog = Ltl.embed_fairness prog in
            (* TODO: give it a better name like target-spin? *)
            write_to_file true filename
                (units_of_program f_prog) (get_type_tab f_prog);
            f_prog

        method update_runtime _ =
            ()

        method decode_trail rt _ =
            let loop_re = Str.regexp ".*<<<<<START OF CYCLE>>>>>.*" in
            let fin = open_in rt#caches#options.trail_name in
            (* parse strings like this: P:GS{0->1:{1,1,0,1,0,0,0,0,0,0,0},0,0} *)
            let loop_pos = ref 0 in
            let trail = ref [] in
            begin try
                while true do
                    let line = input_line fin in
                    let state_exprs = parse_global_state self#get_input line in
                    let intrinsic = parse_intrinsic line in
                    if state_exprs <> []
                    then trail := (State state_exprs) :: !trail
                    else if intrinsic <> StringMap.empty
                    then trail := (Intrinsic intrinsic) :: !trail
                    else if Str.string_match loop_re line 0
                        then loop_pos := (List.length !trail)
                        else (printf "WARNING: no match for %s\n" line)
                done
            with End_of_file ->
                close_in fin;
            end;

            let path = List.rev !trail in
            let prefix = list_sub path 0 !loop_pos in
            let lasso = list_sub path !loop_pos ((List.length path) - !loop_pos)
            in
            if may_log DEBUG
            then begin
                let ps = function
                    | State es ->
                        List.iter (fun e -> printf "%s; " (expr_s e)) es;
                        printf "\n"
                    | Intrinsic map ->
                        printf "Intrinsic: %s\n" (str_map_s (fun s -> s) map)
                in
                printf "SpinPlugin: PREFIX:\n";
                List.iter ps prefix;
                printf "SpinPlugin: LASSO:\n";
                List.iter ps lasso
            end;
            (prefix, lasso)


        method refine _ path = (false, path)
    end

