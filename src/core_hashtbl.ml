open Sexplib
open Sexplib.Conv
open Int_replace_polymorphic_compare
open Core_hashtbl_intf
open With_return

module Binable = Binable0

let failwiths = Error.failwiths

module Hashable = Core_hashtbl_intf.Hashable

let hash_param = Hashable.hash_param
let hash       = Hashable.hash

(* A few small things copied from other parts of core because they depend on us, so we
   can't use them. *)
module Int = struct
  type t = int

  let max (x : t) y = if x > y then x else y
  let min (x : t) y = if x < y then x else y
end

module List = Core_list
module Array = Core_array

let phys_equal = (==)

type ('k, 'v) t =
  { mutable table            : ('k, 'v) Avltree.t array
  ; mutable length           : int
  (* [recently_added] is the reference passed to [Avltree.add]. We put it in the hash
     table to avoid allocating it at every [set]. *)
  ; recently_added           : bool ref
  ; growth_allowed           : bool
  ; hashable                 : 'k Hashable.t
  ; mutable mutation_allowed : bool (* Set during all iteration operations *)
  }

type ('k, 'v) hashtbl = ('k, 'v) t

type 'a key = 'a

module type S         = S         with type ('a, 'b) hashtbl = ('a, 'b) t
module type S_binable = S_binable with type ('a, 'b) hashtbl = ('a, 'b) t

let sexp_of_key t = t.hashable.Hashable.sexp_of_t
let compare_key t = t.hashable.Hashable.compare
let hashable t = t.hashable

let ensure_mutation_allowed t =
  if not t.mutation_allowed then failwith "Hashtbl: mutation not allowed during iteration"
;;

let without_mutating t f =
  if t.mutation_allowed
  then
    begin
      t.mutation_allowed <- false;
      match f () with
      | x             -> t.mutation_allowed <- true; x
      | exception exn -> t.mutation_allowed <- true; raise exn
    end
  else
    f ()
;;

(** Internally use a maximum size that is a power of 2. Reverses the above to find the
    floor power of 2 below the system max array length *)
let max_table_length = Int_pow2.floor_pow2 Sys.max_array_length ;;

let create ?(growth_allowed = true) ?(size = 128) ~hashable () =
  let size = Int.min (Int.max 1 size) max_table_length in
  let size = Int_pow2.ceil_pow2 size in
  { table            = Array.create ~len:size Avltree.empty
  ; length           = 0
  ; growth_allowed   = growth_allowed
  ; recently_added   = ref false
  ; hashable
  ; mutation_allowed = true
  }
;;

(** Supplemental hash. This may not be necessary, it is intended as a defense against poor
    hash functions, for which the power of 2 sized table will be especially sensitive.
    With some testing we may choose to add it, but this table is designed to be robust to
    collisions, and in most of my testing this degrades performance. *)
let _supplemental_hash h =
  let h = h lxor ((h lsr 20) lxor (h lsr 12)) in
  h lxor (h lsr 7) lxor (h lsr 4)
;;

exception Hash_value_must_be_non_negative [@@deriving sexp]

let slot t key =
  let hash = t.hashable.Hashable.hash key in
  (* this is always non-negative because we do [land] with non-negative number *)
  hash land ((Array.length t.table) - 1)
;;

let add_worker t ~replace ~key ~data =
  let i = slot t key in
  let root = t.table.(i) in
  let added = t.recently_added in
  added := false;
  let new_root =
    (* The avl tree might replace the value [replace=true] or do nothing [replace=false]
       to the entry, in that case the table did not get bigger, so we should not
       increment length, we pass in the bool ref t.added so that it can tell us whether
       it added or replaced. We do it this way to avoid extra allocation. Since the bool
       is an immediate it does not go through the write barrier. *)
    Avltree.add ~replace root ~compare:(compare_key t) ~added ~key ~data
  in
  if !added then
    t.length <- t.length + 1;
  (* This little optimization saves a caml_modify when the tree
     hasn't been rebalanced. *)
  if not (phys_equal new_root root) then
    t.table.(i) <- new_root
;;

let maybe_resize_table t =
  let len = Array.length t.table in
  let should_grow = t.length > len in
  if should_grow && t.growth_allowed then begin
    let new_array_length = Int.min (len * 2) max_table_length in
    if new_array_length > len then begin
      let new_table =
        Array.init new_array_length ~f:(fun _ -> Avltree.empty)
      in
      let old_table = t.table in
      t.table <- new_table;
      t.length <- 0;
      let f ~key ~data = add_worker ~replace:true t ~key ~data in
      for i = 0 to Array.length old_table - 1 do
        Avltree.iter old_table.(i) ~f
      done
    end
  end
;;

let set t ~key ~data =
  ensure_mutation_allowed t;
  add_worker ~replace:true t ~key ~data;
  maybe_resize_table t
;;

let replace = set

let add t ~key ~data =
  ensure_mutation_allowed t;
  add_worker ~replace:false t ~key ~data;
  if !(t.recently_added) then begin
    maybe_resize_table t;
    `Ok
  end else
    `Duplicate
;;

let add_or_error t ~key ~data =
  match add t ~key ~data with
  | `Ok -> Result.Ok ()
  | `Duplicate ->
    let sexp_of_key = sexp_of_key t in
    Or_error.error "Hashtbl.add_exn got key already present" key [%sexp_of: key]
;;

let add_exn t ~key ~data =
  Or_error.ok_exn (add_or_error t ~key ~data)
;;

let clear t =
  ensure_mutation_allowed t;
  for i = 0 to Array.length t.table - 1 do
    t.table.(i) <- Avltree.empty;
  done;
  t.length <- 0
;;

let find_and_call t key ~if_found ~if_not_found =
  (* with a good hash function these first two cases will be the overwhelming majority,
     and Avltree.find is recursive, so it can't be inlined, so doing this avoids a
     function call in most cases. *)
  match t.table.(slot t key) with
  | Avltree.Empty -> if_not_found key
  | Avltree.Leaf (k, v) ->
    if compare_key t k key = 0 then if_found v
    else if_not_found key
  | tree ->
    Avltree.find_and_call tree ~compare:(compare_key t) key ~if_found ~if_not_found
;;

let find =
  let if_found v = Some v in
  let if_not_found _ = None in
  fun t key ->
    find_and_call t key ~if_found ~if_not_found
;;

let mem t key =
  match t.table.(slot t key) with
  | Avltree.Empty -> false
  | Avltree.Leaf (k, _) -> compare_key t k key = 0
  | tree -> Avltree.mem tree ~compare:(compare_key t) key
;;

let remove t key =
  ensure_mutation_allowed t;
  let i = slot t key in
  let root = t.table.(i) in
  let added_or_removed = t.recently_added in
  added_or_removed := false;
  let new_root =
    Avltree.remove root
      ~removed:added_or_removed ~compare:(compare_key t) key
  in
  if not (phys_equal root new_root) then
    t.table.(i) <- new_root;
  if !added_or_removed then
    t.length <- t.length - 1
;;

let length t = t.length

let is_empty t = length t = 0

let fold t ~init ~f =
  if length t = 0 then init
  else begin
    let n = Array.length t.table in
    let acc = ref init in
    let m = t.mutation_allowed in
    match
      t.mutation_allowed <- false;
      for i = 0 to n - 1 do
        match Array.unsafe_get t.table i with
        | Avltree.Empty -> ()
        | Avltree.Leaf (key, data) -> acc := f ~key ~data !acc
        | bucket -> acc := Avltree.fold bucket ~init:!acc ~f
      done
    with
    | () ->
      t.mutation_allowed <- m;
      !acc
    | exception exn ->
      t.mutation_allowed <- m;
      raise exn
  end
;;

let iteri t ~f =
  if t.length = 0 then ()
  else begin
    let n = Array.length t.table in
    let m = t.mutation_allowed in
    match
      t.mutation_allowed <- false;
      for i = 0 to n - 1 do
        match Array.unsafe_get t.table i with
        | Avltree.Empty -> ()
        | Avltree.Leaf (key, data) -> f ~key ~data
        | bucket -> Avltree.iter bucket ~f
      done
    with
    | () ->
      t.mutation_allowed <- m
    | exception exn ->
      t.mutation_allowed <- m;
      raise exn
  end
;;

let iter_vals t ~f = iteri t ~f:(fun ~key:_ ~data -> f data)
let iter_keys t ~f = iteri t ~f:(fun ~key ~data:_ -> f key)

(* DEPRECATED - leaving here for a little while so as to ease the transition for
   external core users. (But marking as deprecated in the mli *)
let iter = iteri

let invariant invariant_key invariant_data t =
  for i = 0 to Array.length t.table - 1 do
    Avltree.invariant t.table.(i) ~compare:(compare_key t)
  done;
  let real_len =
    fold t ~init:0 ~f:(fun ~key ~data i ->
      invariant_key key;
      invariant_data data;
      i + 1)
  in
  assert (real_len = t.length);
;;

let find_exn =
  let if_found v = v in
  let if_not_found _ = raise Not_found in
  fun t key ->
    find_and_call t key ~if_found ~if_not_found
;;

(*let find_default t key ~default =
  match find t key with
  | None -> default ()
  | Some a -> a*)

let existsi t ~f =
  with_return (fun r ->
    iteri t ~f:(fun ~key ~data -> if f ~key ~data then r.return true);
    false)
;;

let exists t ~f = existsi t ~f:(fun ~key:_ ~data -> f data)
;;

let for_alli t ~f = not (existsi t ~f:(fun ~key   ~data -> not (f ~key ~data)))
let for_all  t ~f = not (existsi t ~f:(fun ~key:_ ~data -> not (f       data)))

let counti t ~f =
  fold t ~init:0 ~f:(fun ~key ~data acc -> if f ~key ~data then acc+1 else acc)
let count t ~f =
  fold t ~init:0 ~f:(fun ~key:_ ~data acc -> if f data then acc+1 else acc)

let mapi t ~f =
  let new_t =
    create ~growth_allowed:t.growth_allowed
      ~hashable:t.hashable ~size:t.length ()
  in
  iteri t ~f:(fun ~key ~data -> replace new_t ~key ~data:(f ~key ~data));
  new_t

(* How about this? *)
(*
let mapi t ~f =
  let new_t =
    create ~growth_allowed:t.growth_allowed
      ~hashable:t.hashable ~size:t.length ()
  in
  let itfun ~key ~data = replace new_t ~key ~data:(f ~key ~data) in
  iteri t ~f:itfun;
  new_t
*)

let map t ~f = mapi t ~f:(fun ~key:_ ~data -> f data)

let copy t = map t ~f:Fn.id

let filter_mapi t ~f =
  let new_t =
    create ~growth_allowed:t.growth_allowed
      ~hashable:t.hashable ~size:t.length ()
  in
  iteri t ~f:(fun ~key ~data ->
    match f ~key ~data with
    | Some new_data -> replace new_t ~key ~data:new_data
    | None -> ());
  new_t

(* How about this? *)
(*
let filter_mapi t ~f =
  let new_t =
    create ~growth_allowed:t.growth_allowed
      ~hashable:t.hashable ~size:t.length ()
  in
  let itfun ~key ~data = match f ~key ~data with
    | None -> ()
    | Some d -> replace new_t ~key ~data:d
  in
  iter t ~f:itfun;
  new_t
*)

let filter_map t ~f = filter_mapi t ~f:(fun ~key:_ ~data -> f data)

let filteri t ~f =
  filter_mapi t ~f:(fun ~key ~data -> if f ~key ~data then Some data else None)
;;

let filter t ~f = filteri t ~f:(fun ~key:_ ~data -> f data)

let partition_mapi t ~f =
  let t0 =
    create ~growth_allowed:t.growth_allowed
      ~hashable:t.hashable ~size:t.length ()
  in
  let t1 =
    create ~growth_allowed:t.growth_allowed
      ~hashable:t.hashable ~size:t.length ()
  in
  iteri t ~f:(fun ~key ~data ->
    match f ~key ~data with
    | `Fst new_data -> replace t0 ~key ~data:new_data
    | `Snd new_data -> replace t1 ~key ~data:new_data);
  (t0, t1)
;;

let partition_map t ~f = partition_mapi t ~f:(fun ~key:_ ~data -> f data)

let partitioni_tf t ~f =
  partition_mapi t ~f:(fun ~key ~data -> if f ~key ~data then `Fst data else `Snd data)
;;

let partition_tf t ~f = partitioni_tf t ~f:(fun ~key:_ ~data -> f data)

let find_or_add t id ~default =
  match find t id with
  | Some x -> x
  | None ->
    let default = default () in
    replace t ~key:id ~data:default;
    default

(* Some hashtbl implementations may be able to perform this more efficiently than two
   separate lookups *)
let find_and_remove t id =
  let result = find t id in
  if Option.is_some result then remove t id;
  result


let change t id ~f =
  match f (find t id) with
  | None -> remove t id
  | Some data -> replace t ~key:id ~data
;;

let update t id ~f =
  set t ~key:id ~data:(f (find t id))
;;

let incr ?(by = 1) t key =
  update t key ~f:(function
    | None -> by
    | Some i -> i + by)
;;

let add_multi t ~key ~data =
  update t key ~f:(function
    | None   -> [ data ]
    | Some l -> data :: l)
;;

let remove_multi t key =
  match find t key with
  | None -> ()
  | Some [] | Some [_] -> remove t key
  | Some (_ :: tl) -> replace t ~key ~data:tl

let create_mapped ?growth_allowed ?size ~hashable ~get_key ~get_data rows =
  let size = match size with Some s -> s | None -> List.length rows in
  let res = create ?growth_allowed ~hashable ~size () in
  let dupes = ref [] in
  List.iter rows ~f:(fun r ->
    let key = get_key r in
    let data = get_data r in
    if mem res key then
      dupes := key :: !dupes
    else
      replace res ~key ~data);
  match !dupes with
  | [] -> `Ok res
  | keys -> `Duplicate_keys (List.dedup ~compare:hashable.Hashable.compare keys)
;;

(*let create_mapped_exn ?growth_allowed ?size ~hashable ~get_key ~get_data rows =
  let size = match size with Some s -> s | None -> List.length rows in
  let res = create ?growth_allowed ~size ~hashable () in
  List.iter rows ~f:(fun r ->
    let key = get_key r in
    let data = get_data r in
    if mem res key then
      let sexp_of_key = hashable.Hashable.sexp_of_t in
      failwiths "Hashtbl.create_mapped_exn: duplicate key" key <:sexp_of< key >>
    else
      replace res ~key ~data);
  res
;;*)

let create_mapped_multi ?growth_allowed ?size ~hashable ~get_key ~get_data rows =
  let size = match size with Some s -> s | None -> List.length rows in
  let res = create ?growth_allowed ~size ~hashable () in
  List.iter rows ~f:(fun r ->
    let key = get_key r in
    let data = get_data r in
    add_multi res ~key ~data);
  res
;;

let of_alist ?growth_allowed ?size ~hashable lst =
  match create_mapped ?growth_allowed ?size ~hashable ~get_key:fst ~get_data:snd lst with
  | `Ok t -> `Ok t
  | `Duplicate_keys k -> `Duplicate_key (List.hd_exn k)
;;

let of_alist_report_all_dups ?growth_allowed ?size ~hashable lst =
  create_mapped ?growth_allowed ?size ~hashable ~get_key:fst ~get_data:snd lst
;;

let of_alist_or_error ?growth_allowed ?size ~hashable lst =
  match of_alist ?growth_allowed ?size ~hashable lst with
  | `Ok v -> Result.Ok v
  | `Duplicate_key key ->
    let sexp_of_key = hashable.Hashable.sexp_of_t in
    Or_error.error "Hashtbl.of_alist_exn: duplicate key" key sexp_of_key
;;

let of_alist_exn ?growth_allowed ?size ~hashable lst =
  match of_alist_or_error ?growth_allowed ?size ~hashable lst with
  | Result.Ok v -> v
  | Result.Error e -> Error.raise e
;;

let of_alist_multi ?growth_allowed ?size ~hashable lst =
  create_mapped_multi ?growth_allowed ?size ~hashable ~get_key:fst ~get_data:snd lst
;;

let to_alist t = fold ~f:(fun ~key ~data list -> (key, data) :: list) ~init:[] t

let sexp_of_t sexp_of_key sexp_of_data t =
  t
  |> to_alist
  |> List.sort ~cmp:(fun (k1, _) (k2, _) -> t.hashable.compare k1 k2)
  |> [%sexp_of: (key * data) list]
;;

let validate ~name f t = Validate.alist ~name f (to_alist t)

let keys t = fold t ~init:[] ~f:(fun ~key ~data:_ acc -> key :: acc)

let data t = fold ~f:(fun ~key:_ ~data list -> data::list) ~init:[] t

let add_to_groups groups ~get_key ~get_data ~combine ~rows =
  List.iter rows ~f:(fun row ->
    let key = get_key row in
    let data = get_data row in
    let data =
      match find groups key with
      | None -> data
      | Some old -> combine old data
    in
    replace groups ~key ~data)
;;

let group ?growth_allowed ?size ~hashable ~get_key ~get_data ~combine rows =
  let res = create ?growth_allowed ?size ~hashable () in
  add_to_groups res ~get_key ~get_data ~combine ~rows;
  res
;;

let create_with_key ?growth_allowed ?size ~hashable ~get_key rows =
  create_mapped ?growth_allowed ?size ~hashable ~get_key ~get_data:(fun x -> x) rows
;;

let create_with_key_or_error ?growth_allowed ?size ~hashable ~get_key rows =
  match create_with_key ?growth_allowed ?size ~hashable ~get_key rows with
  | `Ok t -> Result.Ok t
  | `Duplicate_keys keys ->
    let sexp_of_key = hashable.Hashable.sexp_of_t in
    Or_error.error "Hashtbl.create_with_key: duplicate keys" keys [%sexp_of: key list]
;;

let create_with_key_exn ?growth_allowed ?size ~hashable ~get_key rows =
  Or_error.ok_exn (create_with_key_or_error ?growth_allowed ?size ~hashable ~get_key rows)
;;

let merge =
  let maybe_set t ~key ~f d =
    match f ~key d with
    | None -> ()
    | Some v ->
      set t ~key ~data:v
  in
  fun t_left t_right ~f ->
    if not (phys_equal t_left.hashable t_right.hashable)
    then invalid_arg "Hashtbl.merge: different 'hashable' values";
    let new_t =
      create ~growth_allowed:t_left.growth_allowed
        ~hashable:t_left.hashable ~size:t_left.length ()
    in
    without_mutating t_left (fun () ->
      without_mutating t_right (fun () ->
        iteri t_left ~f:(fun ~key ~data:left ->
          match find t_right key with
          | None ->
            maybe_set new_t ~key ~f (`Left left)
          | Some right ->
            maybe_set new_t ~key ~f (`Both (left, right))
        );
        iteri t_right ~f:(fun ~key ~data:right ->
          match find t_left key with
          | None ->
            maybe_set new_t ~key ~f (`Right right)
          | Some _ -> () (* already done above *)
        )));
    new_t
;;

let merge_into ~f ~src ~dst =
  iteri src ~f:(fun ~key ~data ->
    match without_mutating dst (fun () -> f ~key data (find dst key)) with
    | Some data -> replace dst ~key ~data
    | None      -> ())

let filteri_inplace t ~f =
  let to_remove =
    fold t ~init:[] ~f:(fun ~key ~data ac ->
      if f ~key ~data then ac else key :: ac)
  in
  List.iter to_remove ~f:(fun key -> remove t key);
;;

let filter_inplace t ~f =
  filteri_inplace t ~f:(fun ~key:_ ~data -> f data)
;;

let filter_keys_inplace t ~f =
  filteri_inplace t ~f:(fun ~key ~data:_ -> f key)
;;

let filter_replace_alli t ~f =
  let map_results =
    fold t ~init:[] ~f:(fun ~key ~data ac -> (key, f ~key ~data) :: ac)
  in
  List.iter map_results ~f:(fun (key,result) ->
    match result with
    | None -> remove t key
    | Some data -> set t ~key ~data
  );
;;

let filter_replace_all t ~f =
  filter_replace_alli t ~f:(fun ~key:_ ~data -> f data)

let replace_alli t ~f =
  let map_results =
    fold t ~init:[] ~f:(fun ~key ~data ac -> (key, f ~key ~data) :: ac)
  in
  List.iter map_results ~f:(fun (key,data) -> set t ~key ~data);
;;

let replace_all t ~f =
  replace_alli t ~f:(fun ~key:_ ~data -> f data)

let equal t t' equal =
  length t = length t' &&
  with_return (fun r ->
    without_mutating t' (fun () ->
      iteri t ~f:(fun ~key ~data ->
        match find t' key with
        | None       -> r.return false
        | Some data' ->
          if not (equal data data')
          then r.return false));
    true)
;;

let similar = equal

module Accessors = struct
  let invariant       = invariant
  let clear           = clear
  let copy            = copy
  let remove          = remove
  let replace         = replace
  let set             = set
  let add             = add
  let add_or_error    = add_or_error
  let add_exn         = add_exn
  let change          = change
  let update          = update
  let add_multi       = add_multi
  let remove_multi    = remove_multi
  let mem             = mem
  let iter_vals       = iter_vals
  let iteri           = iteri
  let iter_keys       = iter_keys
  let iter            = iter
  let exists          = exists
  let existsi         = existsi
  let for_all         = for_all
  let for_alli        = for_alli
  let count           = count
  let counti          = counti
  let fold            = fold
  let length          = length
  let is_empty        = is_empty
  let map             = map
  let mapi            = mapi
  let filter_map      = filter_map
  let filter_mapi     = filter_mapi
  let filter          = filter
  let filteri         = filteri
  let partition_map   = partition_map
  let partition_mapi  = partition_mapi
  let partition_tf    = partition_tf
  let partitioni_tf   = partitioni_tf
  let find_or_add     = find_or_add
  let find            = find
  let find_exn        = find_exn
  let find_and_call   = find_and_call
  let find_and_remove = find_and_remove
  let to_alist        = to_alist
  let validate        = validate
  let merge           = merge
  let merge_into      = merge_into
  let keys            = keys
  let data            = data
  let filter_inplace  = filter_inplace
  let filteri_inplace = filteri_inplace
  let filter_keys_inplace = filter_keys_inplace
  let replace_all     = replace_all
  let replace_alli    = replace_alli
  let filter_replace_all  = filter_replace_all
  let filter_replace_alli = filter_replace_alli
  let equal           = equal
  let similar         = similar
  let incr            = incr
  let sexp_of_key     = sexp_of_key
end

module type Key = Key
module type Key_binable = Key_binable

module Creators (Key : sig
  type 'a t

  val hashable : 'a t Hashable.t
end) : sig

  type ('a, 'b) t_ = ('a Key.t, 'b) t

  val t_of_sexp : (Sexp.t -> 'a Key.t) -> (Sexp.t -> 'b) -> Sexp.t -> ('a, 'b) t_

  include Creators
    with type ('a, 'b) t := ('a, 'b) t_
    with type 'a key := 'a Key.t
    with type ('key, 'data, 'a) create_options := ('key, 'data, 'a) create_options_without_hashable

end = struct

  let hashable = Key.hashable

  type ('a, 'b) t_ = ('a Key.t, 'b) t

  let create ?growth_allowed ?size () = create ?growth_allowed ?size ~hashable ()

  let of_alist ?growth_allowed ?size l =
    of_alist ?growth_allowed ~hashable ?size l
  ;;

  let of_alist_report_all_dups ?growth_allowed ?size l =
    of_alist_report_all_dups ?growth_allowed ~hashable ?size l
  ;;

  let of_alist_or_error ?growth_allowed ?size l =
    of_alist_or_error ?growth_allowed ~hashable ?size l
  ;;

  let of_alist_exn ?growth_allowed ?size l =
    of_alist_exn ?growth_allowed ~hashable ?size l
  ;;

  let t_of_sexp k_of_sexp d_of_sexp sexp =
    let alist = [%of_sexp: (k * d) list] sexp in
    of_alist_exn alist ~size:(List.length alist)
  ;;

  let of_alist_multi ?growth_allowed ?size l =
    of_alist_multi ?growth_allowed ~hashable ?size l
  ;;

  let create_mapped ?growth_allowed ?size ~get_key ~get_data l =
    create_mapped ?growth_allowed ~hashable ?size ~get_key ~get_data l
  ;;

  let create_with_key ?growth_allowed ?size ~get_key l =
    create_with_key ?growth_allowed ~hashable ?size ~get_key l
  ;;

  let create_with_key_or_error ?growth_allowed ?size ~get_key l =
    create_with_key_or_error ?growth_allowed ~hashable ?size ~get_key l
  ;;

  let create_with_key_exn ?growth_allowed ?size ~get_key l =
    create_with_key_exn ?growth_allowed ~hashable ?size ~get_key l
  ;;

  let group ?growth_allowed ?size ~get_key ~get_data ~combine l =
    group ?growth_allowed ~hashable ?size ~get_key ~get_data ~combine l
  ;;
end

module Poly = struct

  type ('a, 'b) t = ('a, 'b) hashtbl

  type 'a key = 'a

  let hashable = Hashable.poly

  include Creators (struct
    type 'a t = 'a
    let hashable = hashable
  end)

  include Accessors

  let sexp_of_t = sexp_of_t

  include Bin_prot.Utils.Make_iterable_binable2 (struct
    type ('a, 'b) z = ('a, 'b) t
    type ('a, 'b) t = ('a, 'b) z
    type ('a, 'b) el = 'a * 'b [@@deriving bin_io]

    let module_name = Some "Core_kernel.Std.Hashtbl"
    let length = length
    let iter t ~f = iteri t ~f:(fun ~key ~data -> f (key, data))
    let init ~len ~next =
      let t = create ~size:len () in
      for _i = 0 to len - 1 do
        let key,data = next () in
        match find t key with
        | None -> replace t ~key ~data
        | Some _ -> failwith "Core_hashtbl.bin_read_t_: duplicate key"
      done;
      t
    ;;
  end)

end

module Make (Key : Key) = struct

  let hashable =
    { Hashable.
      hash = Key.hash;
      compare = Key.compare;
      sexp_of_t = Key.sexp_of_t;
    }
  ;;

  type key = Key.t
  type ('a, 'b) hashtbl = ('a, 'b) t
  type 'a t = (key, 'a) hashtbl
  type 'a key_ = key

  include Creators (struct
    type 'a t = Key.t
    let hashable = hashable
  end)

  include Accessors

  let invariant invariant_key t = invariant ignore invariant_key t

  let sexp_of_t sexp_of_v t = Poly.sexp_of_t Key.sexp_of_t sexp_of_v t

  let t_of_sexp v_of_sexp sexp = t_of_sexp Key.t_of_sexp v_of_sexp sexp

end

module Make_binable (Key : Key_binable) = struct

  include Make (Key)

  include Bin_prot.Utils.Make_iterable_binable1 (struct
    type nonrec 'a t = 'a t
    type 'a el = Key.t * 'a [@@deriving bin_io]

    let module_name = Some "Core_kernel.Std.Hashtbl"
    let length = length
    let iter t ~f = iteri t ~f:(fun ~key ~data -> f (key, data))

    let init ~len ~next =
      let t = create ~size:len () in
      for _i = 0 to len - 1 do
        let (key, data) = next () in
        match find t key with
        | None -> replace t ~key ~data
        | Some _ -> failwiths "Hashtbl.bin_read_t: duplicate key" key [%sexp_of: Key.t]
      done;
      t
    ;;
  end)

end

let%test_unit _ = (* [sexp_of_t] output is sorted by key *)
  let module Table =
    Make (struct
      open Bin_prot.Std
      type t = int [@@deriving bin_io, compare, sexp]
      let hash (x : t) = if x >= 0 then x else ~-x
    end)
  in
  let t = Table.create () in
  for key = -10 to 10; do
    Table.add_exn t ~key ~data:();
  done;
  List.iter
    [ [%sexp_of: unit Table.t]
    ; [%sexp_of: (int, unit) t]
    ]
    ~f:(fun sexp_of_t ->
      let list =
        t
        |> [%sexp_of: t]
        |> [%of_sexp: (int * unit) list]
      in
      assert (Core_list.is_sorted list ~compare:(fun (i1, _) (i2, _) -> i1 - i2)))
;;
