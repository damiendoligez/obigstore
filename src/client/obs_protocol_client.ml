(*
 * Copyright (C) 2011-2012 Mauricio Fernandez <mfp@acm.org>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version,
 * with the special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *)

open Printf
open Lwt
open Obs_data_model
open Obs_request
open Obs_protocol
open Request

module Option = BatOption

module Make(P : Obs_protocol_bin.S) =
struct
  module H =
    Hashtbl.Make(struct
                   type t = int
                   let equal s1 s2 = s1 == s2

                   let hash x =
                     (* id += 2 on each req, so divide by 2 to cover all buckets *)
                     (x lsr 1)
                 end)

  type payload_size = int
  type crc = string

  module type PENDING_RESPONSE =
  sig
    type result
    val read_result : Lwt_io.input_channel -> result Lwt.t
    val wakeup : result Lwt.u
  end

  type ret = [`OK | `EXN of exn]

  type db = {
    mutable closed : bool;
    (* exception raised when we try to perform further requests against a
     * closed db *)
    mutable closed_exn : exn;
    ich : Lwt_io.input_channel;
    och : Lwt_io.output_channel;
    buf : Obs_bytea.t;
    mutex : Lwt_mutex.t;
    pending_reqs : (module PENDING_RESPONSE) H.t;
    async_req_id : string;
    data_address : Unix.sockaddr;
  }

  type keyspace = { ks_name : string; ks_id : int; ks_db : db; }

  type transaction = keyspace

  type backup_cursor = string

  let try_find h k =
    try Some (H.find h k) with Not_found -> None

  let wakeup_safe u x = try Lwt.wakeup u x with _ -> ()
  let wakeup_exn_safe u exn = try Lwt.wakeup_exn u exn with _ -> ()

  let send_exn_to_waiters t exn =
    H.iter
      (fun _ req ->
         let module M = (val req : PENDING_RESPONSE) in
           wakeup_exn_safe M.wakeup exn)
      t.pending_reqs

  let close t =
    if not t.closed then begin
      t.closed <- true;
      ignore (try_lwt Lwt_io.abort t.ich >> Lwt_io.abort t.och with _ -> return ());
      send_exn_to_waiters t (Obs_protocol.Error Obs_protocol.Closed);
      H.clear t.pending_reqs;
    end

  let read_exactly ich n =
    let s = String.create n in
      Lwt_io.read_into_exactly ich s 0 n >>
      return s

  let numeric_id_of_string_request_id s =
    let byte s n = Char.code (String.unsafe_get s n) in
      byte s 0 lor (byte s 1 lsl 8) lor
      (byte s 2 lsl 16) lor (byte s 3 lsl 24) lor
      (byte s 4 lsl 32) lor (byte s 5 lsl 40) lor
      (byte s 6 lsl 48) lor (byte s 7 lsl 56)

  type 'a result = OK of 'a | EXN of exn

  let rec get_response_loop t =
    lwt request_id, len, crc =
      match_lwt P.read_header t.ich with
          Obs_protocol.Header x -> return x
        | Obs_protocol.Corrupted_header ->
            raise_lwt (Obs_protocol.Error Obs_protocol.Corrupted_frame) in
    let pos = Lwt_io.position t.ich in
    let request_id = numeric_id_of_string_request_id request_id in
    let receiver = try_find t.pending_reqs request_id in
      match receiver with
          None ->
            (* skip response *)
            Obs_protocol.skip t.ich (len + 4)
        | Some r ->
            let module R = (val r : PENDING_RESPONSE) in
            (* must read the trailing CRC even if there's an exn in f, lest we
             * lose synchronism *)
            lwt result =
              try_lwt
                lwt x = R.read_result t.ich in
                  return (OK x)
              with e -> return (EXN e) in
            let pos2 = Lwt_io.position t.ich in
            lwt crc2 = read_exactly t.ich 4 in
            let len' = Int64.(to_int (sub pos2 pos)) in
              if len' = len then begin
                begin match result with
                    OK x ->
                      (* FIXME: should check CRC2 = CRC(payload) XOR CRC1 *)
                      H.remove t.pending_reqs request_id;
                      wakeup_safe R.wakeup x
                  | EXN e ->
                      H.remove t.pending_reqs request_id;
                      wakeup_exn_safe R.wakeup e
                end;

              end else begin
                (* wrong length *)
                wakeup_exn_safe R.wakeup
                  (Obs_protocol.Error
                     (Obs_protocol.Inconsistent_length (len, len')));
                (* and we close the conn *)
                close t
              end;
              get_response_loop t

  let make ~data_address ich och =
    let t =
      { ich; och; buf = Obs_bytea.create 64;
        closed = false; closed_exn = Obs_protocol.Error Obs_protocol.Closed;
        mutex = Lwt_mutex.create (); pending_reqs = H.create 61;
        async_req_id = "\001\000\000\000\000\000\000\000";
        data_address;
      }
    in
      ignore begin try_lwt
        get_response_loop t
      with e ->
        let exn = Obs_protocol.Error (Obs_protocol.Exception e) in
          send_exn_to_waiters t exn;
          t.closed_exn <- exn;
          close t;
          return ()
      end;
      t

  let check_closed t =
    if t.closed then raise_lwt t.closed_exn
    else return ()

  let req_id_buf = String.make 8 '\x00'

  let send_request t ~request_id req =
    Obs_bytea.clear t.buf;
    Obs_bytea.add_int32_le t.buf
      (Obs_protocol_bin.Obs_request_serialization.format_id `Extprot);
    Request.write (t.buf :> Extprot.Msg_buffer.t) req;
    for i = 0 to 7 do
      String.unsafe_set req_id_buf i
        (Char.unsafe_chr ((request_id lsr (8 * i) land 0xFF)))
    done;
    P.write_msg t.och req_id_buf t.buf

  let await_req_id_cnt = ref 1
  let req_id_cnt = ref 2

  (* Await requests can block indefinitely, i.e. potentially long enough for
   * more than 2**31 requests to be generated, which would lead to a req id
   * collision on 32-bit platforms (same with 2**63 on 64-bit). So we use two
   * different id spaces: await requests always get odd ids, and the remaining
   * ones are even.
   * *)
  let new_async_req_id = function
      Await _ -> await_req_id_cnt := !await_req_id_cnt + 2; !await_req_id_cnt
    | _ -> req_id_cnt := !req_id_cnt + 2; !req_id_cnt

  let async_request (type a) t req f =
    check_closed t >>
    let wait, wakeup = Lwt.wait () in
    let module R =
      struct
        type result = a
        let read_result = f
        let wakeup = wakeup
      end in
    let request_id = new_async_req_id req in
      H.add t.pending_reqs request_id (module R : PENDING_RESPONSE);
      Lwt_mutex.with_lock t.mutex (fun () -> send_request t ~request_id req) >>
      wait

  let list_keyspaces t =
    async_request t
      (List_keyspaces { List_keyspaces.prefix = "" })
      P.read_keyspace_list

  let register_keyspace t name =
    lwt ks_id =
      async_request t
        (Register_keyspace { Register_keyspace.name; })
        P.read_keyspace in
    let ks = { ks_id; ks_name = name; ks_db = t; } in
      Lwt_gc.finalise
        (fun _ ->
           try_lwt
             async_request t
             (Release_keyspace { Release_keyspace.keyspace = ks_id })
             P.read_ok
           with _ -> return ())
        ks;
      return ks

  let get_keyspace t name =
    match_lwt
      async_request t (Get_keyspace { Get_keyspace.name; }) P.read_keyspace_maybe
    with
        None -> return None
      | Some ks_id -> return (Some { ks_id; ks_name = name; ks_db = t; })

  let keyspace_name ks = ks.ks_name
  let keyspace_id ks = ks.ks_id

  let sync_request_ks ks req f = async_request ks.ks_db req f
  let async_request_ks ks req f = async_request ks.ks_db req f

  let list_tables ks =
    async_request_ks ks (List_tables { List_tables.keyspace = ks.ks_id; })
    P.read_table_list >|= List.map table_of_string

  let table_size_on_disk ks table =
    async_request_ks ks
      (Table_size_on_disk { Table_size_on_disk.keyspace = ks.ks_id; table; })
      P.read_table_size_on_disk

  let key_range_size_on_disk ks ?first ?up_to table =
    async_request_ks ks
      (Key_range_size_on_disk
         { Key_range_size_on_disk.keyspace = ks.ks_id; table;
           range = { first; up_to; reverse = false; } }; )
      P.read_key_range_size_on_disk

  let transaction_aux tx_type ks f =
    async_request_ks ks (Begin { Begin.keyspace = ks.ks_id; tx_type }) P.read_ok >>
    try_lwt
      lwt y = f ks in
        async_request_ks ks (Commit { Commit.keyspace = ks.ks_id }) P.read_ok >>
        return y
    with e ->
      async_request_ks ks (Abort { Abort.keyspace = ks.ks_id }) P.read_ok >>
      raise_lwt e

  let read_committed_transaction ks f =
    transaction_aux Tx_type.Read_committed ks f

  let repeatable_read_transaction ks f =
    transaction_aux Tx_type.Repeatable_read ks f

  let lock ks ~shared names =
    async_request_ks ks
      (Lock { Lock.keyspace = ks.ks_id; names; shared; })
      P.read_ok

  let watch_keys ks table keys =
    async_request_ks ks
      (Watch_keys { Watch_keys.keyspace = ks.ks_id; table; keys; })
      P.read_ok

  let watch_columns ks table columns =
    async_request_ks ks
      (Watch_columns { Watch_columns.keyspace = ks.ks_id; table; columns; })
      P.read_ok

  let get_keys ks table ?max_keys key_range =
    async_request_ks ks
      (Get_keys { Get_keys.keyspace = ks.ks_id; table; max_keys;
                  key_range = krange key_range; })
      P.read_keys

  let count_keys ks table key_range =
    async_request_ks ks
      (Count_keys { Count_keys.keyspace = ks.ks_id; table;
                    key_range = krange key_range; })
      P.read_key_count

  let get_slice ks table ?max_keys ?max_columns ?(decode_timestamps=false)
    key_range ?predicate column_range =
    async_request_ks ks
      (Get_slice { Get_slice.keyspace = ks.ks_id; table;
                   max_keys; max_columns; decode_timestamps;
                   key_range = krange key_range; predicate;
                   column_range = crange column_range; })
      P.read_slice

  let exists_key ks table key =
    match_lwt
      async_request_ks ks
        (Exist_keys { Exist_keys.keyspace = ks.ks_id; table; keys = [ key ] })
        P.read_exist_result
    with
        true :: _ -> return true
      | _ -> return false

  let exist_keys ks table keys =
    async_request_ks ks
      (Exist_keys { Exist_keys.keyspace = ks.ks_id; table; keys; })
      P.read_exist_result

  let get_slice_values ks table ?max_keys key_range columns =
    async_request_ks ks
      (Get_slice_values { Get_slice_values.keyspace = ks.ks_id; table;
                          max_keys; key_range = krange key_range; columns; })
      P.read_slice_values

  let get_slice_values_with_timestamps ks table ?max_keys key_range columns =
    async_request_ks ks
      (Get_slice_values_timestamps
         { Get_slice_values_timestamps.keyspace = ks.ks_id; table;
           max_keys; key_range = krange key_range; columns; })
      P.read_slice_values_timestamps

  let get_columns ks table ?max_columns ?(decode_timestamps=false)
        key column_range =
    async_request_ks ks
      (Get_columns { Get_columns.keyspace = ks.ks_id; table;
                     max_columns; decode_timestamps; key;
                     column_range = crange column_range; })
      P.read_columns

  let get_column_values ks table key columns =
    async_request_ks ks
      (Get_column_values { Get_column_values.keyspace = ks.ks_id; table;
                           key; columns; })
      P.read_column_values

  let get_column ks table key column =
    async_request_ks ks
      (Get_column { Get_column.keyspace = ks.ks_id; table; key; column; })
      P.read_column

  let put_columns ks table key columns =
    async_request_ks ks
      (Put_columns { Put_columns.keyspace = ks.ks_id; table;
                     data = [ (key, columns) ] })
      P.read_ok

  let put_multi_columns ks table data =
    async_request_ks ks
      (Put_columns { Put_columns.keyspace = ks.ks_id; table; data; })
      P.read_ok

  let delete_columns ks table key columns =
    async_request_ks ks
      (Delete_columns { Delete_columns.keyspace = ks.ks_id; table; key; columns; })
      P.read_ok

  let delete_key ks table key =
    async_request_ks ks
      (Delete_key { Delete_key.keyspace = ks.ks_id; table; key; })
      P.read_ok

  let delete_keys ks table key_range =
    async_request_ks ks
      (Delete_keys { Delete_keys.keyspace = ks.ks_id; table;
                     key_range = krange key_range; })
      P.read_ok

  let dump ks ?format ?only_tables ?offset () =
    async_request_ks ks
      (Dump { Dump.keyspace = ks.ks_id; only_tables; cursor = offset;
              format; })
      P.read_backup_dump

  let load ks data =
    async_request_ks ks (Load { Load.keyspace = ks.ks_id; data; })
      P.read_backup_load_result

  let load_stats ks =
    async_request_ks ks (Stats { Stats.keyspace = ks.ks_id })
      P.read_load_stats

  let string_of_cursor x = x
  let cursor_of_string x = Some x

  let listen ks topic =
    async_request_ks ks (Listen { Listen.keyspace = ks.ks_id; topic; })
      P.read_ok

  let unlisten ks topic =
    async_request_ks ks (Unlisten { Unlisten.keyspace = ks.ks_id; topic; })
      P.read_ok

  let notify ks topic =
    async_request_ks ks (Notify { Notify.keyspace = ks.ks_id; topic; })
      P.read_ok

  let await_notifications ks =
    async_request_ks ks (Await { Await.keyspace = ks.ks_id; })
      P.read_notifications

  let get_property t property =
    async_request t (Get_property { Get_property.property })
      P.read_property

  let data_protocol_version = (0, 0, 0)

  let write_data_req och req =
    let len = Obs_bytea.length req in
    let buf = Obs_bytea.unsafe_string req in
      write_checksummed_int32_le och len >>
      Lwt_io.write_from_exactly och buf 0 len >>
      Lwt_io.write och (Obs_crc32c.substring_masked buf 0 len)

  module Raw_dump =
  struct
    type raw_dump = { db : db; id : Int64.t; timestamp : Int64.t; }

    let dump t =
      lwt id, timestamp =
        async_request t (Trigger_raw_dump { Trigger_raw_dump.record = false })
          P.read_raw_dump_id_and_timestamp
      in return { db = t; id; timestamp; }

    let release d =
      async_request d.db
        (Raw_dump_release { Raw_dump_release.id = d.id; })
        P.read_ok

    let open_file d ?(offset=0L) fname =
      lwt ich, och = Lwt_io.open_connection d.db.data_address in
      lwt (major, minor, bugfix) = data_conn_handshake ich och in
      let req = Obs_bytea.create 32 in
        Obs_bytea.add_int32_le req (data_request_code `Get_file);
        Obs_bytea.add_int64_le req d.id;
        Obs_bytea.add_int64_le req offset;
        Obs_bytea.add_int32_le req (String.length fname);
        Obs_bytea.add_string req fname;
        write_data_req och req >>
        Lwt_io.flush och >>
        match_lwt read_checksummed_int ich >|= Option.map data_response_of_code with
            None -> raise_lwt Corrupted_data_header
          | Some (`Other | `Unknown_dump | `Unknown_file) -> return None
          | Some `OK -> return (Some ich)

    let timestamp d = return d.timestamp

    let list_files d =
      async_request d.db
        (Raw_dump_list_files { Raw_dump_list_files.id = d.id; })
        P.read_raw_dump_files

    let file_digest d file =
      async_request d.db
        (Raw_dump_file_digest { Raw_dump_file_digest.id = d.id; file; })
        P.read_raw_dump_file_digest
  end

  module Replication =
  struct
    type ack = [ `ACK | `NACK ]
    type update =
        { slave_id : Int64.t; buf : string; off : int; len : int;
          await_ack : (ack Lwt.t * ack Lwt.u);
        }

    type update_stream =
        { stream_id : Int64.t; stream : update Lwt_stream.t }

    let get_update_stream d =
      lwt fd, ich, och = Obs_conn.open_connection d.Raw_dump.db.data_address in
      let () =
        Lwt_unix.setsockopt fd Unix.TCP_NODELAY true;
        Lwt_unix.setsockopt fd Unix.SO_KEEPALIVE true;
      in
      (* [push] only holds a weak reference to the stream; if we have what
       * amounts to
       * [ignore (let rec get () = Lwt_stream.get stream >>= ... >> get ())]
       * the whole thread and the stream itself might be collected(!) because
       * there's no external "strong" reference to the latter.
       * *)
      let stream, push = Lwt_stream.create () in
      lwt (major, minor, bugfix) = data_conn_handshake ich och in
      let get_buf =
        let b = ref "" in
          (fun n ->
             if n > String.length !b then b := String.create n;
             !b) in
      let req = Obs_bytea.create 12 in
        Obs_bytea.add_int32_le req (data_request_code `Get_updates);
        Obs_bytea.add_int64_le req d.Raw_dump.id;
        write_data_req och req >>
        let ret = { stream_id = d.Raw_dump.id; stream } in
        let () =
          ignore begin
            try_lwt
              let rec read_update ret =
                match_lwt read_checksummed_int64_le ich with
                    None -> raise_lwt Corrupted_data_header
                  | Some -1L -> return ()
                  | Some len ->
                      (* we need to keep a reference to the stream ([push] alone
                       * doesn't suffice, as it only holds a weak ref) *)
                      (* the following is just to make sure the reference is
                       * not optiomized away *)
                      ignore ret.stream;

                      let len = Int64.to_int len in
                      let buf = get_buf len in
                      let wait, wakeup = Lwt.task () in
                        Lwt_io.read_into_exactly ich buf 0 len >>
                        lwt rem_crc = read_exactly ich 4 in
                        let update = { slave_id = d.Raw_dump.id; buf; off = 0;
                                       len; await_ack = (wait, wakeup); } in
                        (* TODO: compute CRC32C, check that it matches
                         * rem_crc, send 1 and read again if mismatch *)
                        lwt () =
                          write_checksummed_int32_le och 0 >> Lwt_io.flush och
                        in
                          push (Some update);
                          begin match_lwt wait with
                              `ACK -> write_checksummed_int32_le och 0
                            | `NACK -> write_checksummed_int32_le och 2
                          end >>
                          Lwt_io.flush och >>
                          read_update ret
              in
                match_lwt read_checksummed_int ich >|=
                          Option.map data_response_of_code
                with
                    Some `OK -> read_update ret
                  | None -> raise_lwt Corrupted_data_header
                  | _ -> push None;
                         return ()
            with exn ->
              (* FIXME: better logging *)
              let bt = Printexc.get_backtrace () in
                eprintf
                  "Exception in protocol client get_update_stream:\n%s\n%s%!"
                  (Printexc.to_string exn) bt;
                Lwt_io.abort och
          end
        in return ret

    let get_update s =
      lwt x = Lwt_stream.get s.stream in
        return x

    let ack_update u =
      (try Lwt.wakeup (snd u.await_ack) `ACK with _ -> ());
      return ()

    let nack_update u =
      (try Lwt.wakeup (snd u.await_ack) `NACK with _ -> ());
      return ()

    let is_sync_update update = return false (* FIXME *)

    let get_update_data u = return (u.buf, u.off, u.len)
  end

  module RAW =
  struct
    type keyspace_ = keyspace
    type keyspace = keyspace_
    let get_slice = get_slice
    let get_slice_values = get_slice_values
    let get_slice_values_with_timestamps = get_slice_values_with_timestamps
    let get_columns = get_columns
    let get_column_values = get_column_values
    let get_column = get_column
    let put_columns = put_columns
    let put_multi_columns = put_multi_columns
  end

  include (Obs_structured.Make(RAW) :
             Obs_structured.STRUCTURED with type keyspace := keyspace)
end
