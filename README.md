[API reference](https://ocaml-multicore.github.io/single-use-event/doc/single-use-event/Single_use_event/index.html)

# **Single-use-event** &mdash; Scheduler agnostic blocking

This is a 3rd generation proposal for a standard blocking mechanism for OCaml.

The mechanism is designed to be **minimalistic** and to **straightforward**ly,
**safe**ly, and **efficient**ly handle all the basic concurrency issues that
might arise, namely the essential race conditions due to the nature of the
problem, within the scope of the provided functionality.

Previous proposals include

- [Unified interface](https://github.com/deepali2806/unified_interface) aka
  [`Suspend` effect](https://github.com/deepali2806/unified_interface/blob/512eadd456e77dc7d02a1aa0813819254308b5f4/lib/sched.mli#L4-L5),
  and
- [Domain local await](https://github.com/ocaml-multicore/domain-local-await/).

See the
[API reference](https://ocaml-multicore.github.io/single-use-event/doc/single-use-event/Single_use_event/index.html)
for details.

<!--
```ocaml
# #thread
# #require "single-use-event"
# #require "backoff"
```
-->

## Examples

### Promise

```ocaml
module Promise : sig
  type 'a t
  val create : unit -> 'a t
  val fill : 'a t -> 'a -> unit
  val await : 'a t -> 'a
end = struct
  type 'a state =
    | Empty of Single_use_event.t list
    | Full of 'a

  type 'a t = 'a state Atomic.t

  let create () = Atomic.make (Empty [])

  let rec fill backoff t full =
    match Atomic.get t with
    | Empty sues as before ->
        if Atomic.compare_and_set t before full then
          List.iter Single_use_event.signal sues
        else
          fill (Backoff.once backoff) t full
    | Full _ ->
        invalid_arg "Promise: already full"

  let fill t value = fill Backoff.default t (Full value)

  let rec cleanup backoff t sue =
    match Atomic.get t with
    | Full _ ->
        ()
    | Empty sues as before ->
        let after = Empty (List.filter ((!=) sue) sues) in
        if not (Atomic.compare_and_set t before after) then
          cleanup (Backoff.once backoff) t sue

  let rec await backoff t =
    match Atomic.get t with
    | Full value ->
        value
    | Empty sues as before ->
        let sue = Single_use_event.create () in
        let after = Empty (sue :: sues) in
        if Atomic.compare_and_set t before after then
          match Single_use_event.await sue with
          | () ->
            await backoff t
          | exception cancellation_exn ->
            cleanup backoff t sue;
            raise cancellation_exn
        else
          await (Backoff.once backoff) t

  let await t = await Backoff.default t
end
```

### Transparently asynchronous IO

```ocaml version>=5.0.0
module Atomic = struct
  include Stdlib.Atomic

  let rec update t fn =
    let before = Atomic.get t in
    let after = fn before in
    if Atomic.compare_and_set t before after then
      before
    else
      update t fn

  let modify t fn = update t fn |> ignore
end
```

```ocaml version>=5.0.0
module Async_io : sig
  open Unix
  val read : file_descr -> bytes -> int -> int -> int
  val write : file_descr -> bytes -> int -> int -> int
  val accept : ?cloexec:bool -> file_descr -> file_descr * sockaddr
end = struct
  module Awaiter = struct
    type t = { file_descr : Unix.file_descr; sue : Single_use_event.t }

    let file_descr_of t = t.file_descr

    let rec signal aws file_descr =
      match aws with
      | [] -> ()
      | aw :: aws ->
          if aw.file_descr == file_descr then
            Single_use_event.signal aw.sue
          else signal aws file_descr

    let signal_or_wakeup wakeup aws file_descr =
      if file_descr == wakeup then begin
        let n = Unix.read file_descr (Bytes.create 1) 0 1 in
        assert (n = 1)
      end
      else signal aws file_descr

    let reject file_descr =
      List.filter (fun aw -> aw.file_descr != file_descr)
  end

  type state = {
    mutable state : [ `Init | `Locked | `Alive | `Dead ];
    mutable pipe_out : Unix.file_descr;
    reading : Awaiter.t list Atomic.t;
    writing : Awaiter.t list Atomic.t;
  }

  let key =
    Domain.DLS.new_key @@ fun () -> {
      state = `Init;
      pipe_out =
        (* Unfortunately we cannot safely allocate a pipe here,
           so we use stdin as a dummy value. *)
        Unix.stdin;
      reading = Atomic.make [];
      writing = Atomic.make [];
    }

  let[@poll error] try_lock s =
    s.state == `Init && begin
      s.state <- `Locked;
      true
    end

  let needs_init s =
    s.state != `Alive

  let[@poll error] unlock s pipe_out =
    s.pipe_out <- pipe_out;
    s.state <- `Alive

  let wakeup s =
    let n = Unix.write s.pipe_out (Bytes.create 1) 0 1 in
    assert (n = 1)

  let rec init s =
    (* DLS initialization may be run multiple times, so we
       perform more involved initialization here. *)
    if try_lock s then begin
      (* The pipe is used to wake up the select after changing
         the lists of reading and writing file descriptors. *)
      let pipe_inn, pipe_out = Unix.pipe ~cloexec:true () in
      unlock s pipe_out;
      let t =
        ()
        |> Thread.create @@ fun () ->
           (* This is the IO select loop that performs select and
              then wakes up fibers blocked on IO. *)
           while s.state != `Dead do
             let rs, ws, _ =
               Unix.select
                 (pipe_inn
                  :: List.map Awaiter.file_descr_of (Atomic.get s.reading))
                 (List.map Awaiter.file_descr_of (Atomic.get s.writing))
                 []
                 (-1.0)
             in
             List.iter
               (Awaiter.signal_or_wakeup pipe_inn (Atomic.get s.reading))
               rs;
             List.iter (Awaiter.signal (Atomic.get s.writing)) ws;
             Atomic.modify s.reading (List.fold_right Awaiter.reject rs);
             Atomic.modify s.writing (List.fold_right Awaiter.reject ws);
         done;
         Unix.close pipe_inn;
         Unix.close pipe_out
      in
      Domain.at_exit @@ fun () ->
        s.state <- `Dead;
        wakeup s;
        Thread.join t
    end
    else if needs_init s then begin
      Thread.yield ();
      init s;
    end

  let get () =
    let s = Domain.DLS.get key in
    if needs_init s then
      init s;
    s

  let await s r file_descr =
    let sue = Single_use_event.create () in
    let awaiter = Awaiter.{ file_descr; sue } in
    Atomic.modify r (List.cons awaiter);
    wakeup s;
    try Single_use_event.await sue
    with cancellation_exn ->
      Atomic.modify r (List.filter ((!=) awaiter));
      raise cancellation_exn

  let read file_descr bytes pos len =
    let s = get () in
    await s s.reading file_descr;
    Unix.read file_descr bytes pos len

  let write file_descr bytes pos len =
    let s = get () in
    await s s.writing file_descr;
    Unix.write file_descr bytes pos len

  let accept ?cloexec file_descr =
    let s = get () in
    await s s.reading file_descr;
    Unix.accept ?cloexec file_descr
end
```

```ocaml version>=5.0.0
module Toy_scheduler : sig
  val fiber : (unit -> unit) -> unit
  val run : (unit -> unit) -> unit
end = struct
  let ready = Atomic.make []
  let num_alive_fibers = ref 0

  let fiber thunk =
    incr num_alive_fibers;
    let thunk () =
      thunk ();
      decr num_alive_fibers
    in
    Atomic.modify ready (List.cons thunk)

  let run program =
    let needs_wakeup = Atomic.make false in
    let pipe_inn, pipe_out = Unix.pipe ~cloexec:true () in
    let rec scheduler () =
      match Atomic.update ready (function [] -> [] | _::xs -> xs) with
      | work::_ ->
        let effc (type a) : a Effect.t -> _ = function
          | Single_use_event.Await sue ->
            Some (fun (k: (a, _) Effect.Deep.continuation) ->
            if
              not (Single_use_event.is_signaled sue) &&
              let enqueue () =
                Atomic.modify ready (List.cons (Effect.Deep.continue k));
                if
                  Atomic.get needs_wakeup &&
                  Atomic.compare_and_set needs_wakeup true false
                then
                  (* The scheduler is potentially waiting on select,
                    so we need to perform a wakeup. *)
                  let n = Unix.write pipe_out (Bytes.create 1) 0 1 in
                  assert (n = 1)
              in
              Single_use_event.try_attach sue enqueue
            then
              ()
            else
              Effect.Deep.continue k ())
          | _ ->
            None in
        Effect.Deep.try_with work () { effc };
        scheduler ()
      | [] ->
        if !num_alive_fibers <> 0 then begin
          if Atomic.get needs_wakeup then
            (* There are blocked fibers, so we wait for them to
               become unblocked. *)
            let _ = Unix.select [pipe_inn] [] [] (-1.0) in
            let n = Unix.read pipe_inn (Bytes.create 1) 0 1 in
            assert (n = 1)
          else
            (* There are blocked fibers, so we need to wait for
               them to become ready.  But we need to check the
               ready list once more before we do so. *)
            Atomic.set needs_wakeup true;
          scheduler ()
        end
    in
    incr num_alive_fibers;
    let program () =
      program ();
      decr num_alive_fibers
    in
    Atomic.modify ready (List.cons program);
    scheduler ()
end
```

```ocaml version>=5.0.0
# Toy_scheduler.run @@ fun () ->

  let n = 100 in
  let port = Random.int 1000 + 3000 in
  let server_addr = Unix.ADDR_INET (Unix.inet_addr_loopback, port) in

  let () =
    Toy_scheduler.fiber @@ fun () ->
    Printf.printf "  Client running\n%!";
    let socket = Unix.socket ~cloexec:true PF_INET SOCK_STREAM 0 in
    Fun.protect ~finally:(fun () -> Unix.close socket) @@ fun () ->
    Unix.connect socket server_addr;
    Printf.printf "  Client connected\n%!";
    let bytes = Bytes.create n in
    let n = Async_io.write socket bytes 0 (Bytes.length bytes) in
    Printf.printf "  Client wrote %d\n%!" n;
    let n = Async_io.read socket bytes 0 (Bytes.length bytes) in
    Printf.printf "  Client read %d\n%!" n
  in

  let () =
    Toy_scheduler.fiber @@ fun () ->
    Printf.printf "  Server running\n%!";
    let client, _client_addr =
      let socket = Unix.socket ~cloexec:true PF_INET SOCK_STREAM 0 in
      Fun.protect ~finally:(fun () -> Unix.close socket) @@ fun () ->
      Unix.set_nonblock socket;
      Unix.bind socket server_addr;
      Unix.listen socket 1;
      Printf.printf "  Server listening\n%!";
      Async_io.accept ~cloexec:true socket
    in
    Fun.protect ~finally:(fun () -> Unix.close client) @@ fun () ->
    Unix.set_nonblock client;
    let bytes = Bytes.create n in
    let n = Async_io.read client bytes 0 (Bytes.length bytes) in
    Printf.printf "  Server read %d\n%!" n;
    let n = Async_io.write client bytes 0 (n / 2) in
    Printf.printf "  Server wrote %d\n%!" n
  in

  Printf.printf "Client server test\n%!"
Client server test
  Server running
  Server listening
  Client running
  Client connected
  Client wrote 100
  Server read 100
  Server wrote 50
  Client read 50
- : unit = ()
```
