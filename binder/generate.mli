(*
 * generate.mli
 * ------------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implemtation of dbus.
 *)

module type TermType =
sig
  type var
  type right
  type left
end

module type ValueType =
sig
  type t
end

module Make (Term : TermType) (Value : ValueType) :
sig
  type lterm = [ `LTerm of Term.left * lterm list ]
  type rterm = [ `RTerm of Term.right * rterm list ]
  type rpattern =
      [ `RTerm of Term.right * rpattern list
      | `Var of Term.var ]
  type lpattern =
      [ `LTerm of Term.left * lpattern list
      | `RTerm of Term.right * rpattern list
      | `Var of Term.var ]

  type generator

  type ('a, 'b) args = ('a, Value.t, 'b, Value.t list -> Value.t) Seq.t

  val make_generator : lpattern -> rpattern -> (rpattern, 'a) args ->
    rpattern list -> ((Value.t, 'a) args -> Value.t list -> Value.t) -> generator

  val generate : generator list -> lterm -> rterm  -> Value.t option
end
