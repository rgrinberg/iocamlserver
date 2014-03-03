(* A http server for iocaml.  
   This will be merged into iocaml proper if it starts to work 

kernel messages
---------------

 ipython/html/services/kernels/handlers.py
 ipython/html/static/notebook/js/notebook.js 

 /kernels?notebook=<guid> - send kernel id + ws_url, start kernel
 /kernels/<guid> - delete, stop kernel, status 204
 /kernels/<guid>/restart|interrupt - restart/interrupt kernel
 /kernels/<guid>/shell|iopub|stdin - websocket

notebook messages
-----------------

 ipython/html/services/notebooks/handlers.py

 /notebooks
 /notebooks/<guid>
 /notebooks/<guid>/checkpoints
 /notebooks/<guid>/checkpoints/<id>


root messages 
-------------

 ipython/html/notebook/handlers.py

 /<guid>
 /new - new notebook
 /<guid>/copy - copy and redirect
 /<name> - redirect to guid

*)

open Printf
open Lwt
open Cohttp
open Cohttp_lwt_unix

(* port configuration *)
let http_addr = "0.0.0.0"
let http_port = 8889
let ws_addr = "127.0.0.1"
let ws_port = 8890
let zmq_shell_port = 8891
let zmq_iopub_port = 8892
let zmq_control_port = 8893
let zmq_heartbeat_port = 8894
let zmq_stdin_port = 8895

(* some stuff we will need to set up dynamically (and figure out what they are!) *)
let title = "Untitled0" (* notebook title *)
let data_project = "/home/andyman/dev/github/iocamlserver" (* not sure...notebook directory? *)
let data_notebook_id = "d8f01c67-33f6-48a8-8d4d-61a9d952e2bb" (* guid for the notebook instance *)

let generate_notebook () = 
    
    let static_url x = "/static/" ^ x in
    let mathjax_url = "http://cdn.mathjax.org/mathjax/latest/MathJax.js" in
    let base_project_url = "/" in
    let data_base_project_url = "/" in
    let data_base_kernel_url = "/" in
    let body_class = "notebook_app" in

    let style = Pages.notebook_stylesheet mathjax_url static_url in
    let header = Pages.notebook_header in
    let site = Pages.notebook_site in
    let script = Pages.notebook_scripts static_url in
    let page = Pages.page 
        title base_project_url static_url
        data_project data_base_project_url data_base_kernel_url
        data_notebook_id body_class
        style header site script
    in
    "<!DOCTYPE HTML>\n" ^ Cow.Html.to_string page

(* the json that's served for an empty notebook *)
let empty_notebook title = 
    let open Yojson.Basic in
    to_string 
        (`Assoc [
            "metadata", `Assoc [
                "language", `String "ocaml";
                "name", `String title;
            ];
            "nbformat", `Int 3;
            "nbformat_minor", `Int 0;
            "worksheets", `List [
                `Assoc [
                    "cells", `List [];
                    "metadata", `Assoc [];
                ];
            ];
        ])

let kernel_id_message kernel_guid ws_addr ws_port = 
    let open Yojson.Basic in
    to_string 
        (`Assoc [
            "kernel_id", `String kernel_guid;
            "ws_url", `String ("ws://" ^ ws_addr ^ ":" ^ string_of_int ws_port);
        ])

let connection_file  
    ip_addr
    zmq_shell_port zmq_iopub_port zmq_control_port
    zmq_heartbeat_port zmq_stdin_port
    = 
    let open Yojson.Basic in
    to_string 
        (`Assoc [
          "stdin_port", `Int zmq_stdin_port; 
          "ip", `String ip_addr; 
          "control_port", `Int zmq_control_port; 
          "hb_port", `Int zmq_heartbeat_port; 
          "signature_scheme", `String "hmac-sha256"; 
          "key", `String ""; 
          "shell_port", `Int zmq_shell_port; 
          "transport", `String "tcp"; 
          "iopub_port", `Int zmq_iopub_port
        ])

type kernel = 
    {
        process : Lwt_process.process_none;
        guid : string;
    }

module Kernel_map = Map.Make(String)

let g_kernels : kernel Kernel_map.t ref = ref Kernel_map.empty
let g_notebooks : string Kernel_map.t ref = ref Kernel_map.empty

let kernel_of_notebooks notebook_guid = Kernel_map.find notebook_guid !g_notebooks
let kernel_data kernel_guid = Kernel_map.find kernel_guid !g_kernels

let write_connection_file 
    kernel_guid ip_addr
    zmq_shell_port zmq_iopub_port zmq_control_port
    zmq_heartbeat_port zmq_stdin_port =

    let cwd = Unix.getcwd () in
    let fname = Filename.concat cwd (kernel_guid ^ ".json") in
    let f = open_out fname in
    output_string f 
        (connection_file ip_addr zmq_shell_port zmq_iopub_port
            zmq_control_port zmq_heartbeat_port zmq_stdin_port);
    close_out f;
    fname

let kernel_response req =
    (* I think at this point we create the kernel and add a mapping *)
    let kernel_guid = Uuidm.(to_string (create `V4)) in
    let conn_file_name = write_connection_file
        kernel_guid ws_addr
        zmq_shell_port zmq_iopub_port zmq_control_port
        zmq_heartbeat_port zmq_stdin_port 
    in
    let command = ("", [| "iocaml.top"; "-connection-file"; conn_file_name |]) in
    lwt notebook_guid =  
        let uri = Request.uri req in
        match Uri.get_query_param uri "notebook" with
        | None -> Lwt.fail (Failure "/kernels expecting notebook id")
        | Some(x) -> return x
    in
    lwt () = Lwt_io.eprintf "kernel_guid: %s\n" kernel_guid in
    lwt () = Lwt_io.eprintf "notebook_guid: %s\n" notebook_guid in
    let k = 
        {
            process = Lwt_process.open_process_none command;
            guid = kernel_guid;
        }
    in
    let () = 
        g_notebooks := Kernel_map.add notebook_guid k.guid !g_notebooks;
        g_kernels := Kernel_map.add kernel_guid k !g_kernels
    in
    Server.respond_string ~status:`OK 
        ~body:(kernel_id_message kernel_guid ws_addr ws_port) ()

(* messages sent by paths in the url *)
module Path_messages = struct

    (* regex's for parsing url paths *)
    open Re

    let s = char '/'
    let d = char '-'
    let hex = alt [digit; (no_case (rg 'a' 'f'))]
    let hex n = repn hex n (Some(n))
    let guid = seq [ hex 8; d; hex 4; d; hex 4; d; hex 4; d; hex 12 ]
    let re_guid = compile guid

    let notebooks = str "/notebooks"
    let kernels = str "/kernels"
    let static = str "/static"
    let status = str "/status"

    let re_notebooks = compile notebooks
    let re_kernels = compile kernels
    let re_static = compile static
    let re_status = compile status

    type message =
        [ `Static
 
        | `Status

        | `Root
        | `Root_guid
        | `Root_new
        | `Root_copy
        | `Root_name
        
        | `Notebooks
        | `Notebooks_guid of string
        | `Notebooks_checkpoint of string
        | `Notebooks_checkpoint_id of string * string

        | `Kernels
        | `Kernels_guid of string
        | `Kernels_restart of string
        | `Kernels_interrupt of string
        
        | `Error_not_found ]

    type ws_message = 
        [ `Ws_shell of string
        | `Ws_iopub of string
        | `Ws_stdin of string
        | `Error_not_found ]

    let rec execl s = function
        | [] -> return `Error_not_found
        | (re,fn) :: tl ->
            return (try Some(fn (get_all (exec re s))) with _ -> None)
            >>= function
                | Some(x) -> return x
                | None -> execl s tl


    let compile_decode p (re,fn) = compile (seq (p::re)), fn

    let decode_notebooks = 
        let cp, guid = str "checkpoints", group guid in
        let re = [
            [eos], (fun _ -> `Notebooks);
            [s; guid; eos], (fun r -> `Notebooks_guid(r.(1)));
            [s; guid; s; cp; eos], (fun r -> `Notebooks_checkpoint(r.(1)));
            [s; guid; s; cp; s; guid; eos], (fun r -> `Notebooks_checkpoint_id(r.(1), r.(2)));
        ] in
        let re = List.map (compile_decode notebooks) re in
        fun path -> execl path re

    let decode_kernels = 
        let guid = group guid in
        let re = [
            [eos], (fun _ -> `Kernels);
            [s; guid; eos], (fun r -> `Kernels_guid(r.(1)));
            [s; guid; s; str "restart"; eos], (fun r -> `Kernels_restart(r.(1)));
            [s; guid; s; str "interrupt"; eos], (fun r -> `Kernels_interrupt(r.(1)));
        ] in
        let re = List.map (compile_decode kernels) re in
        fun path -> execl path re

    let decode_ws = 
        let guid = group guid in
        let re = [
            [s; guid; s; str "shell"; eos], (fun r -> `Ws_shell(r.(1)));
            [s; guid; s; str "iopub"; eos], (fun r -> `Ws_iopub(r.(1)));
            [s; guid; s; str "stdin"; eos], (fun r -> `Ws_stdin(r.(1)));
        ] in
        let re = List.map (compile_decode kernels) re in
        fun path -> execl path re

    let decode path = 
        let d = [
            (fun p -> p="" || p="/"), (fun _ -> return `Root);
            execp re_static, (fun _ -> return `Static);
            execp re_notebooks, decode_notebooks;
            execp re_kernels, decode_kernels;
            execp re_status, (fun _ -> return `Status);
        ] in
        let rec check = function
            | [] -> return `Error_not_found
            | (m,v)::tl ->
                return (m path) 
                >>= fun m -> if m then v path else check tl
        in
        check d

end

let header typ = 
    let h = Header.init () in
    let h = Header.add h "Content-Type" typ in
    let h = Header.add h "Server" "iocaml" in
    h

let header_none = Header.init ()
let header_html = header "text/html; charset=UTF-8"
let header_css = header "text/css"
let header_javascript = header "application/javascript"
let header_json = header "application/json"
let header_font = header "application/x-font-woff"

let header_of_extension filename = 
    if Filename.check_suffix filename ".js" then header_javascript
    else if Filename.check_suffix filename ".css" then header_css
    else if Filename.check_suffix filename ".ipynb" then header_json
    else if Filename.check_suffix filename ".woff" then header_font
    else header_none

let make_server address port =
    let callback conn_id ?body req =
        let open Path_messages in
        let uri = Request.uri req in
        let meth = Request.meth req in
        let path = Uri.path uri in
        
        let not_found () = 
            Printf.eprintf "%s: ERROR: %s -> %s\n%!" 
                (Connection.to_string conn_id) (Uri.to_string uri) path;
            Server.respond_not_found ()
        in

        lwt decode = decode path in
        let ()  = 
            (* XXX log all messages that are not just serving notebook files *)
            if decode <> `Static then 
                Printf.eprintf "%s: %s -> %s\n%!" 
                    (Connection.to_string conn_id) (Uri.to_string uri) path;
        in

        match decode with

        | `Root ->
            let notebook = generate_notebook () in
            Server.respond_string ~status:`OK ~headers:header_html ~body:notebook ()

        | `Static -> 
            let fname = Server.resolve_file ~docroot:"ipython/html" ~uri:(Request.uri req) in
            if Sys.file_exists fname then 
                Server.respond_file ~headers:(header_of_extension fname) ~fname ()
            else not_found ()
    
        | `Status ->
            let static_url x = "/static/" ^ x in
            let guids = List.map fst (Kernel_map.bindings !g_kernels) in
            Server.respond_string ~status:`OK ~headers:header_html 
                ~body:(Cow.Html.to_string 
                    (Pages.(page "status" "" static_url "" "" "" "" "no_class" 
                          empty empty (status_site guids) empty))) ()

        | `Root_guid -> not_found ()
        | `Root_new -> not_found ()
        | `Root_copy -> not_found ()
        | `Root_name -> not_found ()
        | `Notebooks -> not_found ()
        | `Notebooks_guid(_) when meth = `GET -> 
            Server.respond_string ~status:`OK ~body:(empty_notebook "Untitled0") ()

        | `Notebooks_guid(_) when meth = `PUT -> 
            (* save notebook *)
            not_found ()

        | `Notebooks_checkpoint(_) -> 
            Server.respond_string ~status:`OK ~body:"[]" ()

        | `Notebooks_checkpoint_id(_) -> not_found ()
        | `Kernels -> 
            kernel_response req

        | `Kernels_guid(_) -> not_found ()
        | `Kernels_restart(_) -> not_found ()
        | `Kernels_interrupt(_) -> not_found ()

        | `Error_not_found | _ -> not_found ()
    in
    let conn_closed conn_id () =
        Printf.eprintf "%s: closed\n%!" (Connection.to_string conn_id)
    in
    let config = { Server.callback; conn_closed } in
    Server.create ~address ~port config

let rec ws_shell uri (stream,push) = 
    Lwt_stream.next stream >>= fun frame ->
    Lwt_io.eprintf "shell: %s\n" (Websocket.Frame.content frame) >>= fun () ->
    ws_shell uri (stream,push)

let ws_stdin uri (stream,push) = 
    Lwt_stream.next stream >>= fun frame ->
    Lwt_io.eprintf "stdin: %s\n" (Websocket.Frame.content frame) >>= fun () ->
    ws_shell uri (stream,push)

let ws_iopub uri (stream,push) = 
    Lwt_stream.next stream >>= fun frame ->
    Lwt_io.eprintf "iopub: %s\n" (Websocket.Frame.content frame) >>= fun () ->
    ws_shell uri (stream,push)

let ws_init uri (stream,push) = 
    Lwt_stream.next stream >>= fun frame ->
        (* display bring up cookie *)
        Lwt_io.eprintf "cookie: %s\n" (Websocket.Frame.content frame) >>= fun () ->
        (* handle each stream *)
        match_lwt Path_messages.decode_ws (Uri.path uri) with
        | `Ws_shell(guid) -> ws_shell uri (stream,push)
        | `Ws_stdin(guid) -> ws_stdin uri (stream,push)
        | `Ws_iopub(guid) -> ws_iopub uri (stream,push)
        | `Error_not_found -> Lwt.fail (Failure "invalid websocket url")

let run_server () = 
    let http_server = make_server http_addr http_port in
    let ws_server = 
        return 
            (Websocket.establish_server 
                (Lwt_unix.ADDR_INET(Unix.inet_addr_of_string ws_addr, ws_port))
                ws_init)
    in
    let rec wait_forever () = Lwt_unix.sleep 1000.0 >>= wait_forever in
    let ws_server = ws_server >>= fun _ -> wait_forever () in
    Lwt.join [ http_server; ws_server ]

let close_kernels () = 
    Kernel_map.iter 
        (fun _ v -> 
            eprintf "killing kernel: %s\n" v.guid;
            v.process#terminate) !g_kernels

let _ = 
    Sys.catch_break true;
    try 
        (*at_exit close_kernels;*)
        Lwt_unix.run (run_server ())
    with
    | Sys.Break -> close_kernels ()

