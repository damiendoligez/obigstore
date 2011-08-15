open Lwt
open Printf

module D = Protocol_client.Make(Protocol_payload.Version_0_0_0)

let keyspace = ref ""
let server = ref "127.0.0.1"
let port = ref 12050

let usage_message = "Usage: ob_load -keyspace NAME [options]"

let params =
  Arg.align
    [
      "-keyspace", Arg.Set_string keyspace, "NAME Dump tables in keyspace NAME.";
      "-server", Arg.Set_string server, "ADDR Connect to server at ADDR.";
      "-port", Arg.Set_int port, "N Connect to server port N (default: 12050)";
    ]

let load db ~keyspace ich =
  lwt ks = D.register_keyspace db keyspace in
    D.repeatable_read_transaction ks
      (fun tx ->
         let rec loop_load () =
           eprintf "%Ld\r%!" (Lwt_io.position ich);
           lwt len = Lwt_io.read_int ich in
           let buf = String.create len in
             Lwt_io.read_into_exactly ich buf 0 len >>
             D.load tx buf >>
             loop_load ()
         in try_lwt
              loop_load ()
            with End_of_file ->
              eprintf "%Ld%!" (Lwt_io.position ich);
              return ())

let () =
  Printexc.record_backtrace true;
  Arg.parse params ignore usage_message;
  if !keyspace = "" then begin
    Arg.usage params usage_message;
    exit 1
  end;
  in Lwt_unix.run begin
    let input = Lwt_io.stdin in
    let addr = Unix.ADDR_INET (Unix.inet_addr_of_string !server, !port) in
    lwt ich, och = Lwt_io.open_connection addr in
    let db = D.make ich och in
      load db ~keyspace:!keyspace input
  end
