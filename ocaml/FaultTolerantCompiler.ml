open MessagesDef
open OpenFlow0x04Parser
open OpenFlow0x04Types
open PatternImplDef
open NetCoreEval13
open NetCoreCompiler13
open Classifier
open List

module W = Wildcard

let rec mapi' idx f lst = match lst with
  | elm :: lst -> f idx elm :: mapi' (idx+1) f lst
  | [] -> []

let mapi f lst = mapi' 0 f lst

let compile_nc = compile_opt

module Gensym =
struct
  let count = ref (Int32.of_int 0)
  let next () = count := Int32.succ !count; !count
end

let add_group groups gid a b =
  groups := (gid, [a;b]) :: !groups

let rec compile_pb pri crsovr bak sw =
  let pri_tbl = compile_nc pri sw in
  let bak_tbl = compile_nc bak sw in
  let crsovr_tbl = compile_nc crsovr sw in
  let groups = ref [] in
  let merge pri_acts bak_acts = 
    (let gid = Gensym.next () in
     add_group groups gid pri_acts bak_acts;
     [Group gid ]) in
  let ft_tbl = inter merge pri_tbl crsovr_tbl in
  (ft_tbl @ pri_tbl @ bak_tbl, !groups)
