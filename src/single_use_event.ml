type state = Signaled | Initial | Attached of (unit -> unit)
type t = state Atomic.t

let create () = Atomic.make Initial
let is_signaled t = Atomic.get t == Signaled

let signal t =
  if not (is_signaled t) then
    match Atomic.exchange t Signaled with
    | Signaled | Initial -> ()
    | Attached action -> action ()

type _ Effect.t += Await : t -> unit Effect.t

let try_attach t action =
  Atomic.compare_and_set t Initial (Attached action)
  || is_signaled t
  || invalid_arg "Single_use_event: already attached"

let try_unattach t =
  match Atomic.get t with
  | Signaled -> false
  | Initial -> invalid_arg "Single_use_event: not attached"
  | Attached _ as was -> Atomic.compare_and_set t was Signaled

let await t =
  match Atomic.get t with
  | Signaled -> ()
  | Initial -> begin
      try Effect.perform (Await t)
      with Effect.Unhandled (Await _) ->
        let mutex = Mutex.create () and condition = Condition.create () in
        let release () =
          Mutex.lock mutex;
          Mutex.unlock mutex;
          Condition.broadcast condition
        in
        if (not (is_signaled t)) && try_attach t release then begin
          Mutex.lock mutex;
          while not (is_signaled t) do
            Condition.wait condition mutex
          done;
          Mutex.unlock mutex
        end
    end
  | Attached _ -> invalid_arg "Single_use_event: already attached"
