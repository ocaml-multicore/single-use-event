type t
(** Represents a single use event. *)

val create : unit -> t
(** [create ()] allocates a new single use event in the initial state. *)

val is_initial : t -> bool
(** [is_initial t] determines whether the single use event [t] is in the initial
    state. *)

val is_attached : t -> bool
(** [is_attached t] determines whether the single use event [t] is in the attached
    state. *)

val is_signaled : t -> bool
(** [is_signaled t] determines whether the single use event [t] is in the signaled
    state. *)

val signal : t -> unit
(** After [signal t] returns, the single use event [t] will be in the signaled
    state.  If the single use event [t] was in the attached state, the attached
    action will be called. *)

val try_attach : t -> (unit -> unit) -> bool
(** [try_attach t action] tries to set the single use event [t] to the attached
    state, which can only succeed if [t] was in the initial state.  The [action]
    should be safe to call from any execution context. *)

val try_unattach : t -> bool
(** [try_unattach t] tries to set the single use event [t] to the signaled state,
    which can only succeed if [t] was in the attached state. *)

type _ Effect.t +=
  | Await : t -> unit Effect.t
        (** [Await t] effect may be performed by [await t] to await for the
            single use event [t] to be set to the signaled state. *)

val await : t -> unit
(** [await t] waits for the single use event [t] to be set to the signaled state. *)
