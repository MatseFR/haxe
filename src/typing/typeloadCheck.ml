(*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 *)

(* Various checks performed while loading types. *)

open Globals
open Ast
open Type
open Typecore
open DisplayException
open DisplayTypes
open DisplayMode
open CompletionItem
open CompletionModuleKind
open CompletionModuleType
open CompletionResultKind
open Common
open Error

exception Build_canceled of build_state

let is_generic_parameter ctx c =
	(* first check field parameters, then class parameters *)
	let name = snd c.cl_path in
	try
		ignore(lookup_param name ctx.curfield.cf_params);
		has_class_field_flag ctx.curfield CfGeneric
	with Not_found -> try
		ignore(lookup_param name ctx.type_params);
		(match ctx.curclass.cl_kind with | KGeneric -> true | _ -> false);
	with Not_found ->
		false

let valid_redefinition ctx map1 map2 f1 t1 f2 t2 = (* child, parent *)
	let valid t1 t2 =
		Type.unify t1 t2;
		if is_null t1 <> is_null t2 || ((follow t1) == t_dynamic && (follow t2) != t_dynamic) then raise (Unify_error [Cannot_unify (t1,t2)]);
	in
	let open OptimizerTexpr in
	begin match PurityState.get_purity_from_meta f2.cf_meta,PurityState.get_purity_from_meta f1.cf_meta with
		| PurityState.Pure,PurityState.MaybePure -> f1.cf_meta <- (Meta.Pure,[EConst(Ident "expect"),f2.cf_pos],null_pos) :: f1.cf_meta
		| PurityState.ExpectPure p,PurityState.MaybePure -> f1.cf_meta <- (Meta.Pure,[EConst(Ident "expect"),p],null_pos) :: f1.cf_meta
		| _ -> ()
	end;
	let t1, t2 = (match f1.cf_params, f2.cf_params with
		| [], [] -> t1, t2
		| l1, l2 when List.length l1 = List.length l2 ->
			let to_check = ref [] in
			(* TPTODO: defaults *)
			let monos = List.map2 (fun tp1 tp2 ->
				(match follow tp1.ttp_type, follow tp2.ttp_type with
				| TInst ({ cl_kind = KTypeParameter ct1 } as c1,pl1), TInst ({ cl_kind = KTypeParameter ct2 } as c2,pl2) ->
					(match ct1, ct2 with
					| [], [] -> ()
					| _, _ when List.length ct1 = List.length ct2 ->
						(* if same constraints, they are the same type *)
						let check monos =
							List.iter2 (fun t1 t2  ->
								try
									let t1 = apply_params l1 monos (apply_params c1.cl_params pl1 (map2 t1)) in
									let t2 = apply_params l2 monos (apply_params c2.cl_params pl2 (map1 t2)) in
									type_eq EqStrict t1 t2
								with Unify_error l ->
									raise (Unify_error (Unify_custom "Constraints differ" :: l))
							) ct1 ct2
						in
						to_check := check :: !to_check;
					| _ ->
						raise (Unify_error [Unify_custom "Different number of constraints"]))
				| _ -> ());
				TInst (mk_class null_module ([],tp1.ttp_name) null_pos null_pos,[])
			) l1 l2 in
			List.iter (fun f -> f monos) !to_check;
			apply_params l1 monos t1, apply_params l2 monos t2
		| _  ->
			(* ignore type params, will create other errors later *)
			t1, t2
	) in
	match f1.cf_kind,f2.cf_kind with
	| Method m1, Method m2 when not (m1 = MethDynamic) && not (m2 = MethDynamic) ->
		begin match follow t1, follow t2 with
		| TFun (args1,r1) , TFun (args2,r2) -> (
			if not (List.length args1 = List.length args2) then raise (Unify_error [Unify_custom "Different number of function arguments"]);
			let i = ref 0 in
			try
				valid r1 r2;
				List.iter2 (fun (n,o1,a1) (_,o2,a2) ->
					incr i;
					if o1 <> o2 then raise (Unify_error [Not_matching_optional n]);
					(try valid a2 a1 with Unify_error _ -> raise (Unify_error [Cannot_unify(a1,a2)]))
				) args1 args2;
			with Unify_error l ->
				let msg = if !i = 0 then Invalid_return_type else Invalid_function_argument(!i,List.length args1) in
				raise (Unify_error (Cannot_unify (t1,t2) :: msg :: l)))
		| _ ->
			die "" __LOC__
		end
	| _,(Var { v_write = AccNo | AccNever }) ->
		(* write variance *)
		valid t1 t2
	| _,(Var { v_read = AccNo | AccNever }) ->
		(* read variance *)
		valid t2 t1
	| _,_ when has_class_field_flag f2 CfFinal ->
		(* write variance *)
		valid t1 t2
	| _ , _ ->
		(* in case args differs, or if an interface var *)
		type_eq EqStrict t1 t2;
		if is_null t1 <> is_null t2 then raise (Unify_error [Cannot_unify (t1,t2)])

let copy_meta meta_src meta_target sl =
	let meta = ref meta_target in
	List.iter (fun (m,e,p) ->
		if List.mem m sl then meta := (m,e,p) :: !meta
	) meta_src;
	!meta

(** retrieve string from @:native metadata or raise Not_found *)
let get_native_name meta =
	let rec get_native meta = match meta with
		| [] -> raise Not_found
		| (Meta.Native,[v],p as meta) :: _ ->
			meta
		| _ :: meta ->
			get_native meta
	in
	let (_,e,mp) = get_native meta in
	match e with
	| [Ast.EConst (Ast.String(name,_)),p] ->
		name,p
	| [] ->
		raise Not_found
	| _ ->
		typing_error "String expected" mp

let check_native_name_override ctx child base =
	let error base_pos child_pos =
		display_error ctx.com ("Field " ^ child.cf_name ^ " has different @:native value than in superclass") child_pos;
		display_error ~depth:1 ctx.com (compl_msg "Base field is defined here") base_pos
	in
	try
		let child_name, child_pos = get_native_name child.cf_meta in
		try
			let base_name, base_pos = get_native_name base.cf_meta in
			if base_name <> child_name then
				error base_pos child_pos
		with Not_found ->
			error base.cf_name_pos child_pos
	with Not_found -> ()

let check_overriding ctx c f =
	match c.cl_super with
	| None ->
		if has_class_field_flag f CfOverride then display_error ctx.com ("Field " ^ f.cf_name ^ " is declared 'override' but doesn't override any field") f.cf_pos
	| _ when (has_class_flag c CExtern) && Meta.has Meta.CsNative c.cl_meta -> () (* -net-lib specific: do not check overrides on extern CsNative classes *)
	| Some (csup,params) ->
		let p = f.cf_name_pos in
		let i = f.cf_name in
		let check_field f get_super_field is_overload = try
			(if is_overload && not (has_class_field_flag f CfOverload) then
				display_error ctx.com ("Missing overload declaration for field " ^ i) p);
			let f_has_override = has_class_field_flag f CfOverride in
			let t, f2 = get_super_field csup i in
			check_native_name_override ctx f f2;
			(* allow to define fields that are not defined for this platform version in superclass *)
			(match f2.cf_kind with
			| Var { v_read = AccRequire _ } -> raise Not_found;
			| _ -> ());
			if has_class_field_flag f2 CfAbstract then begin
				if f_has_override then
					display_error ctx.com ("Field " ^ i ^ " is declared 'override' but parent field " ^ i ^ " is 'abstract' and does not provide any implementation to override") p
				else
					add_class_field_flag f CfOverride (* our spec requires users to not "override" abstract functions, but our implementation depends on implementations to be declared with "override" ¯\_(ツ)_/¯ *)
			end;
			if (has_class_field_flag f2 CfOverload && not (has_class_field_flag f CfOverload)) then
				display_error ctx.com ("Field " ^ i ^ " should be declared with overload since it was already declared as overload in superclass") p
			else if not f_has_override && not (has_class_field_flag f2 CfAbstract) then begin
				if has_class_flag c CExtern then add_class_field_flag f CfOverride
				else display_error ctx.com ("Field " ^ i ^ " should be declared with 'override' since it is inherited from superclass " ^ s_type_path csup.cl_path) p
			end else if not (has_class_field_flag f CfPublic) && (has_class_field_flag f2 CfPublic) then
				display_error ctx.com ("Field " ^ i ^ " has less visibility (public/private) than superclass one") p
			else (match f.cf_kind, f2.cf_kind with
			| _, Method MethInline ->
				display_error ctx.com ("Field " ^ i ^ " is inlined and cannot be overridden") p
			| a, b when a = b -> ()
			| Method MethInline, Method MethNormal ->
				() (* allow to redefine a method as inlined *)
			| _ ->
				display_error ctx.com ("Field " ^ i ^ " has different property access than in superclass") p);
			if (has_class_field_flag f2 CfFinal) then display_error ctx.com ("Cannot override final method " ^ i) p;
			try
				let t = apply_params csup.cl_params params t in
				let map = TClass.get_map_function csup params in
				valid_redefinition ctx map map f f.cf_type f2 t;
			with
				Unify_error l ->
					display_error ctx.com ("Field " ^ i ^ " overrides parent class with different or incomplete type") p;
					display_error ~depth:1 ctx.com (compl_msg "Base field is defined here") f2.cf_name_pos;
					located_display_error ~depth:1 ctx.com (compl_located_msg (error_msg p (Unify l)));
		with
			Not_found ->
				if has_class_field_flag f CfOverride then
					let msg = if is_overload then
						("Field " ^ i ^ " is declared 'override' but no compatible overload was found")
					else begin
						let fields = TClass.get_all_super_fields c in
						let fields = PMap.fold (fun (_,cf) acc -> match cf.cf_kind with
							| Method MethNormal when not (has_class_field_flag cf CfFinal) -> cf.cf_name :: acc
							| _ -> acc
						) fields [] in
						StringError.string_error i fields ("Field " ^ i ^ " is declared 'override' but doesn't override any field")
					end in
					display_error ctx.com msg p
		in
		if has_class_field_flag f CfOverload then begin
			let overloads = Overloads.get_overloads ctx.com csup i in
			List.iter (fun (t,f2) ->
				(* check if any super class fields are vars *)
				match f2.cf_kind with
				| Var _ ->
					display_error ctx.com ("A variable named '" ^ f2.cf_name ^ "' was already declared in a superclass") f.cf_pos
				| _ -> ()
			) overloads;
			List.iter (fun f ->
				(* find the exact field being overridden *)
				check_field f (fun csup i ->
					List.find (fun (t,f2) ->
						Overloads.same_overload_args f.cf_type (apply_params csup.cl_params params t) f f2
					) overloads
				) true
			) (f :: f.cf_overloads)
		end else
			check_field f (fun csup i ->
				let _, t, f2 = raw_class_field (fun f -> f.cf_type) csup params i in
				t, f2) false

let class_field_no_interf c i =
	try
		let f = PMap.find i c.cl_fields in
		(fun t -> t),f.cf_type , f
	with Not_found ->
		match c.cl_super with
		| None ->
			raise Not_found
		| Some (c,tl) ->
			(* rec over class_field *)
			let _, t , f = raw_class_field (fun f -> f.cf_type) c tl i in
			let map = TClass.get_map_function c tl in
			map,apply_params c.cl_params tl t , f

let rec return_flow ctx e =
	let error() =
		display_error ctx.com (Printf.sprintf "Missing return: %s" (s_type (print_context()) ctx.ret)) e.epos; raise Exit
	in
	let return_flow = return_flow ctx in
	match e.eexpr with
	| TReturn _ | TThrow _ -> ()
	| TParenthesis e | TMeta(_,e) ->
		return_flow e
	| TBlock el ->
		let rec loop = function
			| [] -> error()
			| [e] -> return_flow e
			| e :: _ when DeadEnd.has_dead_end e -> ()
			| _ :: l -> loop l
		in
		loop el
	| TIf (_,e1,Some e2) ->
		return_flow e1;
		return_flow e2;
	| TSwitch (v,cases,Some e) ->
		List.iter (fun (_,e) -> return_flow e) cases;
		return_flow e
	| TSwitch ({eexpr = TMeta((Meta.Exhaustive,_,_),_)},cases,None) ->
		List.iter (fun (_,e) -> return_flow e) cases;
	| TTry (e,cases) ->
		return_flow e;
		List.iter (fun (_,e) -> return_flow e) cases;
	| TWhile({eexpr = (TConst (TBool true))},e,_) ->
		(* a special case for "inifite" while loops that have no break *)
		let rec loop e = match e.eexpr with
			(* ignore nested loops to not accidentally get one of its breaks *)
			| TWhile _ | TFor _ -> ()
			| TBreak -> error()
			| _ -> Type.iter loop e
		in
		loop e
	| _ ->
		if not (DeadEnd.has_dead_end e) then error()

let check_global_metadata ctx meta f_add mpath tpath so =
	let sl1 = full_dot_path2 mpath tpath in
	let sl1,field_mode = match so with None -> sl1,false | Some s -> sl1 @ [s],true in
	List.iter (fun (sl2,m,(recursive,to_types,to_fields)) ->
		let add = ((field_mode && to_fields) || (not field_mode && to_types)) && (match_path recursive sl1 sl2) in
		if add then f_add m
	) ctx.g.global_metadata;
	if ctx.is_display_file then delay ctx PCheckConstraint (fun () -> DisplayEmitter.check_display_metadata ctx meta)

let check_module_types ctx m p t =
	let t = t_infos t in
	try
		let path2 = ctx.com.type_to_module#find t.mt_path in
		if m.m_path <> path2 && String.lowercase (s_type_path path2) = String.lowercase (s_type_path m.m_path) then typing_error ("Module " ^ s_type_path path2 ^ " is loaded with a different case than " ^ s_type_path m.m_path) p;
		let m2 = ctx.com.module_lut#find path2 in
		let hex1 = Digest.to_hex m.m_extra.m_sign in
		let hex2 = Digest.to_hex m2.m_extra.m_sign in
		let s = if hex1 = hex2 then hex1 else Printf.sprintf "was %s, is %s" hex2 hex1 in
		typing_error (Printf.sprintf "Type name %s is redefined from module %s (%s)" (s_type_path t.mt_path)  (s_type_path path2) s) p
	with
		Not_found ->
			ctx.com.type_to_module#add t.mt_path m.m_path

module Inheritance = struct
	let is_basic_class_path path = match path with
		| ([],("Array" | "String" | "Date" | "Xml")) -> true
		| _ -> false

	let check_extends ctx c t p = match follow t with
		| TInst (csup,params) ->
			if is_basic_class_path csup.cl_path && not ((has_class_flag c CExtern) && (has_class_flag csup CExtern)) then typing_error "Cannot extend basic class" p;
			if extends csup c then typing_error "Recursive class" p;
			begin match csup.cl_kind with
				| KTypeParameter _ ->
					if is_generic_parameter ctx csup then typing_error "Extending generic type parameters is no longer allowed in Haxe 4" p;
					typing_error "Cannot extend type parameters" p
				| _ -> csup,params
			end
		| _ -> typing_error "Should extend by using a class" p

	let rec check_interface ctx missing c intf params =
		List.iter (fun (i2,p2) ->
			check_interface ctx missing c i2 (List.map (apply_params intf.cl_params params) p2)
		) intf.cl_implements;
		let p = c.cl_name_pos in
		let check_field f =
			let t = (apply_params intf.cl_params params f.cf_type) in
			let is_overload = ref false in
			let make_implicit_field () =
				let cf = {f with cf_overloads = []; cf_type = apply_params intf.cl_params params f.cf_type} in
				begin try
					let cf' = PMap.find cf.cf_name c.cl_fields in
					ctx.com.overload_cache#remove (c.cl_path,f.cf_name);
					cf'.cf_overloads <- cf :: cf'.cf_overloads
				with Not_found ->
					TClass.add_field c cf
				end;
				cf
			in
			let is_method () = match f.cf_kind with
				| Method _ -> true
				| Var _ -> false
			in
			try
				let map2, t2, f2 = class_field_no_interf c f.cf_name in
				let t2, f2 =
					if f2.cf_overloads <> [] || has_class_field_flag f2 CfOverload then
						let overloads = Overloads.get_overloads ctx.com c f.cf_name in
						is_overload := true;
						List.find (fun (t1,f1) -> Overloads.same_overload_args t t1 f f1) overloads
					else
						t2, f2
				in
				delay ctx PForce (fun () ->
					ignore(follow f2.cf_type); (* force evaluation *)
					let p = f2.cf_name_pos in
					let mkind = function
						| MethNormal | MethInline -> 0
						| MethDynamic -> 1
						| MethMacro -> 2
					in
					if (has_class_field_flag f CfPublic) && not (has_class_field_flag f2 CfPublic) && not (Meta.has Meta.CompilerGenerated f.cf_meta) then
						display_error ctx.com ("Field " ^ f.cf_name ^ " should be public as requested by " ^ s_type_path intf.cl_path) p
					else if not (unify_kind f2.cf_kind f.cf_kind) || not (match f.cf_kind, f2.cf_kind with Var _ , Var _ -> true | Method m1, Method m2 -> mkind m1 = mkind m2 | _ -> false) then
						display_error ctx.com ("Field " ^ f.cf_name ^ " has different property access than in " ^ s_type_path intf.cl_path ^ " (" ^ s_kind f2.cf_kind ^ " should be " ^ s_kind f.cf_kind ^ ")") p
					else try
						let map1 = TClass.get_map_function  intf params in
						valid_redefinition ctx map1 map2 f2 t2 f (apply_params intf.cl_params params f.cf_type)
					with
						Unify_error l ->
							if not (Meta.has Meta.CsNative c.cl_meta && (has_class_flag c CExtern)) then begin
								display_error ctx.com ("Field " ^ f.cf_name ^ " has different type than in " ^ s_type_path intf.cl_path) p;
								display_error ~depth:1 ctx.com (compl_msg "Interface field is defined here") f.cf_pos;
								located_display_error ~depth:1 ctx.com (compl_located_msg (error_msg p (Unify l)));
							end
				)
			with Not_found ->
				if (has_class_flag c CAbstract) && is_method() then begin
					let cf = make_implicit_field () in
					add_class_field_flag cf CfAbstract;
				end else if has_class_field_flag f CfDefault then begin
					let cf = make_implicit_field () in
					cf.cf_expr <- None;
					add_class_field_flag cf CfExtern;
					add_class_field_flag cf CfOverride;
				end else if not (has_class_flag c CInterface) then begin
					if Diagnostics.error_in_diagnostics_run ctx.com c.cl_pos then
						DynArray.add missing (f,t)
					else begin
						let msg = if !is_overload then
							let ctx = print_context() in
							let args = match follow f.cf_type with | TFun(args,_) -> String.concat ", " (List.map (fun (n,o,t) -> (if o then "?" else "") ^ n ^ " : " ^ (s_type ctx t)) args) | _ -> die "" __LOC__ in
							"No suitable overload for " ^ f.cf_name ^ "( " ^ args ^ " ), as needed by " ^ s_type_path intf.cl_path ^ " was found"
						else
							("Field " ^ f.cf_name ^ " needed by " ^ s_type_path intf.cl_path ^ " is missing")
						in
						display_error ctx.com msg p
					end
				end
		in
		let check_field _ cf =
			check_field cf;
			if has_class_field_flag cf CfOverload then
				List.iter check_field (List.rev cf.cf_overloads)
		in
		PMap.iter check_field intf.cl_fields

	let check_interfaces ctx c =
		match c.cl_path with
		| "Proxy" :: _ , _ -> ()
		| _ when (has_class_flag c CExtern) && Meta.has Meta.CsNative c.cl_meta -> ()
		| _ ->
		List.iter (fun (intf,params) ->
			let missing = DynArray.create () in
			check_interface ctx missing c intf params;
			if DynArray.length missing > 0 then begin
				let l = DynArray.to_list missing in
				let diag = {
					mf_pos = c.cl_name_pos;
					mf_on = TClassDecl c;
					mf_fields = List.map (fun (cf,t) -> (cf,t,CompletionType.from_type (Display.get_import_status ctx) t)) l;
					mf_cause = ImplementedInterface(intf,params);
				} in
				let display = ctx.com.display_information in
				display.module_diagnostics <- MissingFields diag :: display.module_diagnostics
			end
		) c.cl_implements

	let check_abstract_class ctx c csup params =
		let missing = ref [] in
		let map = apply_params csup.cl_params params in
		let check_abstract_class_field cf1 t1 =
			try
				let cf2 = PMap.find cf1.cf_name c.cl_fields in
				if not (List.exists (fun cf2 ->
					Overloads.same_overload_args t1 cf2.cf_type cf1 cf2
				) (cf2 :: cf2.cf_overloads)) then
					missing := (cf1,t1) :: !missing
			with Not_found ->
				missing := (cf1,t1) :: !missing
		in
		let cfl = TClass.get_all_fields csup params in
		PMap.iter (fun _ (_,cf) ->
			let cfl = Overloads.collect_overloads map csup cf.cf_name in
			List.iter (fun (t,cf) ->
				if (has_class_field_flag cf CfAbstract) then
					check_abstract_class_field cf t
			) cfl
		) cfl;
		match !missing with
		| [] ->
			()
		| l when Diagnostics.error_in_diagnostics_run ctx.com c.cl_pos ->
			let diag = {
				mf_pos = c.cl_name_pos;
				mf_on = TClassDecl c;
				mf_fields = List.rev_map (fun (cf,t) -> (cf,t,CompletionType.from_type (Display.get_import_status ctx) t)) l;
				mf_cause = AbstractParent(csup,params);
			} in
			let display = ctx.com.display_information in
			display.module_diagnostics <- MissingFields diag :: display.module_diagnostics
		| l ->
			let singular = match l with [_] -> true | _ -> false in
			display_error ctx.com (Printf.sprintf "This class extends abstract class %s but doesn't implement the following method%s" (s_type_path csup.cl_path) (if singular then "" else "s")) c.cl_name_pos;
			display_error ctx.com (Printf.sprintf "Implement %s or make %s abstract as well" (if singular then "it" else "them") (s_type_path c.cl_path)) c.cl_name_pos;
			let pctx = print_context() in
			List.iter (fun (cf,_) ->
				let s = match follow cf.cf_type with
					| TFun(tl,tr) ->
						String.concat ", " (List.map (fun (n,o,t) -> Printf.sprintf "%s:%s" n (s_type pctx t)) tl)
					| t ->
						s_type pctx t
				in
				display_error ~depth:1 ctx.com (compl_msg (Printf.sprintf "%s(%s)" cf.cf_name s)) cf.cf_name_pos
			) (List.rev !missing)

	let set_heritance ctx c herits p =
		let is_lib = Meta.has Meta.LibType c.cl_meta in
		let ctx = { ctx with curclass = c; type_params = c.cl_params; } in
		let old_meta = c.cl_meta in
		let process_meta csup =
			List.iter (fun m ->
				match m with
				| Meta.AutoBuild, el, p -> c.cl_meta <- (Meta.Build,el,{ c.cl_pos with pmax = c.cl_pos.pmin }(* prevent display metadata *)) :: m :: c.cl_meta
				| _ -> ()
			) csup.cl_meta;
			if has_class_flag csup CFinal && not (((has_class_flag csup CExtern) && Meta.has Meta.Hack c.cl_meta) || (match c.cl_kind with KTypeParameter _ -> true | _ -> false)) then
				typing_error ("Cannot extend a final " ^ if (has_class_flag c CInterface) then "interface" else "class") p;
		in
		let check_cancel_build csup =
			match csup.cl_build() with
			| Built -> ()
			| state ->
				(* for macros reason, our super class is not yet built - see #2177 *)
				(* let's reset our build and delay it until we are done *)
				c.cl_meta <- old_meta;
				raise (Build_canceled state)
		in
		let has_interf = ref false in
		(*
			resolve imports before calling build_inheritance, since it requires full paths.
			that means that typedefs are not working, but that's a fair limitation
		*)
		let resolve_imports (t,p) =
			match t.tpackage with
			| _ :: _ -> t,p
			| [] ->
				try
					let path_matches lt = snd (t_path lt) = t.tname in
					let lt = try
						List.find path_matches ctx.m.curmod.m_types
					with Not_found ->
						let t,pi = List.find (fun (lt,_) -> path_matches lt) ctx.m.module_imports in
						ImportHandling.mark_import_position ctx pi;
						t
					in
					{ t with tpackage = fst (t_path lt) },p
				with
					Not_found -> t,p
		in
		let herits = ExtList.List.filter_map (function
			| HExtends t -> Some(true,resolve_imports t)
			| HImplements t -> Some(false,resolve_imports t)
			| t -> None
		) herits in
		let herits = List.filter (ctx.g.do_inherit ctx c p) herits in
		(* Pass 1: Check and set relations *)
		let check_herit t is_extends p =
			let rec check_interfaces_or_delay () =
				match c.cl_build() with
				| BuildMacro pending ->
					(* Ok listen... we're still building this class, which means we can't check its interfaces yet. However,
					   we do want to check them at SOME point. So we use this pending list which was maybe designed for this
					   purpose. However, we STILL have to delay the check because at the time pending is handled, the class
					   is not built yet. See issue #10847. *)
					pending := (fun () -> delay ctx PConnectField check_interfaces_or_delay) :: !pending
				| _ ->
					check_interfaces ctx c
			in
			if is_extends then begin
				if c.cl_super <> None then typing_error "Cannot extend several classes" p;
				let csup,params = check_extends ctx c t p in
				if (has_class_flag c CInterface) then begin
					if not (has_class_flag csup CInterface) then typing_error "Cannot extend by using a class" p;
					c.cl_implements <- (csup,params) :: c.cl_implements;
					if not !has_interf then begin
						if not is_lib then delay ctx PConnectField check_interfaces_or_delay;
						has_interf := true;
					end
				end else begin
					if (has_class_flag csup CInterface) then typing_error "Cannot extend by using an interface" p;
					c.cl_super <- Some (csup,params)
				end;
				(fun () ->
					check_cancel_build csup;
					process_meta csup;
				)
			end else begin match follow t with
				| TInst ({ cl_path = [],"ArrayAccess" } as ca,[t]) when (has_class_flag ca CExtern) ->
					if c.cl_array_access <> None then typing_error "Duplicate array access" p;
					c.cl_array_access <- Some t;
					(fun () -> ())
				| TInst (intf,params) ->
					if extends intf c then typing_error "Recursive class" p;
					if (has_class_flag c CInterface) then typing_error "Interfaces cannot implement another interface (use extends instead)" p;
					if not (has_class_flag intf CInterface) then typing_error "You can only implement an interface" p;
					c.cl_implements <- (intf, params) :: c.cl_implements;
					if not !has_interf && not is_lib && not (Meta.has (Meta.Custom "$do_not_check_interf") c.cl_meta) then begin
						delay ctx PConnectField check_interfaces_or_delay;
						has_interf := true;
					end;
					(fun () ->
						check_cancel_build intf;
						process_meta intf;
					)
				| TDynamic t ->
					if c.cl_dynamic <> None then typing_error "Cannot have several dynamics" p;
					if not (has_class_flag c CExtern) then display_error ctx.com "In haxe 4, implements Dynamic is only supported on externs" p;
					c.cl_dynamic <- Some (match t with None -> t_dynamic | Some t -> t);
					(fun () -> ())
				| _ ->
					typing_error "Should implement by using an interface" p
			end
		in
		let fl = ExtList.List.filter_map (fun (is_extends,(ct,p)) ->
			try
				let t = try
					Typeload.load_instance ~allow_display:true ctx (ct,p) false
				with DisplayException(DisplayFields ({fkind = CRTypeHint} as r)) ->
					(* We don't allow `implements` on interfaces. Just raise fields completion with no fields. *)
					if not is_extends && (has_class_flag c CInterface) then raise_fields [] CRImplements r.fsubject;
					let l = List.filter (fun item -> match item.ci_kind with
						| ITType({kind = Interface} as cm,_) -> (not is_extends || (has_class_flag c CInterface)) && CompletionModuleType.get_path cm <> c.cl_path
						| ITType({kind = Class} as cm,_) ->
							is_extends && not (has_class_flag c CInterface) && CompletionModuleType.get_path cm <> c.cl_path &&
							(not cm.is_final || Meta.has Meta.Hack c.cl_meta) &&
							(not (is_basic_class_path (cm.pack,cm.name)) || ((has_class_flag c CExtern) && cm.is_extern))
						| _ -> false
					) r.fitems in
					raise_fields l (if is_extends then CRExtends else CRImplements) r.fsubject
				in
				Some (check_herit t is_extends p)
			with Error(Module_not_found(([],name)),p,_) when ctx.com.display.dms_kind <> DMNone ->
				if Diagnostics.error_in_diagnostics_run ctx.com p then DisplayToplevel.handle_unresolved_identifier ctx name p true;
				None
		) herits in
		fl
end

let check_final_vars ctx e =
	let final_vars = Hashtbl.create 0 in
	List.iter (fun cf -> match cf.cf_kind with
		| Var _ when (has_class_field_flag cf CfFinal) && cf.cf_expr = None ->
			Hashtbl.add final_vars cf.cf_name cf
		| _ ->
			()
	) ctx.curclass.cl_ordered_fields;
	if Hashtbl.length final_vars > 0 then begin
		let rec find_inits e = match e.eexpr with
			| TBinop(OpAssign,{eexpr = TField({eexpr = TConst TThis},fa)},e2) ->
				Hashtbl.remove final_vars (field_name fa);
				find_inits e2;
			| _ ->
				Type.iter find_inits e
		in
		find_inits e;
		Hashtbl.iter (fun _ cf ->
			display_error ctx.com ("final field " ^ cf.cf_name ^ " must be initialized immediately or in the constructor") cf.cf_pos;
		) final_vars
	end
