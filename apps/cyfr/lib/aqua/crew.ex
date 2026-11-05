# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Crew do
  @moduledoc """
  The crew: the soul hands a job to a crew member, the member works it in
  a child thread of the room, and its answer comes back to the room as a
  reply row. Until crew files exist, the crew members are the athanor's
  roles (every agent of the roster but the soul).

  ## The hand-off

  `ask/2` is `crew.ask {member, task, tools?, options?}`, called by a
  turn of the soul in a room (the gate's lineage names the thread and the
  turn's root): admitted by `Aqua.Runner.Admission.request/4`, it writes
  the request row (`sent_by` the soul, `addressee` the member, `pending`)
  and its `crew_request` outbox record in one transaction and answers the
  request's id. The soul's turn goes on. A person's `@name` in a room is
  the same request, written by the room's runner.

  ## Delivery

  This consumer (`"crew_delivery"`) works an athanor's pending
  `crew_request` and `crew_reply` records under its job claim
  (`Arca.JobClaims`, kind `crew_delivery`, keyed by the athanor id), as
  `Aqua.ScheduleNotes` works its own: it drains on a wake-up
  (`Cyfr.Bus.crew_deliveries/0`), at boot, and on a tick that also
  reaches the work a dead member's claim left once its lease lapsed, so a
  record whose source committed and died before it broadcast is still
  delivered. Each delivery is a send through the thread's runner
  (`Aqua.Runner.send_message/4`) as the person the record names
  (`Sanctum.Tenancy.continuation/3`, from the record's person, athanor
  and origin), and carries the consumer's receipt into the acceptance's
  own transaction, so a record is receipted exactly when its row lands.

    * A request is delivered into the member's child thread under its
      room (`Aqua.Tape.crew_thread/3`, made on the first request), sent by
      whoever sent the request: it opens a turn whose reply address is
      the request, steers the member's turn when the steer rule admits it
      (`Aqua.Runner.steer?/2`), or waits as a turn of its own. The tools
      it narrows the job to and the brain options it sets ride on the
      turn it opens.
    * A reply lands on the request's room, sent by the member and
      addressed to the request's sender, and answers every request the
      record names. To the soul it opens or steers the soul's turn; to
      the person it is room content and wakes nothing. A `needs_you`
      record is a notice of a card in the child turn: it answers nothing.

  A refusal that may pass (`:busy`, `:held_elsewhere`, `:unavailable`,
  and any other but those below) leaves the record pending for the next
  drain, and the records after it for the same thread wait behind it. A
  refusal that cannot (`:archived`, `:not_addressable`, a thread or
  request gone, a person no longer standing) receipts the record
  `refused`; for a request it writes a `failed` reply saying why on the
  room in that same transaction, when the room still takes one.

  `:crew_delivery_enabled` false leaves the consumer unstarted: under the
  test sandbox a tick would work another test's records, so the suite
  turns it off and drains by hand.
  """

  use GenServer

  require Logger

  alias Aqua.Runner
  alias Aqua.Runner.Admission
  alias Aqua.Tape
  alias Arca.JobClaims
  alias Cyfr.Bus.CrewPending
  alias Sanctum.Context

  @consumer "crew_delivery"
  @kinds ["crew_request", "crew_reply"]
  @lease_ms 30_000
  @tick_ms 30_000
  @max_task_bytes 32 * 1024

  @undeliverable [
    :archived,
    :not_addressable,
    :not_found,
    :not_member,
    :denied,
    :no_origin,
    :not_a_room,
    :empty,
    :message_too_long
  ]

  @typedoc "What one drain of an athanor did."
  @type drained ::
          {:ok, %{String.t() => non_neg_integer()}}
          | :busy
          | {:stopped, term()}
          | {:error, term()}

  # ---------------------------------------------------------------------------
  # The hand-off
  # ---------------------------------------------------------------------------

  @doc """
  `crew.ask`: ask `args["member"]` to do `args["task"]` from the turn the
  lineage names (`args["thread_id"]`, `args["root_execution_id"]`), with
  `args["tools"]` (tool names the job is narrowed to) and
  `args["options"]` (the brain's options for the job). Answers the
  request's id; `{:error, :not_addressable}` when the calling turn is not
  the soul's in a room or the member is not of the crew.
  """
  @spec ask(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def ask(%Context{} = ctx, %{"member" => member, "task" => task} = args)
      when is_binary(member) and is_binary(task) do
    task = String.trim(task)

    with :ok <- task(task),
         {:ok, tools} <- tools(args["tools"]),
         {:ok, options} <- options(args["options"]),
         {:ok, turn} <- calling_turn(ctx, args),
         {:ok, thread} <- Tape.thread(ctx, turn.thread_id),
         {:ok, roster} <- Aqua.AgentConfig.roster(ctx),
         :ok <- Admission.request(thread, turn.agent, member, roster),
         {:ok, origin} <- Prima.Origin.from_wire(turn.origin),
         {:ok, %{message: row}} <-
           Tape.accept(ctx, thread.id, %{
             message: %{
               author: Prima.Author.agent(),
               sent_by: turn.agent,
               addressee: member,
               status: "pending",
               content: task,
               payload: %{"from_turn" => turn.id}
             },
             request: %{
               member: member,
               task: task,
               tools: tools,
               options: options,
               person_id: turn.requested_by,
               origin: origin
             }
           }) do
      {:ok,
       %{
         request: row.id,
         member: member,
         status: "pending",
         note: "The reply arrives on this thread as a message of its own; nothing waits for it."
       }}
    end
  end

  def ask(_ctx, _args),
    do: {:error, {:invalid_argument, "crew.ask takes a 'member' and a 'task'"}}

  @doc "`crew.list`: the crew members a turn may ask, with what each is for."
  @spec list(Context.t()) :: {:ok, map()} | {:error, term()}
  def list(%Context{} = ctx) do
    with {:ok, roster} <- Aqua.AgentConfig.roster(ctx) do
      members =
        for %{"name" => name} = agent <- roster, Admission.member?(roster, name) do
          %{name: name, title: agent["title"], description: agent["description"]}
        end

      {:ok, %{members: members, count: length(members)}}
    end
  end

  defp task(""), do: {:error, {:invalid_argument, "crew.ask requires a non-empty 'task'"}}

  defp task(task) when byte_size(task) > @max_task_bytes,
    do: {:error, {:invalid_argument, "crew.ask takes a task of at most 32 KiB"}}

  defp task(_task), do: :ok

  defp tools(nil), do: {:ok, nil}

  defp tools(names) when is_list(names) do
    if names != [] and Enum.all?(names, &(is_binary(&1) and &1 != "")),
      do: {:ok, Enum.uniq(names)},
      else: {:error, {:invalid_argument, "crew.ask takes 'tools' as tool names"}}
  end

  defp tools(_names), do: {:error, {:invalid_argument, "crew.ask takes 'tools' as tool names"}}

  defp options(nil), do: {:ok, %{}}
  defp options(%{} = options), do: {:ok, options}

  defp options(_options),
    do: {:error, {:invalid_argument, "crew.ask takes 'options' as an object"}}

  # The turn the call comes from, by the thread and root the gate's
  # lineage stamped: a call with no open turn behind it asks nobody.
  defp calling_turn(ctx, %{"thread_id" => thread_id, "root_execution_id" => root})
       when is_binary(thread_id) and is_binary(root) do
    case Tape.open_turns(ctx, thread_id) do
      {:ok, turns} ->
        case Enum.find(turns, &(&1.root_execution_id == root)) do
          nil -> {:error, :not_addressable}
          turn -> {:ok, turn}
        end

      {:error, _} = refused ->
        refused
    end
  end

  defp calling_turn(_ctx, _args), do: {:error, :not_addressable}

  # ---------------------------------------------------------------------------
  # The consumer
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    if Application.get_env(:cyfr, :crew_delivery_enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @impl true
  def init(opts) do
    :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.crew_deliveries())
    send(self(), :drain_all)
    {:ok, %{tick_ms: Keyword.get(opts, :tick_ms, @tick_ms)}}
  end

  @impl true
  def handle_info(%CrewPending{athanor_id: athanor_id}, state) do
    _ = drain(athanor_id)
    {:noreply, state}
  end

  def handle_info(:drain_all, state) do
    _ = drain_all()
    Process.send_after(self(), :drain_all, state.tick_ms)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  @doc """
  Drain every athanor holding a crew record this consumer has not
  receipted. Answers each athanor's drain. Never raises.
  """
  @spec drain_all(keyword()) :: %{String.t() => drained()}
  def drain_all(opts \\ []) do
    @kinds
    |> Enum.flat_map(fn kind ->
      case Arca.Outbox.pending_athanors(@consumer, kind) do
        {:ok, athanors} ->
          athanors

        {:error, reason} ->
          Logger.warning("[Aqua.Crew] pending records not read: #{inspect(reason)}")
          []
      end
    end)
    |> Enum.uniq()
    |> Map.new(&{&1, drain(&1, opts)})
  catch
    # A tick has no caller to answer to: a read that raises must not take
    # the consumer down, whose restart would tick again at once.
    kind, reason ->
      Logger.warning(
        "[Aqua.Crew] pending records not read: " <> Prima.LogFilter.format_exception(kind, reason)
      )

      %{}
  end

  @doc """
  Work `athanor_id`'s pending crew records under this consumer's claim on
  it: the requests, then the replies, each kind oldest first. Answers the
  count of each receipt outcome written; `:busy` when another holder has
  the claim; `{:stopped, reason}` when the claim was lost or a record
  could not be worked. A record a passing refusal left pending is
  counted under `"pending"`. The claim is given up when the drain ends.
  Never raises.

  `opts`: `:owner` (the claim's owner, this boot by default) and
  `:lease_ms`.
  """
  @spec drain(String.t(), keyword()) :: drained()
  def drain(athanor_id, opts \\ []) when is_binary(athanor_id) and athanor_id != "" do
    owner = Keyword.get(opts, :owner, Prima.Boot.id())
    lease_ms = Keyword.get(opts, :lease_ms, @lease_ms)
    actor = Prima.Actor.in_athanor(athanor_id)

    # Asked first without the claim, so a wake with nothing to do writes
    # nothing; asked again under it, where the answer counts.
    with {:ok, [_ | _]} <- pending(actor),
         {:ok, claim} <- JobClaims.claim(@consumer, athanor_id, owner, lease_ms) do
      under_claim(actor, claim, lease_ms)
    else
      {:ok, []} -> {:ok, %{}}
      {:busy, _claim} -> :busy
      {:error, _} = refused -> refused
    end
  catch
    kind, reason ->
      Logger.warning(
        "[Aqua.Crew] the crew records of #{athanor_id} were not drained: " <>
          Prima.LogFilter.format_exception(kind, reason)
      )

      {:error, :crashed}
  end

  defp pending(actor) do
    Enum.reduce_while(@kinds, {:ok, []}, fn kind, {:ok, acc} ->
      case Arca.Outbox.pending(actor, @consumer, kind) do
        {:ok, records} -> {:cont, {:ok, acc ++ records}}
        {:error, _} = refused -> {:halt, refused}
      end
    end)
  end

  # The newest claim is given up at the end, whatever the drain did; a
  # drain that raised gives up the claim it took.
  defp under_claim(actor, claim, lease_ms) do
    {answer, last} =
      try do
        worked(actor, claim, lease_ms)
      catch
        kind, reason ->
          _ = JobClaims.release(claim)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    _ = JobClaims.release(last)
    answer
  end

  defp worked(actor, claim, lease_ms) do
    with {:ok, slot} <- Arca.ControlPlane.member_slot(),
         {:ok, records} <- pending(actor) do
      worked(records, claim, slot, lease_ms)
    else
      {:error, :not_owner} -> {{:stopped, :not_owner}, claim}
      {:error, _} = refused -> {refused, claim}
    end
  end

  defp worked(records, claim, slot, lease_ms) do
    records
    |> Enum.reduce_while({%{}, MapSet.new(), claim}, fn record, {counts, waiting, claim} ->
      if MapSet.member?(waiting, lane(record)) do
        {:cont, {count(counts, "pending"), waiting, claim}}
      else
        case work(record, %{claim: claim, slot: slot}) do
          {:ok, outcome} ->
            case JobClaims.renew(claim, lease_ms) do
              {:ok, renewed} -> {:cont, {count(counts, outcome), waiting, renewed}}
              lost -> {:halt, {{:stopped, lost}, waiting, claim}}
            end

          {:wait, reason} ->
            Logger.info("[Aqua.Crew] a #{record.kind} waits: #{inspect(reason)}")
            {:cont, {count(counts, "pending"), MapSet.put(waiting, lane(record)), claim}}

          {:stop, reason} ->
            {:halt, {{:stopped, reason}, waiting, claim}}
        end
      end
    end)
    |> case do
      {%{} = counts, _waiting, last} -> {{:ok, counts}, last}
      {stopped, _waiting, last} -> {stopped, last}
    end
  end

  defp count(counts, outcome), do: Map.update(counts, outcome, 1, &(&1 + 1))

  # The records that must land in order: a room's requests to one member,
  # and the replies to one room.
  defp lane(%Prima.OutboxRecord{kind: "crew_request", snapshot: snapshot}),
    do: {:request, snapshot["room_thread_id"], snapshot["member"]}

  defp lane(%Prima.OutboxRecord{kind: "crew_reply", snapshot: snapshot}),
    do: {:reply, snapshot["asking_thread_id"]}

  # ---- one record ------------------------------------------------------------

  # `{:ok, outcome}` once its receipt is written, `{:wait, reason}` for a
  # refusal that may pass, or `{:stop, reason}`: the claim is lost.
  defp work(%Prima.OutboxRecord{kind: "crew_request", snapshot: snapshot} = record, held) do
    with {:ok, ctx} <- continuation(record),
         {:ok, request} <- request_row(ctx, snapshot["request_id"]) do
      case Tape.crew_thread(ctx, snapshot["room_thread_id"], snapshot["member"]) do
        {:ok, child} ->
          ctx
          |> Runner.send_message(child.id, request.content,
            sent_by: request.sent_by,
            request: request,
            crew: %{tools: snapshot["tools"], options: snapshot["options"]},
            payload: delivered_payload(request),
            receipt: receipt(record, held, "applied")
          )
          |> delivered("applied", fn reason -> failed(ctx, record, request, reason, held) end)

        {:error, reason} ->
          if undeliverable?(reason),
            do: failed(ctx, record, request, reason, held),
            else: {:wait, reason}
      end
    else
      {:error, reason} -> refused(record, reason, held)
    end
  end

  defp work(%Prima.OutboxRecord{kind: "crew_reply", snapshot: snapshot} = record, held) do
    [opening | _] = snapshot["request_ids"]
    outcome = snapshot["outcome"]
    answers = if outcome == "needs_you", do: [], else: snapshot["request_ids"]

    with {:ok, ctx} <- continuation(record),
         {:ok, request} <- request_row(ctx, opening) do
      ctx
      |> Runner.send_message(snapshot["asking_thread_id"], reply_text(snapshot),
        sent_by: snapshot["member"],
        reply: %{request: request, outcome: outcome, answers: answers},
        payload: reply_payload(ctx, record, answers),
        receipt: receipt(record, held, "applied")
      )
      |> delivered("applied", fn reason -> refused(record, reason, held) end)
    else
      {:error, reason} -> refused(record, reason, held)
    end
  end

  # A send's answer: landed with its receipt, a receipt already there, a
  # lost claim, a refusal that may pass, or one that cannot.
  defp delivered({:ok, _accepted}, outcome, _cannot), do: {:ok, outcome}
  defp delivered({:error, :receipted}, outcome, _cannot), do: {:ok, outcome}

  defp delivered({:error, lost}, _outcome, _cannot) when lost in [:taken, :lapsed],
    do: {:stop, lost}

  defp delivered({:error, reason}, _outcome, cannot) do
    if undeliverable?(reason), do: cannot.(reason), else: {:wait, reason}
  end

  # A request that cannot be delivered answers itself on its room: a
  # `failed` reply from the member saying why, with the `refused` receipt
  # in its transaction; a room that takes none any more leaves the
  # receipt alone.
  defp failed(ctx, %Prima.OutboxRecord{snapshot: snapshot} = record, request, reason, held) do
    member = snapshot["member"]

    ctx
    |> Runner.send_message(
      snapshot["room_thread_id"],
      "#{member} could not be reached: #{Aqua.Ops.render_refusal(reason)}",
      sent_by: member,
      reply: %{request: request, outcome: "failed", answers: [request.id]},
      payload: %{"answers" => [request.id]},
      receipt: receipt(record, held, "refused")
    )
    |> delivered("refused", fn cannot -> refused(record, cannot, held) end)
  end

  # The receipt alone, under the claim and this member's slot.
  defp refused(%Prima.OutboxRecord{} = record, reason, %{claim: claim, slot: slot}) do
    if undeliverable?(reason) do
      Logger.info(
        "[Aqua.Crew] the #{record.kind} of #{record.source_kind} #{record.source_id} is " <>
          "undeliverable: #{inspect(reason)}"
      )

      case Arca.ConsumerReceipts.record(
             Prima.Actor.in_athanor(record.athanor_id),
             claim,
             slot,
             receipt_of(record, "refused")
           ) do
        :ok -> {:ok, "refused"}
        {:error, :receipted} -> {:ok, "refused"}
        lost when lost in [:taken, :lapsed] -> {:stop, lost}
        {:error, reason} -> {:stop, reason}
      end
    else
      {:wait, reason}
    end
  end

  defp undeliverable?(reason) when reason in @undeliverable, do: true
  defp undeliverable?({:limit_reached, _cap, _value}), do: true
  defp undeliverable?(_reason), do: false

  defp continuation(%Prima.OutboxRecord{athanor_id: athanor_id, snapshot: snapshot}),
    do: Sanctum.Tenancy.continuation(snapshot["person_id"], athanor_id, snapshot["origin"])

  # The request row a record names, which must still be a request.
  defp request_row(ctx, request_id) when is_binary(request_id) do
    case Tape.message(ctx, request_id) do
      {:ok, %{addressee: member, sent_by: sent_by} = row}
      when is_binary(member) and is_binary(sent_by) ->
        {:ok, row}

      {:ok, _not_a_request} ->
        {:error, :not_addressable}

      {:error, _} = refused ->
        refused
    end
  end

  defp request_row(_ctx, _request_id), do: {:error, :not_addressable}

  # The delivered row names the request it carries, which the child
  # turn's reply answers, and the soul's turn it came from, whose sources
  # the member's turn reads with it.
  defp delivered_payload(request) do
    from_turn =
      case Tape.payload(request) do
        %{"from_turn" => turn_id} when is_binary(turn_id) -> %{"from_turn" => turn_id}
        _ -> %{}
      end

    Map.merge(from_turn, %{"request_id" => request.id, "from_thread" => request.thread_id})
  end

  defp reply_text(%{"text" => text, "member" => member}) do
    case String.trim(text || "") do
      "" -> "#{member} needs you."
      _ -> text
    end
  end

  # What a reply row names beside its text: the child turn it came from,
  # whose sources a turn reading it joins, and the child thread to open;
  # the requests it answers; whether its text was cut; and for a notice,
  # the card that waits.
  defp reply_payload(ctx, %Prima.OutboxRecord{source_id: turn_id, snapshot: snapshot}, answers) do
    base = %{
      "from_turn" => turn_id,
      "answers" => answers,
      "truncated" => snapshot["truncated"] == true
    }

    case Tape.turn(ctx, turn_id) do
      {:ok, turn} ->
        base
        |> Map.put("from_thread", turn.thread_id)
        |> Map.merge(card(ctx, turn, snapshot["outcome"]))

      {:error, _} ->
        base
    end
  end

  defp card(ctx, turn, "needs_you") do
    case Tape.pending_approvals(ctx, turn) do
      {:ok, [approval | _]} ->
        %{"approval_id" => approval.id, "card_message_id" => approval.message_id}

      _ ->
        %{}
    end
  end

  defp card(_ctx, _turn, _outcome), do: %{}

  defp receipt(record, %{claim: claim, slot: slot}, outcome),
    do: %{receipt: receipt_of(record, outcome), claim: claim, slot: slot}

  defp receipt_of(record, outcome) do
    record
    |> Prima.OutboxRecord.source()
    |> Map.merge(%{consumer: @consumer, outcome: outcome})
  end
end
