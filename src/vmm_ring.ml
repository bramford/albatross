(* (c) 2017 Hannes Mehnert, all rights reserved *)

(* a ring buffer with N strings, dropping old ones *)

type t = {
  data : (Ptime.t * string) array ;
  mutable write : int ;
  size : int ;
}

let create ?(size = 1024) () =
  { data = Array.make 1024 (Ptime.min, "") ; write = 0 ; size }

let inc t = (succ t.write) mod t.size

let write t v =
  Array.set t.data t.write v ;
  t.write <- inc t

let dec t n = (pred n + t.size) mod t.size

let earlier ts than =
  if ts = Ptime.min then true
  else Ptime.is_earlier ts ~than

let read_history t than =
  let rec go s acc idx =
    if idx = s then (* don't read it twice *)
      acc
    else
      let ts, v = Array.get t.data idx in
      if earlier ts than then acc
      else go s ((ts, v) :: acc) (dec t idx)
  in
  let idx = dec t t.write in
  let ts, v = Array.get t.data idx in
  if earlier ts than then []
  else go idx [(ts,v)] (dec t idx)
