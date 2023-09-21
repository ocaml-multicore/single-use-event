(** A scheduler independent blocking mechanism.

    This is designed as a low level mechanism intended for writing higher level
    libraries that need to block in a scheduler friendly manner.

    A library that needs to suspend and later resume the current thread of
    execution can {!create} a single use event, arrange {!signal} to be
    called on it, and {!await} for the call.

    To provide an efficient and scheduler friendly implementation of the
    mechanism, schedulers may handle the {!Await} effect.

    The mechanism is designed to be minimalistic and to straightforwardly,
    safely, and efficiently handle all the basic concurrency issues that might
    arise, namely the essential race conditions due to the nature of the
    problem, within the scope of the provided functionality.

    The only place to handle cancellation is at the point of calling {!await},
    which may raise an exception to signal cancellation.  The caller must then
    take care to clean up.

    No mechanism is provided to communicate any result with the signal.  That
    can be done outside of the mechanism and is often not needed.

    This mechanism is entirely first-order.  A handler for the {!Await} effect
    does not need to call arbitrary code outside of the scheduler
    implementation.  Both the scheduler side and the suspend/resume side are
    only responsible for their own concerns.

    All operations on single use events are wait-free, with the obvious
    exception of {!await}.  The {!signal} operation inherits the properties of
    the action attached to the single use event. *)

(** {2 Interface for suspending} *)

type t
(** Represents a single use event.  A single use event can be in one of three
    states in order:

    {ol {- initial,}
        {- attached, and}
        {- signaled.}}

    The state of a single use event can only advance monotonically. *)

val create : unit -> t
(** [create ()] allocates a new single use event in the initial state. *)

val is_signaled : t -> bool
(** [is_signaled sue] determines whether the single use event [sue] is in the
    signaled state.

    This can be used to poll the state of a single use event and avoid work,
    but this should not be used as a substitute for {!await}. *)

val await : t -> unit
(** [await sue] waits for the single use event [sue] to be set to the signaled
    state.  [await sue] must be called at most once per single use event [sue].

    Instead of returning, [await sue] may raise an exception to signal
    cancellation.  In either case the caller of [await sue] is responsible for
    cleaning up.  Usually this means making sure that no references to the
    single use event [sue] remain to avoid space leaks.

    @raise Invalid_argument if the single use event [sue] was in the attached
      state. *)

(** Here is a template for suspending:
    {[
      let suspend _ =
        (* Typically, at this point or just before the [await], a location has
           been published where the result will be written to by the resumer
           side. *)

        let sue = Single_use_event.create () in

        (* TODO: Store references to [sue] in shared data structures for the
           resumer side to find. *)

        if Single_use_event.is_signaled sue then
          (* Resumer side signaled before suspend.  This can happen e.g. when
             the [sue] is inserted into many locations and polling the signaled
             state can be used to avoid work.

             TODO: Clean up accordingly, i.e. remove references to [sue] that
             were inserted before getting the signal.

             TODO: Produce appropriate result. *)
        else
          match Single_use_event.await sue with
          | () ->
            (* Fiber was resumed.

               TODO: Clean up accordingly, i.e. remove any remaining references
               to [sue].

               TODO: Produce appropriate result.

               Typically, a result is read from the location where it was
               written before [Single_use_event.signal sue] by the resumer
               side. *)
          | exception cancellation_exn ->
            (* Fiber was cancelled.

               TODO: Clean up accordingly, i.e. remove all references to
               [sue]. *)

            raise cancellation_exn
    ]} *)

(** {2 Interface for resuming} *)

val signal : t -> unit
(** After [signal sue] returns, the single use event [sue] will be in the
    signaled state.  If the single use event [sue] was in the attached state,
    the attached action will be called after the single use event [sue] was
    set to the signaled state. *)

(** Here is a template for resuming:
    {[
      let resume _ =
        (* Typically, at this point, the result has been atomically written to
            some data structure that the suspend side has access to. *)

        let sue =
          (* TODO: Obtain [sue] from shared data structure.

             Typically at least one specific reference to [sue] is also removed
             at this point. *)
        in
        Single_use_event.signal sue

        (* Typically, nothing needs to be done at this point.

           If necessary, determine whether target fiber was resumed or not as
           desired, and produce appropriate result. *)
    ]} *)

(** {2 Interface for schedulers} *)

(** [Effect.t] was added in OCaml 5.0.  Under older versions of OCaml {!await}
    uses a [Mutex] and a [Condition] variable and there is no way to customize
    the behavior. *)
type _ Effect.t +=
  | Await : t -> unit Effect.t
        (** [Await sue] effect may be performed by [await sue] to await for the
            single use event [sue] to be set to the signaled state. *)

val try_attach : t -> (unit -> unit) -> bool
(** [try_attach sue action] tries to set the single use event [sue] to the
    attached state, which can only succeed if [sue] was in the initial state.
    The [action] should be safe to call from any context that {!signal} might be
    called from.

    [try_attach sue action] must be called at most once per single use event
    [sue].

    @raise Invalid_argument if the single use event [sue] was in the attached
      state. *)

val try_unattach : t -> bool
(** [try_unattach sue] tries to set the single use event [sue] to the signaled
    state, which can only succeed if [sue] was in the attached state.

    [try_unattach sue] may only be called after [try_attach sue action] has been
    called successfully on the single use event [sue].

    @raise Invalid_argument if the single use event [sue] was in the initial
      state. *)

(** Here is a template for schedulers:
    {[
      let handler (type e) : a Effect.t -> _ = function
        | Single_use_event.Await sue ->
          Some (fun (k: (a, _) Effect.Deep.continuation) ->
            if
              (* We first check if the event has already been signaled as an
                 optimization to avoid allocating the [enqueue] closure: *)
              not (Single_use_event.is_signaled sue) &&
              let enqueue () =
                (* TODO: Enqueue [Effect.Deep.continue k ()] to the scheduler's
                   data structure for ready fibers.  This must be safe to call
                   from any execution context that [Single_use_event.signal sue]
                   might be called from.

                   [Single_use_event] guarantees this is called at most once. *)
              in
              Single_use_event.try_attach enqueue
            then begin
              (* If the scheduler supports cancellation, then one would likely
                 register a cancellation action for the fiber at this point.

                 TODO: Remove or edit the sample code below: *)

              set_cancellation_action (fun cancellation_exn ->
                if Single_use_event.try_unattach sue then
                  (* Cancellation won the race, so at this point the fiber
                     should be enqueued to be discontinued with the
                     [cancellation_exn]. *)
                else
                  (* [Single_use_event.signal sue] won the race and [enqueue]
                     has been or will be called. *)
              )

              (* At this point the scheduler would typically take the next ready
                 fiber to execute and continue running it. *)
            end
            else
              (* [Single_use_event.signal sue] won the race, so just
                 continue: *)
              Effect.Deep.continue k ()
        | _ ->
          None
    ]} *)
