open Lwt
open Printf
open Unix
open NetCore

module Controller = NetCore.Make(OpenFlow0x01.Platform)

(* configuration state *)
let controller = ref "learn"

(* command-line arguments *)
let arg_specs = 
  [ ("-c", 
     Arg.Set_string controller, 
     "<controller> run a specific controller")
  ]
 
let arg_rest rest = ()

let usage = "desmoines [options]"

let () = Arg.parse arg_specs arg_rest usage

let main () = 
  Sys.catch_break true;
  try 
    let stream,_ = Lwt_stream.create() in  
    Misc.Log.printf "--- Welcome to NetCore ---\n%!";
    OpenFlow0x01.Platform.init_with_port 6633;
    lwt () = Controller.start_controller stream in 
    return (Misc.Log.printf "--- Done ---\n%!")
  with exn -> 
    Misc.Log.printf "[main] exception: %s\n%s\n%!" 
      (Printexc.to_string exn) 
      (Printexc.get_backtrace ());
    exit 1
      
let _ = main ()
