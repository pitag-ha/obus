(*
 * oBus_connection.ml
 * ------------------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implemtation of dbus.
 *)

open Printf
open OBus_message
open OBus_private
open OBus_value
open OBus_type.Perv
open Lwt

exception Connection_closed
exception Connection_lost
exception Transport_error of exn

type t = OBus_private.packed_connection

type filter = OBus_private.filter

exception Context of t * OBus_message.t

let obus_t = OBus_type.map_with_context obus_unit
  (fun context () -> match context with
     | Context(connection, message) -> connection
     | _ -> raise OBus_type.Cast_failure)
  (fun _ -> ())

let obus_context = OBus_type.map_with_context obus_unit
  (fun context () -> match context with
     | Context(connection, message) -> (connection, message)
     | _ -> raise OBus_type.Cast_failure)
  (fun _ -> ())

(* Mapping from server guid to connection. *)
module Guid_map = OBus_util.Make_map(struct type t = OBus_address.guid end)
let guid_connection_map = ref Guid_map.empty

(* Apply a list of filter on a message, logging failure *)
let apply_filters typ message filters =
  try
    Lwt_sequence.fold_l
      (fun filter message -> match message with
         | Some message -> filter message
         | None -> None)
      filters (Some message)
  with exn ->
    FAILURE(exn, "an %s filter failed with" typ);
    None

(* Get the error message of an error *)
let get_error msg = match msg.body with
  | Basic String x :: _ -> x
  | _ -> ""

(* Run [code] if [connection] contains a running connection, otherwise
   raise the exception to which [packed_connection] is set. *)
DEFINE EXEC(code) = (match connection#get with
                       | Crashed exn ->
                           raise exn
                       | Running connection ->
                           code)

(* Same as [EXEC] but use with [Lwt.fail] instead of [raise] *)
DEFINE LEXEC(code) = (match connection#get with
                        | Crashed exn ->
                            Lwt.fail exn
                        | Running connection ->
                            code)

(* +-----------------------------------------------------------------+
   | Sending messages                                                |
   +-----------------------------------------------------------------+ *)

(* Send a message, maybe adding a reply waiter and return
   [return_thread] *)
let send_message_backend connection reply_waiter_opt return_thread message =
  LEXEC(Lwt_mutex.with_lock connection.outgoing_m begin fun () ->
          match apply_filters "outgoing" { message with serial = connection.next_serial } connection.outgoing_filters with
            | None ->
                DEBUG("outgoing message dropped by filters");
                fail (Failure "message dropped by filters")

            | Some message ->
                begin
                  match reply_waiter_opt with
                    | Some wakener ->
                        connection.reply_waiters <- Serial_map.add message.serial wakener connection.reply_waiters
                    | None ->
                        ()
                end;

                try_lwt
                  lwt () = OBus_transport.send connection.transport message in
                  (* Everything went OK, continue with a new serial *)
                  connection.next_serial <- Int32.succ connection.next_serial;
                  return_thread
                with
                  | OBus_wire.Data_error _ as exn ->
                      (* The message can not be marshaled for some
                         reason. This is not a fatal error. *)
                      fail exn

                  | exn ->
                      (* All other errors are considered as
                         fatal. They are fatal because it is possible
                         that a message has been partially sent on the
                         connection, so the message stream is
                         broken *)
                      lwt exn = connection.packed#set_crash (Transport_error exn) in
                      fail exn
        end)

let send_message connection message =
  send_message_backend connection None (return ()) message

let send_message_with_reply connection message =
  let waiter, wakener = wait () in
  send_message_backend connection (Some wakener) waiter message

let method_call' connection ?flags ?sender ?destination ~path ?interface ~member body ty_reply =
  lwt msg = send_message_with_reply connection
    (OBus_message.method_call ?flags ?sender ?destination ~path ?interface ~member body) in
  match msg with
    | { typ = Method_return _ } ->
        begin
          try
            return (OBus_type.cast_sequence ty_reply ~context:(Context(connection, msg)) msg.body)
          with OBus_type.Cast_failure ->
            (* If not, check why the cast fail *)
            let expected_sig = OBus_type.type_sequence ty_reply
            and got_sig = type_of_sequence msg.body in
            if expected_sig = got_sig then
              (* If the signature match, this means that the user
                 defined a combinator raising a Cast_failure *)
              fail OBus_type.Cast_failure
            else
              (* In other case this means that the expected
                 signature is wrong *)
              fail
                (Failure (sprintf "unexpected signature for reply of method %S on interface %S, expected: %S, got: %S"
                            member (match interface with Some i -> i | None -> "")
                            (string_of_signature expected_sig)
                            (string_of_signature got_sig)))
        end

    | { typ = Error(_, error_name) } ->
        fail (OBus_error.make error_name (get_error msg))

    | _ ->
        assert false

let method_call_no_reply connection ?(flags=default_flags) ?sender ?destination ~path ?interface ~member ty =
  OBus_type.make_func ty begin fun body ->
    send_message connection (OBus_message.method_call ~flags:{ flags with no_reply_expected = true }
                               ?sender ?destination ~path ?interface ~member body)
  end

let dyn_method_call connection ?flags ?sender ?destination ~path ?interface ~member body =
  lwt { body = x } = send_message_with_reply connection
    (OBus_message.method_call ?flags ?sender ?destination ~path ?interface ~member body) in
  return x

let dyn_method_call_no_reply connection ?(flags=default_flags) ?sender ?destination ~path ?interface ~member body =
  send_message connection
    (OBus_message.method_call ~flags:{ flags with no_reply_expected = true }
       ?sender ?destination ~path ?interface ~member body)

let method_call connection ?flags ?sender ?destination ~path ?interface ~member ty =
  OBus_type.make_func ty begin fun body ->
    method_call' connection ?flags ?sender ?destination ~path ?interface ~member body (OBus_type.func_reply ty)
  end

let emit_signal connection ?flags ?sender ?destination ~path ~interface ~member ty x =
  send_message connection (OBus_message.signal ?flags ?sender ?destination ~path ~interface ~member (OBus_type.make_sequence ty x))

let dyn_emit_signal connection ?flags ?sender ?destination ~path ~interface ~member body =
  send_message connection (OBus_message.signal ?flags ?sender ?destination ~path ~interface ~member body)

let dyn_send_reply connection { sender = sender; serial = serial } body =
  send_message connection { destination = sender;
                            sender = None;
                            flags = { no_reply_expected = true; no_auto_start = true };
                            serial = 0l;
                            typ = Method_return(serial);
                            body = body }

let send_reply connection mc typ v =
  dyn_send_reply connection mc (OBus_type.make_sequence typ v)

let send_error connection { sender = sender; serial = serial } name msg =
  send_message connection { destination = sender;
                            sender = None;
                            flags = { no_reply_expected = true; no_auto_start = true };
                            serial = 0l;
                            typ = Error(serial, name);
                            body = [basic(String msg)] }

let send_exn connection method_call exn =
  match OBus_error.unmake exn with
    | Some(name, msg) ->
        send_error connection method_call name msg
    | None ->
        FAILURE(exn, "sending an unregistred ocaml exception as a DBus error");
        send_error connection method_call "ocaml.Exception" (Printexc.to_string exn)

let ignore_send_exn connection method_call exn = ignore(send_exn connection method_call exn)

let unknown_method connection message =
  ignore_send_exn connection message (unknown_method_exn message)

(* +-----------------------------------------------------------------+
   | Signal matching                                                 |
   +-----------------------------------------------------------------+ *)

let signal_match r = function
  | { sender = sender; typ = Signal(path, interface, member); body = body } ->
      (match r.sr_sender, sender with
         | None, _ -> true

         (* this normally never happen because with a message bus, all
            messages have a sender field *)
         | _, None -> false

         | Some name, Some sender -> match React.S.value name with
             | None ->
                 (* This case is when the name the rule filter on do
                    not currently have an owner *)
                 false

             | Some owner -> owner = sender) &&
        (r.sr_path = path) &&
        (r.sr_interface = interface) &&
        (r.sr_member = member)

  | _ ->
      false

let signal_match_ignore_sender r = function
  | { typ = Signal(path, interface, member); body = body } ->
      (r.sr_path = path) &&
        (r.sr_interface = interface) &&
        (r.sr_member = member)

  | _ ->
      false

(* +-----------------------------------------------------------------+
   | Reading/dispatching                                             |
   +-----------------------------------------------------------------+ *)

let dispatch_message connection message = match message with

  (* For method return and errors, we lookup at the reply waiters. If
     one is find then it get the reply, if none, then the reply is
     dropped. *)
  | { typ = Method_return(reply_serial) }
  | { typ = Error(reply_serial, _) } ->
      begin match Serial_map.lookup reply_serial connection.reply_waiters with
        | Some w ->
            connection.reply_waiters <- Serial_map.remove reply_serial connection.reply_waiters;
            wakeup w message

        | None ->
            DEBUG("reply to message with serial %ld dropped%s"
                    reply_serial (match message with
                                    | { typ = Error(_, error_name) } ->
                                        sprintf ", the reply is the error: %S: %S"
                                          error_name (get_error message)
                                    | _ ->
                                        ""))
      end

  | { typ = Signal _ } ->
      begin match connection.name, message.sender with
        | None, _
        | _, None ->
            (* If this is a peer-to-peer connection, we do match on
               the sender *)
            Lwt_sequence.iter_l
              (fun receiver ->
                 if signal_match_ignore_sender receiver message then
                   try
                     receiver.sr_push message
                   with exn ->
                     FAILURE(exn, "signal event failed with"))
              connection.signal_receivers

        | Some _, Some sender ->
            begin match sender, message with

              (* Internal handling of "NameOwnerChange" messages for
                 name resolving. *)
              | "org.freedesktop.DBus",
                { typ = Signal(["org"; "freedesktop"; "DBus"], "org.freedesktop.DBus", "NameOwnerChanged");
                  body = [Basic(String name); Basic(String old_owner); Basic(String new_owner)] } ->

                  let owner = if new_owner = "" then None else Some new_owner in

                  if OBus_name.is_unique name && owner = None then
                    (* If the resovler was monitoring a unique name
                       and it is not owned anymore, this means that
                       the peer with this name has exited. We remember
                       this information here. *)
                    OBus_cache.add connection.exited_peers name;

                  begin match Name_map.lookup name connection.name_resolvers with
                    | Some nr ->
                        DEBUG("updating internal name resolver: %S -> %S" name (match owner with
                                                                                  | Some n -> n
                                                                                  | None -> ""));
                        nr.nr_set owner;

                        if not nr.nr_init_done then begin
                          (* The resolver has not yet been
                             initialized; this means that the reply to
                             GetNameOwner (done by
                             [OBus_resolver.make]) has not yet been
                             received. We consider that this first
                             signal has precedence and terminate
                             initialization. *)
                          nr.nr_init_done <- true;
                          Lwt.wakeup nr.nr_init_wakener ()
                        end

                    | None ->
                        ()
                  end

              (* Internal handling of "NameAcquired" signals *)
              | ("org.freedesktop.DBus",
                 { typ = Signal(["org"; "freedesktop"; "DBus"], "org.freedesktop.DBus", "NameAcquired");
                   body = [Basic(String name)] })

                  (* Only handle signals destined to us *)
                  when message.destination = connection.name ->

                  connection.acquired_names <- name :: connection.acquired_names

              (* Internal handling of "NameLost" signals *)
              | ("org.freedesktop.DBus",
                 { typ = Signal(["org"; "freedesktop"; "DBus"], "org.freedesktop.DBus", "NameLost");
                   body = [Basic(String name)] })

                  (* Only handle signals destined to us *)
                  when message.destination = connection.name ->

                  connection.acquired_names <- List.filter ((<>) name) connection.acquired_names

              | _ ->
                  ()
            end;

            (* Only handle signals broadcasted or destined to us *)
            if message.destination = None || message.destination = connection.name then
              Lwt_sequence.iter_l
                (fun receiver ->
                   if signal_match receiver message then
                     try
                       receiver.sr_push message
                     with exn ->
                       FAILURE(exn, "signal event failed with"))
                connection.signal_receivers
      end

  (* Handling of the special "org.freedesktop.DBus.Peer" interface *)
  | { typ = Method_call(_, Some "org.freedesktop.DBus.Peer", member); body = body } -> begin
      match member, body with
        | "Ping", [] ->
            (* Just pong *)
            ignore (dyn_send_reply connection.packed message [])
        | "GetMachineId", [] ->
            ignore
              (try_bind (fun _ -> Lazy.force OBus_info.machine_uuid)
                 (fun machine_uuid -> send_reply connection.packed message <:obus_type< string >> (OBus_uuid.to_string machine_uuid))
                 (fun exn ->
                    lwt () = send_exn connection.packed message (Failure "cannot get machine uuuid") in
                    fail exn))
        | _ ->
            unknown_method connection.packed message
    end

  | { typ = Method_call(path, interface_opt, member) } ->
      match Object_map.lookup path connection.exported_objects with
        | Some obj ->
            begin try
              obj#obus_handle_call connection.packed message
            with
                exn ->
                  FAILURE(exn, "method call handler failed with")
            end
        | None ->
            (* Handle introspection for missing intermediate object:

               for example if we have only one exported object with
               path "/a/b/c", we need to add introspection support for
               virtual objects with path "/", "/a", "/a/b",
               "/a/b/c". *)
            match
              match interface_opt, member with
                | None, "Introspect"
                | Some "org.freedesktop.DBus.Introspectable", "Introspect" ->
                    begin match children connection path with
                      | [] -> false
                      | l ->
                          ignore
                            (send_reply connection.packed message <:obus_type< OBus_introspect.document >>
                               ([("org.freedesktop.DBus.Introspectable",
                                  [OBus_introspect.Method("Introspect", [],
                                                          [(None, Tbasic Tstring)], [])],
                                  [])], l));
                          true
                    end
                | _ -> false
            with
              | true -> ()
              | false ->
                  ignore_send_exn connection.packed message
                    (Failure (sprintf "No such object: %S" (OBus_path.to_string path)))

let read_dispatch connection =
  lwt message =
    try_lwt
      choose [OBus_transport.recv connection.transport;
              connection.abort_waiter]
    with exn ->
      connection.packed#set_crash
        (match exn with
           | End_of_file -> Connection_lost
           | OBus_wire.Protocol_error _ as exn -> exn
           | exn -> Transport_error exn) >>= fail
  in
  match apply_filters "incoming" message connection.incoming_filters with
    | None ->
        DEBUG("incoming message dropped by filters");
        return ()
    | Some message ->
        dispatch_message connection message;
        return ()

let rec dispatch_forever connection =
  try_bind
    (fun _ -> match connection.down with
       | Some(waiter, wakener) ->
           lwt () = waiter in
           read_dispatch connection
       | None ->
           read_dispatch connection)
    (fun _ -> dispatch_forever connection)
    (function
       | Connection_closed ->
           return ()
       | exn ->
           try
             !(connection.on_disconnect) exn;
             return ()
           with exn ->
             FAILURE(exn, "the error handler (OBus_connection.on_disconnect) failed with");
             return ())

(* +-----------------------------------------------------------------+
   | ``Packed'' connection                                           |
   +-----------------------------------------------------------------+ *)

class packed_connection = object(self)

  val mutable state = Crashed Exit (* Fake initial state *)

  (* Set the initial running state *)
  method set_connection connection =
    state <- Running connection

  method get = state

  val mutable exit_hook = None

  (* Put the connection in a "crashed" state. This means that all
     subsequent call using the connection will fail. *)
  method set_crash exn = match state with
    | Crashed exn ->
        return exn
    | Running connection ->
        state <- Crashed exn;
        begin match exit_hook with
          | Some n ->
              Lwt_sequence.remove n
          | None ->
              ()
        end;

        begin match connection.guid with
          | Some guid -> guid_connection_map := Guid_map.remove guid !guid_connection_map
          | None -> ()
        end;

        (* This make the dispatcher to exit if it is waiting on
           [get_message] *)
        wakeup_exn connection.abort_wakener exn;
        begin match connection.down with
          | Some(waiter, wakener) -> wakeup_exn wakener exn
          | None -> ()
        end;

        (* Wakeup all reply handlers so they will not wait forever *)
        Serial_map.iter (fun _ w -> wakeup_exn w exn) connection.reply_waiters;

        (* Remove all objects *)
        Object_map.iter begin fun p obj ->
          try
            obj#obus_connection_closed connection.packed
          with
              exn ->
                (* This may happen if the programmer has overridden the
                   method *)
                FAILURE(exn, "obus_connection_closed on object with path %S failed with"
                          (OBus_path.to_string p))
        end connection.exported_objects;

        (* If the connection is closed normally, flush it *)
        lwt () =
          if exn = Connection_closed then
            Lwt_mutex.with_lock connection.outgoing_m return
          else
            return ()
        in

        (* Shutdown the transport *)
        lwt () =
            try_lwt
              OBus_transport.shutdown connection.transport
            with exn ->
              FAILURE(exn, "failed to abort/shutdown the transport");
              return ()
        in
        return exn

  initializer
    exit_hook <- Some(Lwt_sequence.add_l
                        (fun _ ->
                           lwt _ = self#set_crash Connection_closed in
                           return ())
                        Lwt_main.exit_hooks)
end

(* +-----------------------------------------------------------------+
   | Connection creation                                             |
   +-----------------------------------------------------------------+ *)

let of_transport ?guid ?(up=true) transport =
  let make _ =
    let abort_waiter, abort_wakener = Lwt.wait () and packed_connection = new packed_connection in
    let connection = {
      name = None;
      acquired_names = [];
      transport = transport;
      on_disconnect = ref (fun _ -> ());
      guid = guid;
      down = (if up then None else Some(Lwt.wait ()));
      abort_waiter = abort_waiter;
      abort_wakener = abort_wakener;
      watch = (try_lwt
                 lwt _ = abort_waiter in
                 return ()
               with
                 | Connection_closed -> return ()
                 | exn -> fail exn);
      name_resolvers = Name_map.empty;
      exited_peers = OBus_cache.create 100;
      outgoing_m = Lwt_mutex.create ();
      next_serial = 1l;
      exported_objects = Object_map.empty;
      incoming_filters = Lwt_sequence.create ();
      outgoing_filters = Lwt_sequence.create ();
      reply_waiters = Serial_map.empty;
      signal_receivers = Lwt_sequence.create ();
      packed = (packed_connection :> t);
    } in
    packed_connection#set_connection connection;
    (* Start the dispatcher *)
    ignore (dispatch_forever connection);
    connection.packed
  in
  match guid with
    | None -> make ()
    | Some guid ->
        match Guid_map.lookup guid !guid_connection_map with
          | Some connection -> connection
          | None ->
              let connection = make () in
              guid_connection_map := Guid_map.add guid connection !guid_connection_map;
              connection

let of_addresses ?(shared=true) addresses = match shared with
  | false ->
      lwt guid, transport = OBus_transport.of_addresses addresses in
      return (of_transport transport)
  | true ->
      (* Try to find a guid that we already have *)
      let guids = OBus_util.filter_map OBus_address.guid addresses in
      match OBus_util.find_map (fun guid -> Guid_map.lookup guid !guid_connection_map) guids with
        | Some connection -> return connection
        | None ->
            (* We ask again a shared connection even if we know that
               there is no other connection to a server with the same
               guid, because during the authentification another
               thread can add a new connection. *)
            lwt guid, transport = OBus_transport.of_addresses addresses in
            return (of_transport ~guid transport)

let loopback = of_transport (OBus_transport.loopback ())

(* +-----------------------------------------------------------------+
   | Other                                                           |
   +-----------------------------------------------------------------+ *)

let running connection = match connection#get with
  | Running _ -> true
  | Crashed _ -> false

let watch connection = LEXEC(connection.watch)

DEFINE GET(param) = (fun connection -> EXEC(connection.param))

let guid = GET(guid)
let transport = GET(transport)
let name = GET(name)
let on_disconnect = GET(on_disconnect)
let close connection = match connection#get with
  | Crashed _ ->
      return ()
  | Running _ ->
      connection#set_crash Connection_closed >>= fun _ -> return ()

let is_up connection =
  EXEC(connection.down = None)

let set_up connection =
  EXEC(match connection.down with
         | None -> ()
         | Some(waiter, wakener) ->
             connection.down <- None;
             wakeup wakener ())

let set_down connection =
  EXEC(match connection.down with
         | Some _ -> ()
         | None -> connection.down <- Some(wait ()))

let incoming_filters = GET(incoming_filters)
let outgoing_filters = GET(outgoing_filters)