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

(* Elaboration from Cabs parse tree to C simplified, typed syntax tree *)

(* Numbered references are to sections of the ISO C99 standard *)

open Format
open Machine
open !Cabs
open Cabshelper
open !C
open Cerrors
open Cutil
open Env

(** * Utility functions *)

(* Error reporting  *)

let fatal_error loc fmt =
  fatal_error (loc.filename,loc.lineno) fmt

let error loc fmt =
  error (loc.filename,loc.lineno) fmt

let warning loc =
  warning (loc.filename,loc.lineno)

let print_typ env fmt ty =
  match ty with
  | TNamed _  ->
      Format.fprintf fmt "'%a' (aka '%a')" Cprint.typ_raw ty Cprint.typ_raw (Cutil.unroll env ty)
  | _ -> Format.fprintf fmt "'%a'" Cprint.typ_raw ty

(* Error reporting for Env functions *)

let wrap fn loc env arg =
  try fn env arg
  with Env.Error msg -> fatal_error loc "%s" (Env.error_message msg)

let wrap2 fn loc env arg1 arg2 =
  try fn env arg1 arg2
  with Env.Error msg -> fatal_error loc "%s" (Env.error_message msg)

(* Translation of locations *)

let elab_loc l = (l.filename, l.lineno)

(* Buffering of the result (a list of topdecl *)

let top_declarations = ref ([] : globdecl list)

(* Environment that records the top declarations of functions and
   variables with external or internal linkage.  Used for
   analyzing "extern" declarations. *)

let top_environment = ref Env.empty

let emit_elab ?(debuginfo = true) ?(linkage = false) env loc td =
  let loc = elab_loc loc in
  let dec ={ gdesc = td; gloc = loc } in
  if debuginfo then Debug.insert_global_declaration env dec;
  top_declarations := dec :: !top_declarations;
  if linkage then begin
    match td with
    | Gdecl(sto, id, ty, init) ->
        top_environment := Env.add_ident !top_environment id sto ty
    | Gfundef f ->
        top_environment :=
          Env.add_ident !top_environment f.fd_name f.fd_storage (fundef_typ f)
    | _ -> ()
  end

let reset() = top_declarations := []; top_environment := Env.empty

let elaborated_program () =
  let p = !top_declarations in
  top_declarations := [];
  (* Reverse it and eliminate unreferenced declarations *)
  Cleanup.program p

(* Monadic map for functions env -> 'a -> 'b * env *)

let rec mmap f env = function
  | [] -> ([], env)
  | hd :: tl ->
      let (hd', env1) = f env hd in
      let (tl', env2) = mmap f env1 tl in
      (hd' :: tl', env2)

(* To detect redefinitions within the same scope *)

let previous_def fn env arg =
  try
    Some (fn env arg)
  with Env.Error _ ->
    None

let redef fn env arg =
  match previous_def fn env arg with
  | None -> false
  | Some(id, info) -> Env.in_current_scope env id

(* Auxiliaries for handling declarations and redeclarations *)

let combine_toplevel_definitions loc env s old_sto old_ty sto ty =
  let new_ty =
    match combine_types AttrCompat env old_ty ty with
    | Some new_ty ->
        new_ty
    | None ->
        error loc
          "redefinition of '%s' with a different type: %a vs %a"
          s (print_typ env) old_ty (print_typ env) ty;
        ty in
  let new_sto =
    (* The only case not allowed is removing static *)
    match old_sto,sto with
    | Storage_static,Storage_static
    | Storage_extern,Storage_extern
    | Storage_register,Storage_register
    | Storage_default,Storage_default -> sto
    | _,Storage_static ->
	error loc "static declaration of '%s' follows non-static declaration" s;
        sto
    | Storage_static,_ -> Storage_static (* Static stays static *)
    | Storage_extern,_ -> sto
    | Storage_default,Storage_extern -> Storage_extern
    | _,Storage_extern -> old_sto
    | _,Storage_register
    | Storage_register,_ -> Storage_register
  in
    (new_sto, new_ty)

let enter_or_refine_ident local loc env s sto ty =
  (* Check for illegal redefinitions:
       - a name that was previously a typedef
       - a variable that was already declared in the same local scope
         (unless both old and new declarations are extern)
       - an enum that was already declared in the same scope.
     Redefinition of a variable at global scope (or extern) is treated below. *)
  if redef Env.lookup_typedef env s then
    error loc "redefinition of '%s' as different kind of symbol" s;
  begin match previous_def Env.lookup_ident env s with
  | Some(id, II_ident(old_sto, old_ty))
    when local && Env.in_current_scope env id
               && not (sto = Storage_extern && old_sto = Storage_extern) ->
      error loc "redefinition of '%s'" s
  | Some(id, II_enum _) when Env.in_current_scope env id ->
      error loc "redefinition of '%s' as different kind of symbol" s;
  | _ ->
     ()
  end;
  (* For a block-scoped, non-"extern" variable, a new declaration
     is entered, and it has no linkage. *)
  if local && sto <> Storage_extern then begin
    let (id, env') = Env.enter_ident env s sto ty in
    (id, sto, env', ty, false)
  end else begin
  (* For a file-scoped or "extern" variable, we need to check against
     prior declarations of this variable with internal or external linkage.
     The variable has linkage. *)
    match previous_def Env.lookup_ident !top_environment s with
    | Some(id, II_ident(old_sto, old_ty)) ->
        let (new_sto, new_ty) =
          combine_toplevel_definitions loc env s old_sto old_ty sto ty in
        (id, new_sto, Env.add_ident env id new_sto new_ty, new_ty, true)
    | _ ->
        let (id, env') = Env.enter_ident env s sto ty in
        (id, sto, env', ty, true)
  end

(* Forward declarations *)

let elab_expr_f : (cabsloc -> Env.t -> Cabs.expression -> C.exp * Env.t) ref
  = ref (fun _ _ _ -> assert false)

let elab_funbody_f : (C.typ -> bool -> Env.t -> statement -> C.stmt) ref
  = ref (fun _ _ _ _ -> assert false)


(** * Elaboration of constants - C99 section 6.4.4 *)

let has_suffix s suff =
  let ls = String.length s and lsuff = String.length suff in
  ls >= lsuff && String.sub s (ls - lsuff) lsuff = suff

let chop_last s n =
  assert (String.length s >= n);
  String.sub s 0 (String.length s - n)

let has_prefix s pref =
  let ls = String.length s and lpref = String.length pref in
  ls >= lpref && String.sub s 0 lpref = pref

let chop_first s n =
  assert (String.length s >= n);
  String.sub s n (String.length s - n)

exception Overflow
exception Bad_digit

let parse_int base s =
  let max_val = (* (2^64-1) / base, unsigned *)
    match base with
    |  8 -> 2305843009213693951L
    | 10 -> 1844674407370955161L
    | 16 -> 1152921504606846975L
    |  _ -> assert false in
  let v = ref 0L in
  for i = 0 to String.length s - 1 do
    if !v < 0L || !v > max_val then raise Overflow;
    v := Int64.mul !v (Int64.of_int base);
    let c = s.[i] in
    let digit =
      if c >= '0' && c <= '9' then Char.code c - 48
      else if c >= 'A' && c <= 'F' then Char.code c - 55
      else raise Bad_digit in
    if digit >= base then raise Bad_digit;
    v := Int64.add !v (Int64.of_int digit)
  done;
  !v

let integer_representable v ik =
  let bitsize = sizeof_ikind ik * 8
  and signed = is_signed_ikind ik in
  if bitsize >= 64 then
    (not signed) || (v >= 0L && v <= 0x7FFF_FFFF_FFFF_FFFFL)
  else if not signed then
    v >= 0L && v < Int64.shift_left 1L bitsize
  else
    v >= 0L && v < Int64.shift_left 1L (bitsize - 1)

let elab_int_constant loc s0 =
  let s = String.map (fun d -> match d with
  | '0'..'9' | 'A'..'F' | 'L' | 'U' | 'X' -> d
  | 'a'..'f' | 'l' | 'u' | 'x' -> Char.chr (Char.code d - 32)
  | _ -> error loc "bad digit '%c' in integer literal '%s'" d s0; d) s0 in
  (* Determine possible types and chop type suffix *)
  let (s, dec_kinds, hex_kinds) =
    if has_suffix s "ULL" || has_suffix s "LLU" then
      (chop_last s 3, [IULongLong], [IULongLong])
    else if has_suffix s "LL" then
      (chop_last s 2, [ILongLong], [ILongLong; IULongLong])
    else if has_suffix s "UL" || has_suffix s "LU" then
      (chop_last s 2, [IULong; IULongLong], [IULong; IULongLong])
    else if has_suffix s "L" then
      (chop_last s 1, [ILong; ILongLong],
                      [ILong; IULong; ILongLong; IULongLong])
    else if has_suffix s "U" then
      (chop_last s 1, [IUInt; IULong; IULongLong],
                      [IUInt; IULong; IULongLong])
    else
      (s, [IInt; ILong; ILongLong],
          [IInt; IUInt; ILong; IULong; ILongLong; IULongLong])
  in
  (* Determine base *)
  let (s, base) =
    if has_prefix s "0X" then
      (chop_first s 2, 16)
    else if has_prefix s "0" then
      (chop_first s 1, 8)
    else
      (s, 10)
  in
  (* Parse digits *)
  let v =
    try parse_int base s
    with
    | Overflow ->
        error loc "integer literal '%s' is too large to be represented in any integer type" s0;
        0L
    | Bad_digit ->
        (*error loc "bad digit in integer literal '%s'" s0;*) (* Is caught earlier *)
        0L
  in
  (* Find smallest allowable type that fits *)
  let ty =
    try List.find (fun ty -> integer_representable v ty)
                  (if base = 10 then dec_kinds else hex_kinds)
    with Not_found ->
      error loc "integer literal '%s' cannot be represented" s0;
      IInt
  in
  (v, ty)

let elab_float_constant f =
  let ty = match f.suffix_FI with
    | Some ("l"|"L") -> FLongDouble
    | Some ("f"|"F") -> FFloat
    | None -> FDouble
    | _ -> assert false (* The lexer should not accept anything else. *)
  in
  let v = {
    hex=f.isHex_FI;
    intPart=begin match f.integer_FI with Some s -> s | None -> "0" end;
    fracPart=begin match f.fraction_FI with Some s -> s | None -> "0" end;
    exp=begin match f.exponent_FI with Some s -> s | None -> "0" end }
  in
  (v, ty)

let elab_char_constant loc wide chars =
  let nbits = if wide then 8 * !config.sizeof_wchar else 8 in
  (* Treat multi-char constants as a number in base 2^nbits *)
  let max_digit = Int64.shift_left 1L nbits in
  let max_val = Int64.shift_left 1L (64 - nbits) in
  let v,_ =
    List.fold_left
      (fun (acc,err) d ->
        if not err then begin
          let overflow = acc < 0L || acc >= max_val
          and out_of_range = d < 0L || d >= max_digit in
          if overflow then
            error loc "character constant too long for its type";
          if out_of_range then
            error loc "escape sequence is out of range (code 0x%LX)" d;
          Int64.add (Int64.shift_left acc nbits) d,overflow || out_of_range
        end else
          Int64.add (Int64.shift_left acc nbits) d,true
      )
      (0L,false) chars in
  if not (integer_representable v IInt) then
    warning loc Unnamed "character constant too long for its type";
  (* C99 6.4.4.4 item 10: single character -> represent at type char
     or wchar_t *)
  Ceval.normalize_int v
    (if List.length chars = 1 then
       if wide then wchar_ikind() else IChar
     else
       IInt)

let elab_string_literal loc wide chars =
  let nbits = if wide then 8 * !config.sizeof_wchar else 8 in
  let char_max = Int64.shift_left 1L nbits in
  List.iter
    (fun c ->
      if c < 0L || c >= char_max
      then error loc "escape sequence is out of range (code 0x%LX)" c)
    chars;
  if wide then
    CWStr chars
  else begin
    let res = Bytes.create (List.length chars) in
    List.iteri
      (fun i c -> Bytes.set res i (Char.unsafe_chr (Int64.to_int c)))
      chars;
    CStr (Bytes.to_string res)
  end

let elab_constant loc = function
  | CONST_INT s ->
      let (v, ik) = elab_int_constant loc s in
      CInt(v, ik, s)
  | CONST_FLOAT f ->
      let (v, fk) = elab_float_constant f in
      CFloat(v, fk)
  | CONST_CHAR(wide, s) ->
      CInt(elab_char_constant loc wide s, IInt, "")
  | CONST_STRING(wide, s) ->
      elab_string_literal loc wide s

let elab_simple_string loc wide chars =
  match elab_string_literal loc wide chars with
  | CStr s -> s
  | _ -> error loc "cannot use wide string literal in 'asm'"; ""


(** * Elaboration of type expressions, type specifiers, name declarations *)

(* Elaboration of attributes *)

exception Wrong_attr_arg

let elab_attr_arg loc env a =
  match a with
  | VARIABLE s ->
      begin try
        match Env.lookup_ident env s with
        | (id, II_ident(sto, ty)) ->  AIdent s
        | (id, II_enum v) -> AInt v
      with Env.Error _ ->
        AIdent s
      end
  | _ ->
      let b,env = !elab_expr_f loc env a in
      match Ceval.constant_expr env b.etyp b with
      | Some(CInt(n, _, _)) -> AInt n
      | Some(CStr s) -> AString s
      | _ -> raise Wrong_attr_arg

let elab_gcc_attr_word = function
  | GCC_ATTR_IDENT s -> s
  | GCC_ATTR_CONST -> "const"
  | GCC_ATTR_PACKED -> "__packed__"

let elab_gcc_attr loc env = function
  | GCC_ATTR_EMPTY -> []
  | GCC_ATTR_NOARGS w ->
      let v = elab_gcc_attr_word w in
      [Attr(v, [])]
  | GCC_ATTR_ARGS (w, args) ->
      let v = elab_gcc_attr_word w in
      begin try
        [Attr(v, List.map (elab_attr_arg loc env) args)]
      with Wrong_attr_arg ->
        warning loc Unknown_attribute
          "unknown attribute '%s' ignored" v; []
      end

let is_power_of_two n = n > 0L && Int64.logand n (Int64.pred n) = 0L

let extract_alignas loc a =
  match a with
  | Attr(("aligned"|"__aligned__"), args) ->
      begin match args with
      | [AInt n] when is_power_of_two n  -> AAlignas (Int64.to_int n)
      | [AInt n] -> error loc "requested alignment is not a power of 2"; a
      | [_] -> error loc "requested alignment is not an integer constant"; a
      | [] -> a (* Use the default alignment as the gcc does *)
      | _ -> error loc "'aligned' attribute takes no more than 1 argument"; a
      end
  | _ -> a

let elab_attribute env = function
  | GCC_ATTR (l, loc) ->
      List.fold_left add_attributes []
        (List.map (fun attr -> [attr])
           (List.map (extract_alignas loc)
              (List.flatten
                 (List.map (elab_gcc_attr loc env) l))))
  | PACKED_ATTR (args, loc) ->
      [Attr("__packed__", List.map (elab_attr_arg loc env) args)]
  | ALIGNAS_ATTR ([a], loc) ->
      begin match elab_attr_arg loc env a with
      | AInt n ->
          if is_power_of_two n then
            [AAlignas (Int64.to_int n)]
          else begin
            error loc "requested alignment is not a power of 2"; []
          end
      | _ -> error loc "requested alignment is not an integer constant"; []
      | exception Wrong_attr_arg -> error loc "bad _Alignas value"; []
      end
  | ALIGNAS_ATTR (_, loc) ->
      error loc "_Alignas takes no more than 1 argument"; []

let elab_attributes env al =
  List.fold_left add_attributes [] (List.map (elab_attribute env) al)

(* Auxiliary for typespec elaboration *)

let typespec_rank = function (* Don't change this *)
  | Cabs.Tvoid -> 0
  | Cabs.Tsigned -> 1
  | Cabs.Tunsigned -> 2
  | Cabs.Tchar -> 3
  | Cabs.Tshort -> 4
  | Cabs.Tlong -> 5
  | Cabs.Tint -> 6
  | Cabs.Tfloat -> 8
  | Cabs.Tdouble -> 9
  | Cabs.T_Bool -> 10
  | _ -> 11 (* There should be at most one of the others *)

let typespec_order t1 t2 = compare (typespec_rank t1) (typespec_rank t2)

(* Is a specifier an anonymous struct/union in the sense of ISO C2011? *)

let is_anonymous_composite spec =
  List.exists
    (function SpecType(Tstruct_union(_, None, Some _, _)) -> true
            | _ -> false)
    spec

(* Elaboration of a type specifier.  Returns 5-tuple:
     (storage class, "inline" flag, "typedef" flag, elaborated type, new env)
   Optional argument "only" is true if this is a standalone
   struct or union declaration, without variable names.
   C99 section 6.7.2.
*)

let rec elab_specifier keep_ty ?(only = false) loc env specifier =
  (* We first divide the parts of the specifier as follows:
       - a storage class
       - a set of attributes (const, volatile, restrict)
       - a list of type specifiers *)
  let sto = ref Storage_default
  and inline = ref false
  and noreturn = ref false
  and attr = ref []
  and tyspecs = ref []
  and typedef = ref false in

  let do_specifier = function
  | SpecCV cv ->
      attr := add_attributes (elab_cvspec env cv) !attr
  | SpecStorage st ->
      if !sto <> Storage_default && st <> TYPEDEF then
        error loc "multiple storage-classes in declaration specifier";
      begin match st with
      | AUTO -> ()
      | STATIC -> sto := Storage_static
      | EXTERN -> sto := Storage_extern
      | REGISTER -> sto := Storage_register
      | TYPEDEF ->
          if !typedef then
            error loc "multiple uses of 'typedef'";
          typedef := true
      end
  | SpecFunction INLINE -> inline := true
  | SpecFunction NORETURN -> noreturn := true
  | SpecType tys -> tyspecs := tys :: !tyspecs in

  List.iter do_specifier specifier;

  let simple ty = (!sto, !inline, !noreturn ,!typedef, add_attributes_type !attr ty, env) in

  (* As done in CIL, partition !attr into type-related attributes,
     which are returned, and other attributes, which are left in !attr.
     The returned type-related attributes are applied to the
     struct/union/enum being defined.
     The leftover non-type-related attributes will be applied
     to the variable being defined. *)
  let get_type_attrs () =
    let (ta, nta) = List.partition attr_is_type_related !attr in
    attr := nta;
    ta in

  (* Now interpret the list of type specifiers.  Much of this code
     is stolen from CIL. *)
  match List.stable_sort typespec_order (List.rev !tyspecs) with
    | [Cabs.Tvoid] -> simple (TVoid [])

    | [Cabs.T_Bool] -> simple (TInt(IBool, []))
    | [Cabs.Tchar] -> simple (TInt(IChar, []))
    | [Cabs.Tsigned; Cabs.Tchar] -> simple (TInt(ISChar, []))
    | [Cabs.Tunsigned; Cabs.Tchar] -> simple (TInt(IUChar, []))

    | [Cabs.Tshort] -> simple (TInt(IShort, []))
    | [Cabs.Tsigned; Cabs.Tshort] -> simple (TInt(IShort, []))
    | [Cabs.Tshort; Cabs.Tint] -> simple (TInt(IShort, []))
    | [Cabs.Tsigned; Cabs.Tshort; Cabs.Tint] -> simple (TInt(IShort, []))

    | [Cabs.Tunsigned; Cabs.Tshort] -> simple (TInt(IUShort, []))
    | [Cabs.Tunsigned; Cabs.Tshort; Cabs.Tint] -> simple (TInt(IUShort, []))

    | [] -> simple (TInt(IInt, []))
    | [Cabs.Tint] -> simple (TInt(IInt, []))
    | [Cabs.Tsigned] -> simple (TInt(IInt, []))
    | [Cabs.Tsigned; Cabs.Tint] -> simple (TInt(IInt, []))

    | [Cabs.Tunsigned] -> simple (TInt(IUInt, []))
    | [Cabs.Tunsigned; Cabs.Tint] -> simple (TInt(IUInt, []))

    | [Cabs.Tlong] -> simple (TInt(ILong, []))
    | [Cabs.Tsigned; Cabs.Tlong] -> simple (TInt(ILong, []))
    | [Cabs.Tlong; Cabs.Tint] -> simple (TInt(ILong, []))
    | [Cabs.Tsigned; Cabs.Tlong; Cabs.Tint] -> simple (TInt(ILong, []))

    | [Cabs.Tunsigned; Cabs.Tlong] -> simple (TInt(IULong, []))
    | [Cabs.Tunsigned; Cabs.Tlong; Cabs.Tint] -> simple (TInt(IULong, []))

    | [Cabs.Tlong; Cabs.Tlong] -> simple (TInt(ILongLong, []))
    | [Cabs.Tsigned; Cabs.Tlong; Cabs.Tlong] -> simple (TInt(ILongLong, []))
    | [Cabs.Tlong; Cabs.Tlong; Cabs.Tint] -> simple (TInt(ILongLong, []))
    | [Cabs.Tsigned; Cabs.Tlong; Cabs.Tlong; Cabs.Tint] -> simple (TInt(ILongLong, []))

    | [Cabs.Tunsigned; Cabs.Tlong; Cabs.Tlong] -> simple (TInt(IULongLong, []))
    | [Cabs.Tunsigned; Cabs.Tlong; Cabs.Tlong; Cabs.Tint] -> simple (TInt(IULongLong, []))

    | [Cabs.Tfloat] -> simple (TFloat(FFloat, []))
    | [Cabs.Tdouble] -> simple (TFloat(FDouble, []))

    | [Cabs.Tlong; Cabs.Tdouble] -> simple (TFloat(FLongDouble, []))

    (* Now the other type specifiers *)

    | [Cabs.Tnamed id] ->
        let (id', info) = wrap Env.lookup_typedef loc env id in
        simple (TNamed(id', []))

    | [Cabs.Tstruct_union(STRUCT, id, optmembers, a)] ->
        let a' =
          add_attributes (get_type_attrs()) (elab_attributes env a) in
        let (id', env') =
          elab_struct_or_union keep_ty only Struct loc id optmembers a' env in
        (!sto, !inline, !noreturn, !typedef, TStruct(id', !attr), env')

    | [Cabs.Tstruct_union(UNION, id, optmembers, a)] ->
        let a' =
          add_attributes (get_type_attrs()) (elab_attributes env a) in
        let (id', env') =
          elab_struct_or_union keep_ty only Union loc id optmembers a' env in
        (!sto, !inline, !noreturn, !typedef, TUnion(id', !attr), env')

    | [Cabs.Tenum(id, optmembers, a)] ->
        let a' =
          add_attributes (get_type_attrs()) (elab_attributes env a) in
        let (id', env') =
          elab_enum only loc id optmembers a' env in
        (!sto, !inline, !noreturn, !typedef, TEnum(id', !attr), env')

    (* Specifier doesn't make sense *)
    | _ ->
        fatal_error loc "illegal combination of type specifiers"

(* Elaboration of a type qualifier. *)

and elab_cvspec env = function
  | CV_CONST -> [AConst]
  | CV_VOLATILE -> [AVolatile]
  | CV_RESTRICT -> [ARestrict]
  | CV_ATTR attr -> elab_attribute env attr

and elab_cvspecs env cv_specs =
  List.fold_left add_attributes [] (List.map (elab_cvspec env) cv_specs)

(* Elaboration of a type declarator.  C99 section 6.7.5. *)
and elab_return_type loc env ty =
  match unroll env ty with
  | TArray _ ->
      error loc "function cannot return array type %a" (print_typ env) ty
  | TFun _ ->
      error loc "function cannot return function type %a" (print_typ env) ty
  | _ -> ()

and elab_type_declarator keep_ty loc env ty kr_ok = function
  | Cabs.JUSTBASE ->
      ((ty, None), env)
  | Cabs.ARRAY(d, cv_specs, sz) ->
      let a = elab_cvspecs env cv_specs in
      let sz' =
        match sz with
        | None ->
            None
        | Some sz ->
            let expr,env = (!elab_expr_f loc env sz) in
            match Ceval.integer_expr env expr  with
            | Some n ->
                if n < 0L then error loc "size of array is negative";
                if n = 0L then warning loc Zero_length_array
                    "zero size arrays are an extension";
                Some n
            | None ->
                error loc "size of array is not a compile-time constant";
                Some 1L in (* produces better error messages later *)
       elab_type_declarator  keep_ty  loc env (TArray(ty, sz', a)) kr_ok  d
  | Cabs.PTR(cv_specs, d) ->
      let a = elab_cvspecs env cv_specs in
      elab_type_declarator keep_ty  loc env (TPtr(ty, a)) kr_ok d
  | Cabs.PROTO(d, (params, vararg)) ->
      elab_return_type loc env ty;
      let params',env' = elab_parameters keep_ty env params in
      let env = if  keep_ty then Env.add_types env env' else env in
      elab_type_declarator  keep_ty  loc env (TFun(ty, Some params', vararg, [])) kr_ok d
  | Cabs.PROTO_OLD(d, params) ->
      elab_return_type loc env ty;
      match params with
      | [] ->
        elab_type_declarator  keep_ty loc env (TFun(ty, None, false, [])) kr_ok d
      | _ ->
        if not kr_ok || d <> Cabs.JUSTBASE then
          fatal_error loc "illegal old-style K&R function definition";
        ((TFun(ty, None, false, []), Some params), env)

(* Elaboration of parameters in a prototype *)

and elab_parameters  keep_ty env params =
  (* Prototype introduces a new scope *)
  let (vars, env) = mmap (elab_parameter  keep_ty) (Env.new_scope env) params in
  (* Catch special case f(t) where t is void or a typedef to void *)
  match vars with
    | [ ( {C.name=""}, t) ] when is_void_type env t -> [],env
    | _ -> vars,env

(* Elaboration of a function parameter *)

and elab_parameter keep_ty env (PARAM (spec, id, decl, attr, loc)) =
  let (sto, inl, noret, tydef, bty, env1) = elab_specifier keep_ty loc env spec in
  if tydef then
    error loc "'typedef' used in function parameter";
  let ((ty, _), _) = elab_type_declarator keep_ty loc env1 bty false decl in
  let ty = add_attributes_type (elab_attributes env attr) ty in
  if sto <> Storage_default && sto <> Storage_register then
    error loc
      "invalid storage-class specifier in function declarator";
  if inl then
    error loc "'inline' can only appear on functions";
  if noret then
    error loc "'_Noreturn' can only appear on functions";
  let id = match id with None -> "" | Some id -> id in
  if id <> "" && redef Env.lookup_ident env id then
    error loc "redefinition of parameter '%s'" id;
  (* replace array and function types by pointer types *)
  let ty1 = argument_conversion env1 ty in
  let (id', env2) = Env.enter_ident env1 id sto ty1 in
  ( (id', ty1) , env2)

(* Elaboration of a (specifier, Cabs "name") pair *)

and elab_fundef_name keep_ty env spec (Name (id, decl, attr, loc)) =
  let (sto, inl, noret, tydef, bty, env') = elab_specifier keep_ty loc env spec in
  if tydef then
    error loc "'typedef' is forbidden here";
  let ((ty, kr_params), env'') = elab_type_declarator keep_ty loc env' bty true decl in
  let a = elab_attributes env attr in
  (id, sto, inl, noret, add_attributes_type a ty, kr_params, env'')

(* Elaboration of a name group.  C99 section 6.7.6 *)

and elab_name_group keep_ty loc env  (spec, namelist) =
  let (sto, inl, noret, tydef, bty, env') =
    elab_specifier keep_ty loc env spec in
  if tydef then
    error loc "'typedef' is forbidden here";
  if inl then
    error loc "'inline' is forbidden here";
  if noret then
    error loc "'_Noreturn' is forbidden here";
  let elab_one_name env (Name (id, decl, attr, loc)) =
    let ((ty, _), env1) =
      elab_type_declarator keep_ty loc env bty false  decl in
    let a = elab_attributes env attr in
    ((id, add_attributes_type a ty), env1) in
  (mmap elab_one_name env' namelist, sto)

(* Elaboration of an init-name group *)

and elab_init_name_group keep_ty loc env (spec, namelist) =
  let (sto, inl, noret, tydef, bty, env') =
    elab_specifier keep_ty ~only:(namelist=[]) loc env spec in
  let elab_one_name env (Init_name (Name (id, decl, attr, loc), init)) =
    let ((ty, _), env1) =
      elab_type_declarator keep_ty loc env bty false  decl in
    let a = elab_attributes env attr in
    if inl && not (is_function_type env ty) then
      error loc "'inline' can only appear on functions";
    if noret && not (is_function_type env ty) then
      error loc "'_Noreturn' can only appear on functions";
    ((id, add_attributes_type a ty, init), env1) in
  (mmap elab_one_name env' namelist, sto, tydef)

(* Elaboration of a field group *)

and elab_field_group keep_ty env (Field_group (spec, fieldlist, loc)) =

  let fieldlist = List.map (
    function
      | (None, x) -> (Name ("", JUSTBASE, [], cabslu), x)
      | (Some n, x) -> (n, x))
    fieldlist
  in

  let ((names, env'), sto) =
    elab_name_group keep_ty loc env  (spec, List.map fst fieldlist) in

  if sto <> Storage_default then
    error loc "non-default storage in struct or union";
  if fieldlist = [] then
    if is_anonymous_composite spec then
       warning loc Celeven_extension  "anonymous structs/unions are a C11 extension"
    else
      (* This should actually never be triggered, empty structs are captured earlier *)
      warning loc Missing_declarations "declaration does not declare anything";

  let elab_bitfield (Name (_, _, _, loc), optbitsize) (id, ty) =
    let optbitsize' =
      match optbitsize with
      | None -> None
      | Some sz ->
          let ik =
            match unroll env' ty with
            | TInt(ik, _) -> ik
            | TEnum(_, _) -> enum_ikind
            | _ -> ILongLong (* trigger next error message *) in
          if integer_rank ik > integer_rank IInt then begin
            error loc
              "the type of bit-field '%s' must be an integer type no bigger than 'int'" id;
            None
          end else begin
            let expr,env' =(!elab_expr_f loc env sz) in
            match Ceval.integer_expr env' expr with
            | Some n ->
                if n < 0L then begin
                  error loc "bit-field '%s' has negative width (%Ld)" id n;
                  None
                end else
                  let max = Int64.of_int(sizeof_ikind ik * 8) in
                  if n >  max then begin
                    error loc "size of bit-field '%s' (%Ld bits) exceeds its type (%Ld bits)" id n max;
                    None
                end else
                if n = 0L && id <> "" then begin
                  error loc "named bit-field '%s' has zero width" id;
                  None
                end else
                  Some(Int64.to_int n)
            | None ->
                error loc "bit-field '%s' width not an integer constant" id;
                None
          end in
    { fld_name = id; fld_typ = ty; fld_bitfield = optbitsize' }
  in
  (List.map2 elab_bitfield fieldlist names, env')

(* Elaboration of a struct or union. C99 section 6.7.2.1 *)

and elab_struct_or_union_info keep_ty kind loc env members attrs =
  let (m, env') = mmap (elab_field_group keep_ty) env members in
  let m = List.flatten m in
  ignore (List.fold_left (fun acc fld ->
    let n = fld.fld_name in
    if n <> "" then begin
      if List.exists ((=) n) acc then
        error loc "duplicate member '%s'" n;
      n::acc
    end else begin
      if Cutil.is_composite_type env fld.fld_typ then
        warning loc Celeven_extension  "anonymous structs/unions are a C11 extension";
      acc end) [] m);
  (* Check for incomplete types *)
  let rec check_incomplete = function
  | [] -> ()
  | [ { fld_typ = TArray(ty_elt, None, _) } ] when kind = Struct -> ()
        (* C99: ty[] allowed as last field of a struct *)
  | fld :: rem ->
      if wrap incomplete_type loc env' fld.fld_typ then
        (* Must be fatal otherwise we get problems constructing the init *)
        fatal_error loc "member '%s' has incomplete type" fld.fld_name;
      check_incomplete rem in
  check_incomplete m;
  (* Warn for empty structs or unions *)
  if m = [] then
    if kind = Struct then begin
      warning loc Gnu_empty_struct "empty struct is a GNU extension"
    end else begin
      fatal_error loc "empty union is a GNU extension"
    end;
  (composite_info_def env' kind attrs m, env')

and elab_struct_or_union keep_ty only kind loc tag optmembers attrs env =
  let warn_attrs () =
    if attrs <> [] then
      warning loc Unnamed "attribute declaration must precede definition" in
  let optbinding, tag =
    match tag with
      | None -> None, ""
      | Some s ->
          Env.lookup_composite env s, s
  in
  match optbinding, optmembers with
  | Some(tag', ci), None
    when (not only) || Env.in_current_scope env tag' ->
      (* Reference to an already declared struct or union.
         Special case: if this is an "only" declaration (without variable names)
         and the composite was bound in another scope,
         create a new incomplete composite instead via the case
         "_, None" below. *)
      if ci.ci_kind <> kind then
        fatal_error loc "use of '%s' with tag type that does not match previous declaration" tag;
      warn_attrs();
      (tag', env)
  | Some(tag', ({ci_sizeof = None} as ci)), Some members
    when Env.in_current_scope env tag' ->
      if ci.ci_kind <> kind then
        error loc "use of '%s' with tag type that does not match previous declaration" tag;
      (* finishing the definition of an incomplete struct or union *)
      let (ci', env') = elab_struct_or_union_info keep_ty kind loc env members attrs in
      (* Emit a global definition for it *)
      emit_elab env' loc (Gcompositedef(kind, tag', attrs, ci'.ci_members));
      (* Replace infos but keep same ident *)
      (tag', Env.add_composite env' tag' ci')
  | Some(tag', {ci_sizeof = Some _}), Some _
    when Env.in_current_scope env tag' ->
      error loc "redefinition of struct or union '%s'" tag;
      (tag', env)
  | _, None ->
      (* declaration of an incomplete struct or union *)
      if tag = "" then
        error loc "anonymous, incomplete struct or union";
      let ci = composite_info_decl kind attrs in
      (* enter it with a new name *)
      let (tag', env') = Env.enter_composite env tag ci in
      (* emit it *)
      emit_elab env' loc (Gcompositedecl(kind, tag', attrs));
      (tag', env')
  | _, Some members ->
      (* definition of a complete struct or union *)
      let ci1 = composite_info_decl kind attrs in
      (* enter it, incomplete, with a new name *)
      let (tag', env') = Env.enter_composite env tag ci1 in
      (* emit a declaration so that inner structs and unions can refer to it *)
      emit_elab env' loc (Gcompositedecl(kind, tag', attrs));
      (* elaborate the members *)
      let (ci2, env'') =
        elab_struct_or_union_info keep_ty kind loc env' members attrs in
      (* emit a definition *)
      emit_elab env'' loc (Gcompositedef(kind, tag', attrs, ci2.ci_members));
      (* Replace infos but keep same ident *)
      (tag', Env.add_composite env'' tag' ci2)

(* Elaboration of an enum item.  C99 section 6.7.2.2 *)

and elab_enum_item env ((s, exp), loc) nextval =
  let (v, exp') =
    match exp with
    | None ->
        (nextval, None)
    | Some exp ->
        let exp',env = !elab_expr_f loc env exp in
        match Ceval.integer_expr env exp' with
        | Some n -> (n, Some exp')
        | None ->
            error loc
              "value of enumerator '%s' is not an integer constant" s;
            (nextval, Some exp') in
  if redef Env.lookup_ident env s then
    error loc "'%s' redeclared as different kind of symbol" s;
  if redef Env.lookup_typedef env s then
    error loc "'%s' redeclared as different kind of symbol" s;
  if not (int_representable v (8 * sizeof_ikind enum_ikind) (is_signed_ikind enum_ikind)) then
    warning loc Constant_conversion "integer literal '%Ld' is too large to be represented in any integer type"
      v;
  let (id, env') = Env.enter_enum_item env s v in
  ((id, v, exp'), Int64.succ v, env')

(* Elaboration of an enumeration declaration.   C99 section 6.7.2.2  *)

and elab_enum only loc tag optmembers attrs env =
  let tag = match tag with None -> "" | Some s -> s in
  match optmembers with
  | None ->
    if only then
      fatal_error loc
         "forward declaration of 'enum %s' is not allowed in ISO C" tag;
      let (tag', info) = wrap Env.lookup_enum loc env tag in (tag', env)
  | Some members ->
      if tag <> "" && redef Env.lookup_enum env tag then
        error loc "redefinition of 'enum %s'" tag;
      let rec elab_members env nextval = function
      | [] -> ([], env)
      | hd :: tl ->
          let (dcl1, nextval1, env1) = elab_enum_item env hd nextval in
          let (dcl2, env2) = elab_members env1 nextval1 tl in
          (dcl1 :: dcl2, env2) in
      let (dcls, env') = elab_members env 0L members in
      let info = { ei_members = dcls; ei_attr = attrs } in
      let (tag', env'') = Env.enter_enum env' tag info in
      emit_elab env' loc (Genumdef(tag', attrs, dcls));
      (tag', env'')

(* Elaboration of a naked type, e.g. in a cast *)

let elab_type loc env spec decl =
  let (sto, inl, noret, tydef, bty, env') = elab_specifier false loc env spec in
  let ((ty, _), env'') = elab_type_declarator false loc env' bty false decl in
  if sto <> Storage_default || inl || noret || tydef then
    error loc "'typedef', 'extern', 'static', 'register' and 'inline' are meaningless in cast";
  (ty, env'')


(* Elaboration of initializers. C99 section 6.7.8 *)

let init_char_array_string opt_size s =
  let len = Int64.of_int (String.length s) in
  let size =
    match opt_size with
    | Some sz -> sz
    | None -> Int64.succ len  (* include final 0 character *) in
  let rec add_chars i init =
    if i < 0L then init else begin
      let c =
        if i < len then Int64.of_int (Char.code s.[Int64.to_int i]) else 0L in
      add_chars (Int64.pred i) (Init_single (intconst c IInt) :: init)
    end in
  Init_array (add_chars (Int64.pred size) [])

let init_int_array_wstring opt_size s =
  let a = Array.of_list s in
  let len = Int64.of_int (Array.length a) in
  let size =
    match opt_size with
    | Some sz -> sz
    | None -> Int64.succ len  (* include final 0 character *) in
  let rec add_chars i init =
    if i < 0L then init else begin
      let c = if i < len then a.(Int64.to_int i) else 0L in
      add_chars (Int64.pred i) (Init_single (intconst c IInt) :: init)
    end in
  Init_array (add_chars (Int64.pred size) [])

let check_init_type loc env a ty =
  if wrap2 valid_assignment loc env a ty then ()
  else if wrap2 valid_cast loc env a.etyp ty then
    if wrap2 int_pointer_conversion loc env a.etyp ty then
      warning loc Int_conversion
        "incompatible integer-pointer conversion initializer has type %a instead of the expected type %a"
         (print_typ env) a.etyp (print_typ env) ty
    else
      warning loc Unnamed
        "incompatible conversion initializer has type %a instead of the expected type %a"
        (print_typ env) a.etyp (print_typ env) ty
  else
    error loc
      "initializer has type %a instead of the expected type %a"
      (print_typ env) a.etyp (print_typ env) ty

(* Representing initialization state using zippers *)

module I = struct

  type zipinit =
    | Ztop of string * typ

    | Zarray of zipinit                 (* ancestor *)
              * typ                     (* type of elements *)
              * int64 option            (* size *)
              * init                    (* default initializer *)
              * init list               (* elements before point, reversed *)
              * int64                   (* position of point *)
              * init list               (* elements after point *)

    | Zstruct of zipinit                (* ancestor *)
               * ident                  (* struct type *)
               * (field * init) list    (* elements before current, reversed *)
               * field                  (* current field *)
               * (field * init) list    (* elements after current *)

    | Zunion of zipinit                 (* ancestor *)
              * ident                   (* union type *)
              * field                   (* current member *)

  (* The initial state: default initialization, current point at top *)
  let top env name ty = (Ztop(name, ty), default_init env ty)

  (* Change the initializer for the current point *)
  let set (z, i) i' = (z, i')

  (* Put the current point back to the top *)
  let rec to_top = function
    | Ztop(name, ty), i as zi -> zi
    | Zarray(z, ty, sz, dfl, before, idx, after), i ->
        to_top (z, Init_array (List.rev_append before (i :: after)))
    | Zstruct(z, id, before, fld, after), i ->
        to_top (z, Init_struct(id, List.rev_append before ((fld, i) :: after)))
    | Zunion(z, id, fld), i ->
        to_top (z, Init_union(id, fld, i))

  (* Extract the initializer corresponding to the current state *)
  let to_init zi = snd (to_top zi)

  (* The type of the current point *)
  let typeof = function
    | Ztop(name, ty), i -> ty
    | Zarray(z, ty, sz, dfl, before, idx, after), i -> ty
    | Zstruct(z, id, before, fld, after), i -> fld.fld_typ
    | Zunion(z, id, fld), i -> fld.fld_typ

  (* The name of the path leading to the current point, for error reporting *)
  let rec zipname = function
    | Ztop(name, ty) -> name
    | Zarray(z, ty, sz, dfl, before, idx, after) ->
        sprintf "%s[%Ld]" (zipname z) idx
    | Zstruct(z, id, before, fld, after) ->
        sprintf "%s.%s" (zipname z) fld.fld_name
    | Zunion(z, id, fld) ->
        sprintf "%s.%s" (zipname z) fld.fld_name

  let name (z, i) = zipname z

  (* Auxiliary functions to deal with arrays *)
  let index_below (idx: int64) (sz: int64 option) =
    match sz with None -> true | Some sz -> idx < sz

  let il_head dfl = function [] -> dfl | i1 :: il -> i1
  let il_tail = function [] -> [] | i1 :: il -> il

  (* Advance the current point to the next point in right-up order.
     Return None if no next point, i.e. we are at top *)
  let rec next = function
    | Ztop(name, ty), i -> None
    | Zarray(z, ty, sz, dfl, before, idx, after), i ->
        let idx' = Int64.succ idx in
        if index_below idx' sz
        then Some(Zarray(z, ty, sz, dfl, i :: before, idx', il_tail after),
                  il_head dfl after)
        else next (z, Init_array (List.rev_append before (i :: after)))
    | Zstruct(z, id, before, fld, []), i ->
        next (z, Init_struct(id, List.rev_append before [(fld, i)]))
    | Zstruct(z, id, before, fld, (fld1, i1) :: after), i ->
        Some(Zstruct(z, id, (fld, i) :: before, fld1, after), i1)
    | Zunion(z, id, fld), i ->
        next (z, Init_union(id, fld, i))

  (* Move the current point "down" to the first component of an array,
     struct, or union.  No effect if the current point is a scalar. *)
  let rec first env (z, i as zi) =
    let ty = typeof zi in
    match unroll env ty, i with
    | TArray(ty, sz, _), Init_array il ->
        if index_below 0L sz then begin
          let dfl = default_init env ty in
          Some(Zarray(z, ty, sz, dfl, [], 0L, il_tail il), il_head dfl il)
        end
        else None
    | TStruct(id, _), Init_struct(id', []) ->
        None
    | TStruct(id, _), Init_struct(id', (fld1, i1) :: flds) ->
        Some(Zstruct(z, id, [], fld1, flds), i1)
    | TUnion(id, _), Init_union(id', fld, i) ->
        begin match (Env.find_union env id).ci_members with
        | [] -> None
        | fld1 :: _ ->
            Some(Zunion(z, id, fld1),
                 if fld.fld_name = fld1.fld_name
                 then i
                 else default_init env fld1.fld_typ)
        end
    | (TStruct _ | TUnion _), Init_single a ->
        (* This is a previous whole-struct initialization that we
           are going to overwrite.  Revert to the default initializer. *)
        first env (z, default_init env ty)
    | _ ->
        Some (z, i)

  (* Move to the [n]-th element of the current point, which must be
     an array. *)
  let index env (z, i as zi) n =
    match unroll env (typeof zi), i with
    | TArray(ty, sz, _), Init_array il ->
        if n >= 0L && index_below n sz then begin
          let dfl = default_init env ty in
          let rec loop p before after =
            if p = n then
              Some(Zarray(z, ty, sz, dfl, before, n, il_tail after),
                   il_head dfl after)
            else
              loop (Int64.succ p)
                   (il_head dfl after :: before)
                   (il_tail after)
          in loop 0L [] il
        end else
          None
    | _, _ ->
        None

  (* Move to the member named [name] of the current point, which must be
     a struct or a union. *)
  let rec member env (z, i as zi) name =
    let ty = typeof zi in
    match unroll env ty, i with
    | TStruct(id, _), Init_struct(id', flds) ->
        let rec find before = function
          | [] -> None
          | (fld, i as f_i) :: after ->
              if fld.fld_name = name then
                Some(Zstruct(z, id, before, fld, after), i)
              else
                find (f_i :: before) after
        in find [] flds
    | TUnion(id, _), Init_union(id', fld, i) ->
        if fld.fld_name = name then
          Some(Zunion(z, id, fld), i)
        else begin
          let rec find = function
            | [] -> None
            | fld1 :: rem ->
                if fld1.fld_name = name then
                  Some(Zunion(z, id, fld1), default_init env fld1.fld_typ)
                else
                  find rem
           in find (Env.find_union env id).ci_members
         end
    | (TStruct _ | TUnion _), Init_single a ->
        member env (z, default_init env ty) name
    | _, _ ->
        None
end

(* Interpret the given designator, moving the initialization state [zi]
   "down" accordingly. *)

let rec elab_designator loc env zi desig =
  match desig with
  | [] ->
      zi
  | INFIELD_INIT name :: desig' ->
      begin match I.member env zi name with
      | Some zi' ->
          elab_designator loc env zi' desig'
      | None ->
          error loc "%s has no member named %s" (I.name zi) name;
          raise Exit
      end
  | ATINDEX_INIT a :: desig' ->
      let expr,env = (!elab_expr_f loc env a) in
      begin match Ceval.integer_expr env expr with
      | None ->
          error loc "array element designator for %s is not an integer constant expression" (I.name zi);
          raise Exit
      | Some n ->
          match I.index env zi n with
          | Some zi' ->
              elab_designator loc env zi' desig'
          | None ->
              error loc "array index %Ld within %s exceeds array bounds" n (I.name zi);
            raise Exit
      end

(* Elaboration of an initialization expression.  Return the corresponding
   initializer. *)

let elab_init loc env root ty_root ie =

(* Perform the initializations described by the list [il] over
   the initialization state [zi].  [first] is true if we are at the
   beginning of a braced initializer.  Returns the final initializer. *)

let rec elab_list zi il first =
  match il with
  | [] ->
      (* All initialization items consumed. *)
      I.to_init zi
  | (desig, item) :: il' ->
      if desig = [] then begin
        match (if first then I.first env zi else I.next zi)
        with
        | None ->
            warning loc Unnamed "excess elements in initializer for %s"
                        (I.name zi);
            I.to_init zi
        | Some zi' ->
            elab_item zi' item il'
      end else
        elab_item (elab_designator loc env (I.to_top zi) desig) item il'

(* Perform the initialization described by [item] for the current
   subobject of state [zi].  Continue initializing with the list [il]. *)

and elab_item zi item il =
  let ty = I.typeof zi in
  match item, unroll env ty with
  (* Special case char array = "string literal"
               or wchar array = L"wide string literal" *)
  | (SINGLE_INIT (CONSTANT (CONST_STRING(w, s)))
     | COMPOUND_INIT [_, SINGLE_INIT(CONSTANT (CONST_STRING(w, s)))]),
    TArray(ty_elt, sz, _)
    when is_integer_type env ty_elt ->
      begin match elab_string_literal loc w s, unroll env ty_elt with
      | CStr s, TInt((IChar | ISChar | IUChar), _) ->
          if not (I.index_below (Int64.of_int(String.length s - 1)) sz) then
            warning loc Unnamed "initializer string for array of chars %s is too long" (I.name zi);
          elab_list (I.set zi (init_char_array_string sz s)) il false
      | CStr _, _ ->
          error loc "initialization of an array of non-char elements with a string literal";
          elab_list zi il false
      | CWStr s, TInt(_, _) when compatible_types AttrIgnoreTop env ty_elt (TInt(wchar_ikind(), [])) ->
          if not (I.index_below (Int64.of_int(List.length s - 1)) sz) then
            warning loc Unnamed "initializer string for array of wide chars %s is too long" (I.name zi);
          elab_list (I.set zi (init_int_array_wstring sz s)) il false
      | CWStr _, _ ->
          error loc "initialization of an array of non-wchar_t elements with a wide string literal";
          elab_list zi il false
      | _ -> assert false
      end
  (* Brace-enclosed compound initializer *)
  | COMPOUND_INIT il', _ ->
      (* Process the brace-enclosed stuff, obtaining its initializer *)
      let ini' = elab_list (I.top env (I.name zi) ty) il' true in
      (* Initialize current subobject with this state, and continue *)
      elab_list (I.set zi ini') il false
  (* Single expression *)
  | SINGLE_INIT a, _ ->
      let a',_ = !elab_expr_f loc env a in
      elab_single zi a' il
  (* No initializer: can this happen? *)
  | NO_INIT, _ ->
      elab_list zi il false

(* Perform initialization by a single expression [a] for the current
   subobject of state [zi],  Continue initializing with the list [il']. *)

and elab_single zi a il =
  let ty = I.typeof zi in
  match unroll env ty with
  | TInt _ | TEnum _ | TFloat _ | TPtr _ ->
      (* This is a scalar: do direct initialization and continue *)
      check_init_type loc env a ty;
      elab_list (I.set zi (Init_single a)) il false
  | TStruct _ | TUnion _ when compatible_types AttrIgnoreTop env ty a.etyp ->
      (* This is a composite that can be initialized directly
         from the expression: do as above *)
      elab_list (I.set zi (Init_single a)) il false
  | TStruct _ | TUnion _ | TArray _ ->
      (* This is an aggregate: we need to drill into it, recursively *)
      begin match I.first env zi with
      | Some zi' ->
          elab_single zi' a il
      | None ->
          error loc "initializer for aggregate %s with no elements requires explicit braces"
                    (I.name zi);
          raise Exit
      end
  | _ ->
      error loc "impossible to initialize %s of type %a"
                (I.name zi) (print_typ env) ty;
      raise Exit

(* Start with top-level object initialized to default *)

in
if is_function_type env ty_root then begin
  error loc "illegal initializer (only variables can be initialized)";
  raise Exit
end;
try
  elab_item (I.top env root ty_root) ie []
with No_default_init ->
  error loc "variable has incomplete type %a" Cprint.typ ty_root;
  raise Exit

(* Elaboration of a top-level initializer *)

let elab_initial loc env root ty ie =
  match ie with
  | NO_INIT -> None
  | _ ->
    try
      Some (elab_init loc env root ty ie)
    with
    | Exit -> None  (* error was already reported *)
    | Env.Error msg -> error loc "%s" (Env.error_message msg); None

(* Complete an array type with the size obtained from the initializer:
   "int x[] = { 1, 2, 3 }" becomes "int x[3] = ..." *)

let fixup_typ loc env ty init =
  match unroll env ty, init with
  | TArray(ty_elt, None, attr), Init_array il ->
      if il = [] then warning loc Zero_length_array "zero size arrays are an extension";
      TArray(ty_elt, Some(Int64.of_int(List.length il)), attr)
  | _ -> ty

(* Entry point *)

let elab_initializer loc env root ty ie =
  match elab_initial loc env root ty ie with
  | None ->
      (ty, None)
  | Some init ->
      (fixup_typ loc env ty init, Some init)


(* Elaboration of expressions *)

let elab_expr vararg loc env a =

  let err fmt = error loc fmt in  (* non-fatal error *)
  let error fmt = fatal_error loc fmt in
  let warning t fmt =
    warning loc t fmt in

  let check_ptr_arith env ty s =
    match unroll env ty with
    | TVoid _ ->
        err "illegal arithmetic on a pointer to void in binary '%c'" s
    | TFun _ ->
        err "illegal arithmetic on a pointer to the function type %a in binary '%c'"  (print_typ env) ty s
    | _ -> if incomplete_type env ty then
        err "arithmetic on a pointer to an incomplete type %a in binary '%c'" (print_typ env) ty s
  in

  let rec elab env = function

(* 6.5.1 Primary expressions *)

  | VARIABLE s ->
      begin match wrap Env.lookup_ident loc env s with
      | (id, II_ident(sto, ty)) ->
          { edesc = EVar id; etyp = ty },env
      | (id, II_enum v) ->
          { edesc = EConst(CEnum(id, v)); etyp = TInt(enum_ikind, []) },env
      end

  | CONSTANT cst ->
      let cst' = elab_constant loc cst in
      { edesc = EConst cst'; etyp = type_of_constant cst' },env

(* 6.5.2 Postfix expressions *)

  | INDEX(a1, a2) ->            (* e1[e2] *)
      let b1,env = elab env a1 in
      let b2,env = elab env a2 in
      let tres =
        match (unroll env b1.etyp, unroll env b2.etyp) with
        | (TPtr(t, _) | TArray(t, _, _)), (TInt _ | TEnum _) -> t
        | (TInt _ | TEnum _), (TPtr(t, _) | TArray(t, _, _)) -> t
        | t1, t2 -> error "subscripted value is neither an array nor pointer" in
      { edesc = EBinop(Oindex, b1, b2, TPtr(tres, [])); etyp = tres },env

  | MEMBEROF(a1, fieldname) ->
      let b1,env = elab env a1 in
      let (fld, attrs) =
        match unroll env b1.etyp with
        | TStruct(id, attrs) ->
            (wrap Env.find_struct_member loc env (id, fieldname), attrs)
        | TUnion(id, attrs) ->
            (wrap Env.find_union_member loc env (id, fieldname), attrs)
        | _ ->
            error "request for member '%s' in something not a structure or union" fieldname in
      (* A field of a const/volatile struct or union is itself const/volatile *)
      { edesc = EUnop(Odot fieldname, b1);
        etyp = add_attributes_type (List.filter attr_inherited_by_members attrs)
                                   (type_of_member env fld) },env

  | MEMBEROFPTR(a1, fieldname) ->
      let b1,env = elab env a1 in
      let (fld, attrs) =
        match unroll env b1.etyp with
        | TPtr(t, _) | TArray(t,_,_) ->
            begin match unroll env t with
            | TStruct(id, attrs) ->
                (wrap Env.find_struct_member loc env (id, fieldname), attrs)
            | TUnion(id, attrs) ->
                (wrap Env.find_union_member loc env (id, fieldname), attrs)
            | _ ->
                error "request for member '%s' in something not a structure or union" fieldname
            end
        | _ ->
            error "member reference type %a is not a pointer" (print_typ env) b1.etyp in
      { edesc = EUnop(Oarrow fieldname, b1);
        etyp = add_attributes_type (List.filter attr_inherited_by_members attrs)
                                   (type_of_member env fld) },env

(* Hack to treat vararg.h functions the GCC way.  Helps with testing.
    va_start(ap,n)
      (preprocessing) --> __builtin_va_start(ap, arg)
      (elaboration)   --> __builtin_va_start(ap)
    va_arg(ap, ty)
      (preprocessing) --> __builtin_va_arg(ap, ty)
      (elaboration)   --> __builtin_va_arg(ap, sizeof(ty))
*)
  | CALL((VARIABLE "__builtin_va_start" as a1), [a2; a3]) ->
      if not vararg then
        err "'va_start' used in function with fixed args";
      let b1,env = elab env a1 in
      let b2,env = elab env a2 in
      let _b3,env = elab env a3 in
      { edesc = ECall(b1, [b2]);
        etyp = TVoid [] },env

  | BUILTIN_VA_ARG (a2, a3) ->
      let ident =
        match wrap Env.lookup_ident loc env "__builtin_va_arg" with
          | (id, II_ident(sto, ty)) -> { edesc = EVar id; etyp = ty }
          | _ -> assert false
      in
      let b2,env = elab env a2 in
      let b3,env = elab env (TYPE_SIZEOF a3) in
      let ty = match b3.edesc with ESizeof ty -> ty | _ -> assert false in
      let ty' = default_argument_conversion env ty in
      if not (compatible_types AttrIgnoreTop env ty ty') then
        warning Varargs "%a is promoted to %a when passed through '...'. You should pass %a, not %a, to 'va_arg'"
          (print_typ env) ty (print_typ env) ty'  (print_typ env) ty'  (print_typ env) ty;
      { edesc = ECall(ident, [b2; b3]); etyp = ty },env

  | CALL(a1, al) ->
      let b1,env =
        (* Catch the old-style usage of calling a function without
           having declared it *)
        match a1 with
        | VARIABLE n when not (Env.ident_is_bound env n) ->
            warning Implicit_function_declaration "implicit declaration of function '%s' is invalid in C99" n;
            let ty = TFun(TInt(IInt, []), None, false, []) in
            (* Check against other definitions and enter in env *)
            let (id, sto, env, ty, linkage) =
              enter_or_refine_ident true loc env n Storage_extern ty in
            (* Emit an extern declaration for it *)
            emit_elab ~linkage env loc (Gdecl(sto, id, ty, None));
            { edesc = EVar id; etyp = ty },env
        | _ -> elab env a1 in
      let bl = mmap  elab env al in
      (* Extract type information *)
      let (res, args, vararg) =
        match unroll env b1.etyp with
        | TFun(res, args, vararg, a) -> (res, args, vararg)
        | TPtr(ty, a) ->
            begin match unroll env ty with
            | TFun(res, args, vararg, a) -> (res, args, vararg)
            | _ -> error "called object type %a is neither a function nor function pointer" (print_typ env) b1.etyp
            end
        | _ -> error "called object type %a is neither a function nor function pointer" (print_typ env) b1.etyp
      in
      (* Type-check the arguments against the prototype *)
      let bl',env =
        match args with
        | None -> bl
        | Some proto -> elab_arguments 1 bl proto vararg in
      { edesc = ECall(b1, bl'); etyp = res },env

  | UNARY(POSINCR, a1) ->
      elab_pre_post_incr_decr Opostincr "increment" a1
  | UNARY(POSDECR, a1) ->
      elab_pre_post_incr_decr Opostdecr "decrement" a1

(* 6.5.4 Cast operators *)

  | CAST ((spec, dcl), SINGLE_INIT a1) ->
      let (ty, env) = elab_type loc env spec dcl in
      let b1,env = elab env a1 in
      if not (wrap2 valid_cast loc env b1.etyp ty) then
        begin match unroll env b1.etyp, unroll env ty with
        | _, (TStruct _|TUnion _ | TVoid _) ->
            err "used type %a where arithmetic or pointer type is required"
              (print_typ env) ty
        | (TStruct _| TUnion _ | TVoid _),_ ->
            err "operand of type %a where arithmetic or pointer type is required"
              (print_typ env) b1.etyp
        | TFloat _, TPtr _  ->
            err "operand of type %a cannot be cast to a pointer type"
              (print_typ env) b1.etyp
        | TPtr _ , TFloat _ ->
            err "pointer cannot be cast to type %a" (print_typ env) ty
        | _ ->
            err "illegal cast from %a to %a" (print_typ env) b1.etyp (print_typ env) ty
        end;
      { edesc = ECast(ty, b1); etyp = ty },env

(* 6.5.2.5 Compound literals *)

  | CAST ((spec, dcl), ie) ->
      let (ty, env) = elab_type loc env spec dcl in
      begin match elab_initializer loc env "<compound literal>" ty ie with
      | (ty', Some i) -> { edesc = ECompound(ty', i); etyp = ty' },env
      | (ty', None)   -> error "ill-formed compound literal"
      end

(* 6.5.3 Unary expressions *)

  | EXPR_SIZEOF a1 ->
      let b1,env = elab env a1 in
      if wrap incomplete_type loc env b1.etyp then
        error "invalid application of 'sizeof' to an incomplete type %a" (print_typ env) b1.etyp;
      let bdesc =
        (* Catch special cases sizeof("string literal") *)
        match b1.edesc with
        | EConst(CStr s) ->
            let sz = String.length s + 1 in
            EConst(CInt(Int64.of_int sz, size_t_ikind(), ""))
        | EConst(CWStr s) ->
            let sz = (!config).sizeof_wchar * (List.length s + 1) in
            EConst(CInt(Int64.of_int sz, size_t_ikind(), ""))
        | _ ->
            ESizeof b1.etyp in
      { edesc = bdesc; etyp = TInt(size_t_ikind(), []) },env

  | TYPE_SIZEOF (spec, dcl) ->
      let (ty, env') = elab_type loc env spec dcl in
      if wrap incomplete_type loc env' ty then
        error "invalid application of 'sizeof' to an incomplete type %a" (print_typ env) ty;
      { edesc = ESizeof ty; etyp = TInt(size_t_ikind(), []) },env'

  | EXPR_ALIGNOF a1 ->
      let b1,env = elab env a1 in
      if wrap incomplete_type loc env b1.etyp then
        error "invalid application of 'alignof' to an incomplete type %a" (print_typ env) b1.etyp;
      { edesc = EAlignof b1.etyp; etyp =  TInt(size_t_ikind(), []) },env

  | TYPE_ALIGNOF (spec, dcl) ->
      let (ty, env') = elab_type loc env spec dcl in
      if wrap incomplete_type loc env' ty then
        error "invalid application of 'alignof' to an incomplete type %a" (print_typ env) ty;
      { edesc = EAlignof ty; etyp =  TInt(size_t_ikind(), []) },env'

  | UNARY(PLUS, a1) ->
      let b1,env = elab env a1 in
      if not (is_arith_type env b1.etyp) then
        error "invalid argument type %a to unary '+'" (print_typ env) b1.etyp;
      { edesc = EUnop(Oplus, b1); etyp = unary_conversion env b1.etyp },env

  | UNARY(MINUS, a1) ->
      let b1,env = elab env a1 in
      if not (is_arith_type env b1.etyp) then
        error "invalid argument type %a to unary '-'" (print_typ env) b1.etyp;
      { edesc = EUnop(Ominus, b1); etyp = unary_conversion env b1.etyp },env

  | UNARY(BNOT, a1) ->
      let b1,env = elab env a1 in
      if not (is_integer_type env b1.etyp) then
        error "invalid argument type %a to unary '~'" (print_typ env) b1.etyp;
      { edesc = EUnop(Onot, b1); etyp = unary_conversion env b1.etyp },env

  | UNARY(NOT, a1) ->
      let b1,env = elab env a1 in
      if not (is_scalar_type env b1.etyp) then
        error "invalid argument type %a to unary '!'" (print_typ env) b1.etyp;
      { edesc = EUnop(Olognot, b1); etyp = TInt(IInt, []) },env

  | UNARY(ADDROF, a1) ->
      let b1,env = elab env a1 in
      if not (is_lvalue b1 || is_function_type env b1.etyp) then
        err "argument of '&' is not an lvalue (invalid %a)" (print_typ env) b1.etyp;
      begin match b1.edesc with
      | EVar id ->
          begin match wrap Env.find_ident loc env id with
          | Env.II_ident(Storage_register, _) ->
              err "address of register variable '%s' requested" id.name
          | _ -> ()
          end
      | EUnop(Odot f, b2) ->
          let fld = wrap2 field_of_dot_access loc env b2.etyp f in
          if fld.fld_bitfield <> None then
            err "address of bit-field '%s' requested" f
      | EUnop(Oarrow f, b2) ->
          let fld = wrap2 field_of_arrow_access loc env b2.etyp f in
          if fld.fld_bitfield <> None then
            err "address of bit-field '%s' requested" f
      | _ -> ()
      end;
      { edesc = EUnop(Oaddrof, b1); etyp = TPtr(b1.etyp, []) },env

  | UNARY(MEMOF, a1) ->
      let b1,env = elab env a1 in
      begin match unroll env b1.etyp with
      (* '*' applied to a function type has no effect *)
      | TFun _ -> b1,env
      | TPtr(ty, _) | TArray(ty, _, _) ->
          { edesc = EUnop(Oderef, b1); etyp = ty },env
      | _ ->
          error "arguemnt of unary '*' is not a pointer (%a invalid)"
            (print_typ env) b1.etyp
      end

  | UNARY(PREINCR, a1) ->
      elab_pre_post_incr_decr Opreincr "increment" a1
  | UNARY(PREDECR, a1) ->
      elab_pre_post_incr_decr Opredecr "decrement" a1

(* 6.5.5 to 6.5.12  Binary operator expressions *)

  | BINARY(MUL, a1, a2) ->
      elab_binary_arithmetic "*" Omul a1 a2

  | BINARY(DIV, a1, a2) ->
      elab_binary_arithmetic "/" Odiv a1 a2

  | BINARY(MOD, a1, a2) ->
      elab_binary_integer "%" Omod a1 a2

  | BINARY(ADD, a1, a2) ->
      let b1,env = elab env a1 in
      let b2,env = elab env a2 in
      let tyres =
        if is_arith_type env b1.etyp && is_arith_type env b2.etyp then
          binary_conversion env b1.etyp b2.etyp
        else begin
          let ty =
            match unroll env b1.etyp, unroll env b2.etyp with
            | (TPtr(ty, a) | TArray(ty, _, a)), (TInt _ | TEnum _) -> ty
            | (TInt _ | TEnum _), (TPtr(ty, a) | TArray(ty, _, a)) -> ty
            | _, _ -> error "invalid operands to binary '+' (%a and %a)"
                  (print_typ env) b1.etyp (print_typ env) b2.etyp
          in
          check_ptr_arith env ty '+';
          TPtr(ty, [])
        end in
      { edesc = EBinop(Oadd, b1, b2, tyres); etyp = tyres },env

  | BINARY(SUB, a1, a2) ->
      let b1,env = elab env a1 in
      let b2,env = elab env a2 in
      let (tyop, tyres) =
        if is_arith_type env b1.etyp && is_arith_type env b2.etyp then begin
          let tyres = binary_conversion env b1.etyp b2.etyp in
          (tyres, tyres)
        end else begin
          match wrap unroll loc env b1.etyp, wrap  unroll loc env b2.etyp with
          | (TPtr(ty, a) | TArray(ty, _, a)), (TInt _ | TEnum _) ->
              if not (wrap pointer_arithmetic_ok loc env ty) then
                err "illegal pointer arithmetic in binary '-'";
              (TPtr(ty, []), TPtr(ty, []))
          | (TInt _ | TEnum _), (TPtr(ty, a) | TArray(ty, _, a)) ->
              check_ptr_arith env ty '-';
              (TPtr(ty, []), TPtr(ty, []))
          | (TPtr(ty1, a1) | TArray(ty1, _, a1)),
            (TPtr(ty2, a2) | TArray(ty2, _, a2)) ->
              if not (compatible_types AttrIgnoreAll env ty1 ty2) then
                err "%a and %a are not pointers to compatible types"
                   (print_typ env) b1.etyp (print_typ env) b1.etyp;
              check_ptr_arith env ty1 '-';
              if wrap sizeof loc env ty1 = Some 0 then
                err "subtraction between two pointers to zero-sized objects";
              (TPtr(ty1, []), TInt(ptrdiff_t_ikind(), []))
          | _, _ -> error "invalid operands to binary '-' (%a and %a)"
                (print_typ env) b1.etyp (print_typ env) b2.etyp
        end in
      { edesc = EBinop(Osub, b1, b2, tyop); etyp = tyres },env

  | BINARY(SHL, a1, a2) ->
      elab_shift "<<" Oshl a1 a2

  | BINARY(SHR, a1, a2) ->
      elab_shift ">>" Oshr a1 a2

  | BINARY(EQ, a1, a2) ->
      elab_comparison Oeq a1 a2
  | BINARY(NE, a1, a2) ->
      elab_comparison One a1 a2
  | BINARY(LT, a1, a2) ->
      elab_comparison Olt a1 a2
  | BINARY(GT, a1, a2) ->
      elab_comparison Ogt a1 a2
  | BINARY(LE, a1, a2) ->
      elab_comparison Ole a1 a2
  | BINARY(GE, a1, a2) ->
      elab_comparison Oge a1 a2

  | BINARY(BAND, a1, a2) ->
      elab_binary_integer "&" Oand a1 a2
  | BINARY(BOR, a1, a2) ->
      elab_binary_integer "|" Oor a1 a2
  | BINARY(XOR, a1, a2) ->
      elab_binary_integer "^" Oxor a1 a2

(* 6.5.13 and 6.5.14 Logical operator expressions *)

  | BINARY(AND, a1, a2) ->
      elab_logical_operator "&&" Ologand a1 a2
  | BINARY(OR, a1, a2) ->
      elab_logical_operator "||" Ologor a1 a2

(* 6.5.15 Conditional expressions *)
  | QUESTION(a1, a2, a3) ->
      let b1,env = elab env a1 in
      let b2,env = elab env a2 in
      let b3,env = elab env a3 in
      if not (is_scalar_type env b1.etyp) then
        err "first argument of '?:' is not a scalar type (invalid %a)"
           (print_typ env) b1.etyp;
      begin match pointer_decay env b2.etyp, pointer_decay env b3.etyp with
      | (TInt _ | TFloat _ | TEnum _), (TInt _ | TFloat _ | TEnum _) ->
          { edesc = EConditional(b1, b2, b3);
            etyp = binary_conversion env b2.etyp b3.etyp },env
      | (TPtr(ty1, a1) as pty1), (TPtr(ty2, a2)  as pty2) ->
          let tyres =
            if is_void_type env ty1 || is_void_type env ty2 then
              TPtr(TVoid (add_attributes a1 a2), [])
            else
              match combine_types AttrIgnoreAll env
                                  (TPtr(ty1, a1)) (TPtr(ty2, a2)) with
              | None ->
                  warning Pointer_type_mismatch "the second and third argument of '?:' have incompatible pointer types (%a and %a)"
                     (print_typ env) pty1  (print_typ env) pty2;
                  (* tolerance *)
                  TPtr(TVoid (add_attributes a1 a2), [])
              | Some ty -> ty
            in
          { edesc = EConditional(b1, b2, b3); etyp = tyres },env
      | TPtr(ty1, a1), TInt _ when is_literal_0 b3 ->
          { edesc = EConditional(b1, b2, nullconst); etyp = TPtr(ty1, []) },env
      | TInt _, TPtr(ty2, a2) when is_literal_0 b2 ->
          { edesc = EConditional(b1, nullconst, b3); etyp = TPtr(ty2, []) },env
      | ty1, ty2 ->
          match combine_types AttrIgnoreAll env ty1 ty2 with
          | None ->
              error "the second and third argument of '?:' incompatible types (%a and %a)"
                 (print_typ env) ty1  (print_typ env) ty2
          | Some tyres ->
              { edesc = EConditional(b1, b2, b3); etyp = tyres },env
      end

(* 6.5.16 Assignment expressions *)

  | BINARY(ASSIGN, a1, a2) ->
      let b1,env = elab env a1 in
      let b2,env = elab env a2 in
      if List.mem AConst (attributes_of_type env b1.etyp) then
        error "left-hand side of assignment has 'const' type";
      if not (is_modifiable_lvalue env b1) then
        err "expression is not assignable";
      if not (wrap2 valid_assignment loc env b2 b1.etyp) then begin
        if wrap2 valid_cast loc env b2.etyp b1.etyp then
          if wrap2 int_pointer_conversion loc env b2.etyp b1.etyp then
            warning Int_conversion
              "incompatible integer-pointer conversion: assigning to %a from %a"
              (print_typ env) b1.etyp (print_typ env) b2.etyp
          else
            warning Unnamed
              "incompatible conversion assigning to %a from %a"
               (print_typ env) b1.etyp (print_typ env) b2.etyp
        else
          err "assigning to %a from incompatible type %a"
            (print_typ env) b1.etyp  (print_typ env) b2.etyp;
      end;
      { edesc = EBinop(Oassign, b1, b2, b1.etyp); etyp = b1.etyp },env

  | BINARY((ADD_ASSIGN | SUB_ASSIGN | MUL_ASSIGN | DIV_ASSIGN | MOD_ASSIGN
            | BAND_ASSIGN | BOR_ASSIGN | XOR_ASSIGN | SHL_ASSIGN | SHR_ASSIGN
            as op), a1, a2) ->
      let (sop, top) =
        match op with
        | ADD_ASSIGN -> (ADD, Oadd_assign)
        | SUB_ASSIGN -> (SUB, Osub_assign)
        | MUL_ASSIGN -> (MUL, Omul_assign)
        | DIV_ASSIGN -> (DIV, Odiv_assign)
        | MOD_ASSIGN -> (MOD, Omod_assign)
        | BAND_ASSIGN -> (BAND, Oand_assign)
        | BOR_ASSIGN -> (BOR, Oor_assign)
        | XOR_ASSIGN -> (XOR, Oxor_assign)
        | SHL_ASSIGN -> (SHL, Oshl_assign)
        | SHR_ASSIGN -> (SHR, Oshr_assign)
        | _ -> assert false in
      begin match elab env (BINARY(sop, a1, a2)) with
      | ({ edesc = EBinop(_, b1, b2, _); etyp = ty } as b),env  ->
          if List.mem AConst (attributes_of_type env b1.etyp) then
            err "left-hand side of assignment has 'const' type";
          if not (is_modifiable_lvalue env b1) then
            err "expression is not assignable";
          if not (wrap2 valid_assignment loc env b b1.etyp) then begin
            if wrap2 valid_cast loc env ty b1.etyp then
              if wrap2 int_pointer_conversion loc env ty b1.etyp then
                warning Int_conversion
                  "incompatible integer-pointer conversion: assigning to %a from %a"
                   (print_typ env) b1.etyp  (print_typ env) ty
              else
                warning Unnamed
                  "incompatible conversion assigning to %a from %a"
                  (print_typ env) b1.etyp (print_typ env) ty
            else
              err "assigning to %a from incompatible type %a"
                 (print_typ env) b1.etyp (print_typ env) ty;
          end;
          { edesc = EBinop(top, b1, b2, ty); etyp = b1.etyp },env
      | _ -> assert false
      end

(* 6.5.17 Sequential expressions *)

  | BINARY(COMMA, a1, a2) ->
      let b1,env = elab env a1 in
      let b2,env = elab env a2 in
      { edesc = EBinop (Ocomma, b1, b2, b2.etyp); etyp = b2.etyp },env

(* Elaboration of pre- or post- increment/decrement *)
  and elab_pre_post_incr_decr op msg a1 =
    let b1,env = elab env a1 in
    if not (is_modifiable_lvalue env b1) then
      err "expression is not assignable";
    if not (is_scalar_type env b1.etyp) then
      err "cannot %s value of type %a" msg (print_typ env) b1.etyp;
    { edesc = EUnop(op, b1); etyp = b1.etyp },env

(* Elaboration of binary operators over integers *)
  and elab_binary_integer msg op a1 a2 =
    let b1,env = elab env a1 in
    let b2,env = elab env a2 in
    if not ((is_integer_type env b1.etyp) && (is_integer_type env b2.etyp)) then
      error "invalid operands to binary '%s' (%a and %a)" msg
        (print_typ env) b1.etyp (print_typ env) b2.etyp;
    let tyres = binary_conversion env b1.etyp b2.etyp in
    { edesc = EBinop(op, b1, b2, tyres); etyp = tyres },env

(* Elaboration of binary operators over arithmetic types *)
  and elab_binary_arithmetic msg op a1 a2 =
    let b1,env = elab env a1 in
    let b2,env = elab env a2 in
    if not ((is_arith_type env b1.etyp) && (is_arith_type env b2.etyp)) then
      error "invalid operands to binary '%s' (%a and %a)" msg
        (print_typ env) b1.etyp (print_typ env) b2.etyp;
    let tyres = binary_conversion env b1.etyp b2.etyp in
    { edesc = EBinop(op, b1, b2, tyres); etyp = tyres },env

(* Elaboration of shift operators *)
  and elab_shift msg op a1 a2 =
    let b1,env = elab env a1 in
    let b2,env = elab env a2 in
    if not ((is_integer_type env b1.etyp) && (is_integer_type env b2.etyp)) then
      error "invalid operands to '%s' (%a and %a)" msg
        (print_typ env) b1.etyp (print_typ env) b2.etyp;
    let tyres = unary_conversion env b1.etyp in
    { edesc = EBinop(op, b1, b2, tyres); etyp = tyres },env

(* Elaboration of comparisons *)
  and elab_comparison op a1 a2 =
      let b1,env = elab env a1 in
      let b2,env = elab env a2 in
      let resdesc =
        match pointer_decay env b1.etyp, pointer_decay env b2.etyp with
        | (TInt _ | TFloat _ | TEnum _), (TInt _ | TFloat _ | TEnum _) ->
            EBinop(op, b1, b2, binary_conversion env b1.etyp b2.etyp)
        | TInt _, TPtr(ty, _) when is_literal_0 b1 ->
            EBinop(op, nullconst, b2, TPtr(ty, []))
        | TPtr(ty, _), TInt _ when is_literal_0 b2 ->
            EBinop(op, b1, nullconst, TPtr(ty, []))
        | TPtr(ty1, _), TPtr(ty2, _)
          when is_void_type env ty1 ->
            EBinop(op, b1, b2, TPtr(ty2, []))
        | TPtr(ty1, _), TPtr(ty2, _)
          when is_void_type env ty2 ->
            EBinop(op, b1, b2, TPtr(ty1, []))
        | TPtr(ty1, _), TPtr(ty2, _) ->
            if not (compatible_types AttrIgnoreAll env ty1 ty2) then
              warning Compare_distinct_pointer_types "comparison of distinct pointer types (%a and %a)"
                (print_typ env) b1.etyp (print_typ env) b2.etyp;
            EBinop(op, b1, b2, TPtr(ty1, []))
        | TPtr _, (TInt _ | TEnum _)
        | (TInt _ | TEnum _), TPtr _ ->
            warning Unnamed "comparison between pointer and integer (%a and %a)"
              (print_typ env) b1.etyp (print_typ env) b2.etyp;
            EBinop(op, b1, b2, TPtr(TVoid [], []))
        | ty1, ty2 ->
            error "illegal comparison between types@ %a@ and %a"
              (print_typ env) b1.etyp (print_typ env) b2.etyp; in
      { edesc = resdesc; etyp = TInt(IInt, []) },env

(* Elaboration of && and || *)
  and elab_logical_operator msg op a1 a2 =
    let b1,env = elab env a1 in
    let b2,env = elab env a2 in
    if not ((is_scalar_type env b1.etyp) && (is_scalar_type env b2.etyp)) then
      error "invalid operands to binary %s (%a and %a)" msg
        (print_typ env) b1.etyp (print_typ env) b2.etyp;
    { edesc = EBinop(op, b1, b2, TInt(IInt, [])); etyp = TInt(IInt, []) },env

(* Type-checking of function arguments *)
  and elab_arguments argno args params vararg =
    match args, params with
    | ([],env), [] -> [],env
    | ([],env), _::_ ->
       let found = argno - 1 in
       let expected = List.length params + found in
       let vararg = if vararg then "at least " else "" in
       err "too few arguments to function call, expected %s%d, have %d" vararg expected found; [],env
   | (_::_,env), [] ->
        if vararg
        then args
        else
          let expected = argno - 1 in
          let found = List.length (fst args) + expected in
          (err "too many arguments to function call, expected %d, have %d" expected found; args)
    | (arg1 :: argl,env), (_, ty_p) :: paraml ->
        let ty_a = argument_conversion env arg1.etyp in
        if not (wrap2 valid_assignment loc env {arg1 with etyp = ty_a} ty_p)
        then begin
          if wrap2 valid_cast loc env ty_a ty_p then begin
            if wrap2 int_pointer_conversion loc env ty_a ty_p then
              warning Int_conversion
                "incompatible integer-pointer conversion: passing %a to parameter %d of type %a"
                (print_typ env) ty_a argno (print_typ env) ty_p
            else
              warning Unnamed
                "incompatible conversion passing %a to parameter %d of type %a"
                (print_typ env) ty_a argno (print_typ env) ty_p end
          else
            err
              "passing %a to parameter %d of incompatible type %a"
              (print_typ env) ty_a argno (print_typ env) ty_p
        end;
        let rest,env = elab_arguments (argno + 1) (argl,env) paraml vararg in
        arg1 :: rest,env
  in elab env a

(* Filling in forward declaration *)
let _ = elab_expr_f := (elab_expr false)

let elab_opt_expr vararg loc env = function
  | None -> None,env
  | Some a -> let a,env = (elab_expr vararg loc env a) in
    Some a,env

let elab_for_expr vararg loc env = function
  | None -> { sdesc = Sskip; sloc = elab_loc loc },env
  | Some a -> let a,env = elab_expr vararg loc env a in
    { sdesc = Sdo a; sloc = elab_loc loc },env

(* Handling of __func__ (section 6.4.2.2) *)

let __func__type_and_init s =
  (TArray(TInt(IChar, [AConst]), Some(Int64.of_int (String.length s + 1)), []),
   init_char_array_string None s)


(* Elaboration of top-level and local definitions *)

let enter_typedefs loc env sto dl =
  if sto <> Storage_default then
    error loc "non-default storage-class on 'typedef' definition";
  List.fold_left (fun env (s, ty, init) ->
    if init <> NO_INIT then
      error loc "initializer in typedef";
    match previous_def Env.lookup_typedef env s with
    | Some (s',ty') ->
        if equal_types env ty ty' then begin
          warning loc Cerrors.Celeven_extension "redefinition of typedef '%s' is C11 extension" s;
          env
        end else begin
          error loc "typedef redefinition with different types (%a vs %a)"
            (print_typ env) ty (print_typ env) ty';
          env
        end
    | None ->
        if redef Env.lookup_ident env s then
          error loc "redefinition of '%s' as different kind of symbol" s;
        let (id, env') = Env.enter_typedef env s ty in
        emit_elab env loc (Gtypedef(id, ty));
        env') env dl

let enter_decdefs local loc env sto dl =
  (* Sanity checks on storage class *)
  if sto = Storage_register && not local then
    fatal_error loc "'register' storage-class on file-scoped variable";
  if sto <> Storage_default && dl = [] then
    warning loc Missing_declarations "declaration does not declare anything";
  let enter_decdef (decls, env) (s, ty, init) =
    let isfun = is_function_type env ty in
    if sto = Storage_extern && init <> NO_INIT then
      error loc "'extern' declaration  variable has an initializer";
    if local && isfun then begin
      match sto with
      | Storage_static -> error loc "function declared in block scope cannot have 'static' storage-class";
      | Storage_register -> error loc "invalid 'register' storage-class on function";
      | _ -> ()
    end;
    (* Local function declarations are always treated as extern *)
    let sto1 = if local && isfun then Storage_extern else sto in
    (* enter ident in environment with declared type, because
       initializer can refer to the ident *)
    let (id, sto', env1, ty, linkage) =
      enter_or_refine_ident local loc env s sto1 ty in
    if not isfun && is_void_type env ty then
      fatal_error loc "'%s' has incomplete type" s;
    (* process the initializer *)
    let (ty', init') = elab_initializer loc env1 s ty init in
    (* update environment with refined type *)
    let env2 = Env.add_ident env1 id sto' ty' in
    (* check for incomplete type *)
    if local && sto' <> Storage_extern
             && not isfun
             && wrap incomplete_type loc env ty' then
      error loc "variable has incomplete type %a" (print_typ env) ty';
    if local && not isfun && sto' <> Storage_extern && sto' <> Storage_static then
      (* Local definition *)
      ((sto', id, ty', init') :: decls, env2)
    else begin
      (* Global definition *)
      emit_elab ~linkage env2 loc (Gdecl(sto', id, ty', init'));
      (decls, env2)
    end in
  let (decls, env') = List.fold_left enter_decdef ([], env) dl in
  (List.rev decls, env')

(* Processing of K&R-style function definitions.  Synopsis:
      T f(X1, ..., Xn)
          T1 Y1; ...; Tm Ym;
      { ... }
  "params" is the list [X1; ...; Xn]
  "defs" is the list of declarations [T1 Y1; ... Tm Ym]
  We need to match the names Xi's with the Yj's so as to find the types Ti'
  of the Xi and produce a typed argument list in prototyped style.
  Owing to default argument promotion, the types Ti' and Tj may not match,
  in which case we need to declare a local variable with the correct type.
  Consider:
      float f(x)  float x;  { return x; }
  Since float arguments are promoted by default to double, this must
  be converted as
      float f(double x)  { float x1 = x; return x1; }
*)

let elab_KR_function_parameters env params defs loc =
  (* Check that the parameters have unique names *)
  List.iter (fun id ->
    if List.length (List.filter ((=) id) params) > 1 then
      fatal_error loc "redefinition of parameter '%s'" id)
    params;
  (* Check that the declarations only declare parameters *)
  let extract_name (Init_name(Name(s, dty, attrs, loc') as name, ie)) =
    if not (List.mem s params) then
      error loc' "Declaration of '%s' which is not a function parameter" s;
    if ie <> NO_INIT then
      error loc' "illegal initialization of parameter '%s'" s;
    name
  in
  (* Extract names and types from the declarations *)
  let elab_param_def env = function
  | DECDEF((spec', name_init_list), loc') ->
      let name_list = List.map extract_name name_init_list in
      let (paramsenv, sto) = elab_name_group true loc' env (spec', name_list) in
      begin match sto with
      | Storage_extern ->
        error loc' "invalid 'extern' storage-class specifier for function parameter"
      | Storage_static ->
        error loc' "invalid 'static' storage-class specifier for function parameter"
      | _ -> ()
      end;
      paramsenv
  | d -> (* Should never be produced by the parser *)
      fatal_error (get_definitionloc d)
                      "Illegal declaration of function parameter" in
  let kr_params_defs,paramsenv =
    let params,paramsenv = mmap elab_param_def env defs in
    List.concat params,paramsenv in
  (* Find the type of a parameter *)
  let type_of_param param =
    match List.filter (fun (p, _) -> p = param) kr_params_defs with
    | [] ->
        (* Parameter is not declared, defaults to "int" in ISO C90,
           is an error in ISO C99.  Just emit a warning. *)
        warning loc Implicit_int "type of '%s' defaults to 'int'" param;
        TInt (IInt, [])
    | (_, ty) :: rem ->
        if rem <> [] then
          error loc "redefinition of parameter '%s'" param;
        ty in
  (* Match parameters against declarations *)
  let rec match_params params' extra_decls = function
    | [] ->
        (List.rev params', List.rev extra_decls)
    | p :: ps ->
        let ty = type_of_param p in
        let ty_var = argument_conversion env ty
        and ty_param = default_argument_conversion env ty in
        if compatible_types AttrIgnoreTop env ty_var ty_param then begin
          (* No need for an extra conversion *)
          let id = Env.fresh_ident p in
          match_params ((id, ty_var) :: params') extra_decls ps
        end else begin
          (* Local variable of type ty_var is to be initialized from
             the parameter of type ty_param *)
          let id_param = Env.fresh_ident p in
          let id_var = Env.fresh_ident p in
          let init = Init_single { edesc = EVar id_param; etyp = ty_param } in
          match_params ((id_param, ty_param) :: params')
                       ((Storage_default, id_var, ty_var, Some init)
                                                           :: extra_decls)
                       ps
        end
  in
  let a,b = match_params [] [] params in
  a,b,paramsenv


(* Look for varargs flag in previous definitions of a function *)

let inherit_vararg env s sto ty =
  match previous_def Env.lookup_ident env s with
  | Some(id, II_ident(_, old_ty))
    when sto = Storage_extern || Env.in_current_scope env id ->
    begin
      match old_ty, ty with
      | TFun(_, _, true, _), TFun(_, _, _, _) -> true
      | _, _ -> false
    end
  | _ -> false


(* Function definitions *)

let elab_fundef env spec name defs body loc =
  let (s, sto, inline, noret, ty, kr_params, env1) =
    elab_fundef_name true env spec name in
  if sto = Storage_register then
    fatal_error loc "invalid 'register' storage-class on function";
  begin match kr_params, defs with
  | None, d::_ ->
    error (get_definitionloc d)
      "old-style parameter declarations in prototyped function definition"
  | _ -> ()
  end;
  (* Process the parameters and the K&R declarations, if any, to obtain:
      - [ty]: the full, prototyped type of the function
      - [extra_decls]: extra declarations to be inserted at the
        beginning of the function *)
  let (ty, extra_decls,env1) =
    match ty, kr_params with
    | TFun(ty_ret, None, vararg, attr), None ->
        (TFun(ty_ret, Some [], vararg, attr), [],env1)
    | ty, None ->
        (ty, [],env1)
    | TFun(ty_ret, None, false, attr), Some params ->
        warning loc Cerrors.CompCert_conformance "non-prototype, pre-standard function definition, converting to prototype form";
        let (params', extra_decls,env) =
          elab_KR_function_parameters env params defs loc in
        (TFun(ty_ret, Some params', inherit_vararg env s sto ty, attr), extra_decls,env)
    | _, Some params ->
        assert false
  in
  (* Extract infos from the type of the function *)
  let (ty_ret, params, vararg, attr) =
    match ty with
    | TFun(ty_ret, Some params, vararg, attr) ->
         if wrap incomplete_type loc env1 ty_ret && not (is_void_type env ty_ret) then
           fatal_error loc "incomplete result type %a in function definition"
             (print_typ env) ty_ret;
        (ty_ret, params, vararg, attr)
    | _ -> fatal_error loc "wrong type for function definition" in
  (* Enter function in the environment, for recursive references *)
  let (fun_id, sto1, env1, _, _) =
    enter_or_refine_ident false loc env1 s sto ty in
  let incomplete_param env ty =
    if wrap incomplete_type loc env ty then
      fatal_error loc "parameter has incomplete type" in
  (* Enter parameters and extra declarations in the environment *)
  let env2 =
    List.fold_left (fun e (id, ty) -> incomplete_param e ty;
      Env.add_ident e id Storage_default ty)
                   (Env.new_scope env1) params in
  let env2 =
    List.fold_left (fun e (sto, id, ty, init) -> Env.add_ident e id sto ty)
                   env2 extra_decls in
  (* Define "__func__" and enter it in the environment *)
  let (func_ty, func_init) = __func__type_and_init s in
  let (func_id, _, env3, func_ty, _) =
    enter_or_refine_ident true loc env2 "__func__" Storage_static func_ty in
  emit_elab ~debuginfo:false env3 loc
                  (Gdecl(Storage_static, func_id, func_ty, Some func_init));
  (* Elaborate function body *)
  let body1 = !elab_funbody_f ty_ret vararg env3 body in
  (* Special treatment of the "main" function *)
  let body2 =
    if s = "main" then begin
      match unroll env ty_ret with
      | TInt(IInt, []) ->
          (* Add implicit "return 0;" at end of function body *)
          sseq no_loc body1
            {sdesc = Sreturn(Some(intconst 0L IInt)); sloc = no_loc}
      | _ ->
          warning loc Main_return_type "return type of 'main' should be 'int'";
          body1
    end else body1 in
  (* Add the extra declarations if any *)
  let body3 =
    if extra_decls = [] then body2 else begin
      let mkdecl d = { sdesc = Sdecl d; sloc = no_loc } in
      { sdesc = Sblock (List.map mkdecl extra_decls @ [body2]);
        sloc = no_loc }
    end in
  if noret && contains_return body1 then
    warning loc Invalid_noreturn "function '%s' declared 'noreturn' should not return" s;
  (* Build and emit function definition *)
  let fn =
    { fd_storage = sto1;
      fd_inline = inline;
      fd_name = fun_id;
      fd_attrib = attr;
      fd_ret = ty_ret;
      fd_params = params;
      fd_vararg = vararg;
      fd_locals = [];
      fd_body = body3 } in
  emit_elab ~linkage:true env1 loc (Gfundef fn);
  env1

(* Definitions *)

let rec elab_definition (local: bool) (env: Env.t) (def: Cabs.definition)
                    : decl list * Env.t =
  match def with
  (* "int f(int x) { ... }" *)
  (* "int f(x, y) double y; { ... }" *)
  | FUNDEF(spec, name, defs, body, loc) ->
      if local then error loc "function definition is not allowed here";
      let env1 = elab_fundef env spec name defs body loc in
      ([], env1)

  (* "int x = 12, y[10], *z" *)
  | DECDEF(init_name_group, loc) ->
      let ((dl, env1), sto, tydef) =
        elab_init_name_group false loc env init_name_group in
      if tydef then
        let env2 = enter_typedefs loc env1 sto dl
        in ([], env2)
      else
        enter_decdefs local loc env1 sto dl

  (* pragma *)
  | PRAGMA(s, loc) ->
      emit_elab env loc (Gpragma s);
      ([], env)

and elab_definitions local env = function
  | [] -> ([], env)
  | d1 :: dl ->
      let (decl1, env1) = elab_definition local env d1 in
      let (decl2, env2) = elab_definitions local env1 dl in
      (decl1 @ decl2, env2)

(* Extended asm *)

let elab_asm_operand vararg loc env (ASMOPERAND(label, wide, chars, e)) =
  let s = elab_simple_string loc wide chars in
  let e',env = elab_expr vararg loc env e in
  (label, s, e'),env


(* Contexts for elaborating statements *)

module StringSet = Set.Make(String)

type stmt_context = {
  ctx_return_typ: typ;          (**r return type for the function *)
  ctx_labels: StringSet.t;      (**r all labels defined in the function *)
  ctx_break: bool;              (**r is 'break' allowed? *)
  ctx_continue: bool;           (**r is 'continue' allowed? *)
  ctx_vararg: bool;             (**r is this a vararg function? *)
}

let stmt_labels stmt =
  let lbls = ref StringSet.empty in
  let rec do_stmt = function
  | BLOCK(b, _) -> do_block b
  | If(_, s1, Some s2, _) -> do_stmt s1; do_stmt s2
  | If(_, s1, None, _) -> do_stmt s1
  | WHILE(_, s1, _) -> do_stmt s1
  | DOWHILE(_, s1, _) -> do_stmt s1
  | FOR(_, _, _, s1, _) -> do_stmt s1
  | SWITCH(_, s1, _) -> do_stmt s1
  | CASE(_, s1, _) -> do_stmt s1
  | DEFAULT(s1, _) -> do_stmt s1
  | LABEL(lbl, s1, loc) ->
      if StringSet.mem lbl !lbls then
        error loc "redefinition of label '%s'\n" lbl;
      lbls := StringSet.add lbl !lbls;
      do_stmt s1
  | _ -> ()
  and do_block b = List.iter do_stmt b
  in do_stmt stmt; !lbls

let ctx_loop ctx = { ctx with ctx_break = true; ctx_continue = true }

let ctx_switch ctx = { ctx with ctx_break = true }

(* Elaboration of statements *)

let rec elab_stmt env ctx s =

  match s with

(* 6.8.3 Expression statements *)

  | COMPUTATION(a, loc) ->
      let a,env =  (elab_expr ctx.ctx_vararg loc env a) in
      { sdesc = Sdo a; sloc = elab_loc loc },env

(* 6.8.1 Labeled statements *)

  | LABEL(lbl, s1, loc) ->
      let s1,env = elab_stmt env ctx s1 in
      { sdesc = Slabeled(Slabel lbl, s1); sloc = elab_loc loc },env

  | CASE(a, s1, loc) ->
      let a',env = elab_expr ctx.ctx_vararg loc env a in
      begin match Ceval.integer_expr env a' with
        | None ->
            error loc "expression of 'case' label is not an integer constant expression"
        | Some n -> ()
      end;
      let s1,env = elab_stmt env ctx s1 in
      { sdesc = Slabeled(Scase a', s1); sloc = elab_loc loc },env

  | DEFAULT(s1, loc) ->
      let s1,env = elab_stmt env ctx s1 in
      { sdesc = Slabeled(Sdefault, s1); sloc = elab_loc loc },env

(* 6.8.2 Compound statements *)

  | BLOCK(b, loc) ->
      elab_block loc env ctx b

(* 6.8.4 Conditional statements *)

  | If(a, s1, s2, loc) ->
      let a',env = elab_expr ctx.ctx_vararg loc env a in
      if not (is_scalar_type env a'.etyp) then
        error loc "controlling expression of 'if' does not have scalar type (%a invalid)"
          (print_typ env) a'.etyp;
      let s1',env = elab_stmt env ctx s1 in
      let s2',env =
        match s2 with
          | None -> sskip,env
          | Some s2 -> elab_stmt env ctx s2
      in
      { sdesc = Sif(a', s1', s2'); sloc = elab_loc loc },env

(* 6.8.5 Iterative statements *)

  | WHILE(a, s1, loc) ->
      let a',env = elab_expr ctx.ctx_vararg loc env a in
      if not (is_scalar_type env a'.etyp) then
        error loc "controlling expression of 'while' does not have scalar type (%a invalid)"
          (print_typ env) a'.etyp;
      let s1',env = elab_stmt env (ctx_loop ctx) s1 in
      { sdesc = Swhile(a', s1'); sloc = elab_loc loc },env

  | DOWHILE(a, s1, loc) ->
      let s1',env = elab_stmt env (ctx_loop ctx) s1 in
      let a',env = elab_expr ctx.ctx_vararg loc env a in
      if not (is_scalar_type env a'.etyp) then
        error loc "controlling expression of 'while' does not have scalar type (%a invalid)"
          (print_typ env) a'.etyp;
      { sdesc = Sdowhile(s1', a'); sloc = elab_loc loc },env

  | FOR(fc, a2, a3, s1, loc) ->
      let (a1', env', decls') =
        match fc with
        | Some (FC_EXP a1) ->
            let a1,env = elab_for_expr ctx.ctx_vararg loc env (Some a1) in
            (a1, env, None)
        | None ->
            let a1,env = elab_for_expr ctx.ctx_vararg loc env None in
            (a1, env, None)
        | Some (FC_DECL def) ->
            let (dcl, env') = elab_definition true (Env.new_scope env) def in
            let loc = elab_loc (get_definitionloc def) in
            (sskip, env',
             Some(List.map (fun d -> {sdesc = Sdecl d; sloc = loc}) dcl)) in
      let a2',env =
        match a2 with
          | None -> intconst 1L IInt,env
          | Some a2 -> elab_expr ctx.ctx_vararg loc env' a2
      in
      if not (is_scalar_type env' a2'.etyp) then
        error loc "controlling expression of 'for' does not have scalar type (%a invalid)" (print_typ env) a2'.etyp;
      let a3',env' = elab_for_expr ctx.ctx_vararg loc env' a3 in
      let s1',env' = elab_stmt env' (ctx_loop ctx) s1 in
      let sfor = { sdesc = Sfor(a1', a2', a3', s1'); sloc = elab_loc loc } in
      begin match decls' with
      | None -> sfor,env
      | Some sl -> { sdesc = Sblock (sl @ [sfor]); sloc = elab_loc loc },env
      end

(* 6.8.4 Switch statement *)
  | SWITCH(a, s1, loc) ->
      let a',env = elab_expr ctx.ctx_vararg loc env a in
      if not (is_integer_type env a'.etyp) then
        error loc "controlling expression of 'switch' does not have integer type (%a invalid)"
          (print_typ env) a'.etyp;
      let s1',env = elab_stmt env (ctx_switch ctx) s1 in
      { sdesc = Sswitch(a', s1'); sloc = elab_loc loc },env

(* 6.8.6 Break and continue statements *)
  | BREAK loc ->
      if not ctx.ctx_break then
        error loc "'break' statement not in loop or switch statement";
      { sdesc = Sbreak; sloc = elab_loc loc },env
  | CONTINUE loc ->
      if not ctx.ctx_continue then
        error loc "'continue' statement not in loop statement";
      { sdesc = Scontinue; sloc = elab_loc loc },env

(* 6.8.6 Return statements *)
  | RETURN(a, loc) ->
      let a',env = elab_opt_expr ctx.ctx_vararg loc env a in
      begin match (unroll env ctx.ctx_return_typ, a') with
      | TVoid _, None -> ()
      | TVoid _, Some _ ->
          error loc
            "'return' with a value in a function returning void"
      | _, None ->
          warning loc Return_type
            "'return' with no value, in a function returning non-void"
      | _, Some b ->
          if not (wrap2 valid_assignment loc env b ctx.ctx_return_typ)
          then begin
            if wrap2 valid_cast loc env b.etyp ctx.ctx_return_typ then
              if wrap2 int_pointer_conversion loc env b.etyp ctx.ctx_return_typ then
                warning loc Int_conversion
                  "incompatible integer-pointer conversion: returning %a from a function with result type %a"
                  (print_typ env) b.etyp (print_typ env) ctx.ctx_return_typ
              else
                warning loc Unnamed
                  "incompatible conversion returning %a from a function with result type %a"
                  (print_typ env) b.etyp (print_typ env) ctx.ctx_return_typ
            else
              error loc
                "returning %a from a function with incompatible result type %a"
                (print_typ env) b.etyp (print_typ env) ctx.ctx_return_typ
          end
      end;
      { sdesc = Sreturn a'; sloc = elab_loc loc },env

(* 6.8.6 Goto statements *)
  | GOTO(lbl, loc) ->
      if not (StringSet.mem lbl ctx.ctx_labels) then
        error loc "use of undeclared label '%s'" lbl;
      { sdesc = Sgoto lbl; sloc = elab_loc loc },env

(* 6.8.3 Null statements *)
  | NOP loc ->
      { sdesc = Sskip; sloc = elab_loc loc },env

(* Traditional extensions *)
  | ASM(cv_specs, wide, chars, outputs, inputs, flags, loc) ->
      let a = elab_cvspecs env cv_specs in
      let s = elab_simple_string loc wide chars in
      let outputs,env = mmap (elab_asm_operand ctx.ctx_vararg loc) env outputs in
      let inputs ,env= mmap (elab_asm_operand ctx.ctx_vararg loc) env inputs in
      let flags = List.map (fun (w,c) -> elab_simple_string loc w c) flags in
      { sdesc = Sasm(a, s, outputs, inputs, flags);
        sloc = elab_loc loc },env

(* Unsupported *)
  | DEFINITION def ->
      error (get_definitionloc def) "ill-placed definition";
      sskip,env

and elab_block loc env ctx b =
  let b',_ = elab_block_body (Env.new_scope env) ctx b in
  { sdesc = Sblock b'; sloc = elab_loc loc },env

and elab_block_body env ctx sl =
  match sl with
  | [] ->
      [],env
  | DEFINITION def :: sl1 ->
      let (dcl, env') = elab_definition true env def in
      let loc = elab_loc (get_definitionloc def) in
      let dcl = List.map (fun ((sto,id,ty,_) as d) ->
        Debug.insert_local_declaration sto id ty loc;
        {sdesc = Sdecl d; sloc = loc}) dcl in
      let sl1',env' = elab_block_body env' ctx sl1 in
      dcl @ sl1',env'
  | s :: sl1 ->
      let s',env = elab_stmt env ctx s in
      let sl1',env = elab_block_body env ctx sl1 in
      s' :: sl1',env

(* Elaboration of a function body.  Return the corresponding C statement. *)

let elab_funbody return_typ vararg env b =
  let ctx =
    { ctx_return_typ = return_typ;
      ctx_labels = stmt_labels b;
      ctx_break = false;
      ctx_continue = false;
      ctx_vararg = vararg;} in
  fst(elab_stmt env ctx b)

(* Filling in forward declaration *)
let _ = elab_funbody_f := elab_funbody


(** * Entry point *)

let elab_file prog =
  reset();
  ignore (elab_definitions false (Builtins.environment()) prog);
  elaborated_program()
