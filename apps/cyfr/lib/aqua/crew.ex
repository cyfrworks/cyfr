# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Crew do
  @moduledoc """
  The crew: the soul hands a job to a crew member, the member works it in
  a child thread of the room, and its answer comes back to the room as a
  reply row. A crew member is a file under `aqua/crew/` (every agent of
  the roster but the soul): who does a job, on a brain of its own, with
  what it is good at and what to avoid; how a job is done is a skill any
  of them reads. Every member is offered the soul's tools on every job,
  and runs under the crew's one grant, Aqua's (`Compendium.AgentSource`):
  a member differs from another in its brain, model and options, a
  program's access among them, never in what CYFR lets a call do.

  ## The index

  `index/2` is the crew the soul is told of, in its prompt and by
  `crew.list`: each member whose brain is ready (`Aqua.Models.model_status/2`),
  by name, brain, what it is good at and what to avoid. A member whose
  brain is not installed or has no key bound, or whose brain is a
  program with no row of its name that stands as a brain's, is left
  out, and every way a job reaches a member holds it to the same
  readiness (`ready/2`): `crew.ask` and a person's `@name` are
  refused `{:crew_unready, member, reason}` before anything is written,
  and a request whose member became unready while it waited is answered
  `failed` with that reason when its delivery comes (an outage of the
  reads waits for the next drain instead).

  ## The hand-off

  `ask/2` is `crew.ask {member, task, title?, options?}`, called
  by a turn of the soul in a room (the gate's lineage names the thread and
  the turn's root): admitted by `Aqua.Runner.Admission.request/4`, it
  writes the request row (`sent_by` the soul, `addressee` the member,
  `pending`) and its `crew_request` outbox record in one transaction and
  answers the request's id. The job's `title`, when one is given, is kept
  in the request row's payload, where the job's activity reads it
  (`Aqua.Crew.Activity`). The soul's turn goes on. A person's `@name` in
  a room is the same request, written by the room's runner.

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
      (`Aqua.Runner.steer?/2`), or waits as a turn of its own. The brain
      options it sets ride on the turn it opens. Delivered, the request
      is announced on its room again (`Cyfr.Bus.ThreadEvent` `:request`):
      a view of the room that read its crew threads when the request
      landed, before the member's thread was made, reads them again.
    * A reply lands on the request's room, sent by the member and
      addressed to the request's sender, and answers every request the
      record names. To the soul it opens or steers the soul's turn; to
      the person it is room content and wakes nothing.

  The same consumer delivers what a workspace thread sends
  (`Aqua.Providers.Workspace`):

    * An opening (`workspace_open`) starts the workspace thread's turn
      on the opening row its transaction wrote, as the person who asked.
    * A report (`workspace_report`) lands on the daily thread current
      when it is delivered (`Aqua.Day`), sent by the soul, with the files
      it carries copied from the workspace thread's posts into its own
      row first, under an id its record decides. Where a try copies is
      recorded before its first byte (`Arca.ConsumerReceipts.place/4`),
      so a delivery tried again first discards what an earlier try
      stored there, whatever day or thread that was, and the receipt
      clears it. It opens or waits as a turn of the soul on the daily
      thread, which tells the person.

  A record whose workspace thread is gone is receipted `refused` and
  delivers nothing; a delivery in flight when it goes lands nothing
  (`Arca.TurnStorage.accept_message/3`).

  A refusal that may pass (`:busy`, `:held_elsewhere`, `:unavailable`,
  and any other but those below) leaves the record pending for the next
  drain, and the records after it for the same thread wait behind it. A
  refusal that cannot (`:archived`, `:thread_retired`,
  `:not_addressable`, a thread or request gone, a person no longer
  standing) receipts the record
  `refused`; for a request it writes a `failed` reply saying why on the
  room in that same transaction, when the room still takes one.

  `:crew_delivery_enabled` false leaves the consumer unstarted: under the
  test sandbox a tick would work another test's records, so the suite
  turns it off and drains by hand.
  """

  use GenServer

  require Logger
  require Prima.TestSeam

  alias Aqua.Runner
  alias Aqua.Runner.Admission
  alias Aqua.Tape
  alias Arca.JobClaims
  alias Cyfr.Bus.CrewPending
  alias Sanctum.Context

  @consumer "crew_delivery"
  @kinds ["crew_request", "crew_reply", "workspace_open", "workspace_report"]
  @lease_ms 30_000
  @tick_ms 30_000
  @max_task_bytes 32 * 1024
  @title_max 64

  # C0 and C1 controls and the Unicode line and paragraph separators: a
  # title is one line of plain text.
  @title_control ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}\x{2028}\x{2029}]/u

  @undeliverable [
    :archived,
    :thread_retired,
    :not_addressable,
    :not_found,
    :not_member,
    :denied,
    :no_origin,
    :not_a_room,
    :empty,
    :message_too_long,
    :workspace_gone,
    :not_a_workspace,
    :not_a_post,
    :attachment_missing,
    :turn_exists,
    :request_ended,
    :opening_ended
  ]
  # The refusals of an opening that leave nobody to tell (the thread is
  # gone, or the person no longer stands there) or that are no refusal of
  # the work (it started already, or the person stopped it first).
  @untold [
    :workspace_gone,
    :not_found,
    :thread_not_found,
    :not_member,
    :denied,
    :archived,
    :no_origin,
    :turn_exists,
    :opening_ended
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
  `args["title"]` (what a desktop shows for the job: trimmed, 1 to
  `title_max/0` code points of plain text on one line, and none when
  absent or blank), `args["scrolls"]` (the scrolls the member is to
  follow, read now and kept in the request, `scrolls/3`) and
  `args["options"]` (the brain's options for the job, merged over the
  member's own). A member's access is its own, set
  by the person on its card: options that name it are refused before
  anything is written. Answers the
  request's id; `{:error, :not_addressable}` when the calling turn is not
  the soul's in a room or the member is not of the crew.
  """
  @spec ask(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def ask(%Context{} = ctx, %{"member" => member, "task" => task} = args)
      when is_binary(member) and is_binary(task) do
    task = String.trim(task)

    with :ok <- task(task),
         {:ok, title} <- parse_title(args["title"], "crew.ask"),
         {:ok, scrolls} <- scrolls(ctx, args["scrolls"], "crew.ask"),
         {:ok, options} <- options(args["options"]),
         {:ok, turn} <- Tape.calling_turn(ctx, args),
         {:ok, thread} <- Tape.thread(ctx, turn.thread_id),
         {:ok, roster} <- Aqua.AgentConfig.roster(ctx),
         :ok <- Admission.request(thread, turn.agent, member, roster),
         :ok <- asker_ready(ctx, turn, roster, member),
         {:ok, origin} <- Prima.Origin.from_wire(turn.origin),
         {:ok, %{message: row}} <-
           Tape.accept(ctx, thread.id, %{
             message: %{
               author: Prima.Author.agent(),
               sent_by: turn.agent,
               addressee: member,
               status: "pending",
               content: task,
               payload: %{"from_turn" => turn.id} |> titled(title) |> with_scrolls(scrolls)
             },
             request: %{
               member: member,
               task: task,
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

  @doc "The most code points a job's title holds, as the stream's shape counts them."
  @spec title_max() :: pos_integer()
  def title_max, do: @title_max

  @doc """
  `crew.list`: the crew index (`index/2`), the members the calling turn
  may hand a job to. A chain's call reads readiness as the person behind
  its turn, as `crew.ask` does and the soul's prompt index reads it; a call
  with no open turn behind it lists nobody (`:not_addressable`), and
  readiness that cannot be read is refused, never an empty list.
  """
  @spec list(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def list(%Context{} = ctx, args) do
    with {:ok, turn} <- Tape.calling_turn(ctx, args),
         {:ok, roster} <- Aqua.AgentConfig.roster(ctx),
         {:ok, person} <- asker(ctx, turn),
         {:ok, index} <- index(person, roster) do
      members =
        for member <- index do
          %{
            name: member["name"],
            brain: member["brain"],
            good_at: member["description"],
            avoid: member["avoid"]
          }
        end

      {:ok, %{members: members, count: length(members)}}
    end
  end

  @doc """
  The crew index of `roster`: every crew member whose brain reads ready
  (`Aqua.Models.model_status/2`), by name, as `%{"name", "brain",
  "description", "avoid"}` — the brain its catalyst's or its program
  row's name, the model and the effort it runs at, what it is good at and
  what to avoid — in
  the roster's order. `ctx` reads the athanor's catalysts on its own
  plane; a listing it cannot read is `{:error, {:unavailable, _}}`, never
  an index with nobody in it.
  """
  @spec index(Context.t(), [map()]) :: {:ok, [map()]} | {:error, {:unavailable, String.t()}}
  def index(%Context{} = ctx, roster) when is_list(roster) do
    members = crew(roster)

    with {:ok, status} <- brain_status(ctx, members) do
      {:ok,
       for %{"name" => name} = member <- members, ready_brain?(status[name]) do
         %{
           "name" => name,
           "brain" => brain(member, status[name]),
           "description" => member["description"] || "",
           "avoid" => member["avoid"] || ""
         }
       end}
    end
  end

  @typedoc "How the athanor's brains stand (`brains/1`)."
  @type brains :: %{
          model_connected: boolean(),
          crew_ready: non_neg_integer(),
          crew_total: non_neg_integer()
        }

  @doc """
  How the athanor's brains stand: whether the soul's brain reads ready,
  the rule the chat's empty state applies, and how many of the roster's
  crew members read ready of all of them, by the readiness `index/2` and
  `ready/2` apply. A roster or a catalyst listing that cannot be read is
  `{:error, {:unavailable, _}}`, never a count of nobody.
  """
  @spec brains(Context.t()) :: {:ok, brains()} | {:error, {:unavailable, String.t()}}
  def brains(%Context{} = ctx) do
    with {:ok, roster} <- Aqua.AgentConfig.roster(ctx),
         soul = Enum.filter(roster, &Prima.AgentRef.soul?(&1["name"])),
         members = crew(roster),
         {:ok, status} <- brain_status(ctx, soul ++ members) do
      {:ok,
       %{
         model_connected: Enum.any?(soul, &ready_brain?(status[&1["name"]])),
         crew_ready: Enum.count(members, &ready_brain?(status[&1["name"]])),
         crew_total: length(members)
       }}
    end
  end

  defp crew(roster), do: Enum.filter(roster, &Admission.member?(roster, &1["name"]))

  # Each agent's brain (`Aqua.Models.model_status/2`), once the athanor's
  # catalysts read: a listing that cannot be read tells nobody's.
  defp brain_status(ctx, agents) do
    case Aqua.AgentConfig.catalyst_listing(ctx) do
      {:ok, _listing} -> {:ok, Aqua.Models.model_status(ctx, agents)}
      {:error, _unread} -> {:error, {:unavailable, "The crew's readiness"}}
    end
  end

  # The one readiness rule: a brain is ready when its status reads
  # `{:ready, _}`, and anything else, no status at all included, is not.
  defp ready_brain?(status), do: match?({:ready, _}, status)

  @typedoc """
  Why a crew member cannot take a job, all of it its brain's, since a
  member holds no consent of its own: no brain named, its catalyst not
  installed, no key bound, only the person's grant of the brain to give,
  no model chosen on a key,
  the brain's own grant damaged, for a brain that is a program its row
  gone, disabled or not a program a brain runs in, or the reads that
  would tell unavailable.
  """
  @type unready ::
          :no_brain
          | :not_installed
          | :no_key
          | :no_grant
          | :no_model
          | :consent_damaged
          | :program_missing
          | :program_disabled
          | :program_unfit
          | :unavailable

  @doc """
  Whether crew member `member` can take a job now: `:ok` when its brain
  reads ready (`Aqua.Models.model_status/2`), else `{:error,
  {:crew_unready, member, t:unready/0}}`, the refusal the person reads
  (`Prima.Refusal`); `:not_addressable` for a name that is no crew
  member. The one readiness rule a hand-off, a mention and a delivery all
  apply, and the index's.
  """
  @spec ready(Context.t(), String.t()) :: :ok | {:error, term()}
  def ready(%Context{} = ctx, member) when is_binary(member) do
    with {:ok, roster} <- Aqua.AgentConfig.roster(ctx), do: ready(ctx, roster, member)
  end

  defp asker_ready(ctx, turn, roster, member) do
    with {:ok, person} <- asker(ctx, turn), do: ready(person, roster, member)
  end

  # A chain's call runs on the guest plane, where the component reads
  # readiness needs are not served: a member's readiness is read as the
  # person behind the calling turn, on their own plane, as the soul's
  # prompt index reads it (`Aqua.Loop.Turn`), and only decides whom an
  # ask reaches and whom a list names; nothing is written under that
  # context.
  defp asker(ctx, turn),
    do: Sanctum.Tenancy.continuation(turn.requested_by, Context.athanor!(ctx), turn.origin)

  defp ready(ctx, roster, member) do
    if Admission.member?(roster, member) do
      entry = Enum.find(roster, &(&1["name"] == member))
      status = Aqua.Models.model_status(ctx, [entry])[member]

      if ready_brain?(status),
        do: :ok,
        else: {:error, {:crew_unready, member, unready(status)}}
    else
      {:error, :not_addressable}
    end
  end

  @doc """
  Why a brain whose status (`Aqua.Models.model_status/2`) reads as it does
  takes no job, as the refusal names it (`t:unready/0`), or `:ready`.
  """
  @spec unready(Aqua.Models.status() | nil) :: unready() | :ready
  def unready({:ready, _}), do: :ready
  def unready(nil), do: :no_brain
  def unready({:missing, _}), do: :not_installed
  def unready({:needs_key, _}), do: :no_key
  def unready({:needs_grant, _}), do: :no_grant
  def unready({:needs_model, _}), do: :no_model
  def unready({:consent_damaged, _}), do: :consent_damaged
  def unready({:program_missing, _}), do: :program_missing
  def unready({:program_disabled, _}), do: :program_disabled
  def unready({:program_unfit, _}), do: :program_unfit
  def unready({_unread, _}), do: :unavailable

  # A brain as a reader names it: its program's name, which its ready
  # status carries, or its catalyst's name, then the model and the effort
  # the member runs it at, for a member is the three together.
  defp brain(%{"program" => program} = member, {:ready, name})
       when is_binary(program) and program != "",
       do: with_model(name, member)

  defp brain(%{"catalyst_ref" => ref} = member, _status) do
    catalyst =
      case Prima.ComponentRef.parse(ref || "") do
        {:ok, %{name: name}} -> name
        _ -> ref
      end

    with_model(catalyst, member)
  end

  defp with_model(brain, member) do
    effort =
      case member["options"] do
        %{"effort" => effort} when is_binary(effort) and effort != "" -> "effort " <> effort
        _none -> nil
      end

    case Enum.reject([member["model"], effort], &(&1 in [nil, ""])) do
      [] -> brain
      said -> "#{brain} (#{Enum.join(said, ", ")})"
    end
  end

  defp task(""), do: {:error, {:invalid_argument, "crew.ask requires a non-empty 'task'"}}

  defp task(task) when byte_size(task) > @max_task_bytes,
    do: {:error, {:invalid_argument, "crew.ask takes a task of at most 32 KiB"}}

  defp task(_task), do: :ok

  @doc """
  A job's or a workspace thread's title as `operation` takes it: trimmed,
  1 to `title_max/0` code points of plain text on one line, and nil when
  absent or blank. The one rule both a hand-off and an opening hold a
  title to.
  """
  @spec parse_title(term(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def parse_title(nil, _operation), do: {:ok, nil}

  def parse_title(title, operation) when is_binary(title) do
    trimmed = if String.valid?(title), do: String.trim(title)

    cond do
      trimmed == "" ->
        {:ok, nil}

      is_nil(trimmed) or Regex.match?(@title_control, trimmed) ->
        {:error, {:invalid_argument, "#{operation} takes a 'title' of plain text on one line"}}

      length(String.codepoints(trimmed)) > @title_max ->
        {:error,
         {:invalid_argument, "#{operation} takes a 'title' of at most #{@title_max} characters"}}

      true ->
        {:ok, trimmed}
    end
  end

  def parse_title(_title, operation),
    do: {:error, {:invalid_argument, "#{operation} takes 'title' as text"}}

  defp titled(payload, nil), do: payload
  defp titled(payload, title), do: Map.put(payload, "title", title)

  @doc """
  The scrolls a job hands over, as the row that hands it keeps them: each
  of `names` read by name under the caller's actor (`Compendium.skill/2`),
  its body as written and its other files' names, in the order named. A
  name is given once, every scroll is one each harness carries
  (`Compendium.AquaSkills`), and their bodies together are within one
  scroll's bound, so a job's post fits one line of the brain wire. A name
  this athanor has no scroll of, another athanor's included, refuses the
  whole call in a sentence naming it, before anything is written. None
  named is none.
  """
  @spec scrolls(Context.t(), term(), String.t()) ::
          {:ok, [%{String.t() => String.t() | [String.t()]}]} | {:error, term()}
  def scrolls(_ctx, nil, _operation), do: {:ok, []}

  def scrolls(%Context{} = ctx, names, operation) when is_list(names) do
    cond do
      not Enum.all?(names, &is_binary/1) ->
        {:error, {:invalid_argument, "#{operation} takes 'scrolls' as the names of scrolls"}}

      Enum.uniq(names) != names ->
        {:error, {:invalid_argument, "#{operation} names each scroll once"}}

      true ->
        with {:ok, scrolls} <- read_scrolls(ctx, names, operation),
             :ok <- within_bound(scrolls, operation),
             do: {:ok, scrolls}
    end
  end

  def scrolls(_ctx, _names, operation),
    do: {:error, {:invalid_argument, "#{operation} takes 'scrolls' as a list of names"}}

  defp read_scrolls(ctx, names, operation) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, kept} ->
      case Compendium.skill(ctx, name) do
        {:ok, %{carried: true} = scroll} ->
          {:cont,
           {:ok,
            [%{"name" => scroll.name, "body" => scroll.body, "files" => scroll.files} | kept]}}

        {:ok, _past_bound} ->
          {:halt,
           {:error,
            {:invalid_argument, "#{operation}: the scroll '#{name}' is too large for Aqua to use"}}}

        {:error, :not_found} ->
          {:halt,
           {:error,
            {:invalid_argument, "#{operation}: this athanor has no scroll named #{inspect(name)}"}}}

        {:error, _unread} ->
          {:halt, {:error, {:unavailable, "Scrolls"}}}
      end
    end)
    |> then(fn
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      refused -> refused
    end)
  end

  defp within_bound(scrolls, operation) do
    bytes = scrolls |> Enum.map(&byte_size(&1["body"])) |> Enum.sum()

    %{bytes: most} = Compendium.skill_bound()

    if bytes <= most,
      do: :ok,
      else:
        {:error,
         {:invalid_argument,
          "#{operation}: the scrolls named hold #{bytes} bytes together, more than the " <>
            "#{most} one job carries"}}
  end

  defp with_scrolls(payload, []), do: payload
  defp with_scrolls(payload, scrolls), do: Map.put(payload, "scrolls", scrolls)

  # A brain option is a named value of one of the kinds a brain declares
  # (`Prima.Model`); which names and values the member's brain takes is
  # checked when the job's turn opens (`Aqua.Loop.Turn`).
  defp options(nil), do: {:ok, %{}}

  defp options(%{"access" => _access}),
    do:
      {:error,
       {:invalid_argument,
        "crew.ask's options cannot name access: a crew member's access is set by the " <>
          "person, on the member's card on the Aqua page"}}

  defp options(%{} = options) do
    if Enum.all?(options, fn {name, value} ->
         is_binary(name) and name != "" and
           (is_binary(value) or is_integer(value) or is_boolean(value))
       end),
       do: {:ok, options},
       else:
         {:error,
          {:invalid_argument, "crew.ask takes 'options' as named strings, integers or booleans"}}
  end

  defp options(_options),
    do: {:error, {:invalid_argument, "crew.ask takes 'options' as an object"}}

  # ---------------------------------------------------------------------------
  # The consumer
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    if Prima.TestSeam.value(true, fn ->
         Application.get_env(:cyfr, :crew_delivery_enabled, true)
       end) do
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
  @spec drain_all() :: %{String.t() => drained()}
  def drain_all do
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
    |> Map.new(&{&1, drain(&1)})
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
  Never raises. The claim is this boot's.
  """
  @spec drain(String.t()) :: drained()
  def drain(athanor_id) when is_binary(athanor_id) and athanor_id != "" do
    owner = Prima.Boot.id()
    lease_ms = @lease_ms
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

  # A workspace thread's openings in order, and every report to the daily
  # thread in order.
  defp lane(%Prima.OutboxRecord{kind: "workspace_open", snapshot: snapshot}),
    do: {:opening, snapshot["workspace_id"]}

  defp lane(%Prima.OutboxRecord{kind: "workspace_report"}), do: :report

  # ---- one record ------------------------------------------------------------

  # `{:ok, outcome}` once its receipt is written, `{:wait, reason}` for a
  # refusal that may pass, or `{:stop, reason}`: the claim is lost.
  defp work(%Prima.OutboxRecord{kind: "crew_request", snapshot: snapshot} = record, held) do
    with {:ok, ctx} <- continuation(record),
         {:ok, request} <- request_row(ctx, snapshot["request_id"]),
         :ok <- still_waiting(request) do
      # The member is held to readiness again: one that became unready
      # while the request waited answers it failed, before any child
      # thread or turn is made for it.
      with :ok <- ready(ctx, snapshot["member"]),
           {:ok, child} <- Tape.crew_thread(ctx, snapshot["room_thread_id"], snapshot["member"]) do
        deliver_request(ctx, record, request, child, held)
      else
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
    [opening | _] = answers = snapshot["request_ids"]

    with {:ok, ctx} <- continuation(record),
         {:ok, request} <- request_row(ctx, opening) do
      ctx
      |> Runner.send_message(snapshot["asking_thread_id"], reply_text(snapshot),
        sent_by: snapshot["member"],
        reply: %{request: request, outcome: snapshot["outcome"], answers: answers},
        payload: reply_payload(ctx, record, answers),
        receipt: receipt(record, held, "applied")
      )
      |> delivered("applied", fn reason -> refused(record, reason, held) end)
    else
      {:error, reason} -> refused(record, reason, held)
    end
  end

  defp work(%Prima.OutboxRecord{kind: "workspace_open", snapshot: snapshot} = record, held) do
    with {:ok, ctx} <- continuation(record),
         {:ok, opening} <- opening_row(ctx, snapshot) do
      ctx
      |> Runner.send_message(opening.thread_id, opening.content,
        opening: opening,
        receipt: receipt(record, held, "applied")
      )
      |> delivered("applied", fn reason -> opening_refused(ctx, record, reason, held) end)
    else
      {:error, reason} -> refused(record, reason, held)
    end
  end

  defp work(%Prima.OutboxRecord{kind: "workspace_report"} = record, held) do
    with {:ok, ctx} <- continuation(record),
         {:ok, daily} <- Aqua.Day.current(ctx) do
      report(ctx, daily, record, held)
    else
      {:error, reason} -> refused(record, reason, held)
    end
  end

  # The report's files copied under its row on today's daily thread, an
  # earlier try's discarded first, then the row landed with its receipt;
  # a landing that fails leaves no copy.
  defp report(ctx, daily, %Prima.OutboxRecord{snapshot: snapshot} = record, held) do
    id = report_id(record)

    with :ok <- place_copy(ctx, record, daily.id, id),
         {:ok, files} <-
           Aqua.Attachments.carried(ctx, snapshot["workspace_id"], snapshot["attachments"] || []),
         {:ok, refs} <- Aqua.Attachments.copy(ctx, daily.id, id, files) do
      ctx
      |> Runner.send_message(daily.id, report_text(snapshot),
        id: id,
        sent_by: Prima.AgentRef.soul_name(),
        report: snapshot,
        kind: "report",
        workspace_id: snapshot["workspace_id"],
        attachments: refs,
        payload: report_payload(snapshot),
        receipt: receipt(record, held, "applied")
      )
      |> tap(&unlanded(&1, ctx, daily.id, id))
      |> delivered("applied", fn reason -> refused(record, reason, held) end)
    else
      {:error, reason} ->
        _ = Aqua.Attachments.discard(ctx, daily.id, id)
        refused(record, reason, held)
    end
  end

  # The request delivered into the member's own thread, its files copied
  # under the delivered row first, as a report's are: an earlier try's
  # copies discarded at its recorded place, this try's place recorded
  # before its first byte, and a landing that fails leaves no copy. A copy
  # that cannot be made ends the request with the member's failed reply
  # saying why; one that may pass waits.
  defp deliver_request(ctx, record, request, child, held) do
    id = request_copy_id(record)
    snapshot = record.snapshot
    files = for ref <- Tape.payload(request)["attachments"] || [], do: carried_ref(request, ref)

    with :ok <- place_copy(ctx, record, child.id, id),
         {:ok, files} <- ctx |> Aqua.Attachments.carried(request.thread_id, files) |> kept(),
         {:ok, refs} <- Aqua.Attachments.copy(ctx, child.id, id, files) do
      ctx
      |> Runner.send_message(child.id, request.content,
        id: id,
        sent_by: request.sent_by,
        request: request,
        crew: %{options: snapshot["options"]},
        attachments: refs,
        payload: delivered_payload(request),
        receipt: receipt(record, held, "applied")
      )
      |> tap(&unlanded(&1, ctx, child.id, id))
      |> delivered("applied", fn reason -> failed(ctx, record, request, reason, held) end)
      |> tap(&announce_delivered(&1, ctx, request))
    else
      {:error, reason} ->
        _ = Aqua.Attachments.discard(ctx, child.id, id)

        if uncopyable?(reason),
          do: failed(ctx, record, request, reason, held),
          else: {:wait, reason}
    end
  end

  # The request delivered, told to its room again now that the member's
  # thread stands; a request answered failed instead is told by its reply.
  defp announce_delivered({:ok, "applied"}, ctx, request),
    do: Tape.announce(ctx, request.thread_id, :request, request)

  defp announce_delivered(_answer, _ctx, _request), do: :ok

  # A request's file that is gone, or whose thread went with it, is one
  # the member is not given: the person reads that it is no longer kept.
  defp kept({:error, :not_a_post}), do: {:error, :attachment_missing}
  defp kept(answer), do: answer

  defp carried_ref(request, ref),
    do: %{"message_id" => request.id, "stored_name" => ref["stored_name"]}

  # A copy that no retry makes: the athanor's storage is full, a file of
  # the request is gone, or the request's thread with it.
  defp uncopyable?(reason),
    do:
      reason in [:storage_full, :too_many_attachments, :attachment_too_large] or
        undeliverable?(reason)

  defp unlanded({:ok, _landed}, _ctx, _thread_id, _id), do: :ok
  defp unlanded(_refused, ctx, thread_id, id), do: Aqua.Attachments.discard(ctx, thread_id, id)

  # The opening a record names, which must still be its workspace
  # thread's: a thread gone is a record with nothing to deliver.
  defp opening_row(ctx, %{"opening_id" => id, "workspace_id" => workspace_id})
       when is_binary(id) do
    case Tape.message(ctx, id) do
      {:ok, %{kind: "opening", thread_id: ^workspace_id} = row} -> {:ok, row}
      {:ok, _other} -> {:error, :not_a_workspace}
      {:error, :not_found} -> {:error, :workspace_gone}
      {:error, _} = refused -> refused
    end
  end

  defp opening_row(_ctx, _snapshot), do: {:error, :not_a_workspace}

  # What an earlier try of this report stored goes before this try
  # copies: its place is recorded, and committed, before its first byte
  # (`Arca.ConsumerReceipts.place/4`), so a try that died leaves it
  # known, and its bytes are discarded there whatever became of the
  # thread that place was under. Then this try records its own place,
  # today's thread.
  defp place_copy(ctx, record, thread_id, id) do
    actor = Sanctum.Context.actor(ctx)
    source = Prima.OutboxRecord.source(record)

    with :ok <- discard_earlier(ctx, Arca.ConsumerReceipts.placed(actor, @consumer, source)),
         :ok <- Aqua.Attachments.discard(ctx, thread_id, id) do
      Arca.ConsumerReceipts.place(actor, @consumer, source, %{
        thread_id: thread_id,
        message_id: id
      })
    end
  end

  defp discard_earlier(ctx, {:ok, %{thread_id: thread_id, message_id: id}}),
    do: Aqua.Attachments.discard(ctx, thread_id, id)

  defp discard_earlier(_ctx, :none), do: :ok
  defp discard_earlier(_ctx, {:error, _} = refused), do: refused

  @doc false
  # The report's row id, decided by its record: every try of one delivery
  # stores its copies under the same id, so a later try finds and
  # discards an earlier one's on the same daily thread.
  @spec report_id(Prima.OutboxRecord.t()) :: String.t()
  def report_id(%Prima.OutboxRecord{} = record), do: record_id(record, "msg_rpt_")

  @doc false
  # The delivered request's row id, decided by its record as a report's
  # is: every try copies the request's files under the same id.
  @spec request_copy_id(Prima.OutboxRecord.t()) :: String.t()
  def request_copy_id(%Prima.OutboxRecord{} = record), do: record_id(record, "msg_req_")

  # The row id every try of one delivery writes: the record's digest.
  defp record_id(%Prima.OutboxRecord{} = record, prefix) do
    %{source_kind: kind, source_id: id, source_revision: revision} =
      Prima.OutboxRecord.source(record)

    digest =
      :crypto.hash(:sha256, Enum.join([record.kind, kind, id, revision], "\n"))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 26)

    prefix <> digest
  end

  # What a report says: the summary the soul wrote in the workspace
  # thread; the server's `error` report says Aqua could not run there, and
  # why; a report with no summary says the thread is done or needs the
  # person.
  defp report_text(%{"outcome" => "error", "title" => title} = snapshot) do
    case String.trim(snapshot["summary"] || "") do
      "" -> "Aqua could not run the workspace thread \"#{title}\"."
      why -> "Aqua could not run the workspace thread \"#{title}\": #{why}"
    end
  end

  defp report_text(%{"summary" => summary} = snapshot) when is_binary(summary) do
    case String.trim(summary) do
      "" -> moved(snapshot)
      text -> text
    end
  end

  defp report_text(snapshot), do: moved(snapshot)

  defp moved(%{"outcome" => "needs_you", "title" => title}),
    do: "The workspace thread \"#{title}\" needs you."

  defp moved(%{"title" => title}), do: "The workspace thread \"#{title}\" is done."

  # What a report row names beside its text: the workspace thread and its
  # title, the outcome, the turn it came from, whose read threads a turn
  # reading it joins (`from_turn`), the read threads the record kept, and
  # whether its summary was cut.
  defp report_payload(snapshot) do
    %{
      "workspace" => snapshot["workspace_id"],
      "title" => snapshot["title"],
      "outcome" => snapshot["outcome"],
      "from_turn" => snapshot["turn_id"],
      "read_threads" => snapshot["read_threads"] || [],
      "truncated" => snapshot["truncated"] == true
    }
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
  # receipt alone, as does a request the person's stop of its room ended,
  # which nothing answers.
  defp failed(_ctx, record, _request, :request_ended, held),
    do: refused(record, :request_ended, held)

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

  # An opening whose delivery is refused for good: the daily thread is
  # told why its work could not start, by the server's `error` report
  # with the refused receipt in its transaction (`Aqua.Tape.refuse_opening/4`),
  # unless nobody is left to tell or the work was never refused
  # (`@untold`), when the receipt alone is written.
  defp opening_refused(ctx, %Prima.OutboxRecord{snapshot: snapshot} = record, reason, held) do
    if reason in @untold or not undeliverable?(reason) do
      refused(record, reason, held)
    else
      ctx
      |> Tape.refuse_opening(snapshot["workspace_id"], snapshot["opening_id"], %{
        receipt: receipt(record, held, "refused"),
        summary: "the work could not start (#{Aqua.Ops.render_refusal(reason)})",
        person_id: snapshot["person_id"],
        origin: snapshot["origin"]
      })
      |> case do
        {:ok, _thread} -> {:ok, "refused"}
        {:error, :receipted} -> {:ok, "refused"}
        {:error, lost} when lost in [:taken, :lapsed] -> {:stop, lost}
        {:error, untold} -> refused(record, untold, held)
      end
    end
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

  # An unready member cannot take the job until a person acts; the reads
  # that would tell are an outage that may pass.
  defp undeliverable?({:crew_unready, _member, reason}), do: reason != :unavailable
  defp undeliverable?(_reason), do: false

  defp continuation(%Prima.OutboxRecord{athanor_id: athanor_id, snapshot: snapshot}),
    do: Sanctum.Tenancy.continuation(snapshot["person_id"], athanor_id, snapshot["origin"])

  # A request the person's stop of its room ended is delivered nowhere,
  # before its member's thread is made; the acceptance asks again under
  # its lock (`Arca.TurnStorage.accept_message/3`).
  defp still_waiting(%{status: "pending"}), do: :ok
  defp still_waiting(_request), do: {:error, :request_ended}

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
  # turn's reply answers, and the soul's turn it came from, whose read
  # threads the member's turn reads with it; it carries the scrolls the
  # request kept, which the member reads after the job (`Aqua.Reader`); it
  # references the request's attachments, which stay stored under the
  # request's own row.
  defp delivered_payload(request) do
    payload = Tape.payload(request)

    from_turn =
      case payload do
        %{"from_turn" => turn_id} when is_binary(turn_id) -> %{"from_turn" => turn_id}
        _ -> %{}
      end

    from_turn
    |> Map.merge(%{"request_id" => request.id, "from_thread" => request.thread_id})
    |> with_scrolls(List.wrap(payload["scrolls"]))
  end

  defp reply_text(%{"text" => text, "member" => member}) do
    case String.trim(text || "") do
      "" -> "#{member} needs you."
      _ -> text
    end
  end

  # What a reply row names beside its text: the child turn it came from,
  # whose read threads a turn reading it joins, and the child thread to
  # open; the requests it answers; and whether its text was cut.
  defp reply_payload(ctx, %Prima.OutboxRecord{source_id: turn_id, snapshot: snapshot}, answers) do
    base = %{
      "from_turn" => turn_id,
      "answers" => answers,
      "truncated" => snapshot["truncated"] == true
    }

    case Tape.turn(ctx, turn_id) do
      {:ok, turn} -> Map.put(base, "from_thread", turn.thread_id)
      {:error, _} -> base
    end
  end

  defp receipt(record, %{claim: claim, slot: slot}, outcome),
    do: %{receipt: receipt_of(record, outcome), claim: claim, slot: slot}

  defp receipt_of(record, outcome) do
    record
    |> Prima.OutboxRecord.source()
    |> Map.merge(%{consumer: @consumer, outcome: outcome})
  end
end
