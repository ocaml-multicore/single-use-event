```ocaml
# #require "single-use-event"
```

```ocaml
module Promise : sig
  type 'a t
  val create : unit -> 'a t
  val fill : 'a t -> 'a -> unit
  val await : 'a t -> 'a
end = struct
  type 'a state =
    | Empty
    | Await of Single_use_event.t * 'a state
    | Full of 'a

  type 'a t = 'a state Atomic.t

  let create () = Atomic.make Empty

  let rec signal = function
    | Await (e, es) ->
      Single_use_event.signal e;
      signal es
    | Empty | Full _ -> ()

  let rec fill t value =
    match Atomic.get t with
    | (Empty | Await _) as es ->
      if Atomic.compare_and_set t es (Full value) then
        signal es
      else
        fill t value
    | Full _ ->
      invalid_arg "Promise: already full"

  let rec await t =
    match Atomic.get t with
    | Full value ->
      value
    | (Empty | Await _) as es ->
      let e = Single_use_event.create () in
      if Atomic.compare_and_set t es (Await (e, es)) then
        Single_use_event.await e;
      await t
end
```
