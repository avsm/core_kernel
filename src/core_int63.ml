#import "config.mlh"
#if JSC_ARCH_SIXTYFOUR
include Core_int
let to_int x = Some x
#else
include Core_int64
#endif

let () = assert (Core_int.(>=) num_bits 63)

(* Even for ARCH_SIXTYFOUR, we can't use Core_random.State.int, because the bound is very
   limited in range.  We actually want a bound that spans the type. *)
let random ?(state = Core_random.State.default) bound =
  of_int64_exn (Core_random.State.int64 state (to_int64 bound))
;;
