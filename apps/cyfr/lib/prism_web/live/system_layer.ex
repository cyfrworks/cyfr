# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer do
  @moduledoc """
  The system layer: what Prism alone draws above every frame — grant,
  unlock, sign-in, credential-entry, pairing and confirmation prompts, and
  safe mode. It presents a prompt and never decides one: the operation a
  confirmation dispatches is decided where the change is, in Sanctum,
  which checks the caller's standing and any fresh confirmation the
  change needs.

  Each view that asks for a grant or a sensitive change mounts it once,
  with the view's `context`, and acts under that context alone: the
  shell, the chat and each console page that asks, as `id:
  "system-layer"` (`layer_id/0`); the person's own panel, which sits on
  every page beside the page's own layer, as `id: "system-layer-panel"`.
  The component's id is its DOM id and the id every update names. A layer
  mounted with `listen: false` opens no stream, so the records the page's
  own layer shows are never drawn twice. `athanor_route` and
  `athanor_name` name the athanor a grant lands in. A prompt
  (`PrismWeb.SystemLayer.Prompt`) arrives by `show/2`, which is
  `send_update(PrismWeb.SystemLayer, id: id, prompt: prompt)`; `prompt:
  nil` clears the open one. A prompt that arrives while another is open
  waits behind it in arrival order; one whose id is already open or
  waiting is the same prompt and is taken once.

  Each prompt's outcome goes to the parent LiveView as
  `{:system_layer, id, :confirmed | :dismissed | {:refused, reason}}`. A
  malformed prompt is not drawn and is `{:refused, :invalid_prompt}`. A
  refused confirmation shows its sentence, reports `{:refused, reason}`
  and stays open, so the person can dismiss it. A confirmation prompt the
  layer opened from the stream, for another client's request, reports
  nothing. A nested view asks through the view that renders it, never
  past it: it sends its prompt to its parent, which places it in its own
  layer (`relay/4`) and hands the outcome back (`relayed/2`).

  A prompt that confirms an action (`Sanctum.Pairing`'s action table) is
  shown with a confirm control only to a client with a person behind it
  who can give a proof (`Sanctum.Pairing.can_confirm?/1`); any other
  client is told to confirm it from a signed-in browser. That is a
  display rule and decides nothing: a confirmation that arrives anyway is
  dispatched like any other, and the operation answers it. No client
  holds a rank. Where the rule hides the control of a credential entry or
  of pairing a device, the prompt offers "Request confirmation" instead,
  which submits the same request: it answers the `confirmation_required`
  signal, and the change waits for a proof given on another client.

  What a confirmation dispatches, through `PrismWeb.Ops.call_tool/3`:

    * a grant — the prompt's body is the consent sheet
      (`PrismWeb.ConsentSheetComponent`), which walks the grant from the
      plan and preview the prompt arrived with (`grant_prompt/4`) and
      draws the preview's typed rows itself: the vault entry each need is
      bound to, the narrowing and the origins the person chooses, each
      previewed again after each choice, the warnings and what changed.
      It hands the layer the walk as it stands. Confirming asks the sheet
      for its walk at that moment, after every choice that came before
      the confirm, and commits exactly that walk, its decisions, through
      `profile.commit`. A commit that is refused consumed the plan's
      token, so the sheet plans again. A plan whose closure is unresolved
      has no preview and nothing to confirm. A grant is planned in one
      athanor: a prompt whose athanor is no longer the layer's context's
      ends dismissed and commits nothing;
    * a credential entry — `vault.create`, an `api_key` entry under the
      subject's name holding the one value typed, which travels on the
      shell's LiveView socket, is never assigned, rendered or logged, and
      never reaches a frame (its parameter name is on the redaction
      roster, `Prima.Sanitizer`). The person also names where the value
      may go — the destination's hosts, and optionally its scheme, port,
      methods and paths — and whether the app may read it; nothing is
      prefilled and disclosure is off until they turn it on
      (`destination_params/1`, `disclose_param/1`);
    * pairing — `pairing.list` when it opens, `pairing.begin`, whose
      answer's `invitation_url` it draws as a QR code, and `pairing.revoke`;
    * safe mode's default desktop — `layout.edit` at the revision safe mode
      was entered at; a layout published since is reported and nothing is
      merged. Trying again dispatches nothing. Safe mode has no dismissal;
      its `:confirmed` tells the parent the person chose, and the parent
      runs frames again from the layout. The layer stops and starts no
      frame itself;
    * a sign-in — nothing: identity is established at the authentication
      boundary, so confirming leaves for the sign-in page;
    * an unlock — no operation unlocks the vault, so an unlock prompt has
      no confirm control and can only be dismissed;
    * recovery material (`PrismWeb.SystemLayer.Recovery`) — enrollment
      through `person.enroll`, a kit again through `person.kit`, another
      kit through `person.enroll_holder`, and the kit's acknowledgment
      through `person.kit_ack`. The seed is the browser's, drawn there and
      submitted (`recovery_submit`) and submitted again once confirmed,
      never assigned; a kit's lines go to the browser in a push and are
      erased there when the prompt ends.

  A page registers a passkey through the layer's `webauthn:create`
  ceremony (`create_passkey/4`): the browser answers the layer, which
  hands the credential to the page (`{:system_layer_passkey, {:ok,
  credential} | :error}`) to register through `passkey.register`.

  ## Fresh confirmation

  A sensitive change answers the `confirmation_required` signal, whose
  `id` is the asking request's secret. The asker keeps it in its own
  process: the layer for the changes it dispatches itself, a page for its
  own (`call/5`). It is never assigned to anything rendered, never put in
  a flash or a log, and sent nowhere but in the repeat of that one change
  (`PrismWeb.Ops.call_tool/4`'s `confirmation_id:`). The prompt names the
  record by its public ref (`Prima.Confirmation.ref/1`), reads the
  record's preview and the client that asked through `confirmation.pending`,
  and shows them before any proof. It offers a passkey (the `webauthn:get`
  ceremony over the record's digest), a fresh sign-in at the person's
  identity provider (`confirmation.reauth`, opened in a new tab so this
  page stays), a code sent to their verified email where one can reach
  them, and cancel (`confirmation.cancel`), each only where the record's
  `methods` offer it.

  The layer listens on `confirmation.changes` while it is mounted on a
  connected page with a person behind it, unless it was mounted with
  `listen: false`, which hears no record's facts: one listener process per
  LiveView, opened through the gate's stream admission
  (`Grimoire.open_stream/3`) under the page's context, ended with the
  LiveView, opened again at its grant's deadline or when the page's focus
  moves, a refused open included. Each open reads `confirmation.pending`
  and shows every record already waiting, since no fact announces them
  again; after that, each of the person's clients opens a prompt on a
  record's `opened` fact. A prompt is drawn without reading the store, so
  it shows while the store cannot answer; only what it reads (the
  listener's open, the pairing prompt's list) waits for the store. The
  asking client knows its own record by the ref of the secret it holds
  and marks that prompt as its own. The asking client shows the request waiting, then
  approved once the record's ref reads `confirmed`, wherever the proof
  was given, then the change's actual outcome. It repeats the change
  once, with its secret: the layer dispatches its own changes again, the
  browser resubmits a typed credential's form (the hook answers
  `system_layer:resubmit`, so the server never holds the value; a page's
  own form that typed one is marked with the prompt it asks under, and
  emptied when that prompt ends), and a
  page is told `{:system_layer, id, :confirmed}` and repeats through
  `call/5`. A repeat answered `confirmation_required` with the same secret
  is still waiting; a `voided`, `expired` or `cancelled` fact for the
  ref ends the wait and says so. Dismissing one's own waiting request
  cancels it.

  The browser half (`assets/js/system_layer/`) draws the prompt in the
  top layer after leaving fullscreen and pointer lock, moves focus into it
  and returns focus on close; Escape dismisses every prompt but safe mode.
  While a modal prompt is open on any layer of the page, every frame is
  hidden and inert, so no frame holds the pointer or the screen over it.
  Every event the layer pushes names it (`layer`, its id), because a page
  can hold two layers and every hook on a page hears every push.
  Every prompt but safe mode is modal and holds focus. Safe mode is a
  top-layer popover that leaves the page operable, so the assistant's
  panel, which Prism draws, is neither covered nor disabled by it.
  """

  use PrismWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Prism.SafeMode
  alias PrismWeb.Ops
  alias PrismWeb.SystemLayer.{Listener, Pairing, Prompt, Recovery}
  alias Sanctum.Context

  @layer_id "system-layer"
  # A panel ends itself this long after its record's expiry, so the home
  # has refused the record before the page says it expired.
  @expiry_grace_ms 250
  @stream "confirmation.changes"
  @sign_in_path "/login"

  # Where a page keeps the secrets of the changes it asked for.
  @asks :system_layer_asks
  # Where a view keeps the nested views whose prompts it placed.
  @relays :system_layer_relays

  @doc "The id the layer is mounted under on a page that holds one."
  @spec layer_id() :: String.t()
  def layer_id, do: @layer_id

  @doc "The stream the layer listens on."
  @spec stream() :: String.t()
  def stream, do: @stream

  @doc "Show `prompt` in the layer mounted under `id`."
  @spec show(String.t(), Prompt.t() | nil) :: :ok
  def show(id \\ @layer_id, prompt) do
    send_update(__MODULE__, id: id, prompt: prompt)
    :ok
  end

  @doc """
  Ask the browser of the page `socket` is to create a passkey with the
  creation options `public_key` and the home's `registration` token, both
  as `passkey.register` answered them, through the layer `layer`'s hook
  (`webauthn:create`). The layer hands the page the answer as
  `{:system_layer_passkey, {:ok, credential}}`, or `{:system_layer_passkey,
  :error}` when the ceremony did not finish.
  """
  @spec create_passkey(Phoenix.LiveView.Socket.t(), map(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def create_passkey(socket, public_key, registration, layer \\ @layer_id)
      when is_map(public_key) and is_binary(registration) do
    push_event(socket, "webauthn:create", %{
      layer: layer,
      purpose: "passkey",
      public_key: public_key,
      registration: registration
    })
  end

  # ---------------------------------------------------------------------------
  # A view asking for a grant
  # ---------------------------------------------------------------------------

  @doc """
  The `:grant` prompt `id` for the component `ref`, read under `ctx` (a
  context, or a socket holding one, as `PrismWeb.Ops.call_tool/3` takes
  it): the consent walk's plan as `profile.plan` answers it, with what its
  head holds (`head_origins`, and `shape_diff` when the shape moved), its
  preview with no vault entry bound yet and the origins the head admits
  (`interactive` alone on a first grant), and the athanor both were read
  in. `opts[:label]` names the profile label the grant is for (the
  `"default"` profile when absent). The sheet the prompt shows takes the
  walk on from there. A plan whose closure is unresolved opens with no
  preview, naming what is missing, and offers nothing to commit.
  `{:error, reason}` when either cannot be read, which the asker shows
  instead of a prompt.
  """
  @spec grant_prompt(
          Context.t() | Phoenix.LiveView.Socket.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, Prompt.t()} | {:error, term()}
  def grant_prompt(ctx_or_socket, id, ref, opts \\ []) when is_binary(id) and is_binary(ref) do
    label = Keyword.get(opts, :label)
    plan_args = Prima.MapUtil.put_present(%{"ref" => ref}, "label", label)

    with %Context{athanor_id: athanor_id} when is_binary(athanor_id) <-
           context_of(ctx_or_socket),
         {:ok, plan} <- Ops.call_tool(ctx_or_socket, "profile/plan", plan_args),
         decisions = first_decisions(ref, label, plan),
         {:ok, preview} <- first_preview(ctx_or_socket, plan, decisions) do
      {:ok,
       %{
         id: id,
         kind: :grant,
         action: :grant,
         subject: %{
           ref: ref,
           athanor_id: athanor_id,
           plan: plan,
           preview: preview,
           decisions: decisions
         }
       }}
    else
      {:error, reason} -> {:error, reason}
      _no_athanor -> {:error, :no_athanor}
    end
  end

  # No entry bound yet, the origins the head admits, or `interactive`
  # alone on a first grant.
  defp first_decisions(ref, label, plan) do
    %{"ref" => ref, "bindings" => [], "origins" => plan[:head_origins] || ["interactive"]}
    |> Prima.MapUtil.put_present("label", label)
  end

  defp first_preview(_ctx_or_socket, %{unresolved: %{}}, _decisions), do: {:ok, nil}

  defp first_preview(ctx_or_socket, _plan, decisions),
    do: Ops.call_tool(ctx_or_socket, "profile/preview", %{"decisions" => decisions})

  @doc """
  Whether the grant a run would start under admits `origin`: the profile
  `profile_id` of the component `ref`, read under `ctx` (a context, or a
  socket holding one) through `Sanctum.Consent.profiles/2` and its head
  through `Sanctum.Consent.head_consent/2`. `:admitted` when its head
  admits it; `{:missing, label}` when an owner profile's head does not,
  `label` the profile's, for the grant prompt that asks for it
  (`grant_prompt/4`'s `label:`); `:unknown` when the profile is not one of
  `ref`'s owner profiles with a head, or cannot be read, which leaves the
  decision to the operation itself.
  """
  @spec admits_origin(
          Context.t() | Phoenix.LiveView.Socket.t(),
          String.t(),
          String.t(),
          Prima.Origin.t()
        ) :: :admitted | {:missing, String.t()} | :unknown
  def admits_origin(ctx_or_socket, ref, profile_id, origin)
      when is_binary(ref) and is_binary(profile_id) do
    with %Context{} = ctx <- context_of(ctx_or_socket),
         {:ok, name_ref} <- Prima.ComponentRef.to_name_ref(ref),
         {:ok, entries} <- Sanctum.Consent.profiles(ctx, name_ref),
         %{kind: :owner, label: label} <- Enum.find(entries, &(&1.id == profile_id)),
         {:ok, head} <- Sanctum.Consent.head_consent(ctx, profile_id) do
      if origin in head.admitted_origins,
        do: :admitted,
        else: {:missing, label}
    else
      _unknown -> :unknown
    end
  end

  def admits_origin(_ctx_or_socket, _ref, _profile_id, _origin), do: :unknown

  defp context_of(%Context{} = ctx), do: ctx
  defp context_of(%Phoenix.LiveView.Socket{assigns: %{context: ctx}}), do: ctx
  defp context_of(_other), do: nil

  @doc """
  Place a nested view's prompt in this view's layer `id`, under this
  view's context; its outcome goes back to the nested view's `pid`
  (`relayed/2`).
  """
  @spec relay(Phoenix.LiveView.Socket.t(), pid(), term(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def relay(socket, pid, prompt, id \\ @layer_id) when is_pid(pid) do
    show(id, prompt)

    case Prompt.id_of(prompt) do
      nil ->
        socket

      prompt_id ->
        Phoenix.Component.assign(socket, @relays, Map.put(relays(socket), prompt_id, pid))
    end
  end

  @doc """
  What a view does with its layer's report on a prompt it placed for a
  nested view: the report forwarded to that view, `{:relayed, socket}`,
  which lets go of the view once the prompt ended; `:none` for a report
  on a prompt of this view's own.
  """
  @spec relayed(Phoenix.LiveView.Socket.t(), {:system_layer, String.t(), term()}) ::
          {:relayed, Phoenix.LiveView.Socket.t()} | :none
  def relayed(socket, {:system_layer, prompt_id, outcome} = report) do
    case Map.fetch(relays(socket), prompt_id) do
      {:ok, pid} ->
        send(pid, report)

        socket =
          if ended?(outcome),
            do: Phoenix.Component.assign(socket, @relays, Map.delete(relays(socket), prompt_id)),
            else: socket

        {:relayed, socket}

      :error ->
        :none
    end
  end

  defp relays(socket), do: Map.get(socket.assigns, @relays, %{})

  # A refused confirmation leaves its prompt open; any other outcome, a
  # prompt never drawn included, ends it.
  defp ended?({:refused, :invalid_prompt}), do: true
  defp ended?({:refused, _reason}), do: false
  defp ended?(_outcome), do: true

  # ---------------------------------------------------------------------------
  # A page asking for a sensitive change
  # ---------------------------------------------------------------------------

  @doc """
  Dispatch `tool` with `args` for a page, through `PrismWeb.Ops.call_tool/4`,
  as the change `tag` names (a term the page chooses, one per change it
  can ask for).

  A change the page already asked for under `tag` and still holds the
  secret of is dispatched naming it: the repeat. Answers:

    * `{:ok, result, socket}` and `{:error, reason, socket}` — the
      operation's own answer;
    * `{:asked, socket}` — the change needs a fresh confirmation: the page
      holds the signal's secret, never rendered, and the layer shows the
      prompt, marked as this client's own. A repeat answered with the same
      secret is still waiting.

  `opts`: `:form`, the DOM id of the form that typed the change, when its
  values must not stay on the server: the browser resubmits it once the
  record is confirmed, and the page dispatches it again as it arrives.
  Without one, the page repeats from `reported/2`. `:layer`, the id of
  the page's layer (`layer_id/0` when absent). `reported/2` needs no id:
  it reads only what this page holds.
  """
  @spec call(Phoenix.LiveView.Socket.t(), term(), String.t(), map(), keyword()) ::
          {:ok, term(), Phoenix.LiveView.Socket.t()}
          | {:error, term(), Phoenix.LiveView.Socket.t()}
          | {:asked, Phoenix.LiveView.Socket.t()}
  def call(socket, tag, tool, args, opts \\ []) do
    held = held_for(socket, tag)
    repeat = if held, do: [confirmation_id: held.id], else: []
    result = Ops.call_tool(socket, tool, args, repeat)
    socket = if held, do: settle_held(socket, held, result), else: socket

    case result do
      {:error, {:confirmation_required, %{id: id}}} when is_map(held) and id == held.id ->
        {:asked, socket}

      {:error, {:confirmation_required, %{id: id} = signal}} when is_binary(id) ->
        form = Keyword.get(opts, :form)
        repeat = if form, do: nil, else: {tool, args}
        layer = Keyword.get(opts, :layer, @layer_id)
        {:asked, ask(socket, signal, tag, repeat, form, layer)}

      {:ok, value} ->
        {:ok, value, socket}

      {:error, reason} ->
        {:error, reason, socket}
    end
  end

  @doc """
  What a page does with what its layer reported: `{:repeat, tag, tool,
  args, socket}` when a change it asked for was confirmed and the page
  repeats it (through `call/5`, with the same `tag`), or `{:ok, socket}`.
  A change that ended — dismissed, cancelled, voided or expired — lets
  its secret go.
  """
  @spec reported(Phoenix.LiveView.Socket.t(), {:system_layer, String.t(), term()}) ::
          {:repeat, term(), String.t(), map(), Phoenix.LiveView.Socket.t()}
          | {:ok, Phoenix.LiveView.Socket.t()}
  def reported(socket, {:system_layer, prompt_id, outcome}) do
    case Map.get(asks(socket), prompt_id) do
      nil ->
        {:ok, socket}

      %{repeat: {tool, args}, tag: tag} when outcome == :confirmed ->
        {:repeat, tag, tool, args, socket}

      %{} when outcome == :confirmed ->
        {:ok, socket}

      %{} ->
        {:ok, drop_ask(socket, prompt_id)}
    end
  end

  defp asks(socket), do: Map.get(socket.assigns, @asks, %{})

  defp held_for(socket, tag),
    do: socket |> asks() |> Map.values() |> Enum.find(&(&1.tag == tag))

  defp ask(socket, %{id: id} = signal, tag, repeat, form, layer) do
    ref = Prima.Confirmation.ref(id)
    prompt_id = Prompt.confirmation_id(ref)

    send_update(__MODULE__,
      id: layer,
      ask: %{
        ref: ref,
        operation: Map.get(signal, :operation),
        expires_at: Map.get(signal, :expires_at),
        form: form
      }
    )

    held = %{id: id, ref: ref, tag: tag, repeat: repeat, form: form, layer: layer}
    Phoenix.Component.assign(socket, @asks, Map.put(asks(socket), prompt_id, held))
  end

  # A repeat's answer, told to the layer: the same secret is still waiting;
  # another one means the record no longer answers this change, which is
  # cancelled and asked for again; anything else is the change's outcome.
  defp settle_held(socket, held, result) do
    prompt_id = Prompt.confirmation_id(held.ref)

    case result do
      {:error, {:confirmation_required, %{id: id}}} when id == held.id ->
        outcome(held, :waiting)
        socket

      {:error, {:confirmation_required, _another}} ->
        _ = Ops.call_tool(socket, "confirmation/cancel", %{"ref" => held.ref})
        outcome(held, {:refused, :asked_again})
        drop_ask(socket, prompt_id)

      {:ok, _value} ->
        outcome(held, :completed)
        drop_ask(socket, prompt_id)

      {:error, reason} ->
        outcome(held, {:refused, reason})
        drop_ask(socket, prompt_id)
    end
  end

  defp outcome(%{ref: ref, layer: layer}, outcome),
    do: send_update(__MODULE__, id: layer, outcome: {ref, outcome})

  defp drop_ask(socket, prompt_id),
    do: Phoenix.Component.assign(socket, @asks, Map.delete(asks(socket), prompt_id))

  # ---------------------------------------------------------------------------
  # Mount and updates
  # ---------------------------------------------------------------------------

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       current: nil,
       queue: [],
       error: nil,
       listen: true,
       listening: nil,
       panels: %{},
       held: %{},
       pairing: nil,
       recovery: nil,
       athanor_route: nil,
       athanor_name: nil
     )}
  end

  @impl true
  # A prompt is drawn without reading the store, so it shows whether or not
  # the store can answer; the reads it triggers — the listener's open and
  # the pairing prompt's list — run on a current context
  # (`CyfrWeb.ContextGuard.guard/2`), as does every update that reads the
  # context. A fact of the stream is taken only in the focus its listener
  # was opened for (`deliver/3`).
  def update(%{prompt: prompt} = assigns, socket) do
    socket = socket |> assign(Map.drop(assigns, [:prompt])) |> place(prompt)

    {:noreply, socket} =
      CyfrWeb.ContextGuard.guard(socket, &{:noreply, &1 |> listen() |> load_shown()})

    {:ok, socket}
  end

  def update(%{fact: fact, tag: tag}, socket) do
    {:noreply, socket} =
      CyfrWeb.ContextGuard.deliver(socket, tag, fn socket ->
        CyfrWeb.ContextGuard.guard(socket, &{:noreply, on_fact(&1, fact)})
      end)

    {:ok, socket}
  end

  def update(%{ask: ask}, socket) do
    {:noreply, socket} = CyfrWeb.ContextGuard.guard(socket, &{:noreply, on_ask(&1, ask)})
    {:ok, socket}
  end

  def update(%{outcome: {ref, outcome}}, socket), do: {:ok, on_outcome(socket, ref, outcome)}

  def update(%{expire: ref}, socket), do: {:ok, expire(socket, ref)}

  # The grant's walk as the sheet holds it now (`walk/2`).
  def update(%{walk: walk}, socket), do: {:ok, walk(socket, walk)}

  # The sheet's walk at the moment the person confirmed, which the layer
  # commits (`commit_walk/2`).
  def update(%{commit: walk}, socket) do
    {:noreply, socket} = CyfrWeb.ContextGuard.guard(socket, &commit_walk(&1, walk))
    {:ok, socket}
  end

  def update(%{listen: :ended}, socket) do
    socket = assign(socket, :listening, nil)
    {:noreply, socket} = CyfrWeb.ContextGuard.guard(socket, &{:noreply, listen(&1)})
    {:ok, socket}
  end

  # The view's own assigns: its context, which may have moved to another
  # athanor (the chat page opening another), so a grant planned in the one
  # it left ends here.
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:noreply, socket} =
      CyfrWeb.ContextGuard.guard(socket, &{:noreply, &1 |> end_moved_grants() |> listen()})

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # The stream
  # ---------------------------------------------------------------------------

  # Opened once per connected view with a person behind it, in the view's
  # process, so the open is decided and recorded before the listener runs;
  # opened again when the view moves to another athanor, whose records are
  # another topic's. The listener hands its facts back under the focus it
  # was opened for (`CyfrWeb.ContextGuard.capture/1`).
  # A start that was refused is remembered with its focus and tried again
  # when the focus moves. Each open, and each reopen at the grant's
  # deadline, reads the records already pending (`refresh/1`): a fact
  # announced before the listener started is not announced again. A
  # layer mounted with `listen: false` opens nothing.
  defp listen(%{assigns: %{listen: false}} = socket), do: socket

  defp listen(%{assigns: %{listening: %{athanor_id: athanor_id} = listening}} = socket) do
    case socket.assigns[:context] do
      %Context{athanor_id: ^athanor_id} ->
        socket

      _moved ->
        if is_pid(listening.pid), do: Listener.stop(listening.pid)
        socket |> assign(:listening, nil) |> listen()
    end
  end

  defp listen(%{assigns: %{listening: nil, context: %Context{} = ctx}} = socket) do
    if connected?(socket) and listenable?(ctx) do
      tag = CyfrWeb.ContextGuard.capture(socket)

      with {:ok, grant} <- Grimoire.open_stream(ctx, @stream, nil),
           {:ok, pid} <- Listener.start(self(), socket.assigns.id, ctx, grant, tag) do
        socket
        |> assign(:listening, %{pid: pid, grant_id: grant.grant_id, athanor_id: ctx.athanor_id})
        |> refresh()
      else
        _refused ->
          assign(socket, :listening, %{pid: nil, grant_id: nil, athanor_id: ctx.athanor_id})
      end
    else
      socket
    end
  end

  defp listen(socket), do: socket

  # The person's records already open, each shown as an opened fact would
  # show it: those the layer holds no panel for yet.
  defp refresh(socket) do
    case pending_entries(socket) do
      {:ok, entries} ->
        Enum.reduce(entries, socket, fn entry, socket ->
          if Map.has_key?(socket.assigns.panels, entry.ref),
            do: socket,
            else: open_entry(socket, entry)
        end)

      {:error, _unread} ->
        socket
    end
  end

  defp listenable?(%Context{plane: :external, authenticated: true} = ctx),
    do: present?(ctx.user_id) and present?(ctx.athanor_id)

  defp listenable?(%Context{}), do: false

  defp present?(value), do: is_binary(value) and value != ""

  # A fact of the stream: what happened to one record of the person's.
  defp on_fact(socket, %{"ref" => ref, "kind" => kind}) when is_binary(ref) do
    case Map.get(socket.assigns.panels, ref) do
      nil when kind == :opened -> open_from_stream(socket, ref)
      nil -> socket
      panel -> fact(socket, ref, panel, kind)
    end
  end

  defp on_fact(socket, _fact), do: socket

  # Another client's request, or this one's before it said so: shown with
  # the home's preview and the client that asked, before any proof.
  defp open_from_stream(socket, ref) do
    case pending_entry(socket, ref) do
      {:ok, entry} -> open_entry(socket, entry)
      _unread -> socket
    end
  end

  defp open_entry(socket, entry) do
    case Prompt.confirmation(entry, false) do
      {:ok, prompt} ->
        status = if Map.get(entry, :state) == "confirmed", do: :confirmed, else: :pending

        socket
        |> put_panel(entry.ref, %{
          prompt_id: prompt.id,
          entry: entry,
          own: false,
          origin: :stream,
          status: status
        })
        |> arrive(prompt)

      {:error, :invalid_prompt} ->
        socket
    end
  end

  # This client's own request reads confirmed: approved, and repeated once.
  # A fact delivered again finds it approved already, and repeats nothing.
  defp fact(socket, ref, %{own: true, status: status} = panel, :confirmed)
       when status in [:waiting, :pending] do
    socket = set_status(socket, ref, :approved)

    case panel.origin do
      :page ->
        report(panel.prompt_id, :confirmed)
        if panel.form, do: push_resubmit(socket, panel.form), else: socket

      :layer ->
        repeat_held(socket, ref)
    end
  end

  defp fact(socket, ref, %{own: false}, :confirmed), do: set_status(socket, ref, :confirmed)

  defp fact(socket, ref, %{own: true} = panel, kind)
       when kind in [:cancelled, :voided, :expired] do
    socket = set_status(socket, ref, {:ended, kind})

    case panel.origin do
      :page ->
        report(panel.prompt_id, {:refused, kind})
        clear_forms(socket, panel)

      :layer ->
        assign(socket, :held, Map.delete(socket.assigns.held, ref))
    end
  end

  defp fact(socket, ref, %{own: false} = panel, kind)
       when kind in [:consumed, :cancelled, :voided, :expired] do
    socket
    |> drop_panel(ref)
    |> remove_prompt(panel.prompt_id)
  end

  defp fact(socket, _ref, _panel, _kind), do: socket

  # A page's own request: its prompt, marked as this client's, or the
  # prompt the stream opened for it first, marked now.
  defp on_ask(socket, %{ref: ref} = ask) do
    case Map.get(socket.assigns.panels, ref) do
      nil ->
        entry =
          case pending_entry(socket, ref) do
            {:ok, entry} -> entry
            _unread -> Map.take(ask, [:ref, :operation, :expires_at])
          end

        case Prompt.confirmation(entry, true) do
          {:ok, prompt} ->
            socket
            |> put_panel(ref, %{
              prompt_id: prompt.id,
              entry: entry,
              own: true,
              origin: :page,
              form: ask.form,
              status: :waiting
            })
            |> mark_form(ask.form, prompt.id)
            |> arrive(prompt)

          {:error, :invalid_prompt} ->
            report(Prompt.confirmation_id(ref), {:refused, :invalid_prompt})
            socket
        end

      panel ->
        socket
        |> put_panel(ref, %{panel | own: true, origin: :page, form: ask.form, status: :waiting})
        |> mark_form(ask.form, panel.prompt_id)
        |> mark_own(panel.prompt_id)
    end
  end

  # A completed change lets go of the form that typed it.
  defp on_outcome(socket, ref, outcome) do
    case Map.get(socket.assigns.panels, ref) do
      nil ->
        socket

      panel ->
        socket = set_status(socket, ref, outcome)
        if outcome == :completed, do: clear_forms(socket, panel), else: socket
    end
  end

  defp pending_entry(socket, ref) do
    with {:ok, entries} <- pending_entries(socket) do
      case Enum.find(entries, &(&1.ref == ref)) do
        nil -> {:error, :not_pending}
        entry -> {:ok, entry}
      end
    end
  end

  defp pending_entries(socket) do
    case Ops.call_tool(socket.assigns.context, "confirmation/pending", %{}) do
      {:ok, %{confirmations: entries}} -> {:ok, entries}
      {:error, reason} -> {:error, reason}
    end
  end

  # A page's form that typed a credential is marked, in the browser, with
  # the prompt it asks under; when that prompt ends — completed, dismissed,
  # cancelled, voided or expired — every form so marked is emptied, so the
  # typed value leaves the page with it.
  defp mark_form(socket, nil, _prompt_id), do: socket

  defp mark_form(socket, form, prompt_id),
    do: push_layer(socket, "system_layer:mark", %{form: form, prompt: prompt_id})

  defp clear_forms(socket, %{form: form, prompt_id: prompt_id}) when is_binary(form),
    do: push_layer(socket, "system_layer:clear", %{prompt: prompt_id, form: form})

  defp clear_forms(socket, _panel), do: socket

  # Every hook on the page hears every push, and a page may hold two
  # layers: each event names the layer whose hook acts on it.
  defp push_layer(socket, event, payload),
    do: push_event(socket, event, Map.put(payload, :layer, socket.assigns.id))

  # ---------------------------------------------------------------------------
  # Panels: one pending confirmation as a prompt shows it
  # ---------------------------------------------------------------------------

  # `panels` holds each record a prompt shows, by its ref: the prompt it is
  # drawn in, the entry `confirmation.pending` answered, whether this
  # client asked for it and who holds the secret (`:page`, `:layer`, or
  # nobody here, `:stream`), its status, the form a browser resubmits, and
  # what a fresh sign-in or a code began.
  defp put_panel(socket, ref, panel) do
    panel =
      Map.merge(
        %{status: :pending, form: nil, reauth_url: nil, code_sent: false, entry: nil},
        panel
      )

    unless Map.has_key?(socket.assigns.panels, ref), do: expire_at(socket.assigns.id, ref, panel)
    assign(socket, :panels, Map.put(socket.assigns.panels, ref, panel))
  end

  # A record's expiry is announced only when its asker repeats after it, so
  # a request nobody repeats would wait forever on this page. Each panel
  # ends itself at its record's `expires_at` instead: the wait ends as
  # expired and a form that typed for it is emptied (`expire/2`).
  defp expire_at(id, ref, %{entry: %{expires_at: at}}) do
    case remaining_ms(at) do
      nil -> :ok
      ms -> send_update_after(__MODULE__, %{id: id, expire: ref}, ms + @expiry_grace_ms)
    end
  end

  defp expire_at(_id, _ref, _panel), do: :ok

  defp remaining_ms(%DateTime{} = at),
    do: max(DateTime.diff(at, DateTime.utc_now(), :millisecond), 0)

  defp remaining_ms(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> remaining_ms(at)
      _unreadable -> nil
    end
  end

  defp remaining_ms(_at), do: nil

  # A request still waiting past its expiry ends as expired, showing so
  # with no proof control left; one already approved, completed or ended
  # is left to the outcome it has. It reads nothing: the page's own request
  # is reported ended and its typed form let go, the layer's own lets go
  # of its secret, and another client's simply ends.
  defp expire(socket, ref) do
    case Map.get(socket.assigns.panels, ref) do
      %{own: true, origin: :page, status: status} = panel when status in [:pending, :waiting] ->
        report(panel.prompt_id, {:refused, :expired})
        socket |> set_status(ref, {:ended, :expired}) |> clear_forms(panel)

      %{own: true, origin: :layer, status: status} when status in [:pending, :waiting] ->
        socket
        |> set_status(ref, {:ended, :expired})
        |> assign(:held, Map.delete(socket.assigns.held, ref))

      %{own: false, status: status} when status in [:pending, :confirmed] ->
        set_status(socket, ref, {:ended, :expired})

      _settled ->
        socket
    end
  end

  defp drop_panel(socket, ref),
    do: assign(socket, :panels, Map.delete(socket.assigns.panels, ref))

  defp set_status(socket, ref, status) do
    case Map.get(socket.assigns.panels, ref) do
      nil -> socket
      panel -> put_panel(socket, ref, %{panel | status: status})
    end
  end

  defp update_panel(socket, ref, changes) do
    case Map.get(socket.assigns.panels, ref) do
      nil -> socket
      panel -> put_panel(socket, ref, Map.merge(panel, changes))
    end
  end

  defp panel_of(panels, %{id: prompt_id}) do
    Enum.find_value(panels, fn {ref, panel} ->
      if panel.prompt_id == prompt_id, do: {ref, panel}
    end)
  end

  defp panel_of(_panels, nil), do: nil

  # The panel of `ref` when its prompt is the open one: a click meant for a
  # prompt already gone never acts on another.
  defp open_panel(socket, ref) do
    with %{} = panel <- Map.get(socket.assigns.panels, ref),
         %{id: id} <- socket.assigns.current,
         true <- id == panel.prompt_id do
      {:ok, panel}
    else
      _other -> :none
    end
  end

  defp mark_own(socket, prompt_id) do
    mark = fn
      %{id: ^prompt_id, kind: :confirmation, subject: subject} = prompt ->
        %{prompt | subject: %{subject | own: true}}

      prompt ->
        prompt
    end

    assign(socket,
      current: socket.assigns.current && mark.(socket.assigns.current),
      queue: Enum.map(socket.assigns.queue, mark)
    )
  end

  defp remove_prompt(socket, prompt_id) do
    case socket.assigns.current do
      %{id: ^prompt_id} -> advance(socket)
      _other -> assign(socket, :queue, Enum.reject(socket.assigns.queue, &(&1.id == prompt_id)))
    end
  end

  defp push_resubmit(socket, form), do: push_layer(socket, "system_layer:resubmit", %{form: form})

  # ---------------------------------------------------------------------------
  # Arrival and the queue
  # ---------------------------------------------------------------------------

  # Placing a prompt reads nothing (`place/2`, `step/1`), so it is drawn
  # whatever the store answers; what a shown prompt reads, the pairing
  # prompt's list, is read after (`load_shown/1`), under the guard.
  defp arrive(socket, prompt), do: socket |> place(prompt) |> load_shown()

  defp place(socket, nil), do: step(socket)

  defp place(socket, prompt) do
    case Prompt.validate(prompt) do
      {:ok, prompt} ->
        socket = panel_for(socket, prompt)

        cond do
          known?(socket, prompt.id) ->
            socket

          is_nil(socket.assigns.current) ->
            socket |> assign(current: prompt, error: nil) |> mark_shown()

          true ->
            assign(socket, queue: socket.assigns.queue ++ [prompt])
        end

      {:error, :invalid_prompt} ->
        report(Prompt.id_of(prompt), {:refused, :invalid_prompt})
        socket
    end
  end

  # A confirmation prompt a parent sent itself shows its record as the
  # layer's own do: the subject is the entry.
  defp panel_for(socket, %{kind: :confirmation, id: id, subject: %{ref: ref} = subject}) do
    if Map.has_key?(socket.assigns.panels, ref) do
      socket
    else
      put_panel(socket, ref, %{
        prompt_id: id,
        entry: subject,
        own: subject.own,
        origin: if(subject.own, do: :page, else: :stream),
        status: if(subject.own, do: :waiting, else: :pending)
      })
    end
  end

  defp panel_for(socket, _prompt), do: socket

  defp known?(%{assigns: %{current: current, queue: queue}}, id) do
    match?(%{id: ^id}, current) or Enum.any?(queue, &(&1.id == id))
  end

  defp advance(socket), do: socket |> step() |> load_shown()

  defp step(%{assigns: %{queue: [next | rest]}} = socket),
    do:
      socket
      |> forget_recovery()
      |> assign(current: next, queue: rest, error: nil)
      |> mark_shown()

  defp step(socket) do
    socket
    |> forget_recovery()
    |> assign(current: nil, queue: [], error: nil, pairing: nil, recovery: nil)
  end

  # A recovery prompt that ends, however it ends, has the browser forget
  # its material and empty the prompt.
  defp forget_recovery(%{assigns: %{recovery: %{prompt_id: prompt_id}}} = socket),
    do: socket |> push_layer("recovery:clear", %{prompt: prompt_id}) |> assign(:recovery, nil)

  defp forget_recovery(socket), do: socket

  # The pairing prompt, as it is shown, has its list still to read; a
  # recovery prompt starts at its form.
  defp mark_shown(%{assigns: %{current: %{kind: :pairing, id: id}}} = socket),
    do:
      assign(socket,
        pairing: %{prompt_id: id, clients: :unread, invitation: nil},
        recovery: nil
      )

  defp mark_shown(%{assigns: %{current: %{kind: kind, id: id}}} = socket)
       when kind in [:enrollment, :kit, :holder],
       do: assign(socket, pairing: nil, recovery: Recovery.start(id))

  defp mark_shown(socket), do: assign(socket, pairing: nil, recovery: nil)

  # What a shown prompt reads: the pairing prompt, the person's paired
  # clients.
  defp load_shown(%{assigns: %{pairing: %{clients: :unread} = pairing}} = socket),
    do: assign(socket, :pairing, %{pairing | clients: clients(socket)})

  defp load_shown(socket), do: socket

  defp report(id, outcome), do: send(self(), {:system_layer, id, outcome})

  defp settle(socket, prompt, :confirmed) do
    report(prompt.id, :confirmed)
    socket |> drop_prompt_asks(prompt.id) |> advance()
  end

  defp refuse(socket, prompt, reason, sentence) do
    report(prompt.id, {:refused, reason})
    assign(socket, :error, sentence)
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("dismiss", %{"id" => id}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case socket.assigns.current do
        %{id: ^id} = prompt ->
          if dismissable?(prompt) do
            socket = end_own_request(socket, prompt)
            if reports?(socket, prompt), do: report(id, :dismissed)
            {:noreply, socket |> drop_prompt_asks(id) |> advance()}
          else
            {:noreply, socket}
          end

        _other ->
          {:noreply, socket}
      end
    end)
  end

  def handle_event("confirm", %{"id" => id}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case open(socket, id, [:grant, :sign_in]) do
        {:ok, prompt} -> confirm(socket, prompt)
        :none -> {:noreply, socket}
      end
    end)
  end

  # The value is read out of the event's parameters and handed to the
  # dispatch; nothing here assigns, renders or logs it. A credential that
  # needs a fresh confirmation is typed again by the browser, which keeps
  # the form filled until its record is confirmed.
  def handle_event("enter_credential", %{"prompt_id" => id} = params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case open(socket, id, [:credential_entry]) do
        {:ok, prompt} -> {:noreply, enter_credential(socket, prompt, params)}
        :none -> {:noreply, socket}
      end
    end)
  end

  # Trying again reads nothing and dispatches nothing, so safe mode's way
  # back works while the store cannot answer; only what the next prompt
  # reads waits for it.
  def handle_event("choose", %{"id" => id, "offer" => "retry"}, socket) do
    with {:ok, %{subject: safe_mode} = prompt} <- open(socket, id, [:safe_mode]),
         :retry <- SafeMode.choose(safe_mode, :retry) do
      report(prompt.id, :confirmed)
      socket = step(socket)
      CyfrWeb.ContextGuard.guard(socket, &{:noreply, load_shown(&1)})
    else
      _none -> {:noreply, socket}
    end
  end

  def handle_event("choose", %{"id" => id, "offer" => offer}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      with {:ok, prompt} <- open(socket, id, [:safe_mode]),
           {:ok, offer} <- offer(offer) do
        {:noreply, choose(socket, prompt, offer)}
      else
        _none -> {:noreply, socket}
      end
    end)
  end

  def handle_event("pairing_begin", %{"id" => id}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case open(socket, id, [:pairing]) do
        {:ok, prompt} -> {:noreply, pairing_begin(socket, prompt)}
        :none -> {:noreply, socket}
      end
    end)
  end

  def handle_event("pairing_revoke", %{"id" => id, "client" => client_id}, socket)
      when is_binary(client_id) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case open(socket, id, [:pairing]) do
        {:ok, prompt} -> {:noreply, pairing_revoke(socket, prompt, client_id)}
        :none -> {:noreply, socket}
      end
    end)
  end

  # The material is read out of the event and handed to the dispatch;
  # nothing here assigns, renders or logs it (`recovery_secret` is on the
  # redaction roster, `Prima.Sanitizer`).
  def handle_event("recovery_submit", %{"prompt_id" => id} = params, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case open(socket, id, Prompt.recovery_kinds()) do
        {:ok, prompt} -> {:noreply, recovery_submit(socket, prompt, params)}
        :none -> {:noreply, socket}
      end
    end)
  end

  def handle_event("recovery_ack", %{"id" => id}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case open(socket, id, Prompt.recovery_kinds()) do
        {:ok, prompt} -> {:noreply, recovery_ack(socket, prompt)}
        :none -> {:noreply, socket}
      end
    end)
  end

  # A page's passkey ceremony (`create_passkey/4`): the answer is the
  # page's to register.
  def handle_event(
        "webauthn_result",
        %{"purpose" => "passkey", "credential" => credential},
        socket
      )
      when is_map(credential) do
    send(self(), {:system_layer_passkey, {:ok, credential}})
    {:noreply, socket}
  end

  def handle_event("webauthn_error", %{"purpose" => "passkey"}, socket) do
    send(self(), {:system_layer_passkey, :error})
    {:noreply, socket}
  end

  def handle_event("prove_passkey", %{"ref" => ref}, socket) do
    case open_panel(socket, ref) do
      {:ok, %{entry: %{webauthn: %{} = options}}} ->
        {:noreply,
         socket
         |> assign(:error, nil)
         |> push_layer("webauthn:get", %{purpose: "confirmation", id: ref, public_key: options})}

      _none ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "webauthn_result",
        %{"purpose" => "confirmation", "id" => ref, "credential" => credential},
        socket
      )
      when is_map(credential) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      prove(socket, ref, %{"ref" => ref, "assertion" => credential})
    end)
  end

  def handle_event("webauthn_error", %{"purpose" => "confirmation", "id" => ref}, socket) do
    case open_panel(socket, ref) do
      {:ok, _panel} ->
        {:noreply, assign(socket, :error, "The passkey did not answer. Nothing was confirmed.")}

      :none ->
        {:noreply, socket}
    end
  end

  def handle_event("reauth", %{"ref" => ref, "method" => method}, socket)
      when method in ["oidc", "email"] do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case open_panel(socket, ref) do
        {:ok, _panel} -> {:noreply, reauth(socket, ref, method)}
        :none -> {:noreply, socket}
      end
    end)
  end

  def handle_event("prove_code", %{"ref" => ref, "code" => code}, socket) when is_binary(code) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      prove(socket, ref, %{"ref" => ref, "code" => String.trim(code)})
    end)
  end

  def handle_event("cancel_confirmation", %{"ref" => ref}, socket) do
    CyfrWeb.ContextGuard.guard(socket, fn socket ->
      case open_panel(socket, ref) do
        {:ok, _panel} -> {:noreply, cancel(socket, ref)}
        :none -> {:noreply, socket}
      end
    end)
  end

  # An event names the prompt it was drawn for, so a late click or Escape
  # meant for a prompt already settled never acts on the next one.
  defp open(socket, id, kinds) do
    case socket.assigns.current do
      %{id: ^id, kind: kind} = prompt -> if kind in kinds, do: {:ok, prompt}, else: :none
      _other -> :none
    end
  end

  defp offer("retry"), do: {:ok, :retry}
  defp offer("default"), do: {:ok, :default}
  defp offer(_other), do: :error

  # ---------------------------------------------------------------------------
  # Confirmations
  # ---------------------------------------------------------------------------

  defp confirm(socket, %{kind: :sign_in} = prompt) do
    {:noreply, socket |> settle(prompt, :confirmed) |> redirect(to: @sign_in_path)}
  end

  # A grant commits the walk the sheet holds at the moment of the confirm,
  # never one the sheet has moved past: the confirm asks the sheet, which
  # answers after every pick that came before it (`commit_walk/2`). A grant
  # planned in another athanor than the context's commits nothing.
  defp confirm(socket, %{kind: :grant, subject: subject} = prompt) do
    if subject.athanor_id != context_athanor(socket) do
      {:noreply, end_grant(socket, prompt)}
    else
      send_update(PrismWeb.ConsentSheetComponent,
        id: sheet_id(socket.assigns.id, prompt.id),
        confirm: prompt.id
      )

      {:noreply, socket}
    end
  end

  # The walk the sheet answered the confirm with, for the grant prompt it
  # names while that prompt is still the open one: its decisions and
  # bindings, under the plan and the preview of exactly those. While the
  # sheet reads a new preview there is nothing to commit yet.
  defp commit_walk(socket, %{prompt: prompt_id} = walk) do
    case open(socket, prompt_id, [:grant]) do
      {:ok, _prompt} ->
        socket = walk(socket, walk)
        %{subject: subject} = prompt = socket.assigns.current

        cond do
          subject.athanor_id != context_athanor(socket) ->
            {:noreply, end_grant(socket, prompt)}

          is_nil(subject.preview) ->
            {:noreply,
             assign(socket, :error, "Nothing to grant yet: the choices are being previewed.")}

          true ->
            args = %{
              "decisions" => subject.decisions,
              "plan_token" => subject.plan.plan_token,
              "proof" => subject.preview.proof,
              "commit_digest" => subject.preview.commit_digest,
              "expected_consent_revision" => Map.get(subject.plan, :expected_consent_revision)
            }

            {:noreply, dispatched(socket, prompt, Ops.call_tool(socket, "profile/commit", args))}
        end

      :none ->
        {:noreply, socket}
    end
  end

  defp enter_credential(socket, %{subject: subject} = prompt, params) do
    secret = Map.get(params, "secret")
    destination = destination_params(params)

    cond do
      present(secret) == :blank ->
        assign(socket, :error, "Enter the credential to save it.")

      destination["hosts"] == [] ->
        assign(socket, :error, "Name the host the credential may be sent to.")

      true ->
        args = %{
          "name" => subject.name,
          "kind" => "api_key",
          "fields" => %{subject.field => secret},
          "destination" => destination,
          "disclose" => disclose_param(params)
        }

        case layer_call(socket, prompt, :resubmit, "vault/create", args) do
          {:asked, socket} -> socket
          {:done, result, socket} -> dispatched(socket, prompt, result)
        end
    end
  end

  @doc """
  The destination a credential form names (`vault.create`'s
  `destination`): `hosts` from the `destination_hosts` field (comma,
  space or line separated, lower-cased), `scheme` from
  `destination_scheme` (`https` unless `http` is chosen), and `port`,
  `methods` and `paths` only when their fields name them. Nothing is
  prefilled from anywhere but what the person typed; the vault holds the
  result to `Prima.Destination`'s grammar.
  """
  @spec destination_params(map()) :: %{String.t() => term()}
  def destination_params(params) when is_map(params) do
    %{
      "hosts" =>
        params |> Map.get("destination_hosts", "") |> words() |> Enum.map(&String.downcase/1),
      "scheme" => if(Map.get(params, "destination_scheme") == "http", do: "http", else: "https")
    }
    |> put_words(
      "methods",
      params |> Map.get("destination_methods", "") |> words() |> Enum.map(&String.upcase/1)
    )
    |> put_words("paths", params |> Map.get("destination_paths", "") |> words())
    |> put_port(Map.get(params, "destination_port", ""))
  end

  @doc """
  Whether a credential form asks for the value to be disclosed to the
  app: only an explicit `disclose` checkbox turned on. Absent, the entry
  is attach-only.
  """
  @spec disclose_param(map()) :: boolean()
  def disclose_param(params) when is_map(params),
    do: Map.get(params, "disclose") in ["true", "on"]

  defp words(text) when is_binary(text),
    do: text |> String.split(~r/[\s,]+/, trim: true)

  defp words(_other), do: []

  defp put_words(map, _key, []), do: map
  defp put_words(map, key, words), do: Map.put(map, key, words)

  # A port the person typed is sent as typed when it is not a number, so
  # the vault's declaration refuses it rather than this form guessing.
  defp put_port(map, port) when is_binary(port) do
    case String.trim(port) do
      "" ->
        map

      trimmed ->
        case Integer.parse(trimmed) do
          {number, ""} -> Map.put(map, "port", number)
          _ -> Map.put(map, "port", trimmed)
        end
    end
  end

  defp put_port(map, _port), do: map

  defp choose(socket, %{subject: safe_mode} = prompt, offer) do
    case SafeMode.choose(safe_mode, offer) do
      :retry ->
        settle(socket, prompt, :confirmed)

      {:publish, document} ->
        args = %{"document" => Prima.Layout.to_json(document), "revision" => safe_mode.revision}
        dispatched(socket, prompt, Ops.call_tool(socket, "layout/edit", args))

      {:error, :not_offered} ->
        socket
    end
  end

  defp dispatched(socket, prompt, {:ok, _result}), do: settle(socket, prompt, :confirmed)

  defp dispatched(socket, %{kind: :safe_mode} = prompt, {:error, {:conflict, _} = reason}) do
    refuse(
      socket,
      prompt,
      reason,
      "Your layout changed since safe mode opened, so nothing was changed. " <>
        "Try again to load the layout as it is now."
    )
  end

  # A refused commit consumed the walk's plan token whatever it answered:
  # the sheet plans the same choices again, and the person may try again
  # once it has.
  defp dispatched(socket, %{kind: :grant} = prompt, {:error, reason}) do
    send_update(PrismWeb.ConsentSheetComponent,
      id: sheet_id(socket.assigns.id, prompt.id),
      replan: true
    )

    socket
    |> walk(%{prompt: prompt.id, plan: nil, preview: nil, decisions: prompt.subject.decisions})
    |> refuse(prompt, reason, Ops.error_message(reason))
  end

  defp dispatched(socket, prompt, {:error, reason}),
    do: refuse(socket, prompt, reason, Ops.error_message(reason))

  # ---------------------------------------------------------------------------
  # Grants
  # ---------------------------------------------------------------------------

  # The id of the sheet a grant prompt shows, in this layer.
  defp sheet_id(layer, prompt_id), do: "#{layer}-grant-#{prompt_id}"

  # The sheet's walk, taken into the open grant prompt it was drawn for:
  # the decisions it holds, and the plan and preview of exactly those, the
  # preview `nil` while the sheet reads one. A walk for a prompt no longer
  # open is late and is dropped. Reads nothing.
  defp walk(socket, %{prompt: prompt_id, plan: plan, preview: preview, decisions: decisions}) do
    case socket.assigns.current do
      %{id: ^prompt_id, kind: :grant, subject: subject} = prompt ->
        subject = %{subject | plan: plan || subject.plan, preview: preview, decisions: decisions}
        assign(socket, :current, %{prompt | subject: subject})

      _other ->
        socket
    end
  end

  # Every grant prompt planned in another athanor than the context's,
  # open or waiting, ends unconfirmed.
  defp end_moved_grants(%{assigns: %{context: %Context{athanor_id: athanor_id}}} = socket) do
    moved? = &match?(%{kind: :grant, subject: %{athanor_id: id}} when id != athanor_id, &1)
    {gone, kept} = Enum.split_with(socket.assigns.queue, moved?)
    Enum.each(gone, &report(&1.id, :dismissed))
    socket = assign(socket, :queue, kept)

    if moved?.(socket.assigns.current),
      do: end_grant(socket, socket.assigns.current),
      else: socket
  end

  defp end_moved_grants(socket), do: socket

  defp end_grant(socket, prompt) do
    report(prompt.id, :dismissed)
    advance(socket)
  end

  defp context_athanor(%{assigns: %{context: %Context{athanor_id: athanor_id}}}), do: athanor_id
  defp context_athanor(_socket), do: nil

  defp present(secret) when is_binary(secret) do
    if String.trim(secret) == "", do: :blank, else: :ok
  end

  defp present(_secret), do: :blank

  # ---------------------------------------------------------------------------
  # The layer's own sensitive changes
  # ---------------------------------------------------------------------------

  # Dispatch a change the layer asks for in `prompt`, naming the secret it
  # holds for that change when it holds one: `{:asked, socket}` while the
  # change waits for a proof, `{:done, result, socket}` with any other
  # answer. `repeat` says how the change is made again once confirmed:
  # `:resubmit`, by the browser; anything else, by the layer.
  defp layer_call(socket, prompt, repeat, tool, args) do
    held = held_of(socket, prompt.id, repeat)
    opts = if held, do: [confirmation_id: held.id], else: []

    case Ops.call_tool(socket, tool, args, opts) do
      {:error, {:confirmation_required, %{id: id}}} when is_map(held) and id == held.id ->
        {:asked, set_status(socket, held.ref, :waiting)}

      {:error, {:confirmation_required, %{id: id}}} when is_binary(id) ->
        socket = drop_prompt_asks(socket, prompt.id, cancel: true)
        ref = Prima.Confirmation.ref(id)

        entry =
          case pending_entry(socket, ref) do
            {:ok, entry} -> entry
            _unread -> nil
          end

        socket =
          socket
          |> assign(
            :held,
            Map.put(socket.assigns.held, ref, %{
              id: id,
              ref: ref,
              prompt_id: prompt.id,
              repeat: repeat
            })
          )
          |> put_panel(ref, %{
            prompt_id: prompt.id,
            entry: entry,
            own: true,
            origin: :layer,
            status: :waiting
          })
          |> assign(:error, nil)

        {:asked, socket}

      result ->
        {:done, result, drop_prompt_asks(socket, prompt.id)}
    end
  end

  defp held_of(socket, prompt_id, repeat) do
    socket.assigns.held
    |> Map.values()
    |> Enum.find(&(&1.prompt_id == prompt_id and &1.repeat == repeat))
  end

  # The confirmed record of a change the layer holds the secret of: made
  # again once, with it.
  defp repeat_held(socket, ref) do
    case Map.get(socket.assigns.held, ref) do
      %{repeat: :resubmit} ->
        push_resubmit(socket, "#{socket.assigns.id}-credential")

      %{repeat: :recovery_resubmit, prompt_id: prompt_id} ->
        push_layer(socket, "recovery:resubmit", %{prompt: prompt_id})

      %{prompt_id: prompt_id, repeat: repeat} ->
        case socket.assigns.current do
          %{id: ^prompt_id, kind: :pairing} = prompt ->
            case repeat do
              :pairing_begin -> pairing_begin(socket, prompt)
              {:pairing_revoke, client_id} -> pairing_revoke(socket, prompt, client_id)
            end

          %{id: ^prompt_id, kind: :kit} = prompt ->
            recovery_submit(socket, prompt, %{})

          _gone ->
            socket
        end

      nil ->
        socket
    end
  end

  # Let go of every secret and panel `prompt_id` holds; `cancel: true`
  # also cancels a request still waiting for its proof.
  defp drop_prompt_asks(socket, prompt_id, opts \\ []) do
    {gone, kept} =
      Enum.split_with(socket.assigns.held, fn {_ref, held} -> held.prompt_id == prompt_id end)

    if Keyword.get(opts, :cancel, false) do
      for {ref, _held} <- gone, waiting?(socket, ref) do
        Ops.call_tool(socket.assigns.context, "confirmation/cancel", %{"ref" => ref})
      end
    end

    panels =
      socket.assigns.panels
      |> Enum.reject(fn {_ref, panel} -> panel.prompt_id == prompt_id end)
      |> Map.new()

    assign(socket, held: Map.new(kept), panels: panels)
  end

  defp waiting?(socket, ref),
    do: match?(%{status: status} when status in [:waiting, :pending], socket.assigns.panels[ref])

  # Dismissing one's own request still waiting for its proof cancels it.
  defp end_own_request(socket, prompt) do
    case panel_of(socket.assigns.panels, prompt) do
      {ref, %{own: true, origin: :page, status: :waiting} = panel} ->
        Ops.call_tool(socket.assigns.context, "confirmation/cancel", %{"ref" => ref})
        socket |> clear_forms(panel) |> drop_panel(ref)

      {ref, %{own: true, origin: :page} = panel} ->
        socket |> clear_forms(panel) |> drop_panel(ref)

      {ref, %{own: false}} ->
        drop_panel(socket, ref)

      {_ref, %{origin: :layer}} ->
        drop_prompt_asks(socket, prompt.id, cancel: true)

      {ref, _panel} ->
        drop_panel(socket, ref)

      nil ->
        socket
    end
  end

  # A prompt the stream opened for another client's request reports
  # nothing: its parent never asked for it.
  defp reports?(socket, %{kind: :confirmation} = prompt) do
    case panel_of(socket.assigns.panels, prompt) do
      {_ref, %{origin: :stream}} -> false
      _own -> true
    end
  end

  defp reports?(_socket, _prompt), do: true

  # ---------------------------------------------------------------------------
  # Proofs
  # ---------------------------------------------------------------------------

  defp prove(socket, ref, args) do
    case open_panel(socket, ref) do
      {:ok, panel} ->
        case Ops.call_tool(socket, "confirmation/confirm", args) do
          {:ok, _confirmed} ->
            status = if panel.own, do: panel.status, else: :confirmed
            {:noreply, socket |> set_status(ref, status) |> assign(:error, nil)}

          {:error, reason} ->
            {:noreply, assign(socket, :error, Ops.error_message(reason))}
        end

      :none ->
        {:noreply, socket}
    end
  end

  defp reauth(socket, ref, method) do
    case Ops.call_tool(socket, "confirmation/reauth", %{"ref" => ref, "method" => method}) do
      {:ok, %{url: url}} when method == "oidc" and is_binary(url) ->
        socket |> update_panel(ref, %{reauth_url: url}) |> assign(:error, nil)

      {:ok, _sent} ->
        socket |> update_panel(ref, %{code_sent: true}) |> assign(:error, nil)

      {:error, reason} ->
        assign(socket, :error, Ops.error_message(reason))
    end
  end

  defp cancel(socket, ref) do
    case Ops.call_tool(socket, "confirmation/cancel", %{"ref" => ref}) do
      {:ok, _cancelled} -> assign(socket, :error, nil)
      {:error, reason} -> assign(socket, :error, Ops.error_message(reason))
    end
  end

  # ---------------------------------------------------------------------------
  # Pairing
  # ---------------------------------------------------------------------------

  defp clients(socket) do
    case Ops.call_tool(socket.assigns.context, "pairing/list", %{}) do
      {:ok, %{clients: clients}} -> {:ok, clients}
      {:error, reason} -> {:error, Ops.error_message(reason)}
    end
  end

  defp pairing_begin(socket, prompt) do
    case layer_call(socket, prompt, :pairing_begin, "pairing/begin", %{}) do
      {:asked, socket} ->
        socket

      {:done, {:ok, %{invitation_url: url, expires_at: expires_at}}, socket} ->
        # An address too long for a QR code still gives the link.
        svg =
          case PrismWeb.QR.svg(url, label: "Pairing code", class: "h-56 w-56") do
            {:ok, svg} -> svg
            {:error, :too_long} -> nil
          end

        invitation = %{url: url, svg: svg, expires_at: expires_at}

        socket
        |> assign(:pairing, %{pairing_of(socket, prompt) | invitation: invitation})
        |> assign(:error, nil)

      {:done, {:error, reason}, socket} ->
        refuse(socket, prompt, reason, Ops.error_message(reason))
    end
  end

  defp pairing_revoke(socket, prompt, client_id) do
    case layer_call(socket, prompt, {:pairing_revoke, client_id}, "pairing/revoke", %{
           "client_id" => client_id
         }) do
      {:asked, socket} ->
        socket

      {:done, {:ok, _revoked}, socket} ->
        socket
        |> assign(:pairing, %{pairing_of(socket, prompt) | clients: clients(socket)})
        |> assign(:error, nil)

      {:done, {:error, reason}, socket} ->
        refuse(socket, prompt, reason, Ops.error_message(reason))
    end
  end

  defp pairing_of(socket, prompt) do
    case socket.assigns.pairing do
      %{prompt_id: id} = pairing when id == prompt.id -> pairing
      _other -> %{prompt_id: prompt.id, clients: {:ok, []}, invitation: nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Recovery material
  # ---------------------------------------------------------------------------

  # The material the browser submitted, dispatched as the prompt's change;
  # once confirmed, the browser submits it again (`:recovery_resubmit`) or,
  # for a kit, the layer asks again (`{:recovery_kit, attempt_id}`).
  defp recovery_submit(socket, prompt, params) do
    case Recovery.request(prompt, params) do
      {:ok, tool, args, repeat} ->
        case layer_call(socket, prompt, repeat, tool, args) do
          {:asked, socket} -> socket
          {:done, result, socket} -> recovered(socket, prompt, result)
        end

      {:error, sentence} ->
        assign(socket, :error, sentence)
    end
  end

  # A kit answered goes to the browser alone, which draws its three lines;
  # the layer keeps the attempt it belongs to, which the acknowledgment
  # names, and nothing of the kit.
  defp recovered(socket, prompt, {:ok, %{attempt_id: attempt_id} = answer}) do
    case Recovery.kit_lines(answer) do
      nil ->
        settle(socket, prompt, :confirmed)

      lines ->
        socket
        |> push_layer("recovery:kit", %{prompt: prompt.id, kit: lines})
        |> assign(:recovery, %{Recovery.start(prompt.id) | phase: :kit, attempt_id: attempt_id})
        |> assign(:error, nil)
    end
  end

  defp recovered(socket, prompt, {:ok, _answer}), do: settle(socket, prompt, :confirmed)

  defp recovered(socket, prompt, {:error, reason}),
    do: refuse(socket, prompt, reason, Ops.error_message(reason))

  # The person saved the kit: its seed is erased at the home, and the
  # browser forgets the lines as the prompt ends.
  defp recovery_ack(%{assigns: %{recovery: %{phase: :kit, attempt_id: id}}} = socket, prompt)
       when is_binary(id) do
    case Ops.call_tool(socket, "person/kit_ack", %{"attempt_id" => id}) do
      {:ok, _acknowledged} -> settle(socket, prompt, :confirmed)
      {:error, reason} -> assign(socket, :error, Ops.error_message(reason))
    end
  end

  defp recovery_ack(socket, _prompt), do: socket

  # ---------------------------------------------------------------------------
  # Who can confirm
  # ---------------------------------------------------------------------------

  defp dismissable?(%{kind: kind}), do: kind != :safe_mode

  # A display rule: it hides a control and never decides. A prompt that
  # confirms no action offers its control to every client; one that does,
  # to a client with a person behind it who can give a proof.
  defp may_confirm?(_context, %{action: nil}), do: true

  defp may_confirm?(%Sanctum.Context{} = context, _prompt),
    do: Sanctum.Pairing.can_confirm?(context)

  defp may_confirm?(_context, _prompt), do: false

  defp can_prove?(%Sanctum.Context{} = context), do: Sanctum.Pairing.can_confirm?(context)
  defp can_prove?(_context), do: false

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    may = assigns.current && may_confirm?(assigns[:context], assigns.current)

    panel =
      case panel_of(assigns.panels, assigns.current) do
        {ref, panel} -> Map.put(panel, :ref, ref)
        nil -> nil
      end

    assigns =
      assign(assigns,
        may: may,
        # A record is proven here only by a client with a person behind it;
        # one with none waits for another client of the person.
        proves: panel != nil and can_prove?(assigns[:context]),
        panel: panel,
        safe_mode: match?(%{kind: :safe_mode}, assigns.current)
      )

    ~H"""
    <div
      id={@id}
      phx-hook="SystemLayer"
      class="contents"
      data-open={to_string(not is_nil(@current))}
      data-prompt-id={@current && @current.id}
      data-dismissable={to_string(not is_nil(@current) and dismissable?(@current))}
      data-mode={if @safe_mode, do: "popover", else: "modal"}
    >
      <dialog
        id={"#{@id}-dialog"}
        phx-mounted={JS.ignore_attributes(["open"])}
        popover={@safe_mode && "manual"}
        role={if @safe_mode, do: "alertdialog", else: "dialog"}
        aria-modal={to_string(not @safe_mode)}
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        class={[
          "m-auto w-full max-w-lg rounded-lg border border-gray-700 bg-gray-900 p-6 text-gray-100 shadow-xl",
          not @safe_mode && "backdrop:bg-black/70"
        ]}
      >
        <div :if={@current} class="space-y-4" data-kind={@current.kind}>
          <h2 id={"#{@id}-title"} class="text-lg font-semibold">
            {title(@current)}
          </h2>
          <p id={"#{@id}-description"} class="text-sm text-gray-300">
            {description(@current)}
          </p>

          <.standing prompt={@current} may={@may} />

          <.body
            prompt={@current}
            may={@may}
            myself={@myself}
            id={@id}
            pairing={@pairing}
            recovery={@recovery}
            context={assigns[:context]}
            athanor_route={@athanor_route}
            athanor_name={@athanor_name}
          />

          <.panel :if={@panel} panel={@panel} may={@proves} myself={@myself} id={@id} />

          <p :if={@error} role="alert" class="rounded border border-red-500 p-2 text-sm">
            <span class="font-semibold">Not done:</span> {@error}
          </p>

          <.controls prompt={@current} may={@may} myself={@myself} id={@id} panel={@panel} />

          <p :if={@queue != []} class="text-xs text-gray-400">
            {waiting(@queue)}
          </p>
        </div>
      </dialog>
    </div>
    """
  end

  attr :prompt, :map, required: true
  attr :may, :boolean, required: true

  # Said only where the control is hidden: a client with no person behind
  # it cannot give a proof, and the person confirms from a signed-in browser.
  defp standing(%{prompt: %{action: nil}} = assigns), do: ~H""
  defp standing(%{may: true} = assigns), do: ~H""

  defp standing(assigns) do
    ~H"""
    <p class="text-sm" data-standing="none">
      This client has no person behind it, so it cannot confirm this. Confirm it from a
      signed-in browser.
    </p>
    """
  end

  attr :prompt, :map, required: true
  attr :may, :boolean, required: true
  attr :myself, :any, required: true
  attr :id, :string, required: true
  attr :pairing, :map, default: nil
  attr :recovery, :map, default: nil
  attr :context, :any, default: nil
  attr :athanor_route, :any, default: nil
  attr :athanor_name, :any, default: nil

  # The consent walk: the sheet starts from the plan and preview the
  # prompt arrived with and hands each walk it makes back to this layer.
  defp body(%{prompt: %{kind: :grant}} = assigns) do
    ~H"""
    <div class="max-h-[60vh] overflow-y-auto" data-test="grant-sheet">
      <.live_component
        module={PrismWeb.ConsentSheetComponent}
        id={sheet_id(@id, @prompt.id)}
        ref={@prompt.subject.ref}
        walk={@prompt.subject}
        context={@context}
        athanor_route={@athanor_route}
        athanor_name={@athanor_name}
        layer={@id}
        prompt_id={@prompt.id}
      />
    </div>
    """
  end

  # The form is the browser's: kept as typed across every update, so the
  # value can be submitted again once its record is confirmed, and gone
  # with the prompt.
  defp body(%{prompt: %{kind: :credential_entry}} = assigns) do
    ~H"""
    <div id={"#{@id}-credential-#{@prompt.id}"} phx-update="ignore">
      <form
        id={"#{@id}-credential"}
        phx-submit="enter_credential"
        phx-target={@myself}
        class="space-y-2"
      >
        <input type="hidden" name="prompt_id" value={@prompt.id} />
        <label for={"#{@id}-secret"} class="block text-sm font-medium">
          {@prompt.subject.field} for {@prompt.subject.name}
        </label>
        <input
          id={"#{@id}-secret"}
          name="secret"
          type="password"
          autocomplete="off"
          required
          data-test="credential-secret"
          class="w-full rounded-md border border-gray-600 bg-transparent px-2 py-1 font-mono text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-400"
        />
        <fieldset class="space-y-2" data-test="credential-destination">
          <legend class="text-sm font-medium">Where it may be sent</legend>
          <label for={"#{@id}-destination-hosts"} class="block text-xs text-gray-400">
            Hosts (for example api.example.com, or *.example.com)
          </label>
          <input
            id={"#{@id}-destination-hosts"}
            name="destination_hosts"
            type="text"
            autocomplete="off"
            required
            data-test="credential-destination-hosts"
            class="w-full rounded-md border border-gray-600 bg-transparent px-2 py-1 font-mono text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-400"
          />
          <div class="grid grid-cols-2 gap-2">
            <div>
              <label for={"#{@id}-destination-scheme"} class="block text-xs text-gray-400">
                Scheme
              </label>
              <select
                id={"#{@id}-destination-scheme"}
                name="destination_scheme"
                class="w-full rounded-md border border-gray-600 bg-transparent px-2 py-1 text-sm"
              >
                <option value="https">https</option>
                <option value="http">http</option>
              </select>
            </div>
            <div>
              <label for={"#{@id}-destination-port"} class="block text-xs text-gray-400">
                Port (optional)
              </label>
              <input
                id={"#{@id}-destination-port"}
                name="destination_port"
                type="text"
                inputmode="numeric"
                autocomplete="off"
                class="w-full rounded-md border border-gray-600 bg-transparent px-2 py-1 font-mono text-sm"
              />
            </div>
          </div>
          <label for={"#{@id}-destination-methods"} class="block text-xs text-gray-400">
            Methods (optional, for example GET POST)
          </label>
          <input
            id={"#{@id}-destination-methods"}
            name="destination_methods"
            type="text"
            autocomplete="off"
            class="w-full rounded-md border border-gray-600 bg-transparent px-2 py-1 font-mono text-sm"
          />
          <label for={"#{@id}-destination-paths"} class="block text-xs text-gray-400">
            Path prefixes (optional, for example /v1/)
          </label>
          <input
            id={"#{@id}-destination-paths"}
            name="destination_paths"
            type="text"
            autocomplete="off"
            class="w-full rounded-md border border-gray-600 bg-transparent px-2 py-1 font-mono text-sm"
          />
        </fieldset>
        <label class="flex items-start gap-2 text-sm">
          <input
            type="checkbox"
            name="disclose"
            value="true"
            data-test="credential-disclose"
            class="mt-1"
          />
          <span>
            Let the app read the value itself. Left off, the value is never handed to the
            app, and an app asking for it is refused.
          </span>
        </label>
      </form>
    </div>
    """
  end

  defp body(%{prompt: %{kind: :safe_mode}} = assigns) do
    ~H"""
    <p class="text-sm">No app runs while safe mode is on. Choose how to go on.</p>
    """
  end

  defp body(%{prompt: %{kind: :pairing}} = assigns) do
    ~H"""
    <Pairing.devices
      prompt_id={@prompt.id}
      pairing={@pairing}
      may={@may}
      myself={@myself}
      button_class={button_class(false)}
      primary_class={button_class(true)}
    />
    """
  end

  defp body(%{prompt: %{kind: kind}} = assigns) when kind in [:enrollment, :kit, :holder] do
    ~H"""
    <Recovery.body
      prompt={@prompt}
      recovery={@recovery}
      may={@may}
      myself={@myself}
      id={@id}
      button_class={button_class(false)}
      primary_class={button_class(true)}
    />
    """
  end

  defp body(assigns), do: ~H""

  attr :panel, :map, required: true
  attr :may, :boolean, required: true
  attr :myself, :any, required: true
  attr :id, :string, required: true

  # One pending confirmation: the home's preview and the client that asked,
  # before any proof; this client's own request's status; and the proofs
  # the record's methods offer, to a client that can give one.
  defp panel(assigns) do
    assigns =
      assign(assigns,
        entry: assigns.panel.entry,
        methods: (assigns.panel.entry && assigns.panel.entry[:methods]) || [],
        open: assigns.panel.status in [:pending, :waiting]
      )

    ~H"""
    <section
      class="space-y-3 rounded-md border border-gray-700 p-3"
      aria-labelledby={"#{@id}-confirmation-title"}
      data-test="confirmation"
      data-ref={@panel.ref}
      data-own={to_string(@panel.own)}
    >
      <h3 id={"#{@id}-confirmation-title"} class="text-sm font-medium">
        {if @panel.own, do: "Confirm your request", else: "A request waits for your confirmation"}
      </h3>

      <dl
        :if={@entry && @entry[:preview]}
        class="grid grid-cols-3 gap-1 text-sm"
        data-test="confirmation-preview"
      >
        <dt class="text-gray-400">Change</dt>
        <dd class="col-span-2 font-mono">{@entry.preview["operation"]}</dd>
        <dt :if={@entry.preview["resource"]} class="text-gray-400">Concerning</dt>
        <dd :if={@entry.preview["resource"]} class="col-span-2">{@entry.preview["resource"]}</dd>
        <dt class="text-gray-400">In</dt>
        <dd class="col-span-2">{@entry.preview["athanor"]} at {@entry.preview["home"]}</dd>
        <%= for {name, value} <- Enum.sort(@entry.preview["details"] || %{}) do %>
          <dt class="text-gray-400">{name}</dt>
          <dd class="col-span-2 break-all">{detail(value)}</dd>
        <% end %>
      </dl>

      <p
        :if={is_nil(@entry) or is_nil(@entry[:preview])}
        class="text-sm"
        data-test="confirmation-preview"
      >
        {@panel.entry && @panel.entry[:operation]}
      </p>

      <p :if={@entry && @entry[:asker]} class="text-sm" data-test="confirmation-asker">
        Asked by {asker(@entry.asker)}{if @panel.own, do: " (this page)", else: ""}.
      </p>

      <p
        class="text-sm"
        role="status"
        data-test="confirmation-status"
        data-status={status_name(@panel.status)}
      >
        {status(@panel)}
      </p>

      <div :if={@may and @open and @entry != nil} class="flex flex-wrap gap-2">
        <button
          :if={"passkey" in @methods}
          type="button"
          phx-click="prove_passkey"
          phx-target={@myself}
          phx-value-ref={@panel.ref}
          data-test="confirm-passkey"
          class={button_class(true)}
        >
          Confirm with a passkey
        </button>
        <button
          :if={"oidc" in @methods and is_nil(@panel.reauth_url)}
          type="button"
          phx-click="reauth"
          phx-target={@myself}
          phx-value-ref={@panel.ref}
          phx-value-method="oidc"
          data-test="confirm-reauth"
          class={button_class(false)}
        >
          Sign in again
        </button>
        <a
          :if={@panel.reauth_url}
          href={@panel.reauth_url}
          target="_blank"
          rel="noopener noreferrer"
          data-test="confirm-reauth-open"
          class={button_class(false)}
        >
          Open the sign-in in a new tab
        </a>
        <button
          :if={"email" in @methods and not @panel.code_sent}
          type="button"
          phx-click="reauth"
          phx-target={@myself}
          phx-value-ref={@panel.ref}
          phx-value-method="email"
          data-test="confirm-email"
          class={button_class(false)}
        >
          Email me a code
        </button>
      </div>

      <form
        :if={@may and @open and @panel.code_sent}
        id={"#{@id}-code"}
        phx-submit="prove_code"
        phx-target={@myself}
        class="flex gap-2"
      >
        <input type="hidden" name="ref" value={@panel.ref} />
        <label for={"#{@id}-code-input"} class="sr-only">The code sent to your email</label>
        <input
          id={"#{@id}-code-input"}
          name="code"
          inputmode="numeric"
          autocomplete="one-time-code"
          placeholder="Code from your email"
          data-test="confirm-code"
          class="flex-1 rounded-md border border-gray-600 bg-transparent px-2 py-1 font-mono text-sm"
        />
        <button type="submit" data-test="confirm-code-submit" class={button_class(true)}>
          Confirm
        </button>
      </form>

      <button
        :if={@panel.status in [:pending, :waiting]}
        type="button"
        phx-click="cancel_confirmation"
        phx-target={@myself}
        phx-value-ref={@panel.ref}
        data-test="confirm-cancel"
        class={button_class(false)}
      >
        Cancel this request
      </button>
    </section>
    """
  end

  attr :prompt, :map, required: true
  attr :may, :boolean, required: true
  attr :myself, :any, required: true
  attr :id, :string, required: true
  attr :panel, :map, default: nil

  defp controls(%{prompt: %{kind: :safe_mode}} = assigns) do
    assigns = assign(assigns, :offers, SafeMode.offers(assigns.prompt.subject))

    ~H"""
    <div class="flex flex-wrap justify-end gap-2">
      <button
        :for={offered <- @offers}
        type="button"
        phx-click="choose"
        phx-target={@myself}
        phx-value-id={@prompt.id}
        phx-value-offer={offered.offer}
        class={[button_class(offered.offer == :retry)]}
      >
        {offer_label(offered)}
      </button>
    </div>
    """
  end

  defp controls(assigns) do
    ~H"""
    <div class="flex flex-wrap justify-end gap-2">
      <button
        type="button"
        phx-click="dismiss"
        phx-target={@myself}
        phx-value-id={@prompt.id}
        data-test="prompt-dismiss"
        class={button_class(false)}
      >
        {dismiss_label(@prompt, @panel)}
      </button>
      <button
        :if={@may and @prompt.kind in [:grant, :sign_in]}
        type="button"
        phx-click="confirm"
        phx-target={@myself}
        phx-value-id={@prompt.id}
        disabled={@prompt.kind == :grant and is_nil(@prompt.subject.preview)}
        data-test="prompt-confirm"
        class={[button_class(true), "disabled:opacity-50"]}
      >
        {confirm_label(@prompt)}
      </button>
      <button
        :if={@prompt.kind == :credential_entry}
        type="submit"
        form={"#{@id}-credential"}
        data-test="credential-submit"
        class={button_class(true)}
      >
        {if @may, do: "Save to vault", else: "Request confirmation"}
      </button>
    </div>
    """
  end

  defp button_class(primary?) do
    [
      "rounded-md px-3 py-2 text-sm font-semibold focus:outline-none focus-visible:ring-2",
      "focus-visible:ring-blue-300 focus-visible:ring-offset-2 focus-visible:ring-offset-gray-900",
      if(primary?,
        do: "bg-blue-600 text-white hover:bg-blue-500",
        else: "border border-gray-600 text-gray-100 hover:bg-gray-800"
      )
    ]
  end

  defp title(%{kind: :grant, subject: %{ref: ref}}), do: "Grant #{ref}"
  defp title(%{kind: :unlock}), do: "Unlock the vault"
  defp title(%{kind: :sign_in}), do: "Sign in"

  defp title(%{kind: :credential_entry, subject: %{name: name}}),
    do: "Enter a credential for #{name}"

  defp title(%{kind: :safe_mode}), do: "Safe mode"
  defp title(%{kind: :pairing}), do: "Your devices"
  defp title(%{kind: :confirmation, subject: %{operation: operation}}), do: "Confirm #{operation}"

  defp title(%{kind: kind} = prompt) when kind in [:enrollment, :kit, :holder],
    do: Recovery.title(prompt)

  defp description(%{kind: :grant}),
    do:
      "Approve what this app may use and reach, as listed below. Nothing is granted until you do."

  defp description(%{kind: :unlock, subject: subject}) do
    concerning = if name = subject[:name], do: " for #{name}", else: ""

    "An app asks to unlock the vault#{concerning}. Nothing on this server unlocks the " <>
      "vault, so there is nothing to confirm here."
  end

  defp description(%{kind: :sign_in, subject: subject}),
    do: subject[:message] || "Sign in to go on. You leave this page to do it."

  defp description(%{kind: :credential_entry}),
    do:
      "The value goes straight to your vault, sealed at rest. No app sees it, and it is " <>
        "never shown again."

  defp description(%{kind: :safe_mode, subject: %SafeMode{reason: :not_ready}}),
    do: "Your desktop did not start."

  defp description(%{kind: :safe_mode, subject: %SafeMode{reason: :crashed}}),
    do: "Your desktop stopped working."

  defp description(%{kind: :safe_mode, subject: %SafeMode{reason: :requested}}),
    do: "You turned safe mode on."

  defp description(%{kind: :pairing}),
    do:
      "Pair a phone or another browser with this home, or revoke a device you paired. " <>
        "Pairing and revoking each need a fresh confirmation."

  defp description(%{kind: :confirmation, subject: %{own: true}}),
    do:
      "You asked for a change that needs a fresh confirmation. Nothing changes until you " <>
        "confirm it here or on another of your devices."

  defp description(%{kind: :confirmation}),
    do:
      "A client of yours asked for a change that needs a fresh confirmation. Check what it " <>
        "would change and who asked before you confirm."

  defp description(%{kind: kind} = prompt) when kind in [:enrollment, :kit, :holder],
    do: Recovery.description(prompt)

  defp confirm_label(%{kind: :grant}), do: "Grant"
  defp confirm_label(%{kind: :sign_in}), do: "Sign in"

  defp dismiss_label(%{kind: :confirmation}, %{own: true, status: :waiting}), do: "Cancel"
  defp dismiss_label(%{kind: :confirmation}, %{own: false, status: :pending}), do: "Not now"
  defp dismiss_label(%{kind: :confirmation}, _panel), do: "Close"
  defp dismiss_label(_prompt, _panel), do: "Dismiss"

  defp offer_label(%{offer: :retry}), do: "Try again"
  defp offer_label(%{offer: :default}), do: "Use the default desktop"

  defp waiting([_one]), do: "One more prompt is waiting."
  defp waiting(queue), do: "#{length(queue)} more prompts are waiting."

  defp detail(value) when is_list(value), do: Enum.join(value, ", ")
  defp detail(value), do: value

  # The client that asked, as the home named it: a hint, never a proof.
  defp asker(%{"kind" => "client"} = asker), do: "a paired device#{named(asker)}"
  defp asker(%{"kind" => "key"} = asker), do: "an API key#{named(asker)}"
  defp asker(%{"kind" => "frame"} = asker), do: "an app#{named(asker)}"
  defp asker(%{"kind" => "unbound"}), do: "this home"

  defp asker(%{"kind" => "session"} = asker) do
    since =
      case asker["since"] && DateTime.from_iso8601(asker["since"]) do
        {:ok, at, _offset} -> " since #{Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")}"
        _none -> ""
      end

    "a browser signed in#{if asker["name"], do: " with #{asker["name"]}", else: ""}#{since}"
  end

  defp asker(_asker), do: "a client of yours"

  defp named(%{"name" => name}) when is_binary(name) and name != "", do: " named #{name}"
  defp named(_asker), do: ""

  defp status_name({:refused, _reason}), do: "refused"
  defp status_name({:ended, kind}), do: Atom.to_string(kind)
  defp status_name(status) when is_atom(status), do: Atom.to_string(status)

  defp status(%{status: :pending}), do: "Waiting for a proof."
  defp status(%{status: :confirmed}), do: "Confirmed. The client that asked completes the change."

  defp status(%{status: :waiting}),
    do: "Waiting for your confirmation, here or on another of your devices."

  defp status(%{status: :approved}), do: "Approved. Completing the change."
  defp status(%{status: :completed}), do: "Completed."

  defp status(%{status: {:refused, :asked_again}}),
    do: "The request changed, so it was asked for again. Nothing was changed."

  defp status(%{status: {:refused, reason}}), do: "Refused: " <> Ops.error_message(reason)
  defp status(%{status: {:ended, :cancelled}}), do: "Cancelled. Nothing was changed."

  defp status(%{status: {:ended, :voided}}),
    do: "This request was withdrawn. Nothing was changed."

  defp status(%{status: {:ended, :expired}}), do: "This request expired. Nothing was changed."
end

defmodule PrismWeb.SystemLayer.Listener do
  @moduledoc false
  # The system layer's listener on `confirmation.changes`: one process per
  # LiveView that mounts the layer, under the grant the view's open
  # answered. It subscribes to the one topic the grant admits
  # (`Cyfr.Bus.granted_topic/2`), hands each fact to the layer projected
  # to the grant's fields, ends when the view does, and at the grant's
  # deadline tells the layer, which opens the stream again through the
  # gate. It reaches no store.

  alias Sanctum.Context

  @doc false
  # Started subscribed, so no fact published after the grant is missed.
  # It hands its facts to the layer `layer` names in `view`.
  @spec start(pid(), String.t(), Context.t(), Prima.StreamGrant.t(), CyfrWeb.ContextGuard.tag()) ::
          {:ok, pid()} | {:error, term()}
  def start(view, layer, %Context{} = ctx, %Prima.StreamGrant{} = grant, tag) do
    ready = make_ref()
    me = self()

    case Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
           run({view, layer}, me, ready, ctx, grant, tag)
         end) do
      {:ok, pid} ->
        receive do
          {^ready, :subscribed} ->
            {:ok, pid}

          {^ready, {:error, reason}} ->
            {:error, reason}
        after
          5_000 ->
            # A listener that never said it was subscribed is stopped, not
            # left to hear a topic no one reads.
            Task.Supervisor.terminate_child(Prism.TaskSupervisor, pid)
            {:error, :not_subscribed}
        end

      {:error, reason} ->
        {:error, reason}

      _not_started ->
        {:error, :not_started}
    end
  end

  @doc false
  @spec stop(pid()) :: :ok
  def stop(pid) do
    send(pid, {__MODULE__, :stop})
    :ok
  end

  defp run({view, _layer} = to, starter, ready, ctx, grant, tag) do
    monitor = Process.monitor(view)
    actor = Context.actor(ctx)

    case Cyfr.Bus.subscribe(actor, Cyfr.Bus.granted_topic(actor, grant)) do
      :ok ->
        send(starter, {ready, :subscribed})
        remaining = max(DateTime.diff(grant.deadline, DateTime.utc_now(), :millisecond), 0)
        Process.send_after(self(), {__MODULE__, :deadline}, remaining)
        loop(to, monitor, grant, tag, payload_struct(grant))

      {:error, reason} ->
        send(starter, {ready, {:error, reason}})
    end
  end

  # The one struct the grant's topic carries (the bus roster's); anything
  # else in the mailbox is not the stream's to hand on.
  defp payload_struct(%Prima.StreamGrant{topic: key}),
    do: Enum.find_value(Cyfr.Bus.topics(), fn row -> row.key == key && row.struct end)

  defp loop({view, layer} = to, monitor, grant, tag, payload) do
    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :ok

      {__MODULE__, :stop} ->
        :ok

      {__MODULE__, :deadline} ->
        Phoenix.LiveView.send_update(view, PrismWeb.SystemLayer, id: layer, listen: :ended)

      %{__struct__: ^payload} = fact ->
        Phoenix.LiveView.send_update(view, PrismWeb.SystemLayer,
          id: layer,
          fact: Prima.StreamGrant.project(grant, Map.from_struct(fact)),
          tag: tag
        )

        loop(to, monitor, grant, tag, payload)

      _other ->
        loop(to, monitor, grant, tag, payload)
    end
  end
end
