(* Extract a symbolic skeleton from a process description, i.e.,
  the transition relation between local states with the edges labeled
  by conditions and actions

  Igor Konnov, 2014
 *)

open Printf
open Unix

open Accums
open Debug
open Plugin
open SpinIr
open SpinIrImp
open VarRole

open SymbSkel

class symb_skel_plugin_t (plugin_name: string)
        (ctr_plugin: PiaCounterPlugin.pia_counter_plugin_t) =
    object(self)
        inherit analysis_plugin_t plugin_name

        method transform rt prog =
            List.iter (self#extract_proc rt prog) (Program.get_procs prog);
            prog

        method test_input filename =
            try access filename [F_OK]
            with Unix_error _ ->
                raise (InputRequired ("local transitions in " ^ filename))

        method read_transitions prev_next filename =
            let each_line a l =
                let segs = Str.split (Str.regexp_string ",") l in
                let vals = List.map str_i segs in
                let h = Hashtbl.create (List.length prev_next) in
                List.iter2 (Hashtbl.add h) prev_next vals;
                printf "%s\n" l
            in
            ignore (fold_file each_line () filename)

        method write_vars tt prev_next filename =
            let fout = open_out filename in
            let write v =
                let t = tt#get_type v in
                fprintf fout "%s:%d\n" v#get_name t#range_len
            in
            List.iter write prev_next;
            close_out fout

        method extract_proc rt prog proc =
            (* TODO: we need only next_vars, no actual counter info *)
            let tbl = rt#caches#analysis#get_pia_ctr_ctx_tbl in
            let ctx = tbl#get_ctx proc#get_name in
            let tt = Program.get_type_tab prog in
            let unpair l (p, n) = n :: p :: l in
            let prev_next =
                List.rev (List.fold_left unpair [] ctx#prev_next_pairs)
            in 
            self#write_vars tt prev_next
                (sprintf "vis-%s.txt" proc#get_name);
            let filename = sprintf "local-tr-%s.txt" proc#get_name in
            self#test_input filename;
            self#read_transitions prev_next filename;
            collect_constraints rt prog proc

        method update_runtime rt =
            ()
    end

