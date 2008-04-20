(*
 * xparser.ml
 * ----------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implemtation of dbus.
 *)

exception Parse_failed

open Xml

type param =
  | P of string
  | D of string * string
  | F of string * string list
  | A of string * string * string list

type 'a xml_parser = xml -> 'a option
type ('a, 'b) param_parser = (param, string, 'a, 'b) Seq.t
type 'a seq_elt_parser = xml list -> 'a * xml list
type ('a, 'b) seq_parser = xml list -> 'a -> 'b * xml list

let param_desc = function
  | P(n) -> (n, None, None)
  | D(n, v) -> (n, Some v, None)
  | F(n, vs) -> (n, None, Some vs)
  | A(n, v, vs) -> (n, Some v, Some vs)

let get_arg args spec =
  let (name, default, field) = param_desc spec in
  let value =
    try List.assoc name args
    with Not_found -> match default with
      | Some(v) -> v
      | None -> raise Parse_failed
  in
    match field with
      | None -> value
      | Some f when List.mem value f -> value
      | _ -> raise Parse_failed

let elt elt_name params sons_parser f = function
  | Element(name, args, sons) when name = elt_name ->
      begin try
        match sons_parser sons
          (Seq.apply f
             (Seq.map (get_arg args) params)) with
          | v, [] -> Some(v)
          | _ -> None
      with
          Parse_failed -> None
      end
  | _ -> None

let one xml_parser xmls =
  match Util.part_map xml_parser xmls with
    | [v], l -> (v, l)
    | _ -> raise Parse_failed

let any xml_parser xmls =
  Util.part_map xml_parser xmls

let opt xml_parser xmls =
  match Util.part_map xml_parser xmls with
    | [], l -> (None, l)
    | [v], l -> (Some(v), l)
    | _ -> raise Parse_failed

let union xml_parsers xmls =
  Util.part_map (fun xml ->
                   match Util.filter_map (fun xml_parser -> xml_parser xml) xml_parsers with
                     | [v] -> Some(v)
                     | _ -> None) xmls

let sn xmls f = (f, xmls)

let sc seq_elt_parser seq_parser xmls f =
  let g, rest = seq_elt_parser xmls in
    seq_parser rest (f g)

let parse xml_parser xml =
  match xml_parser xml with
    | Some(v) -> v
    | None -> raise Parse_failed

let s0 = sn
let s1 x1 = sc x1 (sn)
let s2 x2 x1 = sc x2 (sc x1 (sn))
let s3 x3 x2 x1 = sc x3 (sc x2 (sc x1 (sn)))
let s4 x4 x3 x2 x1 = sc x4 (sc x3 (sc x2 (sc x1 (sn))))
let s5 x5 x4 x3 x2 x1 = sc x5 (sc x4 (sc x3 (sc x2 (sc x1 (sn)))))