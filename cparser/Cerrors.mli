(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the GNU General Public License as published by  *)
(*  the Free Software Foundation, either version 2 of the License, or  *)
(*  (at your option) any later version.  This file is also distributed *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(* Printing of warnings and error messages *)

val reset : unit -> unit
  (** Reset the error counters. *)

exception Abort
  (** Exception raised upon fatal errors *)

val check_errors : unit -> bool
  (** Check whether errors occured *)

type warning_type =
  | Unnamed                        (** warnings which cannot be turned off *)
  | Unknown_attribute              (** usage of unsupported/unknown attributes *)
  | Zero_length_array              (** gnu extension for zero lenght arrays *)
  | Celeven_extension              (** C11 features *)
  | Gnu_empty_struct               (** gnu extension for empty struct *)
  | Missing_declarations           (** declation which do not declare anything *)
  | Constant_conversion            (** dangerous constant conversions *)
  | Int_conversion                 (** pointer <-> int conversions *)
  | Varargs                        (** promotable vararg argument *)
  | Implicit_function_declaration  (** deprecated implicit function declaration *)
  | Pointer_type_mismatch          (** pointer type mismatch in ?: operator *)
  | Compare_distinct_pointer_types (** comparison between different pointer types *)
  | Implicit_int                   (** implict int parameter or return type *)
  | Main_return_type               (** wrong return type for main *)
  | Invalid_noreturn               (** noreturn function containing return *)
  | Return_type                    (** void return in non-void function *)
  | Literal_range                  (** literal ranges *)
  | Unknown_pragmas                (** unknown/unsupported pragma *)
  | CompCert_conformance           (** features that are not part of the CompCert C core language *)

val warning  : (string * int) -> warning_type -> ('a, Format.formatter, unit, unit, unit, unit) format6 -> 'a
(** [warning (f,c) w fmt arg1 ... argN] formats the arguments [arg1] to [argN] as warining according to
    the format string [fmt] and outputs the result on [stderr] with additional file [f] and column [c]
    and warning key for [w] *)

val error : (string * int) -> ('a, Format.formatter, unit, unit, unit, unit) format6 -> 'a
(** [error (f,c) w fmt arg1 ... argN] formats the arguments [arg1] to [argN] as error according to
    the format string [fmt] and outputs the result on [stderr] with additional file [f] and column [c]
    and warning key for [w]. *)

val fatal_error : (string * int) -> ('a, Format.formatter, unit, unit, unit, 'b) format6 -> 'a
(** [fatal_error (f,c) w fmt arg1 ... argN] formats the arguments [arg1] to [argN] as error according to
    the format string [fmt] and outputs the result on [stderr] with additional file [f] and column [c]
    and warning key for [w]. Additionally raises the excpetion [Abort] after printing the error message *)

val fatal_error_raw : ('a, out_channel, unit, 'b) format4 -> 'a
(** [fatal_error_raw] is identical to fatal_error, except it uses [Printf] and does not automatically
    introduce indentation *)

val warning_help : string
(** Help string for all warning options *)

val warning_options : (Commandline.pattern * Commandline.action) list
(** List of all options for diagnostics *)

val raise_on_errors : unit -> unit
