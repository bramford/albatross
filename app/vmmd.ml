(* (c) 2017 Hannes Mehnert, all rights reserved *)

open Lwt.Infix

let write_tls state t data =
  Lwt.catch (fun () -> Vmm_tls.write_tls (fst t) data)
    (fun e ->
       let state', out = Vmm_engine.handle_disconnect !state t in
       state := state' ;
       Lwt_list.iter_s (fun (s, data) -> Vmm_lwt.write_raw s data) out >>= fun () ->
       Tls_lwt.Unix.close (fst t) >>= fun () ->
       raise e)

let to_ipaddr (_, sa) = match sa with
  | Lwt_unix.ADDR_UNIX _ -> invalid_arg "cannot convert unix address"
  | Lwt_unix.ADDR_INET (addr, port) -> Ipaddr_unix.V4.of_inet_addr_exn addr, port

let pp_sockaddr ppf (_, sa) = match sa with
  | Lwt_unix.ADDR_UNIX str -> Fmt.pf ppf "unix domain socket %s" str
  | Lwt_unix.ADDR_INET (addr, port) -> Fmt.pf ppf "TCP %s:%d"
                                         (Unix.string_of_inet_addr addr) port

let process state xs =
  Lwt_list.iter_s (function
      | `Raw (s, str) -> Vmm_lwt.write_raw s str
      | `Tls (s, str) -> write_tls state s str)
    xs

let handle ca state t =
  Logs.debug (fun m -> m "connection from %a" pp_sockaddr t) ;
  let authenticator =
    let time = Ptime_clock.now () in
    X509.Authenticator.chain_of_trust ~time ~crls:!state.Vmm_engine.crls [ca]
  in
  Lwt.catch
    (fun () -> Tls_lwt.Unix.reneg ~authenticator (fst t))
    (fun e ->
       (match e with
        | Tls_lwt.Tls_alert a -> Logs.err (fun m -> m "TLS ALERT %s" (Tls.Packet.alert_type_to_string a))
        | Tls_lwt.Tls_failure f -> Logs.err (fun m -> m "TLS FAILURE %s" (Tls.Engine.string_of_failure f))
        | exn -> Logs.err (fun m -> m "%s" (Printexc.to_string exn))) ;
       Tls_lwt.Unix.close (fst t) >>= fun () ->
       Lwt.fail e) >>= fun () ->
  (match Tls_lwt.Unix.epoch (fst t) with
   | `Ok epoch -> Lwt.return epoch.Tls.Core.peer_certificate_chain
   | `Error ->
     Tls_lwt.Unix.close (fst t) >>= fun () ->
     Lwt.fail_with "error while getting epoch") >>= fun chain ->
  match Vmm_engine.handle_initial !state t (to_ipaddr t) chain ca with
  | Ok (state', outs, next) ->
    state := state' ;
    process state outs >>= fun () ->
    (match next with
     | `Create cont ->
       (match cont !state t with
        | Ok (state', outs, vm) ->
          state := state' ;
          process state outs >>= fun () ->
          Lwt.async (fun () ->
              Vmm_lwt.wait_and_clear vm.Vmm_core.pid vm.Vmm_core.stdout >>= fun r ->
              let state', outs = Vmm_engine.handle_shutdown !state vm r in
              state := state' ;
              process state outs) ;
          Lwt.return_unit
        | Error (`Msg e) ->
          Logs.err (fun m -> m "error while cont %s" e) ;
          let err = Vmm_wire.fail ~msg:e 0 !state.Vmm_engine.client_version in
          process state [ `Tls (t, err) ]) >>= fun () ->
       Tls_lwt.Unix.close (fst t)
     | `Loop (prefix, perms) ->
       let rec loop () =
         Vmm_tls.read_tls (fst t) >>= function
         | Error (`Msg msg) ->
           Logs.err (fun m -> m "reading client %a error: %s" pp_sockaddr t msg) ;
           loop ()
         | Ok (hdr, buf) ->
           let state', out = Vmm_engine.handle_command !state t prefix perms hdr buf in
           state := state' ;
           process state out >>= fun () ->
           loop ()
       in
       Lwt.catch loop
         (fun e ->
            let state', cons = Vmm_engine.handle_disconnect !state t in
            state := state' ;
            Lwt_list.iter_s (fun (s, data) -> Vmm_lwt.write_raw s data) cons >>= fun () ->
            Tls_lwt.Unix.close (fst t) >>= fun () ->
            raise e)
     | `Close socks ->
       Logs.debug (fun m -> m "closing session with %d active ones" (List.length socks)) ;
       Lwt_list.iter_s (fun (t, _) -> Tls_lwt.Unix.close t) socks >>= fun () ->
       Tls_lwt.Unix.close (fst t))
  | Error (`Msg e) ->
    Logs.err (fun m -> m "VMM %a %s" pp_sockaddr t e) ;
    let err = Vmm_wire.fail ~msg:e 0 !state.Vmm_engine.client_version in
    process state [`Tls (t, err)] >>= fun () ->
    Tls_lwt.Unix.close (fst t)

let server_socket port =
  let open Lwt_unix in
  let s = socket PF_INET SOCK_STREAM 0 in
  set_close_on_exec s ;
  setsockopt s SO_REUSEADDR true ;
  Versioned.bind_2 s (ADDR_INET (Unix.inet_addr_any, port)) >>= fun () ->
  listen s 10 ;
  Lwt.return s

let init_exception () =
  Lwt.async_exception_hook := (function
      | Tls_lwt.Tls_failure a ->
        Logs.err (fun m -> m "tls failure: %s" (Tls.Engine.string_of_failure a))
      | exn ->
        Logs.err (fun m -> m "exception: %s" (Printexc.to_string exn)))

let rec read_log state s =
  Vmm_lwt.read_exactly s >>= function
  | Error (`Msg msg) ->
    Logs.err (fun m -> m "reading log error %s" msg) ;
    read_log state s
  | Ok (hdr, data) ->
    let state', outs = Vmm_engine.handle_log !state hdr data in
    state := state' ;
    process state outs >>= fun () ->
    read_log state s

let rec read_cons state s =
  Vmm_lwt.read_exactly s >>= function
  | Error (`Msg msg) ->
    Logs.err (fun m -> m "reading console error %s" msg) ;
    read_cons state s
  | Ok (hdr, data) ->
    let state', outs = Vmm_engine.handle_cons !state hdr data in
    state := state' ;
    process state outs >>= fun () ->
    read_cons state s

let rec read_stats state s =
  Vmm_lwt.read_exactly s >>= function
  | Error (`Msg msg) ->
    Logs.err (fun m -> m "reading stats error %s" msg) ;
    read_stats state s
  | Ok (hdr, data) ->
    let state', outs = Vmm_engine.handle_stat !state hdr data in
    state := state' ;
    process state outs >>= fun () ->
    read_stats state s

let cmp_s (_, a) (_, b) =
  let open Lwt_unix in
  match a, b with
  | ADDR_UNIX str, ADDR_UNIX str' -> String.compare str str' = 0
  | ADDR_INET (addr, port), ADDR_INET (addr', port') ->
    port = port' &&
    String.compare (Unix.string_of_inet_addr addr) (Unix.string_of_inet_addr addr') = 0
  | _ -> false

let jump _ dir cacert cert priv_key =
  Sys.(set_signal sigpipe Signal_ignore) ;
  Lwt_main.run
    (init_exception () ;
     let d = Fpath.v dir in
     let c = Lwt_unix.(socket PF_UNIX SOCK_STREAM 0) in
     Lwt_unix.set_close_on_exec c ;
     Lwt_unix.(connect c (ADDR_UNIX Fpath.(to_string (d / "cons" + "sock")))) >>= fun () ->
     Lwt.catch (fun () ->
         let s = Lwt_unix.(socket PF_UNIX SOCK_STREAM 0) in
         Lwt_unix.set_close_on_exec s ;
         Lwt_unix.(connect s (ADDR_UNIX Fpath.(to_string (d / "stat" + "sock")))) >|= fun () ->
         Some s)
       (function
         | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return None
         | e -> Lwt.fail e) >>= fun s ->
     let l = Lwt_unix.(socket PF_UNIX SOCK_STREAM 0) in
     Lwt_unix.set_close_on_exec l ;
     Lwt_unix.(connect l (ADDR_UNIX Fpath.(to_string (d / "log" + "sock")))) >>= fun () ->
     server_socket 1025 >>= fun socket ->
     X509_lwt.private_of_pems ~cert ~priv_key >>= fun cert ->
     X509_lwt.certs_of_pem cacert >>= (function
         | [ ca ] -> Lwt.return ca
         | _ -> Lwt.fail_with "expect single ca as cacert") >>= fun ca ->
     let config =
       Tls.(Config.server ~version:(Core.TLS_1_2, Core.TLS_1_2)
              ~reneg:true ~certificates:(`Single cert) ())
     in
     (match Vmm_engine.init d cmp_s c s l with
      | Ok s -> Lwt.return s
      | Error (`Msg m) -> Lwt.fail_with m) >>= fun t ->
     let state = ref t in
     Lwt.async (fun () -> read_cons state c) ;
     (match s with
      | None -> ()
      | Some s -> Lwt.async (fun () -> read_stats state s)) ;
     Lwt.async (fun () -> read_log state l) ;
     let rec loop () =
       Lwt.catch (fun () ->
           Lwt_unix.accept socket >>= fun (fd, addr) ->
           Lwt_unix.set_close_on_exec fd ;
           Lwt.catch
             (fun () -> Tls_lwt.Unix.server_of_fd config fd >|= fun t -> (t, addr))
             (fun exn ->
                Lwt.catch (fun () -> Lwt_unix.close fd) (fun _ -> Lwt.return_unit) >>= fun () ->
                Lwt.fail exn) >>= fun t ->
           Lwt.async (fun () -> handle ca state t) ;
           loop ())
         (function
           | Unix.Unix_error (e, f, _) ->
             Logs.err (fun m -> m "Unix error %s in %s" (Unix.error_message e) f) ;
             loop ()
           | Tls_lwt.Tls_failure a ->
             Logs.err (fun m -> m "tls failure: %s" (Tls.Engine.string_of_failure a)) ;
             loop ()
           | exn ->
             Logs.err (fun m -> m "exception %s" (Printexc.to_string exn)) ;
             loop ())
     in
     loop ())

let setup_log style_renderer level =
  Fmt_tty.setup_std_outputs ?style_renderer ();
  Logs.set_level level;
  Logs.set_reporter (Logs_fmt.reporter ~dst:Format.std_formatter ())

open Cmdliner

let setup_log =
  Term.(const setup_log
        $ Fmt_cli.style_renderer ()
        $ Logs_cli.level ())

let wdir =
  let doc = "Working directory (unix domain sockets, etc.)" in
  Arg.(required & pos 0 (some dir) None & info [] ~doc)

let cacert =
  let doc = "CA certificate" in
  Arg.(required & pos 1 (some file) None & info [] ~doc)

let cert =
  let doc = "Certificate" in
  Arg.(required & pos 2 (some file) None & info [] ~doc)

let key =
  let doc = "Private key" in
  Arg.(required & pos 3 (some file) None & info [] ~doc)

let cmd =
  Term.(ret (const jump $ setup_log $ wdir $ cacert $ cert $ key)),
  Term.info "vmmd" ~version:"%%VERSION_NUM%%"

let () = match Term.eval cmd with `Ok () -> exit 0 | _ -> exit 1
