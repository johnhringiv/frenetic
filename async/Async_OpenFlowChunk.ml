open Core.Std

module Platform = Async_OpenFlow_Platform
module Header = OpenFlow_Header

module Message : Platform.Message 
  with type t = (Header.t * Cstruct.t) = struct

  type t = (Header.t * Cstruct.t) sexp_opaque with sexp

  let header_of (hdr, _) = hdr

  let parse hdr buf = (hdr, Cstruct.set_len buf (hdr.Header.length - Header.size))

  let marshal (hdr, body) buf =
    Cstruct.blit body 0 buf 0 (hdr.Header.length - Header.size)

  let marshal' x = x

  let to_string x = Sexp.to_string_hum (sexp_of_t x)

end

module Controller = struct
  open Async.Std

  module Platform = Platform.Make(Message)
  module Client_id = Platform.Client_id

  module ClientTbl = Hashtbl.Make(Client_id)

  exception Handshake of Client_id.t * string

  module Conn = struct
    type t = {
      state : [ `Handshake | `Active | `Idle ];
      version : int option;
      state_entered : Time.t;
      last_activity : Time.t
    }

    let create () : t =
      let now = Time.now () in
      { state = `Handshake
      ; version = None
      ; state_entered = now
      ; last_activity = now
      }

    let activity (t:t) : t =
      let t = { t with last_activity = Time.now () } in
      if t.state = `Active then
        t
      else
        { t with state = `Active; state_entered = t.last_activity }

    let complete_handshake (t:t) (version:int) : t =
      activity { t with version = Some(version) }

    let idle (t:t) (expires : Time.Span.t) : t =
      let right_now = Time.now () in
      if t.state = `Idle || Time.(add t.last_activity expires > right_now) then
        t
      else
        { t with state = `Idle; state_entered = right_now }
  end

  type t = {
    platform : Platform.t;
    clients  : Conn.t ClientTbl.t
  }

  type m = Platform.m
  type e = Platform.e
  type h = [
      | `Connect of Client_id.t * int
      | `Disconnect of Client_id.t * Sexp.t
      | `Message of Client_id.t * m
    ]

  module Handler = struct
    let connect (t:t) (c_id:Client_id.t) =
      ClientTbl.add_exn t.clients c_id (Conn.create ())

    let handshake (t:t) (c_id:Client_id.t) (version:int) =
      ClientTbl.change t.clients c_id (function
        | None       -> assert false
        | Some(conn) -> Some(Conn.complete_handshake conn version))

    let activity (t:t) ?ver (c_id:Client_id.t) =
      ClientTbl.change t.clients c_id (function
        | None       -> assert false
        | Some(conn) -> Some(Conn.activity conn))

    let idle (t:t) (c_id:Client_id.t) (expires : Time.Span.t) =
      ClientTbl.change t.clients c_id (function
        | None       -> assert false
        | Some(conn) ->
          let conn' = Conn.idle conn expires in
          begin if not (conn = conn') then
            printf "client %s marked as idle" (Client_id.to_string c_id)
          end;
          Some(conn'))

    let disconnect (t:t) (c_id:Client_id.t) =
      ClientTbl.remove t.clients c_id
  end

  module Mon = struct
    let rec mark_idle t wait expires =
      after wait >>> fun () ->
      ClientTbl.iter t.clients (fun ~key:c_id ~data:_ ->
        Handler.idle t c_id expires);
      mark_idle t wait expires
  end

  let create ?max_pending_connections
      ?verbose
      ?log_disconnects
      ?buffer_age_limit ~port () =
    Platform.create ?max_pending_connections ?verbose ?log_disconnects
      ?buffer_age_limit ~port ()
    >>| function t ->
      let ctl = {
        platform = t;
        clients = ClientTbl.create ();
      } in
      Mon.mark_idle ctl (Time.Span.of_sec 1.0) (Time.Span.of_sec 3.0);
      ctl

  let listen t = Platform.listen t.platform

  let close t c_id =
    Handler.disconnect t c_id;
    Platform.close t.platform c_id

  let has_client_id t c_id =
    match ClientTbl.find t.clients c_id with
      | None
      | Some({ Conn.state = `Handshake }) -> false
      | _ -> true

  let send t c_id m =
    Platform.send t.platform c_id m
    >>| function
      | `Sent x -> Handler.activity t c_id; `Sent x
      | `Drop x -> `Drop x

  let send_ignore_errors t = Platform.send_ignore_errors t.platform

  let send_to_all t = Platform.send_to_all t.platform
  let client_addr_port t = Platform.client_addr_port t.platform
  let listening_port t = Platform.listening_port t.platform

  let ensure response =
    match response with
      | `Sent _ -> []
      | `Drop exn -> raise exn

  let handshake v t evt =
    let open Header in
    match evt with
      | `Connect c_id ->
        Handler.connect t c_id;
        let header = { version = v; type_code = type_code_hello;
                       length = size; xid = 0l; } in
        Platform.send t.platform c_id (header, Cstruct.of_string "")
        >>| (function
          | `Sent _   -> []
          | `Drop exn -> raise exn)
      | `Message (c_id, msg) ->
        begin match ClientTbl.find t.clients c_id with
          | None -> assert false
          | Some({ Conn.state = `Handshake }) ->
            let hdr, bits = msg in
            begin
              if not (hdr.type_code = type_code_hello) then begin
                close t c_id;
                raise (Handshake (c_id, Printf.sprintf
                          "Expected 0 code in header: %s%!"
                          (Header.to_string hdr)))
              end
            end;
            Handler.handshake t c_id (min hdr.version v);
            return [`Connect (c_id, min hdr.version v)]
          | Some(_) ->
            Handler.activity t c_id;
            return [`Message (c_id, msg)]
        end
      | `Disconnect (c_id, exn) ->
        begin match ClientTbl.find t.clients c_id with
          | None -> assert false
          | Some({ Conn.state = `Handshake }) ->
            Handler.disconnect t c_id;
            return []
          | Some(_) ->
            Handler.disconnect t c_id;
            return [`Disconnect (c_id, exn)]
        end

  let echo t evt =
    let open Header in
    match evt with
      | `Message (c_id, (hdr, bytes)) ->
        begin if hdr.Header.type_code = type_code_echo_request then
          (* Echo requests get a reply *)
          let hdr = { hdr with type_code = type_code_echo_reply } in
          send t c_id (hdr , bytes)
          >>| function
            | `Sent _   -> []
            | `Drop exn -> raise exn
        else if hdr.Header.type_code = type_code_echo_reply then
          (* Echo replies get eaten *)
          return []
        else
          (* All other messages get forwarded *)
          return [evt]
        end
      | _ -> return [evt]
end
