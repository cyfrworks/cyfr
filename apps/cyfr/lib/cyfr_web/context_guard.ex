# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.ContextGuard do
  @moduledoc """
  The one guard a retained console context passes before it is acted on.

  A console socket, a nested view, a component, a task a page started and
  an open stream all hold a `Sanctum.Context` that was established once
  and then kept. Its authority is only as current as its `validated_at`.
  This module is where every such holder asks for a current one: a
  context validated within the freshness bound (`Sanctum.Caller.fresh?/1`)
  is used as it is, and any other is revalidated from the store
  (`Sanctum.Caller.revalidate_session/1`) before the work runs. A standing
  announcement — sessions revoked, this session invalidated, a membership
  changed, the focused estate archived — revalidates at once, whatever
  the context's age. Announcements are the prompt path; the bound is the
  backstop for one that never arrives.

  The surfaces:

    * `on_mount(:protected, …)` — routed and nested LiveViews. It
      establishes the cookie's session, subscribes to the standing
      announcements, and only then revalidates, so a revocation between
      establishing and subscribing is still read. It attaches hooks that
      run the rule before every `handle_event`, `handle_info` and (for a
      root view) `handle_params`.
    * `guard/2` — a LiveComponent's `handle_event` and `update`, which no
      view hook sees.
    * `check/1` — a bare context: the catalog adapter, a task, a
      per-request read.
    * `refocus/2` — a view that moves its focus to another estate.
    * `capture/1` and `deliver/3` — a task's result, delivered only to the
      tenant and focus it was computed for.
    * `watch/2`, `standing/2` and `unwatch/1` — a long-lived stream.

  Refusals: a session that no longer stands (`:unauthenticated`,
  `:not_standing`) sends the person to sign in, a focus that no longer
  stands (`:not_member`) sends them to the root, and a store that cannot
  answer (`:unavailable`) halts the action with "try again shortly" —
  never a success and never a sign-out.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Cyfr.Bus.{AthanorArchived, CallerInvalidated, Membership, Session}
  alias Phoenix.LiveView
  alias Phoenix.LiveView.Socket
  alias Sanctum.{Caller, Context}

  require Logger

  # The Plug session key the sign-in writes the Sanctum session token under.
  @session_key :sanctum_session_token

  # Every holder's forced recheck — a component that found its context
  # refused, a stream's periodic tick — is this one message.
  @recheck {__MODULE__, :recheck}

  # A deadline-bounded stream revalidates at least this often, whether or
  # not an announcement reached it.
  @stream_recheck_ms :timer.seconds(30)

  @unavailable "Your session could not be checked just now. Try again shortly."
  @focus_lost "That estate is no longer open to you."

  @typedoc "Why a retained context was refused."
  @type refusal :: Caller.revalidation_refusal()

  @typedoc """
  What a deferred result was computed under: the tenant, the membership
  that authorized the focus, and when that context was last validated.
  """
  @type tag :: {String.t() | nil, String.t() | :key | nil, DateTime.t() | nil}

  @typedoc """
  A stream's standing watch (`watch/2`): the context it holds, the
  recheck's cadence and timer, and the person whose standing it
  subscribed to.
  """
  @type watch :: %{
          context: Context.t(),
          every: pos_integer(),
          timer: reference(),
          user_id: String.t() | nil
        }

  @doc "The Plug session key holding the Sanctum session token."
  @spec session_key() :: atom()
  def session_key, do: @session_key

  @doc "The message that makes a holder revalidate now, whatever its context's age."
  @spec recheck_message() :: {module(), :recheck}
  def recheck_message, do: @recheck

  # ---------------------------------------------------------------------------
  # LiveViews
  # ---------------------------------------------------------------------------

  @doc """
  `on_mount` for every protected LiveView, routed or nested.

  A nested view names the page's estate in its session as `"athanor_id"`
  and is established focused on it. The connected mount subscribes to the
  standing announcements before it revalidates, and the context it
  assigns is the revalidated one.
  """
  def on_mount(:protected, _params, session, socket) do
    token = session[to_string(@session_key)]

    # The mount slides the session when it is due, on Sanctum's own task
    # pool (`Sanctum.Caller.establish/2`), never on this process.
    case Caller.establish(token, focus: session["athanor_id"]) do
      {:ok, ctx} ->
        case admit(socket, ctx) do
          {:ok, socket} -> {:cont, attach(socket)}
          {:error, reason} -> {:halt, LiveView.redirect(socket, to: mount_refusal(reason))}
        end

      {:error, refusal} ->
        {:halt, LiveView.redirect(socket, to: mount_refusal(refusal))}
    end
  end

  defp admit(socket, ctx) do
    if LiveView.connected?(socket) do
      Cyfr.LoggerContext.set_request_id(socket.id)
      subscribe(ctx)

      with {:ok, fresh} <- Caller.revalidate_session(ctx),
           do: {:ok, put_context(socket, fresh)}
    else
      {:ok, put_context(socket, ctx)}
    end
  end

  defp attach(socket) do
    socket =
      socket
      |> LiveView.attach_hook(__MODULE__, :handle_event, &on_event/3)
      |> LiveView.attach_hook(__MODULE__, :handle_info, &on_info/2)

    # Only a view mounted at the router has params of its own; LiveView
    # refuses the hook on any other (a nested view, an isolated mount).
    if routed?(socket),
      do: LiveView.attach_hook(socket, __MODULE__, :handle_params, &on_params/3),
      else: socket
  end

  defp routed?(%Socket{parent_pid: parent, router: router}),
    do: is_nil(parent) and not is_nil(router)

  defp on_event(_event, _params, socket), do: proceed(socket)
  defp on_params(_params, _uri, socket), do: proceed(socket)

  # Announcements about this caller revalidate now; announcements about
  # anyone else are consumed here, as the gate's own traffic. A membership
  # change goes on to the page afterwards, which may have a list to reread.
  defp on_info(%Session{kind: :revoked, user_id: user_id}, socket) do
    if caller?(socket, &(&1.user_id == user_id)),
      do: settle(socket, :halt),
      else: {:halt, socket}
  end

  defp on_info(%CallerInvalidated{session_key: key}, socket) do
    if caller?(socket, &(&1.session_token_hash == key)),
      do: settle(socket, :halt),
      else: {:halt, socket}
  end

  defp on_info(%AthanorArchived{athanor_id: athanor_id}, socket) do
    if caller?(socket, &(&1.athanor_id == athanor_id)),
      do: settle(socket, :halt),
      else: {:halt, socket}
  end

  defp on_info(%Membership{}, socket), do: settle(socket, :cont)
  defp on_info(%Session{kind: :created}, socket), do: {:halt, socket}
  defp on_info(@recheck, socket), do: settle(socket, :halt)
  defp on_info(_message, socket), do: proceed(socket)

  defp caller?(socket, fun) do
    case socket.assigns[:context] do
      %Context{} = ctx -> fun.(ctx)
      _ -> false
    end
  end

  # The freshness rule: a fresh context goes on as it is.
  defp proceed(socket) do
    case socket.assigns[:context] do
      %Context{} = ctx -> if Caller.fresh?(ctx), do: {:cont, socket}, else: settle(socket, :cont)
      _ -> {:cont, socket}
    end
  end

  # Revalidate now. `continue` is what a success does with the message.
  defp settle(socket, continue) do
    case socket.assigns[:context] do
      %Context{} = ctx ->
        case Caller.revalidate_session(ctx) do
          {:ok, fresh} -> {continue, put_context(socket, fresh)}
          {:error, reason} -> {:halt, refuse(socket, reason)}
        end

      _ ->
        {continue, socket}
    end
  end

  defp refuse(socket, :unavailable), do: LiveView.put_flash(socket, :error, @unavailable)

  defp refuse(socket, :not_member) do
    socket
    |> LiveView.put_flash(:error, @focus_lost)
    |> LiveView.redirect(to: refusal_path(:not_member))
  end

  defp refuse(socket, reason), do: LiveView.redirect(socket, to: refusal_path(reason))

  @doc """
  Put a context the page narrowed to another estate on the socket.

  `focused` has already passed the focus authorization
  (`Sanctum.Context.focus/2`). On a connected socket a move to another
  estate is revalidated before it is assigned, since the context it was
  derived from may be older than the bound.
  """
  @spec refocus(Socket.t(), Context.t()) :: {:ok, Socket.t()} | {:error, refusal()}
  def refocus(%Socket{} = socket, %Context{} = focused) do
    moved? = focus_of(socket.assigns[:context]) != focus_of(focused)

    if LiveView.connected?(socket) and moved? do
      with {:ok, fresh} <- Caller.revalidate_session(focused),
           do: {:ok, put_context(socket, fresh)}
    else
      {:ok, put_context(socket, focused)}
    end
  end

  defp focus_of(%Context{athanor_id: athanor_id}), do: athanor_id
  defp focus_of(_), do: nil

  defp put_context(socket, %Context{} = ctx) do
    Cyfr.LoggerContext.set_from_context(ctx)
    assign(socket, :context, ctx)
  end

  # ---------------------------------------------------------------------------
  # Components
  # ---------------------------------------------------------------------------

  @doc """
  Run a LiveComponent callback on a current context.

  A component's `handle_event` and `update` run without the view's hooks,
  so each one that acts on `assigns.context` runs inside this: the
  callback gets the socket with a current context, or it does not run. A
  refused context is handed to the view, which redirects
  (`recheck_message/0`); a store that cannot answer says so. Refused, the
  answer is `{:noreply, socket}` — an `update` reshapes it.
  """
  @spec guard(Socket.t(), (Socket.t() -> result)) :: result | {:noreply, Socket.t()}
        when result: term()
  def guard(%Socket{} = socket, fun) when is_function(fun, 1) do
    case socket.assigns[:context] do
      %Context{} = ctx ->
        case check(ctx) do
          {:ok, ^ctx} ->
            fun.(socket)

          {:ok, fresh} ->
            fun.(assign(socket, :context, fresh))

          {:error, :unavailable} ->
            {:noreply, LiveView.put_flash(socket, :error, @unavailable)}

          {:error, _refused} ->
            send(self(), @recheck)
            {:noreply, socket}
        end

      _ ->
        fun.(socket)
    end
  end

  # ---------------------------------------------------------------------------
  # Bare contexts
  # ---------------------------------------------------------------------------

  @doc """
  The freshness rule for a context with no socket around it: `{:ok, ctx}`
  as it is while fresh, else the revalidated context or its refusal.
  """
  @spec check(Context.t()) :: {:ok, Context.t()} | {:error, refusal()}
  def check(%Context{} = ctx) do
    if Caller.fresh?(ctx), do: {:ok, ctx}, else: Caller.revalidate_session(ctx)
  end

  @doc """
  Establish the session behind a browser cookie token for a per-request
  read, focused on `athanor_id` when one is given, and hold it to the
  freshness rule. Answers the context or `Sanctum.Caller`'s refusal.
  """
  @spec authenticate(String.t() | nil, String.t() | nil) ::
          {:ok, Context.t()} | {:error, Caller.refusal()}
  def authenticate(token, athanor_id \\ nil) do
    with {:ok, ctx} <- Caller.establish(token, focus: athanor_id),
         {:ok, ctx} <- check(ctx) do
      Cyfr.LoggerContext.set_from_context(ctx)
      {:ok, ctx}
    end
  end

  # ---------------------------------------------------------------------------
  # Deferred results
  # ---------------------------------------------------------------------------

  @doc """
  What a task started now is computed under: the tenant, the membership
  that authorized the focus, and when that context was validated. The
  task sends it back with its result, for `deliver/3`.
  """
  @spec capture(Socket.t() | Context.t()) :: tag()
  def capture(%Socket{assigns: assigns}), do: capture(Map.get(assigns, :context))

  def capture(%Context{} = ctx), do: {ctx.athanor_id, basis(ctx), ctx.validated_at}
  def capture(_none), do: {nil, nil, nil}

  @doc """
  Deliver a deferred result to the socket only if it was computed for the
  tenant and focus the socket works in now; otherwise it is dropped and
  the callback answers `{:noreply, socket}`. The view's hook has already
  brought the socket's context up to date when this runs.
  """
  @spec deliver(Socket.t(), tag(), (Socket.t() -> result)) :: result | {:noreply, Socket.t()}
        when result: term()
  def deliver(%Socket{} = socket, {athanor_id, basis, _validated_at}, fun)
      when is_function(fun, 1) do
    case socket.assigns[:context] do
      %Context{athanor_id: ^athanor_id} = ctx ->
        if basis(ctx) == basis, do: fun.(socket), else: discard(socket)

      _ ->
        discard(socket)
    end
  end

  defp discard(socket) do
    Logger.debug("[CyfrWeb.ContextGuard] dropped a result computed under another focus")
    {:noreply, socket}
  end

  defp basis(%Context{credential_binding: %{focus_basis: basis}}), do: basis
  defp basis(%Context{}), do: nil

  # ---------------------------------------------------------------------------
  # Streams
  # ---------------------------------------------------------------------------

  @doc """
  Watch `ctx`'s standing for a stream opened by the calling process:
  subscribe to the standing announcements and arm the periodic recheck,
  every thirty seconds unless `every:` (milliseconds) says otherwise.
  Every stream that watches must `unwatch/1` the watch it holds last
  when it ends.
  """
  @spec watch(Context.t(), keyword()) :: watch()
  def watch(%Context{} = ctx, opts \\ []) do
    every = Keyword.get(opts, :every, @stream_recheck_ms)
    :ok = Cyfr.Bus.subscribe_standing(ctx.user_id)
    %{context: ctx, every: every, timer: arm(every), user_id: ctx.user_id}
  end

  @doc """
  Whether `message` is one `standing/2` reads, for a stream whose
  `receive` takes nothing else it does not own.
  """
  defguard standing_message(message)
           when is_struct(message, Session) or is_struct(message, CallerInvalidated) or
                  is_struct(message, AthanorArchived) or is_struct(message, Membership) or
                  message == @recheck

  @doc """
  What a message a watching stream received means for it:

    * `{:ok, watch}` — a standing announcement or the recheck, and the
      context still stands (revalidated when it was about this caller);
    * `{:refused, reason}` — the stream ends with its refusal;
    * `:ignore` — not a standing message at all.
  """
  @spec standing(term(), watch()) :: {:ok, watch()} | {:refused, refusal()} | :ignore
  # The recheck is the timer's own message, so the timer is spent; the next
  # one is armed only for a context that still stands, and a refused stream
  # ends with no recheck left behind.
  def standing(@recheck, watch) do
    with {:ok, watch} <- revalidate(watch), do: {:ok, %{watch | timer: arm(watch.every)}}
  end

  def standing(%Session{kind: :revoked, user_id: user_id}, %{context: ctx} = watch),
    do: if(ctx.user_id == user_id, do: revalidate(watch), else: {:ok, watch})

  def standing(%CallerInvalidated{session_key: key}, %{context: ctx} = watch),
    do: if(ctx.session_token_hash == key, do: revalidate(watch), else: {:ok, watch})

  def standing(%AthanorArchived{athanor_id: athanor_id}, %{context: ctx} = watch),
    do: if(ctx.athanor_id == athanor_id, do: revalidate(watch), else: {:ok, watch})

  def standing(%Membership{}, watch), do: revalidate(watch)
  def standing(%Session{kind: :created}, watch), do: {:ok, watch}
  def standing(_message, _watch), do: :ignore

  @doc "End a watch: unsubscribe, disarm, and drop a recheck already queued."
  @spec unwatch(watch()) :: :ok
  def unwatch(%{timer: timer, user_id: user_id}) do
    Process.cancel_timer(timer)
    :ok = Cyfr.Bus.unsubscribe_standing(user_id)

    receive do
      @recheck -> :ok
    after
      0 -> :ok
    end
  end

  defp revalidate(%{context: ctx} = watch) do
    case Caller.revalidate_session(ctx) do
      {:ok, fresh} -> {:ok, %{watch | context: fresh}}
      {:error, reason} -> {:refused, reason}
    end
  end

  defp arm(every), do: Process.send_after(self(), @recheck, every)

  # ---------------------------------------------------------------------------
  # Announcements and refusals
  # ---------------------------------------------------------------------------

  # Every announcement that can end a context's standing
  # (`Cyfr.Bus.subscribe_standing/1`). The archive and invalidation topics
  # are server-wide, so a move to another estate needs no new
  # subscription; each holder filters for its own caller.
  defp subscribe(%Context{user_id: user_id}), do: Cyfr.Bus.subscribe_standing(user_id)

  defp refusal_path(:not_member), do: "/"
  defp refusal_path(_session_refused), do: "/login"

  # A mount that cannot establish: back through the door, told why when
  # the reason is theirs to know. A nested view's page focus refused is
  # the focus lost.
  defp mount_refusal(:unavailable), do: "/login?error=unavailable"
  defp mount_refusal(:no_athanor), do: "/login?error=no_athanor"
  defp mount_refusal(reason) when reason in [:not_member, :archived, :not_found], do: "/"
  defp mount_refusal(_refused), do: "/login"
end
