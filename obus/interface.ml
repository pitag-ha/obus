(*
 * interface.ml
 * ------------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implemtation of dbus.
 *)

type name = string

type property_handlers = {
  property_set : string -> Header.t -> string -> int -> unit;
  property_get : string -> Header.t -> string -> int -> unit;
  property_getall : Header.t -> string -> int -> unit;
}

type handlers = {
  method_call : Header.t -> string -> int -> bool;
  introspecter : string -> (signature * string list) option;
  property : property_handlers option;
}

type 'a t = {
  name : name;
  handlers : handlers;
}

let make_interface _ name handlers =
  { name = name;
    handlers = handlers }
let name i = i.name
let get_handlers i = i.handlers

type value = string
type annotation = Annotation of name * value
type argument = Arg of name * Type.single
type method_sig = Method of name * argument list * argument list * annotation list
type signal_sig = Signal of name * argument list * annotation list
type signature = Interface of name * method_sig list * signal_sig list * annotation list

let print_xml print (Interface(name, definitions, annotations)) =
  let print_args dir args =
    List.iter begin fun (Arg(name, typ)) ->
      print "      <arg name=\"%s\" direction=\"%s\" type=\"%s\"/>\n" name dir (Type.string_of_single typ)
    end args
  in
  let print_annotations indent annotations =
    List.iter begin fun (Annotation(name, value)) ->
      print "    %s<annotation name=\"%s\" value=\"%s\"/>\n" indent name value
    end annotations
  in
  print "  <interface name=\"%s\">\n" name;
  List.iter begin function
    | Method(name, ins, outs, annotations) ->
        print "    <method name=\"%s\">\n" name;
        print_args "in" ins;
        print_args "out" out;
        print_annotations "  " annotations;
        print "    </method>\n"
    | Signal(name, ins, outs, annotations) ->
        print "    <signal name=\"%s\">\n" name;
        print_args "in" ins;
        print_annotatiions "  " annotations;
        print "    </signal>\n"
    | Property(name, typ, access, annotations) ->
        print "    <property name=\"%s\" type=\"%s\" access=\"%s\">\n"
          name (Type.string_of_single typ)
          (match access with
             | Read -> "read"
             | Write -> "write"
             | Read_write -> "readwrite");
        print_annotatiions "  " annotations;
        print "    </property>"
  end definitions;
  print_annotatiions "" annotations;
  print "  </interface>\n"

