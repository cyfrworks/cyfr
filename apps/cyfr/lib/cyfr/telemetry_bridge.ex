# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TelemetryBridge do
  @moduledoc """
  The one place a telemetry event becomes a bus message.

  A foundation below the host emits `:telemetry` and never broadcasts, so
  every announcement the identity domain makes — a tray entry, a session
  minted or revoked, a dropped caller memo, a vault entry,
  a share, an archive, the API key and webhook rosters, a pending
  confirmation — every file offer the storage layer moves, and every
  lifecycle event the console follows reaches `Cyfr.Bus` here. The
  events it attaches are exactly
  `Cyfr.Telemetry.Catalog.consumed_by(:bridge)`; there is no second list.

  Each event maps to one payload constructor, which takes only the
  metadata fields it names: telemetry metadata is whatever its emitter
  attached, and the console is a trust boundary. A shared thread's change
  alone reads beside its metadata: what each person it names now lists
  of the thread (`Sanctum.SharedThreads.listings/2`). A reason or an error is
  classified here (`Sanctum.Refusals.classify/1`, which knows the identity
  domain's vocabulary the bus may not name) and carried as its class and
  public sentence, never an arbitrary term. A tenant
  event that names no athanor has nowhere to go: it is dropped and counted
  as `[:cyfr, :bus, :bridge_dropped]`.

  What waits for a person (`Cyfr.Bus.Attention`) is told on their own
  attention topic from the events of the records it references: an item
  that begins waiting is read again, when its message is delivered,
  through the stream's own derivation (`Cyfr.Providers.Attention`), so a
  live item is the one the stream's refresh lists, and one that stops is
  `removed` by its id.

  The athanor's recent files and the offers waiting for its person
  (`Cyfr.Bus.FileListed`) are told on its files topic the same way: a
  path under `data/` that changed, or an offer that began or stopped
  waiting, is read again through the stream's own derivation
  (`Cyfr.Providers.Files`) when its message is delivered.

  The handlers run in the emitting process, and `:telemetry` detaches a
  handler that fails in any way for the life of the node. Every failure —
  a refused publish, a raising PubSub, an exit — is caught and logged
  here, so one bad event costs one message and not every update after it.
  """

  use GenServer

  require Logger

  alias Cyfr.Bus

  alias Cyfr.Bus.{
    ApiKeys,
    AthanorArchived,
    Attention,
    Build,
    CallerInvalidated,
    Components,
    Confirmation,
    Execution,
    FeedRun,
    FileListed,
    FileOffer,
    FrameCredential,
    Notify,
    PolicyDecision,
    Request,
    ScheduleRun,
    Session,
    ShareChanged,
    SharedThreadChanged,
    ThreadListed,
    Tinctures,
    VaultEntry,
    VaultEntryChanged,
    Webhooks
  }

  # What a pending confirmation's life announces, one event per kind of
  # `Cyfr.Bus.Confirmation`.
  @confirmation_events [
    [:cyfr, :sanctum, :confirmation, :opened],
    [:cyfr, :sanctum, :confirmation, :confirmed],
    [:cyfr, :sanctum, :confirmation, :consumed],
    [:cyfr, :sanctum, :confirmation, :cancelled],
    [:cyfr, :sanctum, :confirmation, :voided],
    [:cyfr, :sanctum, :confirmation, :expired]
  ]

  # What ends a pending confirmation's wait; a confirmed record still waits
  # for the change its asker repeats.
  @confirmation_ends [:consumed, :cancelled, :voided, :expired]

  # What ends an offer's wait for its recipient.
  @offer_ends [:accepted, :declined, :withdrawn, :expired]

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The events the bridge attaches: the catalog's `:bridge` roster."
  @spec events() :: [[atom(), ...]]
  def events, do: Cyfr.Telemetry.Catalog.consumed_by(:bridge)

  @doc "The handler id the bridge attaches `event` under."
  @spec handler_id([atom(), ...]) :: {module(), [atom(), ...]}
  def handler_id(event), do: {__MODULE__, event}

  @impl true
  def init(_opts) do
    attach()
    {:ok, %{}}
  end

  # Handlers are global to the node, not owned by this process: a restart
  # would otherwise find the pre-restart attach in place. Detaching first
  # makes the attach mean what it says.
  @impl true
  def terminate(_reason, _state) do
    Enum.each(events(), &:telemetry.detach(handler_id(&1)))
  end

  @impl true
  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  defp attach do
    for event <- events() do
      id = handler_id(event)
      _ = :telemetry.detach(id)

      case :telemetry.attach(id, event, &__MODULE__.handle_event/4, nil) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[Cyfr.TelemetryBridge] could not attach #{inspect(event)}: #{inspect(reason)} — " <>
              "console updates for this event will not arrive"
          )
      end
    end

    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    for message <- messages(event, measurements, metadata), do: deliver(event, message)
    :ok
  catch
    kind, reason ->
      Logger.warning(
        "[Cyfr.TelemetryBridge] #{inspect(event)} not bridged: " <>
          Prima.LogFilter.format_exception(kind, reason)
      )

      :ok
  end

  # ---------------------------------------------------------------------------
  # One constructor per event
  # ---------------------------------------------------------------------------

  # What an event becomes: `{:tenant, athanor_id, topic_fun, build}` for a
  # tenant topic, `{:global, topic, payload}` for a global one. A tenant
  # message is built only once its athanor is known.
  defp messages([:cyfr, :opus, :execute, :start], _measurements, meta),
    do: [tenant(meta, &Bus.executions/1, &Execution.new(&1, :started, execution(meta)))]

  defp messages([:cyfr, :opus, :execute, :stop], _measurements, meta) do
    [
      tenant(meta, &Bus.executions/1, &Execution.new(&1, :completed, execution(meta)))
      | root_notify(meta, :execution_finished)
    ] ++ run_attention(meta, :completed)
  end

  # A cancel ends the row as the caller asked; it is not a failure the
  # tray announces.
  defp messages(
         [:cyfr, :opus, :execute, :exception],
         _measurements,
         %{status: :cancelled} = meta
       ),
       do: [tenant(meta, &Bus.executions/1, &Execution.new(&1, :cancelled, execution(meta)))]

  defp messages([:cyfr, :opus, :execute, :exception], _measurements, meta) do
    [
      tenant(meta, &Bus.executions/1, &Execution.new(&1, :failed, execution(meta)))
      | root_notify(meta, :execution_failed)
    ] ++ run_attention(meta, :failed)
  end

  defp messages([:cyfr, :emissary, :request], measurements, meta) do
    fields =
      meta
      |> Map.take([:request_id, :method, :tool, :action, :status])
      |> Map.put(:duration_ms, measurements[:duration_ms])

    [tenant(meta, &Bus.requests/1, &Request.new(&1, :logged, fields))]
  end

  defp messages([:cyfr, :sanctum, :policy, :decision], _measurements, meta) do
    fields = Map.take(meta, [:event_type, :decision, :component_ref])
    [tenant(meta, &Bus.enforcement/1, &PolicyDecision.new(&1, :changed, fields))]
  end

  defp messages([:cyfr, :locus, :build, stage], _measurements, meta)
       when stage in [:start, :progress, :stop] do
    kind = %{start: :started, progress: :progress, stop: :stopped}[stage]

    fields =
      meta
      |> Map.take([:build_id, :reference, :phase, :message, :status, :error])
      |> classified([:error])

    [tenant(meta, &Bus.builds/1, &Build.new(&1, kind, fields))]
  end

  # A fire is a schedule's or a feed's by the row's own kind, which the
  # scheduler reads from the row it fired; an event naming neither is
  # dropped rather than guessed.
  defp messages([:cyfr, :schedules, :fired], _measurements, meta),
    do: [fired(meta, :fired)]

  # A run that could not start, or ran and failed: the one silent loss the
  # tray must show, a feed's as much as a schedule's.
  defp messages([:cyfr, :schedules, :failed], _measurements, meta) do
    [
      fired(meta, :failed),
      tenant(meta, &Bus.notify/1, fn actor ->
        Notify.new(
          actor,
          :schedule_failed,
          meta |> Map.take([:schedule_id, :execution_id, :reason]) |> classified([:reason])
        )
      end)
    ] ++ schedule_attention(meta, :failed)
  end

  # A schedule's run that completed settles its failing; a feed's has no
  # item.
  defp messages([:cyfr, :schedules, :completed], _measurements, %{kind: "schedule"} = meta),
    do: schedule_attention(meta, :completed)

  defp messages([:cyfr, :schedules, :completed], _measurements, %{kind: "feed"}), do: []

  # A grant moved: the component it is for is named, so a reader of the
  # registry reads whether its grant is current again.
  defp messages([:cyfr, :sanctum, :consent, :changed], _measurements, meta) do
    fields =
      case Prima.ComponentRef.parse(meta[:source_ref] || "") do
        {:ok, %{type: type, namespace: namespace, name: name}} ->
          %{ref: Prima.ComponentRef.build(type, namespace, name), type: type, name: name}

        _unparsed ->
          %{}
      end

    [tenant(meta, &Bus.components/1, &Components.new(&1, :changed, fields))]
  end

  defp messages([:cyfr, :compendium, :component, action], _measurements, meta)
       when action in [:install, :remove, :push] do
    kind = %{install: :installed, remove: :removed, push: :pushed}[action]
    [tenant(meta, &Bus.components/1, &Components.new(&1, kind, component_fields(meta)))]
  end

  defp messages([:cyfr, :opus, :tincture, :invoke, stage], _measurements, meta)
       when stage in [:start, :stop] do
    kind = if stage == :start, do: :invoke_started, else: :invoke_stopped

    fields =
      meta
      |> Map.take([:request_id, :tincture_ref, :reference, :status, :error])
      |> classified([:error])

    [tenant(meta, &Bus.tinctures/1, &Tinctures.new(&1, kind, fields))]
  end

  # The tray: an athanor's own, or — naming none — the operators'.
  defp messages([:cyfr, :sanctum, :notify], _measurements, %{athanor_id: nil} = meta),
    do: [{:global, Bus.platform_notify(), Notify.platform(meta[:kind], notify_payload(meta))}]

  defp messages([:cyfr, :sanctum, :notify], _measurements, meta) do
    [
      tenant(meta, &Bus.notify/1, fn actor ->
        Notify.new(actor, meta[:kind], notify_payload(meta))
      end)
      | approval_attention(meta)
    ]
  end

  # The memo is a cached authorization decision held in each member's own
  # table, so the announcement is global: every member drops what it holds
  # for that session row key. The member that announced dropped its own
  # before the event fired.
  defp messages([:cyfr, :sanctum, :caller, :invalidated], _measurements, %{hash: key})
       when is_binary(key),
       do: [{:global, Bus.caller_invalidated_global(), CallerInvalidated.new(key)}]

  defp messages([:cyfr, :sanctum, :session, :created], _measurements, _meta),
    do: [{:global, Bus.sessions(), Session.new(:created)}]

  defp messages([:cyfr, :sanctum, :sessions, :revoked], _measurements, %{user_id: user_id})
       when is_binary(user_id),
       do: [{:global, Bus.sessions(), Session.new(:revoked, user_id)}]

  defp messages(
         [:cyfr, :sanctum, :frame_credential, :changed],
         _measurements,
         %{user_id: user_id, credential_id: id, change: change}
       )
       when is_binary(user_id) and is_binary(id),
       do: [{:global, Bus.frame_credentials(user_id), FrameCredential.new(change, user_id, id)}]

  # A shared thread's change, on the own topic of each person it names:
  # its people, and anyone the change took from it, or the one person whose
  # read mark moved. And on each one's list
  # of threads in their own athanor, the thread as it reads now or its
  # removal (`Sanctum.SharedThreads.listings/2`): the one announcement here
  # that reads, since a shared thread is no athanor's and its event names
  # only who to tell.
  defp messages([:cyfr, :sanctum, :shared_thread, kind], _measurements, %{
         thread_id: thread_id,
         user_ids: user_ids
       })
       when is_binary(thread_id) and is_list(user_ids) do
    user_ids = for user_id <- user_ids, is_binary(user_id) and user_id != "", do: user_id

    changed =
      for user_id <- user_ids,
          do:
            {:global, Bus.shared_threads(user_id),
             SharedThreadChanged.new(kind, user_id, thread_id)}

    changed ++
      for {user_id, athanor_id, listing} <- listings(thread_id, user_ids) do
        actor = Prima.Actor.in_athanor(athanor_id)
        {:tenant, actor, Bus.threads(actor, user_id), &listed(&1, thread_id, listing)}
      end
  end

  # Two topics, one announcement: the athanor's own, and the deliberately
  # global one the external-server reconciler reads because it cannot know
  # every tenant topic.
  defp messages([:cyfr, :sanctum, :vault, :entry_changed], _measurements, meta) do
    build = fn actor ->
      meta_fields = Map.take(meta[:meta] || %{}, [:name, :old_name])
      VaultEntryChanged.new(actor, meta[:verb], Map.put(meta_fields, :entry_id, meta[:entry_id]))
    end

    [
      tenant(meta, &Bus.vault_changed/1, build),
      tenant(meta, fn _actor -> Bus.vault_changed_global() end, build, :global)
      | vault_entries(meta)
    ]
  end

  # A share's durable change, on the one global topic its recipients in
  # other athanors hear: the share id and the kind, and nothing else the
  # emitter attached (the acting person among it).
  defp messages(
         [:cyfr, :sanctum, :share, kind],
         _measurements,
         %{share_id: share_id, kind: kind}
       )
       when is_binary(share_id) and share_id != "",
       do: [{:global, Bus.shares(), ShareChanged.new(kind, share_id)}]

  # Sending a copy, on the topic of each person it concerns: an offer's
  # transitions reach its sender and its recipient, and a receipt that
  # landed or that the sweep failed its recipient alone, the sender's
  # offer having been accepted already. The offer, the kind, the sender
  # and the filename travel, and nothing else the emitter attached.
  defp messages(
         [:cyfr, :arca, :file_offer, kind],
         _measurements,
         %{
           offer_id: offer_id,
           kind: kind,
           sender_user_id: sender,
           recipient_user_id: recipient,
           filename: filename
         }
       )
       when is_binary(offer_id) and offer_id != "" and is_binary(sender) and sender != "" and
              is_binary(recipient) and recipient != "" and is_binary(filename) and
              filename != "" do
    payload = FileOffer.new(kind, offer_id, sender, filename)

    for(
      user_id <- told(kind, sender, recipient),
      do: {:global, Bus.file_offers(user_id), payload}
    ) ++
      offer_waits(kind, offer_id, recipient)
  end

  # A path under an athanor's data/ changed: what it names now, read when
  # the message is delivered.
  defp messages([:cyfr, :arca, :file, :changed], _measurements, %{
         athanor_id: athanor_id,
         path: "data" <> _ = path
       })
       when is_binary(athanor_id) and athanor_id != "" do
    [files(athanor_id, &Cyfr.Providers.Files.file(&1, path))]
  end

  defp messages([:cyfr, :sanctum, :athanor, :archived], _measurements, %{athanor_id: id})
       when is_binary(id) and id != "",
       do: [{:global, Bus.athanor_archived_global(), AthanorArchived.new(id)}]

  # A pending confirmation moved: on its person's own topic, carrying its
  # ref, operation and expiry and nothing else the emitter attached.
  defp messages(
         [:cyfr, :sanctum, :confirmation, stage] = event,
         _measurements,
         %{user_id: user_id} = meta
       )
       when event in @confirmation_events and is_binary(user_id) and user_id != "" do
    fields = Map.take(meta, [:ref, :operation, :expires_at])

    [
      tenant(meta, &Bus.confirmations(&1, user_id), &Confirmation.new(&1, stage, fields))
      | confirmation_attention(stage, meta)
    ]
  end

  defp messages([:cyfr, :sanctum, :api_keys, :changed], _measurements, meta),
    do: [tenant(meta, &Bus.api_keys/1, &ApiKeys.new(&1, :changed))]

  defp messages([:cyfr, :sanctum, :webhooks, :changed], _measurements, meta),
    do: [tenant(meta, &Bus.webhooks/1, &Webhooks.new(&1, :changed))]

  # An event the roster names whose metadata lacks what its message needs.
  defp messages(_event, _measurements, _meta), do: [:dropped]

  defp execution(meta) do
    %{
      execution_id: meta[:execution_id],
      request_id: meta[:request_id],
      parent_execution_id: meta[:parent_execution_id],
      reference: meta[:reference],
      component_type: meta[:component_type],
      duration_ms: meta[:duration_ms],
      started_at: meta[:started_at],
      ended_at: meta[:ended_at],
      error: execution_error(meta)
    }
  end

  # The entry as a canvas reads it, from the standing the committed write
  # left: a rename takes the old name away first, and an entry that no
  # longer stands is removed by its name.
  defp vault_entries(meta) do
    entry = meta[:meta] || %{}

    renamed =
      if is_binary(entry[:old_name]) and entry[:old_name] != entry[:name],
        do: [vault_entry(meta, :removed, %{name: entry[:old_name]})],
        else: []

    standing =
      case entry do
        %{status: status} when is_binary(status) ->
          vault_entry(meta, :changed, Map.take(entry, [:name, :type, :status]))

        _gone ->
          vault_entry(meta, :removed, %{name: entry[:name]})
      end

    renamed ++ [standing]
  end

  defp vault_entry(meta, kind, fields),
    do: tenant(meta, &Bus.vault_entries/1, &VaultEntry.new(&1, kind, fields))

  # A version as a registry event names it: its versionless reference, its
  # type, name and version. What only the listing reads (its icon, a newer
  # shipped version, its grant) is left to the stream's refresh.
  defp component_fields(meta) do
    type = meta[:component_type] && to_string(meta[:component_type])

    ref =
      if is_binary(type) and is_binary(meta[:publisher]) and is_binary(meta[:name]),
        do: Prima.ComponentRef.build(type, meta[:publisher], meta[:name])

    %{ref: ref, type: type, name: meta[:name], version: meta[:version]}
  end

  # What each person lists of a shared thread now. A read that fails costs
  # the lists their update and never the change's own messages before it.
  defp listings(thread_id, user_ids) do
    Sanctum.SharedThreads.listings(thread_id, user_ids)
  catch
    kind, reason ->
      Logger.warning(
        "[Cyfr.TelemetryBridge] the lists of threads of shared thread #{thread_id} not told: " <>
          Prima.LogFilter.format_exception(kind, reason)
      )

      []
  end

  # A shared thread on one person's list, or its leaving it.
  defp listed(actor, thread_id, :removed), do: ThreadListed.new(actor, :removed, id: thread_id)
  defp listed(actor, _thread_id, listing), do: ThreadListed.new(actor, :shared, listing)

  # Who a file offer's message is for: a receipt, failed or landed, is its
  # recipient's; every other transition is both people's.
  defp told(kind, _sender, recipient) when kind in [:failed, :landed], do: [recipient]
  defp told(_kind, sender, recipient), do: Enum.uniq([recipient, sender])

  defp fired(%{kind: "schedule"} = meta, kind) do
    fields =
      meta
      |> Map.take([:schedule_id, :occurrence_id, :execution_id, :scheduled_for, :reason])
      |> classified([:reason])

    tenant(meta, &Bus.schedule_runs/1, &ScheduleRun.new(&1, kind, fields))
  end

  defp fired(%{kind: "feed"} = meta, kind) do
    fields =
      meta
      |> Map.take([:occurrence_id, :execution_id, :reason])
      |> Map.put(:binding, meta[:schedule_id])
      |> classified([:reason])

    tenant(meta, &Bus.feed_runs/1, &FeedRun.new(&1, kind, fields))
  end

  defp fired(_meta, _kind), do: :dropped

  defp notify_payload(meta) do
    case meta[:payload] || %{} do
      %{} = payload -> classified(payload, [:reason])
      other -> other
    end
  end

  # A reason or an error, as the gate classifies it: the payload keeps its
  # class and sentence and drops the term.
  defp classified(fields, keys) do
    Enum.reduce(keys, fields, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.update!(acc, key, &classify/1), else: acc
    end)
  end

  defp classify(nil), do: nil
  defp classify(reason), do: Sanctum.Refusals.classify(reason)

  # A run's error as its record keeps it: the sentence under the class
  # `Opus.Record.fail/3` gave it, the same reading the stored row gives a
  # stream's refresh (`Opus.Providers.Feed.recent_runs/2`).
  defp execution_error(%{error: message, error_class: class}) when is_binary(message),
    do: Execution.error(message, class)

  defp execution_error(meta), do: classify(meta[:error])

  # The tray counts only root executions: a chain's children are the same
  # piece of work.
  defp root_notify(%{parent_execution_id: parent}, _kind) when not is_nil(parent), do: []

  defp root_notify(meta, kind) do
    [
      tenant(meta, &Bus.notify/1, fn actor ->
        Notify.new(actor, kind, Map.take(meta, [:execution_id, :reference]))
      end)
    ]
  end

  # ---------------------------------------------------------------------------
  # What waits for a person
  # ---------------------------------------------------------------------------

  # A top-level run of a reference its person ran: a failure is that
  # reference's item as it stands once read, and any end of a run of it
  # settles the item, which is the reference itself. A child is part of
  # its root's work.
  defp run_attention(meta, outcome) do
    case meta do
      %{athanor_id: athanor_id, user_id: user_id, reference: reference}
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) and
             user_id != "" and is_binary(reference) ->
        if is_nil(meta[:parent_execution_id]),
          do: [ran(outcome, athanor_id, user_id, reference)],
          else: []

      _unattributed ->
        []
    end
  end

  defp ran(:failed, athanor_id, user_id, reference) do
    attention(fn ->
      Cyfr.Providers.Attention.failed_run(Prima.Actor.in_athanor(athanor_id), user_id, reference)
      |> waiting(athanor_id, user_id)
    end)
  end

  defp ran(:completed, athanor_id, user_id, reference),
    do:
      attention(fn ->
        {:ok, [{athanor_id, user_id, :removed, %{id: reference, outcome: :resolved}}]}
      end)

  # A schedule's failure is its item as it stands once read; a completed
  # run of it settles the item.
  defp schedule_attention(meta, outcome) do
    case meta do
      %{kind: "schedule", athanor_id: athanor_id, user_id: user_id, schedule_id: id}
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) and
             user_id != "" and is_binary(id) ->
        [scheduled(outcome, athanor_id, user_id, id)]

      _feed_or_unattributed ->
        []
    end
  end

  defp scheduled(:failed, athanor_id, user_id, id) do
    attention(fn ->
      Cyfr.Providers.Attention.failed_schedule(Prima.Actor.in_athanor(athanor_id), user_id, id)
      |> waiting(athanor_id, user_id)
    end)
  end

  defp scheduled(:completed, athanor_id, user_id, id),
    do:
      attention(fn -> {:ok, [{athanor_id, user_id, :removed, %{id: id, outcome: :resolved}}]} end)

  # An approval waits for the athanor's person: opened, it is read as it
  # stands; resolved, it is removed with how its decision ended it.
  defp approval_attention(%{
         athanor_id: athanor_id,
         kind: kind,
         payload: %{approval_id: id} = payload
       })
       when kind in [:approval_pending, :approval_resolved] and is_binary(athanor_id) and
              athanor_id != "" and is_binary(id) do
    [
      attention(fn ->
        with {:ok, person} <- Cyfr.Providers.Attention.person(athanor_id) do
          case kind do
            :approval_pending ->
              Cyfr.Providers.Attention.approval(Prima.Actor.in_athanor(athanor_id), id)
              |> waiting(athanor_id, person)

            :approval_resolved ->
              outcome = left_as(Map.get(payload, :decision))
              {:ok, [{athanor_id, person, :removed, %{id: id, outcome: outcome}}]}
          end
        end
      end)
    ]
  end

  defp approval_attention(_meta), do: []

  # An offer waits for its recipient in their own athanor, wherever its
  # sender is, among what waits for them and among their files: one
  # message, so a denial that ends thousands of offers reads each
  # recipient's athanor once per transition. A receipt's landing or
  # failure is not a wait.
  defp offer_waits(kind, offer_id, recipient) when kind == :offered or kind in @offer_ends do
    [
      {:offer_wait,
       fn ->
         with {:ok, athanor_id} <- Cyfr.Providers.Attention.own_athanor(recipient) do
           actor = Prima.Actor.in_athanor(athanor_id)

           if kind == :offered do
             with {:ok, waits} <-
                    %{actor | user_id: recipient}
                    |> Cyfr.Providers.Attention.file_offer(offer_id)
                    |> waiting(athanor_id, recipient),
                  {:ok, files} <- Cyfr.Providers.Files.offer(actor, recipient, offer_id),
                  do: {:ok, actor, waits, files}
           else
             {:ok, actor,
              [{athanor_id, recipient, :removed, %{id: offer_id, outcome: left_as(kind)}}],
              [Cyfr.Providers.Files.removed(offer_id)]}
           end
         end
       end}
    ]
  end

  defp offer_waits(_kind, _offer_id, _recipient), do: []

  # Read when delivered, so a read that fails costs this message alone.
  defp files(athanor_id, read), do: {:files, Prima.Actor.in_athanor(athanor_id), read}

  # A confirmation is its announcement's item: the record is the identity
  # domain's, and the announcement carries what the item names.
  defp confirmation_attention(
         :opened,
         %{
           athanor_id: athanor_id,
           user_id: user_id,
           ref: ref,
           operation: operation,
           opened_at: %DateTime{} = opened_at
         }
       )
       when is_binary(athanor_id) and athanor_id != "" and is_binary(ref) and
              is_binary(operation) do
    item =
      Cyfr.Providers.Attention.confirmation(%{
        ref: ref,
        operation: operation,
        opened_at: opened_at
      })

    [attention(fn -> waiting({:ok, [item]}, athanor_id, user_id) end)]
  end

  defp confirmation_attention(stage, %{athanor_id: athanor_id, user_id: user_id, ref: ref})
       when stage in @confirmation_ends and is_binary(athanor_id) and athanor_id != "" and
              is_binary(ref),
       do: [
         attention(fn ->
           {:ok, [{athanor_id, user_id, :removed, %{id: ref, outcome: left_as(stage)}}]}
         end)
       ]

  defp confirmation_attention(_stage, _meta), do: []

  # How an item left its person's attention (`Cyfr.Bus.Attention.outcomes/0`),
  # by its record's end: a confirmation's stage, an offer's transition or
  # an approval's decision. An end whose time ran out is `expired`, one
  # that took the record away (a voided confirmation, a withdrawn offer, a
  # deleted thread's approval) `withdrawn`, and every other `resolved`.
  defp left_as(ended) when ended in [:expired, "expired"], do: :expired
  defp left_as(ended) when ended in [:voided, :withdrawn, "withdrawn"], do: :withdrawn
  defp left_as(_settled), do: :resolved

  # Read when delivered, so a read that fails costs this message alone.
  defp attention(read), do: {:attention, read}

  # Items as their person's attention messages.
  defp waiting({:ok, items}, athanor_id, user_id),
    do:
      {:ok,
       for(
         %{kind: kind} = item <- items,
         do: {athanor_id, user_id, kind, Map.delete(item, :kind)}
       )}

  defp waiting({:error, reason}, _athanor_id, _user_id), do: {:error, reason}

  defp tenant(meta, topic, build, scope \\ :tenant) do
    case meta[:athanor_id] do
      athanor_id when is_binary(athanor_id) and athanor_id != "" ->
        actor = Prima.Actor.in_athanor(athanor_id)
        {scope, actor, topic.(actor), build}

      _none ->
        :dropped
    end
  end

  # ---------------------------------------------------------------------------
  # Delivery
  # ---------------------------------------------------------------------------

  defp deliver(event, :dropped) do
    :telemetry.execute([:cyfr, :bus, :bridge_dropped], %{count: 1}, %{event: event})
  end

  defp deliver(event, {:tenant, actor, topic, build}),
    do: publish(event, fn -> Bus.broadcast(actor, topic, build.(actor)) end)

  defp deliver(event, {:global, actor, topic, build}),
    do: publish(event, fn -> Bus.broadcast_global(topic, build.(actor)) end)

  defp deliver(event, {:global, topic, payload}),
    do: publish(event, fn -> Bus.broadcast_global(topic, payload) end)

  defp deliver(event, {:attention, read}) do
    publish(event, fn ->
      case read.() do
        {:ok, items} -> Enum.reduce_while(items, :ok, &tell/2)
        # No person to tell: an athanor or a recipient this server holds no row for.
        :none -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp deliver(event, {:files, actor, read}) do
    publish(event, fn ->
      with {:ok, items} <- read.(actor),
           do: Enum.reduce_while(items, :ok, &list_file(actor, &1, &2))
    end)
  end

  defp deliver(event, {:offer_wait, read}) do
    publish(event, fn ->
      case read.() do
        {:ok, actor, waits, files} ->
          with :ok <- Enum.reduce_while(waits, :ok, &tell/2),
               do: Enum.reduce_while(files, :ok, &list_file(actor, &1, &2))

        # No person to tell: a recipient this server holds no athanor for.
        :none ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # One item of an athanor's files, on its files topic.
  defp list_file(actor, %{kind: kind} = item, :ok) do
    payload = FileListed.new(actor, kind, Map.delete(item, :kind))

    case Bus.broadcast(actor, Bus.files(actor), payload) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  # One person's attention message, on their own topic in the athanor the
  # item is in.
  defp tell({athanor_id, user_id, kind, fields}, :ok) do
    actor = Prima.Actor.in_athanor(athanor_id)
    payload = Attention.new(actor, kind, fields)

    case Bus.broadcast(actor, Bus.attention(actor, user_id), payload) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  # A publish that fails — refused, or the PubSub raising — is logged and
  # contained here, one message at a time.
  defp publish(event, fun) do
    case fun.() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Cyfr.TelemetryBridge] #{inspect(event)} not published: #{inspect(reason)}"
        )
    end
  catch
    kind, reason ->
      Logger.warning(
        "[Cyfr.TelemetryBridge] #{inspect(event)} not published: " <>
          Prima.LogFilter.format_exception(kind, reason)
      )
  end
end
