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

(* Type instance and type parameter handling. *)

open Ast
open Common
open DisplayTypes.DisplayMode
open DisplayTypes.CompletionResultKind
open CompletionItem
open CompletionModuleType
open CompletionModuleKind
open ClassFieldOrigin
open DisplayException
open Type
open Typecore
open Error
open Globals
open Filename

let build_count = ref 0

let type_function_params_rec = ref (fun _ _ _ _ -> die "" __LOC__)

let check_field_access ctx cff =
	let display_access = ref None in
	let rec loop p0 acc l =
		let check_display p1 =
			let pmid = {p0 with pmin = p0.pmax; pmax = p1.pmin} in
			if DisplayPosition.display_position#enclosed_in pmid then match acc with
			| access :: _ -> display_access := Some access;
			| [] -> ()
		in
		match l with
		| [] ->
			(* This is a bit dodgy. Ideally we would use the position of the `function` keyword, but we don't have that...
			   Using the name means this is going to complete within the `function` keyword too. Not sure what we
			   can do about it. *)
			check_display (pos (cff.cff_name))
		| (access,p1) :: l ->
			check_display p1;
			try
				let _,p2 = List.find (fun (access',_) -> access = access') acc in
				if p1 <> null_pos && p2 <> null_pos then begin
					display_error ctx.com (Printf.sprintf "Duplicate access modifier %s" (Ast.s_access access)) p1;
					display_error ~depth:1 ctx.com (compl_msg "Previously defined here") p2;
				end;
				loop p1 acc l
			with Not_found -> match access with
				| APublic | APrivate ->
					begin try
						let _,p2 = List.find (fun (access',_) -> match access' with APublic | APrivate -> true | _ -> false) acc in
						display_error ctx.com (Printf.sprintf "Conflicting access modifier %s" (Ast.s_access access)) p1;
						display_error ~depth:1 ctx.com (compl_msg "Conflicts with this") p2;
						loop p1 acc l
					with Not_found ->
						loop p1 ((access,p1) :: acc) l
					end
				| _ ->
					loop p1 ((access,p1) :: acc) l
	in
	let pmin = {cff.cff_pos with pmax = cff.cff_pos.pmin} in
	loop pmin [] cff.cff_access;
	!display_access

let find_type_in_module m tname =
	List.find (fun mt ->
		let infos = t_infos mt in
		not infos.mt_private && snd infos.mt_path = tname
	) m.m_types

(* raises Type_not_found *)
let find_type_in_module_raise ctx m tname p =
	try
		List.find (fun mt ->
			let infos = t_infos mt in
			if snd infos.mt_path = tname then
				if ctx.m.curmod != infos.mt_module && infos.mt_private then
					raise_typing_error (Type_not_found (m.m_path,tname,Private_type)) p
				else
					true
			else
				false
		) m.m_types
	with Not_found ->
		raise_typing_error (Type_not_found (m.m_path,tname,Not_defined)) p

(* raises Module_not_found or Type_not_found *)
let load_type_raise ctx mpath tname p =
	let m = ctx.g.do_load_module ctx mpath p in
	find_type_in_module_raise ctx m tname p

(* raises Not_found *)
let load_type ctx mpath tname p = try
	load_type_raise ctx mpath tname p
with Error((Module_not_found _ | Type_not_found _),p2,_) when p = p2 ->
	raise Not_found

(** since load_type_def and load_instance are used in PASS2, they should not access the structure of a type **)

let find_type_in_current_module_context ctx pack name =
	let no_pack = pack = [] in
	let path_matches t2 =
		let tp = t_path t2 in
		(* see also https://github.com/HaxeFoundation/haxe/issues/9150 *)
		tp = (pack,name) || (no_pack && snd tp = name)
	in
	try
		(* Check the types in our own module *)
		List.find path_matches ctx.m.curmod.m_types
	with Not_found ->
		(* Check the local imports *)
		let t,pi = List.find (fun (t2,pi) -> path_matches t2) ctx.m.module_imports in
		ImportHandling.mark_import_position ctx pi;
		t

let find_in_wildcard_imports ctx mname p f =
	let rec loop l =
		match l with
		| [] ->
			raise Not_found
		| (pack,ppack) :: l ->
			begin
			try
				let path = (pack,mname) in
				let m =
					try
						ctx.g.do_load_module ctx path p
					with Error (Module_not_found mpath,_,_) when mpath = path ->
						raise Not_found
				in
				let r = f m ~resume:true in
				ImportHandling.mark_import_position ctx ppack;
				r
			with Not_found ->
				loop l
			end
	in
	loop ctx.m.wildcard_packages

(* TODO: move these generic find functions into a separate module *)
let find_in_modules_starting_from_current_package ~resume ctx mname p f =
	let rec loop l =
		let path = (List.rev l,mname) in
		match l with
		| [] ->
			let m =
				try
					ctx.g.do_load_module ctx path p
				with Error (Module_not_found mpath,_,_) when resume && mpath = path ->
					raise Not_found
			in
			f m ~resume:resume
		| _ :: sl ->
			try
				let m =
					try
						ctx.g.do_load_module ctx path p
					with Error (Module_not_found mpath,_,_) when mpath = path ->
						raise Not_found
					in
				f m ~resume:true;
			with Not_found ->
				loop sl
	in
	let pack = fst ctx.m.curmod.m_path in
	loop (List.rev pack)

let find_in_unqualified_modules ctx name p f ~resume =
	try
		find_in_wildcard_imports ctx name p f
	with Not_found ->
		find_in_modules_starting_from_current_package ctx name p f ~resume:resume

let load_unqualified_type_def ctx mname tname p =
	let find_type m ~resume =
		if resume then
			find_type_in_module m tname
		else
			find_type_in_module_raise ctx m tname p
	in
	find_in_unqualified_modules ctx mname p find_type ~resume:false

let load_module ctx path p =
	try
		ctx.g.do_load_module ctx path p
	with Error (Module_not_found mpath,_,_) as exc when mpath = path ->
		match path with
		| ("std" :: pack, name) ->
			ctx.g.do_load_module ctx (pack,name) p
		| _ ->
			raise exc

let load_qualified_type_def ctx pack mname tname p =
	let m = load_module ctx (pack,mname) p in
	find_type_in_module_raise ctx m tname p

(*
	load a type or a subtype definition
*)
let load_type_def ctx p t =
	if t = Parser.magic_type_path then
		raise_fields (DisplayToplevel.collect ctx TKType NoValue true) CRTypeHint (DisplayTypes.make_subject None p);
	(* The type name is the module name or the module sub-type name *)
	let tname = (match t.tsub with None -> t.tname | Some n -> n) in

	try
		(* If there's a sub-type, there's no reason to look in our module or its imports *)
		if t.tsub <> None then raise Not_found;
		find_type_in_current_module_context ctx t.tpackage tname
	with Not_found ->
		if t.tpackage = [] then
			load_unqualified_type_def ctx t.tname tname p
		else
			load_qualified_type_def ctx t.tpackage t.tname tname p

(* let load_type_def ctx p t =
	let timer = Timer.timer ["typing";"load_type_def"] in
	Std.finally timer (load_type_def ctx p) t *)

let resolve_position_by_path ctx path p =
	let mt = load_type_def ctx p path in
	let p = (t_infos mt).mt_pos in
	raise_positions [p]

let generate_args_meta com cls_opt add_meta args =
	let values = List.fold_left (fun acc ((name,p),_,_,_,eo) -> match eo with Some e -> ((name,p,NoQuotes),e) :: acc | _ -> acc) [] args in
	(match values with
		| [] -> ()
		| _ -> add_meta (Meta.Value,[EObjectDecl values,null_pos],null_pos)
	);
	if List.exists (fun (_,_,m,_,_) -> m <> []) args then
		let fn = { f_params = []; f_args = args; f_type = None; f_expr = None } in
		add_meta (Meta.HaxeArguments,[EFunction(FKAnonymous,fn),null_pos],null_pos)

let is_redefined ctx cf1 fields p =
	try
		let cf2 = PMap.find cf1.cf_name fields in
		let st = s_type (print_context()) in
		if not (type_iseq cf1.cf_type cf2.cf_type) then begin
			display_error ctx.com ("Cannot redefine field " ^ cf1.cf_name ^ " with different type") p;
			display_error ctx.com ("First type was " ^ (st cf1.cf_type)) cf1.cf_pos;
			typing_error ("Second type was " ^ (st cf2.cf_type)) cf2.cf_pos
		end else
			true
	with Not_found ->
		false

let make_extension_type ctx tl =
	let mk_extension fields (t,p) = match follow t with
		| TAnon a ->
			PMap.fold (fun cf fields ->
				if not (is_redefined ctx cf fields p) then PMap.add cf.cf_name cf fields
				else fields
			) a.a_fields fields
		| _ ->
			typing_error "Can only extend structures" p
	in
	let fields = List.fold_left mk_extension PMap.empty tl in
	let tl = List.map (fun (t,_) -> t) tl in
	let ta = mk_anon ~fields (ref (Extend tl)) in
	ta

let check_param_constraints ctx t map c p =
	match follow t with
	| TMono _ -> ()
	| _ ->
		let ctl = (match c.cl_kind with KTypeParameter l -> l | _ -> []) in
		List.iter (fun ti ->
			let ti = map ti in
			try
				unify_raise t ti p
			with Error(Unify l,p,n) ->
				let fail() =
					if not ctx.untyped then located_display_error ctx.com (error_msg p (Unify (Constraint_failure (s_type_path c.cl_path) :: l)));
				in
				match follow t with
				| TInst({cl_kind = KExpr e},_) ->
					let e = type_expr {ctx with locals = PMap.empty} e (WithType.with_type ti) in
					begin try unify_raise e.etype ti p
					with Error (Unify _,_,_) -> fail() end
				| _ ->
					fail()

		) ctl

(* build an instance from a full type *)
let rec load_instance' ctx (t,p) allow_no_params =
	let t = try
		if t.tpackage <> [] || t.tsub <> None then raise Not_found;
		let pt = lookup_param t.tname ctx.type_params in
		if t.tparams <> [] then typing_error ("Class type parameter " ^ t.tname ^ " can't have parameters") p;
		pt
	with Not_found ->
		let mt = load_type_def ctx p t in
		let is_generic,is_generic_build,is_extern = match mt with
			| TClassDecl {cl_kind = KGeneric} -> true,false,false
			| TClassDecl {cl_kind = KGenericBuild _} -> false,true,false
			| TClassDecl c when (has_class_flag c CExtern) -> false,false,true
			| TTypeDecl td ->
				DeprecationCheck.if_enabled ctx.com (fun() ->
					try
						let msg = match Meta.get Meta.Deprecated td.t_meta with
							| _,[EConst(String(s,_)),_],_ -> s
							| _ -> "This typedef is deprecated in favor of " ^ (s_type (print_context()) td.t_type)
						in
						DeprecationCheck.warn_deprecation ctx.com msg p
					with Not_found ->
						()
				);
				false,false,false
			| _ -> false,false,false
		in
		let types , path , f = ctx.g.do_build_instance ctx mt p in
		let is_rest = is_generic_build && (match types with [{ttp_name="Rest"}] -> true | _ -> false) in
		if allow_no_params && t.tparams = [] && not is_rest then begin
			let monos = Monomorph.spawn_constrained_monos (fun t -> t) types in
			f (monos)
		end else if path = ([],"Dynamic") then
			match t.tparams with
			| [] -> t_dynamic
			| [TPType t] -> TDynamic (Some (load_complex_type ctx true t))
			| _ -> typing_error "Too many parameters for Dynamic" p
		else begin
			let is_java_rest = ctx.com.platform = Java && is_extern in
			let is_rest = is_rest || is_java_rest in
			let load_param t =
				match t with
				| TPExpr e ->
					let name = (match fst e with
						| EConst (String(s,_)) -> "S" ^ s
						| EConst (Int (_,_) as c) -> "I" ^ s_constant c
						| EConst (Float (_,_) as c) -> "F" ^ s_constant c
						| EDisplay _ ->
							ignore(type_expr ctx e WithType.value);
							"Expr"
						| _ -> "Expr"
					) in
					let c = mk_class ctx.m.curmod ([],name) p (pos e) in
					c.cl_kind <- KExpr e;
					TInst (c,[]),pos e
				| TPType t -> load_complex_type ctx true t,pos t
			in
			let checks = DynArray.create () in
			let rec loop tl1 tl2 is_rest = match tl1,tl2 with
				| t :: tl1,({ttp_name=name;ttp_type=t2}) :: tl2 ->
					let t,pt = load_param t in
					let check_const c =
						let is_expression = (match t with TInst ({ cl_kind = KExpr _ },_) -> true | _ -> false) in
						let expects_expression = name = "Const" || Meta.has Meta.Const c.cl_meta in
						let accepts_expression = name = "Rest" in
						if is_expression then begin
							if not expects_expression && not accepts_expression then
								typing_error "Constant value unexpected here" p
						end else if expects_expression then
							typing_error "Type parameter is expected to be a constant value" p
					in
					let is_rest = is_rest || name = "Rest" && is_generic_build in
					let t = match follow t2 with
						| TInst ({ cl_kind = KTypeParameter [] } as c, []) when not is_generic ->
							check_const c;
							t
						| TInst (c,[]) ->
							check_const c;
							DynArray.add checks (t,c,pt);
							t
						| _ -> die "" __LOC__
					in
					t :: loop tl1 tl2 is_rest
				| [],[] ->
					[]
				| [],[{ttp_name="Rest"}] when is_generic_build ->
					[]
				| [],({ttp_type=t;ttp_default=def}) :: tl ->
					if is_java_rest then
						t_dynamic :: loop [] tl is_rest
					else begin match def with
						| None ->
							if ignore_error ctx.com then
								t :: loop [] tl is_rest
							else
								typing_error ("Not enough type parameters for " ^ s_type_path path) p
						| Some t ->
							t :: loop [] tl is_rest
					end
				| t :: tl,[] ->
					let t,pt = load_param t in
					if is_rest then
						t :: loop tl [] true
					else if ignore_error ctx.com then
						[]
					else
						typing_error ("Too many type parameters for " ^ s_type_path path) pt
			in
			let params = loop t.tparams types false in
			if not is_rest then begin
				let map t =
					let t = apply_params types params t in
					let t = (match follow t with
						| TInst ({ cl_kind = KGeneric } as c,pl) ->
							(* if we solve a generic contraint, let's substitute with the actual generic instance before unifying *)
							let _,_, f = ctx.g.do_build_instance ctx (TClassDecl c) p in
							f pl
						| _ -> t
					) in
					t
				in
				delay ctx PCheckConstraint (fun () ->
					DynArray.iter (fun (t,c,p) ->
						check_param_constraints ctx t map c p
					) checks
				);
			end;
			f params
		end
	in
	t

and load_instance ctx ?(allow_display=false) ((_,pn) as tp) allow_no_params =
	try
		let t = load_instance' ctx tp allow_no_params in
		if allow_display then DisplayEmitter.check_display_type ctx t tp;
		t
	with Error (Module_not_found path,_,_) when ctx.macro_depth <= 0 && (ctx.com.display.dms_kind = DMDefault) && DisplayPosition.display_position#enclosed_in pn ->
		let s = s_type_path path in
		DisplayToplevel.collect_and_raise ctx TKType NoValue CRTypeHint (s,pn) (patch_string_pos pn s)

(*
	build an instance from a complex type
*)
and load_complex_type' ctx allow_display (t,p) =
	match t with
	| CTParent t -> load_complex_type ctx allow_display t
	| CTPath { tpackage = ["$"]; tname = "_hx_mono" } -> spawn_monomorph ctx p
	| CTPath t -> load_instance ~allow_display ctx (t,p) false
	| CTOptional _ -> typing_error "Optional type not allowed here" p
	| CTNamed _ -> typing_error "Named type not allowed here" p
	| CTIntersection tl ->
		let tl = List.map (fun (t,pn) ->
			try
				(load_complex_type ctx allow_display (t,pn),pn)
			with DisplayException(DisplayFields ({fkind = CRTypeHint} as r)) ->
				let l = List.filter (fun item -> match item.ci_kind with
					| ITType({kind = Struct},_) -> true
					| _ -> false
				) r.fitems in
				raise_fields l (CRStructExtension true) r.fsubject
		) tl in
		let tr = Monomorph.create() in
		let t = TMono tr in
		let r = exc_protect ctx (fun r ->
			r := lazy_processing (fun() -> t);
			let ta = make_extension_type ctx tl in
			Monomorph.bind tr ta;
			ta
		) "constraint" in
		TLazy r
	| CTExtend (tl,l) ->
		begin match load_complex_type ctx allow_display (CTAnonymous l,p) with
		| TAnon a as ta ->
			let mk_extension (t,p) =
				match follow t with
				| TInst ({cl_kind = KTypeParameter _},_) ->
					typing_error "Cannot structurally extend type parameters" p
				| TMono _ ->
					typing_error "Loop found in cascading signatures definitions. Please change order/import" p
				| TAnon a2 ->
					PMap.iter (fun _ cf -> ignore(is_redefined ctx cf a2.a_fields p)) a.a_fields;
					mk_anon ~fields:(PMap.foldi PMap.add a.a_fields a2.a_fields) (ref (Extend [t]))
				| _ -> typing_error "Can only extend structures" p
			in
			let loop (t,p) = match follow t with
				| TAnon a2 ->
					PMap.iter (fun f cf ->
						if not (is_redefined ctx cf a.a_fields p) then
							a.a_fields <- PMap.add f cf a.a_fields
					) a2.a_fields
				| _ ->
					typing_error "Can only extend structures" p
			in
			let il = List.map (fun (t,pn) ->
				try
					(load_instance ctx ~allow_display (t,pn) false,pn)
				with DisplayException(DisplayFields ({fkind = CRTypeHint} as r)) ->
					let l = List.filter (fun item -> match item.ci_kind with
						| ITType({kind = Struct},_) -> true
						| _ -> false
					) r.fitems in
					raise_fields l (CRStructExtension false) r.fsubject
			) tl in
			let tr = Monomorph.create() in
			let t = TMono tr in
			let r = exc_protect ctx (fun r ->
				r := lazy_processing (fun() -> t);
				Monomorph.bind tr (match il with
					| [i] ->
						mk_extension i
					| _ ->
						List.iter loop il;
						a.a_status := Extend (List.map (fun(t,_) -> t) il);
						ta);
				t
			) "constraint" in
			TLazy r
		| _ -> die "" __LOC__
		end
	| CTAnonymous l ->
		let displayed_field = ref None in
		let rec loop acc f =
			let n = fst f.cff_name in
			let p = f.cff_pos in
			if PMap.mem n acc then typing_error ("Duplicate field declaration : " ^ n) p;
			let topt = function
				| None -> typing_error ("Explicit type required for field " ^ n) p
				| Some t -> load_complex_type ctx allow_display t
			in
			if n = "new" then warning ctx WDeprecated "Structures with new are deprecated, use haxe.Constraints.Constructible instead" p;
			let no_expr = function
				| None -> ()
				| Some (_,p) -> typing_error "Expression not allowed here" p
			in
			let pub = ref true in
			let dyn = ref false in
			let params = ref [] in
			let final = ref false in
			ignore(check_field_access ctx f); (* TODO: do we want to do anything with this? *)
			List.iter (fun a ->
				match fst a with
				| APublic -> ()
				| APrivate ->
					let p = pos a in
					if Filename.basename p.pfile <> "NativeIterable.hx" then (* Terrible workaround for #7436 *)
						warning ctx WDeprecated "private structure fields are deprecated" p;
					pub := false;
				| ADynamic when (match f.cff_kind with FFun _ -> true | _ -> false) -> dyn := true
				| AFinal -> final := true
				| AStatic | AOverride | AInline | ADynamic | AMacro | AExtern | AAbstract | AOverload as a -> typing_error ("Invalid access " ^ Ast.s_access a) p
			) f.cff_access;
			let t , access = (match f.cff_kind with
				| FVar(t,e) when !final ->
					no_expr e;
					let t = (match t with None -> typing_error "Type required for structure property" p | Some t -> t) in
					load_complex_type ctx allow_display t, Var { v_read = AccNormal; v_write = AccNever }
				| FVar (Some (CTPath({tpackage=[];tname="Void"}),_), _)  | FProp (_,_,Some (CTPath({tpackage=[];tname="Void"}),_),_) ->
					typing_error "Fields of type Void are not allowed in structures" p
				| FVar (t, e) ->
					no_expr e;
					topt t, Var { v_read = AccNormal; v_write = AccNormal }
				| FFun fd ->
					params := (!type_function_params_rec) ctx fd (fst f.cff_name) p;
					no_expr fd.f_expr;
					let old = ctx.type_params in
					ctx.type_params <- !params @ old;
					let args = List.map (fun ((name,_),o,_,t,e) -> no_expr e; name, o, topt t) fd.f_args in
					let t = TFun (args,topt fd.f_type), Method (if !dyn then MethDynamic else MethNormal) in
					ctx.type_params <- old;
					t
				| FProp (i1,i2,t,e) ->
					no_expr e;
					let access (m,_) get =
						match m with
						| "null" -> AccNo
						| "never" -> AccNever
						| "default" -> AccNormal
						| "dynamic" -> AccCall
						| "get" when get -> AccCall
						| "set" when not get -> AccCall
						| x when get && x = "get_" ^ n -> AccCall
						| x when not get && x = "set_" ^ n -> AccCall
						| _ ->
							typing_error "Custom property access is no longer supported in Haxe 3" f.cff_pos;
					in
					let t = (match t with None -> typing_error "Type required for structure property" p | Some t -> t) in
					load_complex_type ctx allow_display t, Var { v_read = access i1 true; v_write = access i2 false }
			) in
			let t = if Meta.has Meta.Optional f.cff_meta then ctx.t.tnull t else t in
			let cf = {
				(mk_field n ~public:!pub t p (pos f.cff_name)) with
				cf_kind = access;
				cf_params = !params;
				cf_doc = f.cff_doc;
				cf_meta = f.cff_meta;
			} in
			if !final then add_class_field_flag cf CfFinal;
			init_meta_overloads ctx None cf;
			if ctx.is_display_file then begin
				DisplayEmitter.check_display_metadata ctx cf.cf_meta;
				if DisplayPosition.display_position#enclosed_in cf.cf_name_pos then displayed_field := Some cf;
			end;
			PMap.add n cf acc
		in
		let a = { a_fields = (List.fold_left loop PMap.empty l); a_status = ref Closed; } in
		begin match !displayed_field with
		| None ->
			()
		| Some cf ->
			delay ctx PBuildClass (fun () -> DisplayEmitter.display_field ctx (AnonymousStructure a) CFSMember cf cf.cf_name_pos);
		end;
		TAnon a
	| CTFunction (args,r) ->
		match args with
		| [CTPath { tpackage = []; tparams = []; tname = "Void" },_] ->
			TFun ([],load_complex_type ctx allow_display r)
		| _ ->
			TFun (List.map (fun t ->
				let t, opt = (match fst t with CTOptional t | CTParent((CTOptional t,_)) -> t, true | _ -> t,false) in
				let n,t = (match fst t with CTNamed (n,t) -> (fst n), t | _ -> "", t) in
				n,opt,load_complex_type ctx allow_display t
			) args,load_complex_type ctx allow_display r)

and load_complex_type ctx allow_display (t,pn) =
	try
		load_complex_type' ctx allow_display (t,pn)
	with Error(Module_not_found(([],name)),p,_) as exc ->
		if Diagnostics.error_in_diagnostics_run ctx.com p then begin
			delay ctx PForce (fun () -> DisplayToplevel.handle_unresolved_identifier ctx name p true);
			t_dynamic
		end else if ignore_error ctx.com && not (DisplayPosition.display_position#enclosed_in pn) then
			t_dynamic
		else
			raise exc

and init_meta_overloads ctx co cf =
	let overloads = ref [] in
	let filter_meta m = match m with
		| ((Meta.Overload | Meta.Value),_,_) -> false
		| _ -> true
	in
	let cf_meta = List.filter filter_meta cf.cf_meta in
	cf.cf_meta <- List.filter (fun m ->
		match m with
		| (Meta.Overload,[(EFunction (kind,f),p)],_)  ->
			(match kind with FKNamed _ -> typing_error "Function name must not be part of @:overload" p | _ -> ());
			(match f.f_expr with Some (EBlock [], _) -> () | _ -> typing_error "Overload must only declare an empty method body {}" p);
			(match cf.cf_kind with
				| Method MethInline -> typing_error "Cannot @:overload inline function" p
				| _ -> ());
			let old = ctx.type_params in
			begin match cf.cf_params with
				| [] ->
					()
				| l ->
					ctx.type_params <- List.filter (fun t ->
						not (List.mem t l) (* TODO: this still looks suspicious *)
					) ctx.type_params
			end;
			let params : type_params = (!type_function_params_rec) ctx f cf.cf_name p in
			ctx.type_params <- params @ ctx.type_params;
			let topt = function None -> typing_error "Explicit type required" p | Some t -> load_complex_type ctx true t in
			let args =
				List.map
					(fun ((a,_),opt,_,t,cto) ->
						let t = if opt then ctx.t.tnull (topt t) else topt t in
						let opt = opt || cto <> None in
						a,opt,t
					)
					f.f_args
			in
			let cf = { cf with cf_type = TFun (args,topt f.f_type); cf_params = params; cf_meta = cf_meta} in
			generate_args_meta ctx.com co (fun meta -> cf.cf_meta <- meta :: cf.cf_meta) f.f_args;
			overloads := cf :: !overloads;
			ctx.type_params <- old;
			false
		| (Meta.Overload,[],_) when ctx.com.config.pf_overload ->
			add_class_field_flag cf CfOverload;
			let topt (n,_,t) = match t with | TMono t when t.tm_type = None -> typing_error ("Explicit type required for overload functions\n... For function argument '" ^ n ^ "'") cf.cf_pos | _ -> () in
			(match follow cf.cf_type with
			| TFun (args,_) -> List.iter topt args
			| _ -> () (* could be a variable *));
			true
		| (Meta.Overload,[],p) ->
			typing_error "This platform does not support this kind of overload declaration. Try @:overload(function()... {}) instead" p
		| (Meta.Overload,_,p) ->
			typing_error "Invalid @:overload metadata format" p
		| _ ->
			true
	) cf.cf_meta;
	cf.cf_overloads <- (List.rev !overloads)

let hide_params ctx =
	let old_m = ctx.m in
	let old_type_params = ctx.type_params in
	let old_deps = ctx.g.std.m_extra.m_deps in
	ctx.m <- {
		curmod = ctx.g.std;
		module_imports = [];
		module_using = [];
		module_globals = PMap.empty;
		wildcard_packages = [];
		import_statements = [];
	};
	ctx.type_params <- [];
	(fun() ->
		ctx.m <- old_m;
		ctx.type_params <- old_type_params;
		(* restore dependencies that might be have been wronly inserted *)
		ctx.g.std.m_extra.m_deps <- old_deps;
	)

(*
	load a type while ignoring the current imports or local types
*)
let load_core_type ctx name =
	let show = hide_params ctx in
	let t = load_instance ctx (mk_type_path ([],name),null_pos) false in
	show();
	add_dependency ctx.m.curmod (match t with
	| TInst (c,_) -> c.cl_module
	| TType (t,_) -> t.t_module
	| TAbstract (a,_) -> a.a_module
	| TEnum (e,_) -> e.e_module
	| _ -> die "" __LOC__);
	t

let t_iterator ctx =
	let show = hide_params ctx in
	match load_type_def ctx null_pos (mk_type_path ([],"Iterator")) with
	| TTypeDecl t ->
		show();
		add_dependency ctx.m.curmod t.t_module;
		if List.length t.t_params <> 1 then die "" __LOC__;
		let pt = mk_mono() in
		apply_typedef t [pt], pt
	| _ ->
		die "" __LOC__

(*
	load either a type t or Null<Unknown> if not defined
*)
let load_type_hint ?(opt=false) ctx pcur t =
	let t = match t with
		| None -> spawn_monomorph ctx pcur
		| Some (t,p) ->	load_complex_type ctx true (t,p)
	in
	if opt then ctx.t.tnull t else t

(* ---------------------------------------------------------------------- *)
(* PASS 1 & 2 : Module and Class Structure *)

type type_param_host =
	| TPHType
	| TPHConstructor
	| TPHMethod
	| TPHEnumConstructor

let rec type_type_param ctx host path get_params p tp =
	let n = fst tp.tp_name in
	let c = mk_class ctx.m.curmod (fst path @ [snd path],n) (pos tp.tp_name) (pos tp.tp_name) in
	c.cl_params <- type_type_params ctx host c.cl_path get_params p tp.tp_params;
	c.cl_kind <- KTypeParameter [];
	c.cl_meta <- tp.Ast.tp_meta;
	if host = TPHEnumConstructor then c.cl_meta <- (Meta.EnumConstructorParam,[],null_pos) :: c.cl_meta;
	let t = TInst (c,extract_param_types c.cl_params) in
	if ctx.is_display_file && DisplayPosition.display_position#enclosed_in (pos tp.tp_name) then
		DisplayEmitter.display_type ctx t (pos tp.tp_name);
	let default = match tp.tp_default with
		| None ->
			None
		| Some ct ->
			let t = load_complex_type ctx true ct in
			begin match host with
			| TPHType ->
				()
			| TPHConstructor
			| TPHMethod
			| TPHEnumConstructor ->
				display_error ctx.com "Default type parameters are only supported on types" (pos ct)
			end;
			Some t
	in
	match tp.tp_constraints with
	| None ->
		mk_type_param n t default
	| Some th ->
		let r = exc_protect ctx (fun r ->
			r := lazy_processing (fun() -> t);
			let ctx = { ctx with type_params = ctx.type_params @ get_params() } in
			let rec loop th = match fst th with
				| CTIntersection tl -> List.map (load_complex_type ctx true) tl
				| CTParent ct -> loop ct
				| _ -> [load_complex_type ctx true th]
			in
			let constr = loop th in
			(* check against direct recursion *)
			let rec loop t =
				match follow t with
				| TInst (c2,_) when c == c2 -> typing_error "Recursive constraint parameter is not allowed" p
				| TInst ({ cl_kind = KTypeParameter cl },_) ->
					List.iter loop cl
				| _ ->
					()
			in
			List.iter loop constr;
			c.cl_kind <- KTypeParameter constr;
			t
		) "constraint" in
		mk_type_param n (TLazy r) default

and type_type_params ctx host path get_params p tpl =
	let names = ref [] in
	List.map (fun tp ->
		if List.exists (fun name -> name = fst tp.tp_name) !names then display_error ctx.com ("Duplicate type parameter name: " ^ fst tp.tp_name) (pos tp.tp_name);
		names := (fst tp.tp_name) :: !names;
		type_type_param ctx host path get_params p tp
	) tpl

let load_core_class ctx c =
	let ctx2 = (match ctx.g.core_api with
		| None ->
			let com2 = Common.clone ctx.com ctx.com.is_macro_context in
			com2.defines.Define.values <- PMap.empty;
			Common.define com2 Define.CoreApi;
			Common.define com2 Define.Sys;
			Define.raw_define_value com2.defines "target.threaded" "true"; (* hack because we check this in sys.thread classes *)
			if ctx.com.is_macro_context then Common.define com2 Define.Macro;
			com2.class_path <- ctx.com.std_path;
			if com2.display.dms_check_core_api then com2.display <- {com2.display with dms_check_core_api = false};
			CommonCache.lock_signature com2 "load_core_class";
			let ctx2 = ctx.g.do_create com2 in
			ctx.g.core_api <- Some ctx2;
			ctx2
		| Some c ->
			c
	) in
	let tpath = match c.cl_kind with
		| KAbstractImpl a -> mk_type_path a.a_path
		| _ -> mk_type_path c.cl_path
	in
	let t = load_instance ctx2 (tpath,c.cl_pos) true in
	flush_pass ctx2 PFinal "core_final";
	match t with
	| TInst (ccore,_) | TAbstract({a_impl = Some ccore}, _) ->
		ccore
	| _ ->
		die "" __LOC__

let init_core_api ctx c =
	let ccore = load_core_class ctx c in
	begin try
		List.iter2 (fun tp1 tp2 -> match follow tp1.ttp_type, follow tp2.ttp_type with
			| TInst({cl_kind = KTypeParameter l1},_),TInst({cl_kind = KTypeParameter l2},_) ->
				begin try
					List.iter2 (fun t1 t2 -> type_eq EqCoreType t2 t1) l1 l2
				with
					| Invalid_argument _ ->
						typing_error "Type parameters must have the same number of constraints as core type" c.cl_pos
					| Unify_error l ->
						display_error ctx.com ("Type parameter " ^ tp2.ttp_name ^ " has different constraint than in core type") c.cl_pos;
						located_display_error ctx.com (error_msg c.cl_pos (Unify l));
				end
			| t1,t2 ->
				Printf.printf "%s %s" (s_type (print_context()) t1) (s_type (print_context()) t2);
				die "" __LOC__
		) ccore.cl_params c.cl_params;
	with Invalid_argument _ ->
		typing_error "Class must have the same number of type parameters as core type" c.cl_pos
	end;
	(match c.cl_doc with
	| None -> c.cl_doc <- ccore.cl_doc
	| Some _ -> ());
	let compare_fields f f2 =
		let p = (match f2.cf_expr with None -> c.cl_pos | Some e -> e.epos) in
		(try
			type_eq EqCoreType (apply_params ccore.cl_params (extract_param_types c.cl_params) f.cf_type) f2.cf_type
		with Unify_error l ->
			display_error ctx.com ("Field " ^ f.cf_name ^ " has different type than in core type") p;
			located_display_error ctx.com (error_msg p (Unify l)));
		if (has_class_field_flag f2 CfPublic) <> (has_class_field_flag f CfPublic) then typing_error ("Field " ^ f.cf_name ^ " has different visibility than core type") p;
		(match f2.cf_doc with
		| None -> f2.cf_doc <- f.cf_doc
		| Some _ -> ());
		if f2.cf_kind <> f.cf_kind then begin
			match f2.cf_kind, f.cf_kind with
			| Method MethInline, Method MethNormal -> () (* allow to add 'inline' *)
			| Method MethNormal, Method MethInline -> () (* allow to disable 'inline' *)
			| _ ->
				typing_error ("Field " ^ f.cf_name ^ " has different property access than core type") p;
		end;
		(match follow f.cf_type, follow f2.cf_type with
		| TFun (pl1,_), TFun (pl2,_) ->
			if List.length pl1 != List.length pl2 then typing_error "Argument count mismatch" p;
			List.iter2 (fun (n1,_,_) (n2,_,_) ->
				if n1 <> n2 then typing_error ("Method parameter name '" ^ n2 ^ "' should be '" ^ n1 ^ "'") p;
			) pl1 pl2;
		| _ -> ());
	in
	let check_fields fcore fl =
		PMap.iter (fun i f ->
			if not (has_class_field_flag f CfPublic) then () else
			let f2 = try PMap.find f.cf_name fl with Not_found -> typing_error ("Missing field " ^ i ^ " required by core type") c.cl_pos in
			compare_fields f f2;
		) fcore;
		PMap.iter (fun i f ->
			let p = (match f.cf_expr with None -> c.cl_pos | Some e -> e.epos) in
			if (has_class_field_flag f CfPublic) && not (Meta.has Meta.Hack f.cf_meta) && not (PMap.mem f.cf_name fcore) && not (has_class_field_flag f CfOverride) then typing_error ("Public field " ^ i ^ " is not part of core type") p;
		) fl;
	in
	check_fields ccore.cl_fields c.cl_fields;
	check_fields ccore.cl_statics c.cl_statics;
	(match ccore.cl_constructor, c.cl_constructor with
	| None, None -> ()
	| Some cf, _ when not (has_class_field_flag cf CfPublic) -> ()
	| Some f, Some f2 -> compare_fields f f2
	| None, Some cf when not (has_class_field_flag cf CfPublic) -> ()
	| _ -> typing_error "Constructor differs from core type" c.cl_pos)

let string_list_of_expr_path (e,p) =
	try string_list_of_expr_path_raise (e,p)
	with Exit -> typing_error "Invalid path" p
