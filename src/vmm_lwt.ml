(* (c) 2017 Hannes Mehnert, all rights reserved *)

open Lwt.Infix

let pp_process_status ppf = function
  | Unix.WEXITED c -> Fmt.pf ppf "exited with %d" c
  | Unix.WSIGNALED s -> Fmt.pf ppf "killed by signal %a" Fmt.Dump.signal s
  | Unix.WSTOPPED s -> Fmt.pf ppf "stopped by signal %a" Fmt.Dump.signal s

let ret = function
  | Unix.WEXITED c -> `Exit c
  | Unix.WSIGNALED s -> `Signal s
  | Unix.WSTOPPED s -> `Stop s

let rec waitpid pid =
  Lwt.catch
    (fun () -> Lwt_unix.waitpid [] pid >|= fun r -> Ok r)
    (function
      | Unix.(Unix_error (EINTR, _, _)) ->
        Logs.debug (fun m -> m "EINTR in waitpid(), %d retrying" pid) ;
        waitpid pid
      | e ->
        Logs.err (fun m -> m "error %s in waitpid() %d"
                     (Printexc.to_string e) pid) ;
        Lwt.return (Error ()))

let wait_and_clear pid stdout =
  Logs.debug (fun m -> m "waitpid() for pid %d" pid) ;
  waitpid pid >|= fun r ->
  Vmm_commands.close_no_err stdout ;
  match r with
  | Error () ->
    Logs.err (fun m -> m "waitpid() for %d returned error" pid) ;
    `Exit 23
  | Ok (_, s) ->
    Logs.debug (fun m -> m "pid %d exited: %a" pid pp_process_status s) ;
    ret s

let read_exactly s =
  let buf = Bytes.create 8 in
  let rec r b i l =
    Lwt.catch (fun () ->
        Lwt_unix.read s b i l >>= function
        | 0 ->
          Logs.err (fun m -> m "end of file while reading") ;
          Lwt.return (Error `Eof)
        | n when n == l -> Lwt.return (Ok ())
        | n when n < l -> r b (i + n) (l - n)
        | _ ->
          Logs.err (fun m -> m "read too much, shouldn't happen)") ;
          Lwt.return (Error `Toomuch))
      (fun e ->
         let err = Printexc.to_string e in
         Logs.err (fun m -> m "exception %s while reading" err) ;
         Lwt.return (Error `Exception))

  in
  r buf 0 8 >>= function
  | Error e -> Lwt.return (Error e)
  | Ok () ->
    match Vmm_wire.parse_header (Bytes.to_string buf) with
    | Error (`Msg m) -> Lwt.return (Error (`Msg m))
    | Ok hdr ->
      let l = hdr.Vmm_wire.length in
      if l > 0 then
        let b = Bytes.create l in
        r b 0 l >|= function
        | Error e -> Error e
        | Ok () ->
          (* Logs.debug (fun m -> m "read hdr %a, body %a"
                         Cstruct.hexdump_pp (Cstruct.of_bytes buf)
                         Cstruct.hexdump_pp (Cstruct.of_bytes b)) ; *)
          Ok (hdr, Bytes.to_string b)
      else
        Lwt.return (Ok (hdr, ""))

let write_raw s buf =
  let buf = Bytes.unsafe_of_string buf in
  let rec w off l =
    Lwt.catch (fun () ->
        Lwt_unix.send s buf off l [] >>= fun n ->
        if n = l then
          Lwt.return (Ok ())
        else
          w (off + n) (l - n))
      (fun e ->
         Logs.err (fun m -> m "exception %s while writing" (Printexc.to_string e)) ;
         Lwt.return (Error `Exception))
  in
  (* Logs.debug (fun m -> m "writing %a" Cstruct.hexdump_pp (Cstruct.of_bytes buf)) ; *)
  w 0 (Bytes.length buf)
