
open Lwt
open Data_model

module List = struct include BatList include List end
module Option = BatOption
module L = LevelDB
module RA = L.Read_access
module IT = L.Iterator

module String =
struct
  include String
  include BatString

  let compare x y =
    String_util.cmp_substrings x 0 (String.length x) y 0 (String.length y)
end

type db =
    {
      basedir : string;
      db : L.db;
      keyspaces : (string, int) Hashtbl.t;
    }

type keyspace = { ks_db : db; ks_name : string; ks_id : int }

type backup_cursor = Backup.cursor

let (|>) x f = f x

let read_keyspaces db =
  let h = Hashtbl.create 13 in
    L.iter_from
      (fun k v ->
         match Datum_key.decode_keyspace_table_name k with
             None -> false
           | Some keyspace_name ->
               Hashtbl.add h keyspace_name (int_of_string v);
               true)
      db
      Datum_key.keyspace_table_prefix;
    h

let open_db basedir =
  let db = L.open_db ~comparator:Datum_key.custom_comparator basedir in
    (* ensure we have a end_of_db record *)
    if not (L.mem db Datum_key.end_of_db_key) then
      L.put ~sync:true db Datum_key.end_of_db_key (String.make 8 '\000');
    { basedir; db; keyspaces = read_keyspaces db; }

let close_db t = L.close t.db

let list_keyspaces t =
  Hashtbl.fold (fun k v l -> k :: l) t.keyspaces [] |>
  List.sort String.compare |> return

let register_keyspace t ks_name =
  try
    return { ks_db = t; ks_name; ks_id = Hashtbl.find t.keyspaces ks_name }
  with Not_found ->
    let max_id = Hashtbl.fold (fun _ v id -> max v id) t.keyspaces 0 in
    let ks_id = max_id + 1 in
      L.put ~sync:true t.db (Datum_key.keyspace_table_key ks_name) (string_of_int ks_id);
      Hashtbl.add t.keyspaces ks_name ks_id;
      return { ks_db = t; ks_name; ks_id; }

let get_keyspace t ks_name =
  return begin try
    Some ({ ks_db = t; ks_name; ks_id = Hashtbl.find t.keyspaces ks_name })
  with Not_found -> None end

let keyspace_name ks = ks.ks_name

let keyspace_id ks = ks.ks_id

let list_tables ks =
  let it = L.iterator ks.ks_db.db in
  let table_buf = ref "" in
  let table_len = ref 0 in
  let table_buf_r = Some table_buf in
  let table_len_r = Some table_len in

  let jump_to_next_table () =
    match String.sub !table_buf 0 !table_len with
        "" ->
          let datum_key =
            Datum_key.encode_datum_key_to_string ks.ks_id
              ~table:"" ~key:"" ~column:"" ~timestamp:Int64.min_int
          in IT.seek it datum_key 0 (String.length datum_key);
      | table ->
          let datum_key = Datum_key.encode_table_successor_to_string ks.ks_id table in
            IT.seek it datum_key 0 (String.length datum_key); in

  let rec collect_tables acc =
    jump_to_next_table ();
    if not (IT.valid it) then acc
    else begin
      let k = IT.get_key it in
        if not (Datum_key.decode_datum_key
                  ~table_buf_r ~table_len_r
                  ~key_buf_r:None ~key_len_r:None
                  ~column_buf_r:None ~column_len_r:None
                  ~timestamp_buf:None
                  k (String.length k))
        then
          acc
        else
          collect_tables ((String.sub !table_buf 0 !table_len) :: acc)
    end

  in return (List.rev (collect_tables []))

let table_size_on_disk ks table =
  L.get_approximate_size ks.ks_db.db
    (Datum_key.encode_datum_key_to_string ks.ks_id
       ~table ~key:"" ~column:"" ~timestamp:Int64.min_int)
    (Datum_key.encode_datum_key_to_string ks.ks_id
       ~table ~key:"\255\255\255\255\255\255" ~column:"\255\255\255\255\255\255"
       ~timestamp:Int64.zero) |>
  return

let key_range_size_on_disk ks ?first ?up_to table =
  L.get_approximate_size ks.ks_db.db
    (Datum_key.encode_datum_key_to_string ks.ks_id
       ~table ~key:(Option.default "" first) ~column:"" ~timestamp:Int64.min_int)
    (Datum_key.encode_datum_key_to_string ks.ks_id
       ~table
       ~key:(Option.default "\255\255\255\255\255\255" up_to)
       ~column:"\255\255\255\255\255\255"
       ~timestamp:Int64.zero) |>
  return

module S =
struct
  include Set.Make(String)

  let of_list l = List.fold_left (fun s x -> add x s) empty l
  let to_list s = List.rev (fold (fun x l -> x :: l) s [])

  let subset ?first ?up_to s =
    (* trim entries before the first, if proceeds *)
    let s = match first with
        None -> s
      | Some first ->
          let _, found, after = split first s in
            if found then add first after else after in
    (* trim entries starting from up_to if proceeds *)
    let s = match up_to with
        None -> s
      | Some last ->
          let before, _, _ = split last s in
            before
    in s
end

module M =
struct
  include Map.Make(String)

  let find_default x k m = try find k m with Not_found -> x

  let submap ?first ?up_to m =
    (* trim entries before the first, if proceeds *)
    let m = match first with
        None -> m
      | Some first ->
          let _, found, after = split first m in
            match found with
                Some v -> add first v after
              | None -> after in
    (* trim entries starting with up_to, if proceeds *)
    let m = match up_to with
        None -> m
      | Some last ->
          let before, _, _ = split last m in
            before
    in m

  let modify f default k m = add k (f (find_default default k m)) m

  let modify_if_found f k m = try add k (f (find k m)) m with Not_found -> m
end

type transaction =
    {
      mutable deleted_keys : S.t M.t; (* table -> key set *)
      mutable added_keys : S.t M.t; (* table -> key set *)
      mutable added : string M.t M.t M.t; (* table -> key -> column -> value *)
      mutable deleted : S.t M.t M.t; (* table -> key -> column set *)
      access : L.read_access;
      repeatable_read : bool;
      iter_pool : L.iterator Lwt_pool.t option;
      ks : keyspace;
      batch : L.writebatch Lazy.t;
    }

let tx_key = Lwt.new_key ()

let transaction_aux make_access_and_iters ks f =
  match Lwt.get tx_key with
    | None -> begin
        let access, iter_pool, repeatable_read =
          make_access_and_iters ks.ks_db None in
        let tx =
          { added_keys = M.empty; deleted_keys = M.empty;
            added = M.empty; deleted = M.empty;
            access; repeatable_read; iter_pool; ks;
            batch = lazy (L.Batch.make ());
          } in
        lwt y = Lwt.with_value tx_key (Some tx) (fun () -> f tx) in
        let b = Lazy.force tx.batch in
        let datum_key = Bytea.create 13 in
        let timestamp = Int64.of_float (Unix.gettimeofday () *. 1e6) in
          (* TODO: should iterate in Lwt monad so we can yield every once in a
           * while*)
          M.iter
            (fun table m ->
               M.iter
                 (fun key s ->
                    S.iter
                      (fun column ->
                         Datum_key.encode_datum_key datum_key ks.ks_id ~table ~key ~column
                           ~timestamp;
                         L.Batch.delete_substring b
                           (Bytea.unsafe_string datum_key) 0
                           (Bytea.length datum_key))
                      s)
                 m)
            tx.deleted;
          M.iter
            (fun table m ->
               M.iter
                 (fun key m ->
                    M.iter
                      (fun column v ->
                         (* FIXME: should save timestamp provided in
                          * put_columns and use it here if it wasn't
                          * Auto_timestamp *)
                         Datum_key.encode_datum_key datum_key ks.ks_id ~table ~key ~column
                           ~timestamp;
                         L.Batch.put_substring b
                           (Bytea.unsafe_string datum_key) 0 (Bytea.length datum_key)
                           v 0 (String.length v))
                      m)
                 m)
            tx.added;
          L.Batch.write ~sync:true ks.ks_db.db b; (* FIXME: should not block *)
          return y
      end
    | Some parent_tx ->
        let access, iter_pool, repeatable_read =
          make_access_and_iters ks.ks_db (Some parent_tx) in
        let tx = { parent_tx with access; iter_pool; repeatable_read; } in
        lwt y = Lwt.with_value tx_key (Some tx) (fun () -> f tx) in
          parent_tx.deleted_keys <- tx.deleted_keys;
          parent_tx.added <- tx.added;
          parent_tx.deleted <- tx.deleted;
          parent_tx.added_keys <- tx.added_keys;
          return y

let read_committed_transaction f =
  transaction_aux
    (fun db -> function
         None -> (L.read_access db.db, None, false)
       | Some tx -> (tx.access, tx.iter_pool, false))
    f

let repeatable_read_transaction f =
  transaction_aux
    (fun db -> function
         Some { access; repeatable_read = true; iter_pool = Some pool; _} ->
           (access, Some pool, true)
       | _ ->
           let access = L.Snapshot.read_access (L.Snapshot.make db.db) in
           let pool = Lwt_pool.create 1000 (* FIXME: which limit? *)
                        (fun () -> return (RA.iterator access))
           in (access, Some pool, true))
    f

(* string -> string ref -> int -> bool *)
let is_same_value v buf len =
  String.length v = !len && String_util.strneq v 0 !buf 0 !len

let is_column_deleted tx table =
  let deleted_col_table = tx.deleted |> M.find_default M.empty table in
    begin fun ~key_buf ~key_len ~column_buf ~column_len ->
      (* TODO: use substring sets to avoid allocation *)
      if M.is_empty deleted_col_table then
        false
      else begin
        let key =
          if key_len = String.length key_buf then key_buf
          else String.sub key_buf 0 key_len in
        let deleted_cols = M.find_default S.empty key deleted_col_table in
          if S.is_empty deleted_cols then
            false
          else
            let col =
              if column_len = String.length column_buf then column_buf
              else String.sub column_buf 0 column_len
            in S.mem col deleted_cols
      end
    end

(* In [let f = exists_key tx table in ... f key], [f key] returns true iff
 * there's some column with the given key in the given [table]. *)
let exists_key tx table =
  let datum_key = Bytea.create 13 in
  let it = RA.iterator tx.access in
  let buf = ref "" in
  let table_buf = ref "" and table_len = ref 0 in
  let key_buf = ref "" and key_len = ref 0 in
  let column_buf = ref "" and column_len = ref 0 in
  let table_buf_r = Some table_buf and table_len_r = Some table_len in
  let key_buf_r = Some key_buf and key_len_r = Some key_len in
  let column_buf_r = Some column_buf and column_len_r = Some column_len in
  let is_column_deleted = is_column_deleted tx table

  in begin fun key ->
    Datum_key.encode_datum_key datum_key tx.ks.ks_id ~table ~key ~column:""
      ~timestamp:Int64.min_int;
    IT.seek it (Bytea.unsafe_string datum_key) 0 (Bytea.length datum_key);
    if not (IT.valid it) then
      false
    else begin
      let len = IT.fill_key it buf in
      let ok =
        Datum_key.decode_datum_key
          ~table_buf_r ~table_len_r ~key_buf_r ~key_len_r
          ~column_buf_r ~column_len_r ~timestamp_buf:None
          !buf len
      in
        if not ok then false
        else
          (* verify that it's the same table and key, and the column is not
           * deleted *)
          is_same_value table table_buf table_len &&
          is_same_value key key_buf key_len &&
          not (is_column_deleted ~key_buf:key ~key_len:(String.length key)
                 ~column_buf:!column_buf ~column_len:!column_len)
    end
  end

type 'a fold_result =
    Continue
  | Skip_key
  | Continue_with of 'a
  | Skip_key_with of 'a
  | Finish_fold of 'a

let fold_over_data_aux it tx table f acc ?(first_column="") ~first_key ~up_to_key =
  let buf = ref "" in
  let table_buf = ref "" and table_len = ref 0 in
  let key_buf = ref "" and key_len = ref 0 in
  let column_buf = ref "" and column_len = ref 0 in
  let table_buf_r = Some table_buf and table_len_r = Some table_len in
  let key_buf_r = Some key_buf and key_len_r = Some key_len in
  let column_buf_r = Some column_buf and column_len_r = Some column_len in
  let timestamp_buf = Datum_key.make_timestamp_buf () in
  let some_timestamp_buf = Some timestamp_buf in

  let at_or_past_upto_key = match up_to_key with
      None -> (fun () -> false)
    | Some k ->
        (fun () ->
           String_util.cmp_substrings
             !key_buf 0 !key_len
             k 0 (String.length k) >= 0) in

  let next_key () =
    let s = String.create (!key_len + 1) in
      String.blit !key_buf 0 s 0 !key_len;
      s.[!key_len] <- '\000';
      s in

  let datum_key_buf = Bytea.create 13 in

  let rec do_fold_over_data acc =
    if not (IT.valid it) then
      return acc
    else begin
      let len = IT.fill_key it buf in
        if not (Datum_key.decode_datum_key
                  ~table_buf_r ~table_len_r
                  ~key_buf_r ~key_len_r
                  ~column_buf_r ~column_len_r
                  ~timestamp_buf:some_timestamp_buf
                  !buf len)
        then return acc (* if this happens, we must have hit the end of the data area *)
        else begin
          (* check that we're still in the table *)
          if not (is_same_value table table_buf table_len) then
            return acc
          (* check if we're at or past up_to *)
          else if at_or_past_upto_key () then
            return acc
          else begin
            let r = f acc it ~key_buf:!key_buf ~key_len:!key_len
                     ~column_buf:!column_buf ~column_len:!column_len
                     ~timestamp_buf
            in
              (* seeking to next datum/key/etc *)
              begin match r with
                  Continue | Continue_with _ -> IT.next it;
                | Skip_key | Skip_key_with _ ->
                    Datum_key.encode_datum_key datum_key_buf tx.ks.ks_id
                      ~table ~key:(next_key ()) ~column:"" ~timestamp:Int64.min_int;
                    IT.seek it
                      (Bytea.unsafe_string datum_key_buf) 0
                      (Bytea.length datum_key_buf)
                | Finish_fold _ -> ()
              end;
              match r with
                  Continue | Skip_key -> do_fold_over_data acc
                | Continue_with x | Skip_key_with x -> do_fold_over_data x
                | Finish_fold x -> return x
          end
      end
    end in

  (* jump to first entry *)
  let first_datum_key =
    Datum_key.encode_datum_key_to_string tx.ks.ks_id ~table
      ~key:(Option.default "" first_key) ~column:first_column
      ~timestamp:Int64.min_int
  in
    IT.seek it first_datum_key 0 (String.length first_datum_key);
    do_fold_over_data acc

let fold_over_data tx table f ?first_column acc ~first_key ~up_to_key =
  match tx.iter_pool with
      None ->
        let it = RA.iterator tx.access in
          try_lwt
            fold_over_data_aux it tx table f acc ?first_column ~first_key ~up_to_key
          finally
            IT.close it;
            return ()
    | Some pool ->
        Lwt_pool.use pool
          (fun it -> fold_over_data_aux it tx table f acc ?first_column
                       ~first_key ~up_to_key)

let get_keys_aux init_f map_f fold_f tx table ?(max_keys = max_int) = function
    Keys l ->
      let exists_key = exists_key tx table in
      let s = S.of_list l in
      let s = S.diff s (M.find_default S.empty table tx.deleted_keys) in
      let s =
        S.filter
          (fun k ->
             S.mem k (M.find_default S.empty table tx.added_keys) ||
             exists_key k)
          s
      in return (map_f s)

  | Key_range { first; up_to } ->
      (* we recover all the keys added in the transaction *)
      let s = M.find_default S.empty table tx.added_keys in
      let s = S.subset ?first ?up_to s in
      (* now s contains the added keys in the wanted range *)

      let is_key_deleted =
        let s = M.find_default S.empty table tx.deleted_keys in
          if S.is_empty s then
            (fun buf len -> false)
          else
            (fun buf len -> S.mem (String.sub buf 0 len) s) in

      let is_column_deleted = is_column_deleted tx table in
      let keys_on_disk_kept = ref 0 in

      let fold_datum acc it
            ~key_buf ~key_len
            ~column_buf ~column_len ~timestamp_buf =
        if !keys_on_disk_kept >= max_keys then
          Finish_fold acc
        else begin
          (* check if the key is deleted *)
          if is_key_deleted key_buf key_len then
            Continue
          (* check if the column has been deleted *)
          else if is_column_deleted ~key_buf ~key_len ~column_buf ~column_len then
            Continue
          (* if neither the key nor the column were deleted *)
          else begin
            incr keys_on_disk_kept;
            Skip_key_with (fold_f acc key_buf key_len);
          end
        end
      in
        fold_over_data tx table fold_datum (init_f s) ~first_key:first ~up_to_key:up_to

let get_keys tx table ?(max_keys = max_int) range =
  get_keys_aux
    (fun s -> s)
    (fun s -> s)
    (fun s key_buf key_len -> S.add (String.sub key_buf 0 key_len) s)
    tx table ~max_keys range >|= S.to_list >|= List.take max_keys

let count_keys tx table range =
  let s = ref S.empty in
  get_keys_aux
    (fun _s -> s := _s; S.cardinal _s)
    (fun s -> S.cardinal s)
    (fun n key_buf key_len ->
       if S.mem (String.sub key_buf 0 key_len) !s then n
       else (n + 1))
    tx table ~max_keys:max_int range >|= Int64.of_int

let merge_rev cmp l1 l2 =
  let rec loop_merge_rev cmp acc l1 l2 =
    match l1, l2 with
        [], [] -> acc
      | [], x :: tl | x :: tl, [] -> loop_merge_rev cmp (x :: acc) [] tl
      | x1 :: tl1, x2 :: tl2 ->
          match cmp x1 x2 with
              n when n > 0 -> loop_merge_rev cmp (x1 :: acc) tl1 l2
            | n when n < 0 -> loop_merge_rev cmp (x2 :: acc) l1 tl2
            | _ -> loop_merge_rev cmp (x2 :: acc) tl1 tl2
  in loop_merge_rev cmp [] l1 l2

let filter_map_merge cmp map merge ~limit l1 l2 =

  let rec loop_fmm cmp f g acc l1 l2 = function
      n when n > 0 -> begin
        match l1, l2 with
            [], [] -> acc
          | [], x :: tl | x :: tl, [] ->
              (match f x with None -> loop_fmm cmp f g acc [] tl n
                 | Some y -> loop_fmm cmp f g (y :: acc) [] tl (n-1))
          | x1 :: tl1, x2 :: tl2 -> match cmp x1 x2 with
                m when m < 0 ->
                  (match f x1 with None -> loop_fmm cmp f g acc tl1 l2 n
                     | Some y -> loop_fmm cmp f g (y :: acc) tl1 l2 (n-1))
              | m when m > 0 ->
                  (match f x2 with None -> loop_fmm cmp f g acc l1 tl2 n
                     | Some y -> loop_fmm cmp f g (y :: acc) l1 tl2 (n-1))
              | _ ->
                  (match f (g x1 x2) with None -> loop_fmm cmp f g acc tl1 tl2 n
                     | Some y -> loop_fmm cmp f g (y :: acc) tl1 tl2 (n-1))
      end
    | _ -> acc

  in loop_fmm cmp map merge [] l1 l2 limit


let get_slice_aux
      postproc_keydata get_keydata_key keep_columnless_keys
      tx table
      ~max_keys
      ~max_columns
      ~decode_timestamps
      key_range column_range =
  let column_selected = match column_range with
      All_columns -> (fun ~buf ~len -> true)
    | Columns l ->
        if List.length l < 5 then (* TODO: determine threshold *)
          (fun ~buf ~len ->
             List.exists
               (fun s ->
                  String_util.cmp_substrings s 0 (String.length s) buf 0 len = 0)
               l)
        else begin
          let s = S.of_list l in
            (fun ~buf ~len ->
               let c =
                 if len = String.length buf then buf
                 else String.sub buf 0 len
               in S.mem c s)
        end
    | Column_range r ->
        let cmp_first = match r.first with
            None -> (fun ~buf ~len -> true)
          | Some x ->
              (fun ~buf ~len ->
                 String_util.cmp_substrings buf 0 len x 0 (String.length x) >= 0) in
        let cmp_up_to = match r.up_to with
            None -> (fun ~buf ~len -> true)
          | Some x ->
              (fun ~buf ~len ->
                 String_util.cmp_substrings buf 0 len x 0 (String.length x) < 0)
        in (fun ~buf ~len -> cmp_first ~buf ~len && cmp_up_to ~buf ~len) in

  let is_column_deleted = is_column_deleted tx table

  in match key_range with
    Keys l ->
      let l =
        List.filter
          (fun k -> not (S.mem k (M.find_default S.empty table tx.deleted_keys)))
          (List.sort String.compare l) in
      lwt key_data_list, _ =
        Lwt_list.fold_left_s
          (fun (key_data_list, keys_so_far) key ->
             if keys_so_far >= max_keys then return (key_data_list, keys_so_far)
             else
               let columns_selected = ref 0 in

               let fold_datum rev_cols it
                     ~key_buf ~key_len ~column_buf ~column_len
                     ~timestamp_buf =
                 (* must skip deleted columns *)
                 if is_column_deleted
                      ~key_buf:key ~key_len:(String.length key)
                      ~column_buf ~column_len then
                   Continue
                 (* also skip non-selected columns *)
                 else if not (column_selected column_buf column_len) then
                   Continue
                 (* otherwise, if the column is not deleted and is selected *)
                 else begin
                   incr columns_selected;
                   let data = IT.get_value it in
                   let col = String.sub column_buf 0 column_len in
                   let timestamp = match decode_timestamps with
                       false -> No_timestamp
                     | true -> Timestamp (Datum_key.decode_timestamp timestamp_buf) in
                   let rev_cols = { name = col; data; timestamp; } :: rev_cols in
                     if !columns_selected >= max_columns then
                       Finish_fold rev_cols
                     else Continue_with rev_cols
                 end in

               lwt rev_cols1 =
                 fold_over_data tx table fold_datum []
                     ~first_key:(Some key) ~up_to_key:(Some (key ^ "\000")) in

               let rev_cols2 =
                 M.fold
                   (fun col data l ->
                      if column_selected col (String.length col) then
                        { name = col; data; timestamp = No_timestamp } :: l
                      else l)
                   (tx.added |>
                    M.find_default M.empty table |> M.find_default M.empty key)
                   [] in

               let cols =
                 merge_rev
                   (fun c1 c2 -> String.compare c1.name c2.name)
                   rev_cols1 rev_cols2

               in match postproc_keydata (key, List.rev cols) with
                   None -> return (key_data_list, keys_so_far)
                 | Some x -> return (x :: key_data_list, keys_so_far + 1))
          ([], 0) l in
      let last_key = match key_data_list with
          x :: _ -> Some (get_keydata_key x)
        | [] -> None
      in return (last_key, List.rev key_data_list)

    | Key_range { first; up_to } ->
        let first_pass = ref true in
        let keys_so_far = ref 0 in
        let prev_key = Bytea.create 13 in
        let cols_in_this_key = ref 0 in
        let cols_kept = ref 0 in

        let fold_datum ((key_data_list, key_data) as acc)
              it ~key_buf ~key_len ~column_buf ~column_len ~timestamp_buf =
          let ((key_data_list, key_data) as acc') =
            if String_util.cmp_substrings
                 (Bytea.unsafe_string prev_key) 0 (Bytea.length prev_key)
                 key_buf 0 key_len = 0
            then
              acc
            else begin
              (* new key, increment count and copy the key to prev_key *)
                cols_kept := 0;
                cols_in_this_key := 0;
                incr keys_so_far;
                let acc' =
                  match key_data with
                    _ :: _ ->
                      ((Bytea.contents prev_key, key_data) :: key_data_list, [])
                  | [] ->
                      if not !first_pass && keep_columnless_keys then
                        ((Bytea.contents prev_key, key_data) :: key_data_list, [])
                      else acc
                in
                  Bytea.clear prev_key;
                  Bytea.add_substring prev_key key_buf 0 key_len;
                  acc'
            end

          in
            first_pass := false;
            incr cols_in_this_key;
            (* see if we already have enough columns for this key*)
            if !cols_kept >= max_columns then begin
              (* seeking is very expensive, so we only do it when it looks
               * like the key has got a lot of columns *)
              if !cols_in_this_key - max_columns < 50 then (* FIXME: determine constant *)
                (if acc == acc' then Continue else Continue_with acc')
              else
                (if acc == acc' then Skip_key else Skip_key_with acc')
            end else if not (column_selected column_buf column_len) then begin
              (* skip column *)
              (if acc == acc' then Continue else Continue_with acc')
            end else if is_column_deleted ~key_buf ~key_len ~column_buf ~column_len then
              (if acc == acc' then Continue else Continue_with acc')
            else begin
              let () = incr cols_kept in
              let data = IT.get_value it in
              let col = String.sub column_buf 0 column_len in
              let timestamp = match decode_timestamps with
                  false -> No_timestamp
                | true -> Timestamp (Datum_key.decode_timestamp timestamp_buf) in
              let col_data = { name = col; data; timestamp; } in

              let key_data = col_data :: key_data in
              let acc = (key_data_list, key_data) in
                (* early termination w/o iterating over further keys if we
                 * already have enough  *)
                (* we cannot use >= because further columns for the same key
                 * could follow *)
                if !keys_so_far > max_keys then
                  Finish_fold acc
                (* alternatively, if we're in the last key, and have enough
                 * columns, finish *)
                else if !keys_so_far = max_keys && !cols_kept >= max_columns then
                  Finish_fold acc
                else
                  Continue_with acc
            end
        in

        lwt rev_key_data_list1 =
          lwt l1, d1 =
            fold_over_data tx table fold_datum ([], [])
              ~first_key:first ~up_to_key:up_to
          in match d1 with
              [] when not !first_pass && keep_columnless_keys ->
                return ((Bytea.contents prev_key, d1) :: l1)
            | [] -> return l1
            | cols -> return ((Bytea.contents prev_key, cols) :: l1) in

        (* rev_key_data_listN : (key * column list) list   cols also in rev order *)

        let rev_key_data_list2 =
          M.fold
            (fun key key_data_in_mem l ->
               let cols =
                 M.fold
                   (fun col data l ->
                      if column_selected col (String.length col) then
                        let col_data = { name = col; data; timestamp = No_timestamp} in
                          col_data :: l
                      else l)
                   key_data_in_mem
                   []
               in (key, cols) :: l)
            (M.submap ?first ?up_to (M.find_default M.empty table tx.added))
            [] in

        let key_data_list1 = List.rev rev_key_data_list1 in
        let key_data_list2 = List.rev rev_key_data_list2 in

        let rev_key_data_list =
          filter_map_merge
            (fun (k1, _) (k2, _) -> String.compare k1 k2)
            postproc_keydata
            (fun (k, rev_cols1) (_, rev_cols2) ->
               let cols =
                 merge_rev
                   (fun c1 c2 -> String.compare c1.name c2.name)
                   rev_cols1 rev_cols2
               in (k, List.rev cols))
            ~limit:max_keys key_data_list1 key_data_list2 in

        let last_key = match rev_key_data_list with
            x :: _ -> Some (get_keydata_key x)
          | [] -> None
        in return (last_key, List.rev rev_key_data_list)

let get_slice tx table
      ?(max_keys = max_int) ?(max_columns = max_int)
      ?(decode_timestamps = false) key_range column_range =
  let postproc_keydata (key, rev_cols) =
    match rev_cols with
      | _ :: _ as l when max_columns > 0 ->
          let columns = List.take max_columns (List.rev l) in
          let last_column = (List.last columns).name in
            Some ({ key; last_column; columns; })
      | _ -> None in

  let get_keydata_key { key; _ } = key

  in get_slice_aux postproc_keydata get_keydata_key false tx table
      ~max_keys ~max_columns ~decode_timestamps key_range column_range

let get_slice_values tx table
      ?(max_keys = max_int) key_range columns =
  let postproc_keydata (key, cols) =
    let l =
      List.map
        (fun column ->
           try Some (List.find (fun c -> c.name = column) cols).data
           with Not_found -> None)
        columns
    in Some (key, l) in

  let get_keydata_key (key, _) = key

  in get_slice_aux postproc_keydata get_keydata_key true tx table
       ~max_keys ~max_columns:(List.length columns)
       ~decode_timestamps:false key_range (Columns columns)

let get_columns tx table ?(max_columns = max_int) ?decode_timestamps
                key column_range =
  match_lwt
    get_slice tx table ~max_columns ?decode_timestamps
      (Keys [key]) column_range
  with
    | (_, { last_column = last_column;
            columns = ((_ :: _ as columns)) } :: _ ) ->
        return (Some (last_column, columns))
    | _ -> return None

let get_column_values tx table key columns =
  match_lwt get_slice_values tx table (Keys [key]) columns with
    | (_, (_, l):: _) -> return l
    | _ -> assert false

let get_column tx table key column_name =
  match_lwt
    get_columns tx table key ~decode_timestamps:true (Columns [column_name])
  with
      Some (_, c :: _) -> return (Some (c.data, c.timestamp))
    | _ -> return None

let put_columns tx table key columns =
  tx.added_keys <- M.modify (S.add key) S.empty table tx.added_keys;
  tx.deleted_keys <- M.modify_if_found (S.remove key) table tx.deleted_keys;
  tx.deleted <-
    M.modify_if_found
      (fun m ->
         if M.is_empty m then m
         else
           M.modify_if_found
             (fun s ->
                List.fold_left (fun s c -> S.remove c.name s) s columns)
             key m)
      table tx.deleted;
  tx.added <-
    M.modify
      (fun m ->
         (M.modify
            (fun m ->
               List.fold_left
                 (fun m c -> M.add c.name c.data m)
                 m columns)
            M.empty key m))
      M.empty table tx.added;
  return ()

let delete_columns tx table key cols =
  tx.added <-
    M.modify_if_found
      (fun m ->
         (M.modify
             (fun m -> List.fold_left (fun m c -> M.remove c m) m cols)
             M.empty key m))
      table tx.added;
  if M.is_empty (M.find_default M.empty table tx.added |>
                 M.find_default M.empty key) then
    tx.added_keys <- M.modify_if_found (S.remove key) table tx.added_keys;
  tx.deleted <-
    M.modify
      (fun m ->
         M.modify
           (fun s -> List.fold_left (fun s c -> S.add c s) s cols)
           S.empty key m)
      M.empty table tx.deleted;
  return ()

let delete_key tx table key =
  match_lwt
    get_columns tx table ~max_columns:max_int ~decode_timestamps:false
      key All_columns
  with
      None -> return ()
    | Some (_, columns) ->
        lwt () = delete_columns tx table key
                   (List.map (fun c -> c.name) columns)
        in
          tx.deleted_keys <- M.modify (S.add key) S.empty table tx.deleted_keys;
          return ()

let dump tx ?only_tables ?offset () =
  let open Backup in
  let max_chunk = 65536 in
  let data = Bytea.create 13 in
  lwt pending_tables = match offset with
      Some c -> return c.bc_remaining_tables
    | None -> (* FIXME: should use the tx's iterator to list the tables *)
        list_tables tx.ks in
  let curr_key, curr_col = match offset with
      Some c -> Some c.bc_key, Some c.bc_column
    | None -> None, None in

  let next_key = ref "" in
  let next_col = ref "" in

  let got_enough_data () = Bytea.length data > max_chunk in
  let value_buf = ref "" in

  let fold_datum curr_table it
        ~key_buf ~key_len ~column_buf ~column_len ~timestamp_buf =
    if got_enough_data () then begin
      next_key := String.sub key_buf 0 key_len;
      next_col := String.sub column_buf 0 column_len;
      Finish_fold curr_table
    end else begin
      Backup.add_datum data curr_table it
        ~key_buf ~key_len ~column_buf ~column_len ~timestamp_buf ~value_buf;
      Continue
    end in

  let rec collect_data ~curr_key ~curr_col = function
      [] ->
        if Bytea.length data = 0 then return None
        else return (Some (Bytea.contents data, None))
    | curr_table :: tl as tables ->
        lwt _ =
          fold_over_data tx curr_table fold_datum curr_table
            ~first_key:curr_key ?first_column:curr_col ~up_to_key:None
        in
          if got_enough_data () then begin
            let cursor =
              { bc_remaining_tables = tables; bc_key = !next_key;
                bc_column = !next_col; }
            in return (Some (Bytea.contents data, Some cursor))

          (* we don't have enough data yet, move to next table *)
          end else begin
            collect_data ~curr_key:None ~curr_col:None tl
          end

  in collect_data ~curr_key ~curr_col pending_tables

let load tx data =
  let enc_datum_key datum_key ~table ~key ~column ~timestamp =
    Datum_key.encode_datum_key datum_key tx.ks.ks_id
      ~table ~key ~column ~timestamp
  in return (Backup.load enc_datum_key (Lazy.force tx.batch) data)

let cursor_of_string = Backup.cursor_of_string
let string_of_cursor = Backup.string_of_cursor
