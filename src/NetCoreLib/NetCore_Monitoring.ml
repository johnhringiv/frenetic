open NetCore_Types

(* Yes! This is user-requesting monitoring, so just print to stdout!!! *)
let printf = Printf.printf

let monitor_pol pol = 
  printf "policy is:\n%s\n%!" (NetCore_Pretty.pol_to_string pol);
  pol

let monitor_tbl sw pol = 
  let tbl = NetCore_Compiler.flow_table_of_policy sw pol in
  printf "Flow table at switch %Ld is:\n%!" sw;
  List.iter
    (fun (m,a) -> printf " %s => %s\n%!"
      (OpenFlow0x01.Match.to_string m)
      (OpenFlow0x01.Action.sequence_to_string a))
    tbl;
  pol

let monitor_switch_events = function
  | SwitchUp (sw, _) -> printf "switch %Ld connected.\n%!" sw
  | SwitchDown sw -> printf "switch %Ld disconnected.\n%!" sw

let monitor_load (window : float) filter =
  let monitor_load_handler packets bytes =
    printf "%Ld packets and %Ld bytes matched %s in the last %f seconds.\n%!"
      packets bytes (NetCore_Pretty.pol_to_string filter) window in
  PoSeq (filter, PoAction (NetCore_Action.Output.query window monitor_load_handler))
  
