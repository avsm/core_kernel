
module type Infix               = Polymorphic_compare_intf.Infix
module type Polymorphic_compare = Polymorphic_compare_intf.S

module type Validate = sig
  type t

  val validate_lbound : min : t Maybe_bound.t -> t Validate.check
  val validate_ubound : max : t Maybe_bound.t -> t Validate.check
  val validate_bound
    :  min : t Maybe_bound.t
    -> max : t Maybe_bound.t
    -> t Validate.check
end

module type With_zero = sig
  type t

  val validate_positive     : t Validate.check
  val validate_non_negative : t Validate.check
  val validate_negative     : t Validate.check
  val validate_non_positive : t Validate.check
  val is_positive     : t -> bool
  val is_non_negative : t -> bool
  val is_negative     : t -> bool
  val is_non_positive : t -> bool
end

module type S_common = sig
  include Polymorphic_compare
  (** [ascending] is identical to [compare]. [descending x y = ascending y x].  These are
      intended to be mnemonic when used like [List.sort ~cmp:ascending] and [List.sort
      ~cmp:descending], since they cause the list to be sorted in ascending or descending
      order, respectively. *)
  val ascending : t -> t -> int
  val descending : t -> t -> int

  val between : t -> low:t -> high:t -> bool

  (** [clamp_exn t ~min ~max] returns [t'], the closest value to [t] such that
      [between t' ~low:min ~high:max] is true.

      Raises if [not (min <= max)]. *)
  val clamp_exn : t -> min:t -> max:t -> t
  val clamp     : t -> min:t -> max:t -> t Or_error.t

  module Replace_polymorphic_compare : Polymorphic_compare with type t := t

  include Comparator.S with type t := t

  include Validate with type t := t
end

(** Usage example:

    {[
      module Foo : sig
        type t = ...
        include Comparable.S with type t := t
      end
    ]}

    Then use [Comparable.Make] in the struct (see comparable.mli for an example). *)
module type S = sig
  include S_common

  module Map : Core_map.S
    with type Key.t = t
    with type Key.comparator_witness = comparator_witness
  module Set : Core_set.S
    with type Elt.t = t
    with type Elt.comparator_witness = comparator_witness
end

module type Map_and_set_binable = sig
  type t
  include Comparator.S with type t := t
  module Map : Core_map.S_binable
    with type Key.t = t
    with type Key.comparator_witness = comparator_witness
  module Set : Core_set.S_binable
    with type Elt.t = t
    with type Elt.comparator_witness = comparator_witness
end

module type S_binable = sig
  include S_common
  include Map_and_set_binable
    with type t := t
    with type comparator_witness := comparator_witness
end
