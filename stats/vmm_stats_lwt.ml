(* (c) 2017, 2018 Hannes Mehnert, all rights reserved *)

(* the process responsible for gathering statistics (CPU + mem + network) *)

(* a shared unix domain socket between vmmd and vmm_stats is used as
   communication channel, where the vmmd can issue commands:

   - add pid taps
   - remove pid
   - statistics pid

   every 10 seconds, statistics of all registered pids are recorded. `statistics`
   reports last recorded stats *)

open Lwt.Infix

let t = ref (Vmm_stats.empty ())

let pp_sockaddr ppf = function
  | Lwt_unix.ADDR_UNIX str -> Fmt.pf ppf "unix domain socket %s" str
  | Lwt_unix.ADDR_INET (addr, port) -> Fmt.pf ppf "TCP %s:%d"
                                         (Unix.string_of_inet_addr addr) port

let handle s addr () =
  Logs.info (fun m -> m "handling stats connection %a" pp_sockaddr addr) ;
  let rec loop acc =
    Vmm_lwt.read_exactly s >>= function
    | Error (`Msg msg) -> Logs.err (fun m -> m "error while reading %s" msg) ; loop acc
    | Error _ -> Logs.err (fun m -> m "exception while reading") ; Lwt.return acc
    | Ok (hdr, data) ->
      Logs.debug (fun m -> m "received %a" Cstruct.hexdump_pp (Cstruct.of_string data)) ;
      let t', action, out = Vmm_stats.handle !t hdr data in
      let acc = match action with
        | `Add pid -> pid :: acc
        | `Remove pid -> List.filter (fun m -> m <> pid) acc
        | `None -> acc
      in
      t := t' ;
      Logs.debug (fun m -> m "sent %a" Cstruct.hexdump_pp (Cstruct.of_string out)) ;
      Vmm_lwt.write_raw s out >>= function
      | Ok () -> loop acc
      | Error _ -> Logs.err (fun m -> m "exception while writing") ; Lwt.return acc
  in
  loop [] >>= fun vmids ->
  Lwt.catch (fun () -> Lwt_unix.close s) (fun _ -> Lwt.return_unit) >|= fun () ->
  Logs.warn (fun m -> m "disconnect, dropping %d vms!" (List.length vmids)) ;
  let t' = Vmm_stats.remove_vmids !t vmids in
  t := t'

let rec timer interval () =
  t := Vmm_stats.tick !t ;
  Lwt_unix.sleep interval >>= fun () ->
  timer interval ()

let jump _ file interval =
  Sys.(set_signal sigpipe Signal_ignore) ;
  let interval = Duration.(to_f (of_sec interval)) in
  Lwt_main.run
    ((Lwt_unix.file_exists file >>= function
       | true -> Lwt_unix.unlink file
       | false -> Lwt.return_unit) >>= fun () ->
     let s = Lwt_unix.(socket PF_UNIX SOCK_STREAM 0) in
     Lwt_unix.(bind s (ADDR_UNIX file)) >>= fun () ->
     Lwt_unix.listen s 1 ;
     Lwt.async (timer interval) ;
     let rec loop () =
       Lwt_unix.accept s >>= fun (cs, addr) ->
       Lwt.async (handle cs addr) ;
       loop ()
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

let socket =
  let doc = "Socket to listen on" in
  let sock = Fpath.(to_string (Vmm_core.tmpdir / "stat" + "sock")) in
  Arg.(value & opt string sock & info [ "s" ; "socket" ] ~doc)

let interval =
  let doc = "Interval between statistics gatherings (in seconds)" in
  Arg.(value & opt int 10 & info [ "internval" ] ~doc)

let cmd =
  Term.(ret (const jump $ setup_log $ socket $ interval)),
  Term.info "vmm_stats" ~version:"%%VERSION_NUM%%"

let () = match Term.eval cmd with `Ok () -> exit 0 | _ -> exit 1
