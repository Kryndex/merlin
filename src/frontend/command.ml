(* {{{ COPYING *(

  This file is part of Merlin, an helper for ocaml editors

  Copyright (C) 2013  Frédéric Bour  <frederic.bour(_)lakaban.net>
                      Thomas Refis  <refis.thomas(_)gmail.com>
                      Simon Castellan  <simon.castellan(_)iuwt.fr>

  Permission is hereby granted, free of charge, to any person obtaining a
  copy of this software and associated documentation files (the "Software"),
  to deal in the Software without restriction, including without limitation the
  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
  sell copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  The Software is provided "as is", without warranty of any kind, express or
  implied, including but not limited to the warranties of merchantability,
  fitness for a particular purpose and noninfringement. In no event shall
  the authors or copyright holders be liable for any claim, damages or other
  liability, whether in an action of contract, tort or otherwise, arising
  from, out of or in connection with the software or the use or other dealings
  in the Software.

)* }}} *)

open Std
open Misc

open Protocol
open Merlin_lib

type state = {
  mutable project : Project.t;
  mutable buffer : Buffer.t;
  mutable lexer : Lexer.t option;
}

let store : (string, Project.t) Hashtbl.t = Hashtbl.create 3
let project_by_key key =
  try Hashtbl.find store key
  with Not_found ->
    let project = Project.create () in
    Hashtbl.replace store key project;
    project

let new_state () =
  let project = project_by_key "" in
  let buffer = Buffer.create project Parser.implementation in
  { project; buffer; lexer = None }

let position state =
  let lexer =
    match state.lexer with
    | None -> Buffer.start_lexing state.buffer
    | Some l -> l
  in
  Lexer.position lexer, Buffer.path state.buffer

let buffer_changed state =
  state.lexer <- None

let buffer_update state items =
  Buffer.update state.buffer items;
  buffer_changed state

let dispatch (state : state) =
  fun (type a) (request : a request) ->
  (match request with
  | (Tell `Start : a request) ->
    let lexer = Buffer.start_lexing state.buffer in
    state.lexer <- Some lexer;
    ignore (Buffer.update state.buffer (Lexer.history lexer));
    Lexer.position lexer, Buffer.path state.buffer

  | (Tell (`Source source) : a request) ->
    let lexer = match state.lexer with
      | Some lexer ->
        assert (not (Lexer.eof lexer));
        lexer
      | None ->
        let lexer = Buffer.start_lexing state.buffer in
        state.lexer <- Some lexer; lexer
    in
    assert (Lexer.feed lexer source);
    ignore (Buffer.update state.buffer (Lexer.history lexer));
    (* Stop lexer on EOF *)
    if Lexer.eof lexer then state.lexer <- None;
    Lexer.position lexer, Buffer.path state.buffer

  | (Type_expr (source, None) : a request) ->
    failwith "TODO"

  | (Type_expr (source, Some pos) : a request) ->
    failwith "TODO"

  | (Type_enclosing ((expr, offset), pos) : a request) ->
    failwith "TODO"

  | (Complete_prefix (prefix, pos) : a request) ->
    let node = Completion.node_at (Buffer.typer state.buffer) pos in
    let compl = Completion.node_complete state.project node prefix in
    List.rev compl

  | (Locate (path, opt_pos) : a request) ->
    let node, local_defs =
      let typer = Buffer.typer state.buffer in
      match opt_pos with
      | None     -> Browse.({ dummy with env = Typer.env typer }), []
      | Some pos -> Completion.node_at typer pos, Merlin_typer.structures typer
    in
    let opt =
      Track_definition.from_string ~project:state.project ~env:(node.Browse.env)
        ~local_defs path
    in
    Option.map opt ~f:(fun (file_opt, loc) ->
      Logger.log `locate
        (sprintf "--> %s"
          (match file_opt with None -> "<local buffer>" | Some f -> f)) ;
      file_opt, loc.Location.loc_start
    )

  | (Drop : a request) ->
    let lexer = Buffer.lexer state.buffer in
    Buffer.update state.buffer (History.drop_tail lexer);
    buffer_changed state;
    position state

  | (Seek `Position : a request) ->
    position state

  | (Seek (`Before pos) : a request) ->
    let items = Buffer.lexer state.buffer in
    (* true while i is before pos *)
    let until_after pos i = Lexing.compare_pos (Lexer.item_start i) pos < 0 in
    (* true while i is after pos *)
    let until_before pos i = Lexing.compare_pos (Lexer.item_start i) pos >= 0 in
    let items = History.seek_forward (until_after pos) items in
    let items = History.seek_backward (until_before pos) items in
    buffer_update state items;
    position state

  | (Seek (`Exact pos) : a request) ->
    let items = Buffer.lexer state.buffer in
    (* true while i is before pos *)
    let until_after pos i = Lexing.compare_pos (Lexer.item_start i) pos < 0 in
    (* true while i is after pos *)
    let until_before pos i = Lexing.compare_pos (Lexer.item_end i) pos > 0 in
    let items = History.seek_forward (until_after pos) items in
    let items = History.seek_backward (until_before pos) items in
    buffer_update state items;
    position state

  | (Seek `End : a request) ->
    let items = Buffer.lexer state.buffer in
    let items = History.seek_forward (fun _ -> true) items in
    buffer_update state items;
    position state

  | (Boundary (dir,pos) : a request) ->
    failwith "TODO"

  | (Reset (ml,path) : a request) ->
    let parser = match ml with
      | `ML  -> Raw_parser.implementation_state
      | `MLI -> Raw_parser.interface_state
    in
    let buffer = Buffer.create ?path state.project parser in
    buffer_changed state;
    state.buffer <- buffer;
    position state

  | (Refresh : a request) ->
    Project.invalidate ~flush:true state.project

  | (Errors : a request) ->
    let pexns = Buffer.parser_errors state.buffer in
    let texns = Typer.exns (Buffer.typer state.buffer) in
    texns @ pexns

  | (Dump `Parser : a request) ->
    let ppf, to_string = Format.to_string () in
    Parser.dump ppf (Buffer.parser state.buffer);
    `String (to_string ())

  | (Dump _ : a request) ->
    failwith "TODO"

  | (Which_path s : a request) ->
    begin
      try
        find_in_path_uncap (Project.source_path state.project) s
      with Not_found ->
        find_in_path_uncap (Project.source_path state.project) s
    end

  | (Which_with_ext ext : a request) ->
    modules_in_path ~ext
      (Path_list.to_strict_list (Project.source_path state.project))

  | (Project_load (cmd,path) : a request) ->
    let fn = match cmd with
      | `File -> Dot_merlin.read
      | `Find -> Dot_merlin.find
    in
    let dot_merlins = fn path in
    let config = Dot_merlin.parse dot_merlins in
    let key = match config.Dot_merlin.dot_merlins with
      | [] -> ""
      | (a :: _) -> a
    in
    let project = project_by_key key in
    let failures = Project.set_dot_merlin project (Some config) in
    state.project <- project;
    (config.Dot_merlin.dot_merlins, failures)

  | (Findlib_list : a request) ->
    Fl_package_base.list_packages ()

  | (Findlib_use packages : a request) ->
    Project.User.load_packages state.project packages

  | (Extension_list kind : a request) ->
    let enabled = Project.extensions state.project in
    let set = match kind with
      | `All -> Extension.all
      | `Enabled -> enabled
      | `Disabled -> String.Set.diff Extension.all enabled
    in
    String.Set.to_list set

  | (Extension_set (action,extensions) : a request) ->
    let enabled = match action with
      | `Enabled  -> true
      | `Disabled -> false
    in
    List.iter ~f:(Project.User.set_extension state.project ~enabled)
      extensions

  | (Path (var,action,pathes) : a request) ->
    List.iter pathes
      ~f:(Project.User.path state.project ~action ~var ?cwd:None)

  | (Path_list `Build : a request) ->
    Path_list.to_strict_list (Project.build_path state.project)

  | (Path_list `Source : a request) ->
    Path_list.to_strict_list (Project.source_path state.project)

  | (Path_reset : a request) ->
    Project.User.reset state.project

  : a)