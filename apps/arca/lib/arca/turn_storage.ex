# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TurnStorage do
  @moduledoc """
  The durable turn: `turns`, `turn_steps`, the message rows a turn
  writes and the events it records, each transition one transaction.

  A turn is accepted with its message (`accept_message/3`), started once its
  root execution and pins exist (`start/3`), and every runner-owned write
  names the `fence` the runner holds: the transaction's first write is a
  conditional update of the turn row on that fence, which takes the row's
  lock, so a runner whose fence another process moved (`supersede/3`,
  `takeover/3`, `pause_recovered/3`) is refused `{:error, :superseded}`
  before it reads or writes anything else, and one that names no fence is
  refused `{:error, :fence_required}`. A host transition that takes a turn
  over compares the fence it read and raises it by one in the same write,
  so fences only grow.
  A step is proposed before its effect (`commit_events/3`), flipped to
  `dispatched` in its own commit (`dispatch_step/3`), and closed with its
  result row, outcome and event together (`close_step/4`). Pause and
  resume flip the turn, its root attempt and its root execution in one
  transaction; `finish/4` is the one terminal write.

  Multi-row writes that append a message run under `with_seq_retry/1`:
  the `(thread_id, seq)` race surfaces as a changeset raise inside
  the transaction and the whole transaction is retried, since a retry
  inside an aborted Postgres transaction cannot land.

  ## The turn's read threads

  `turns.read_threads` are the ids of the threads whose posts the turn
  has read (`Arca.ThreadStorage.threads_text/1`), a list that only grows,
  by which a thread's deletion finds the turn. What a turn reads of
  threads' rows is decided and recorded in one transaction before it is
  read (`join_read/3`): which rows it is handed and the threads they
  depend on. A step's threads join in the transaction that writes it,
  after the turn row is taken: those it opens with (`put_step/3`'s
  `:threads` and `:threads_from`) and those its result carries
  (`close_step/4`'s `:threads`).

  ## The thread claim

  Which root turn may run at all is the thread's, not the turn's:
  `threads.active_turn_id` (`Arca.ThreadStorage`). `start/3` takes it in
  the transaction that moves the turn to `running`, naming the consumed
  sequence the caller read; `finish/4` gives it up; `takeover/3` and
  `pause_recovered/3` take it from a turn whose holder is not a live
  member, in the same transaction that counts the recovery — so a member
  that did not take the claim cannot spend one.
  A pause keeps the claim: the turn is still this member's work.

  ## Crew requests and replies

  A request to a crew member is a row of its room accepted with the
  `crew_request` outbox record that delivers it (`accept_message/3`'s
  `:request`), and a turn a delivered request opens stores the reply
  address. Every terminal write of such a turn (`finish/4`) records its
  `crew_reply` in that transaction, so a crash after the commit loses no
  answer. The consumer's receipt is written in the transaction that lands
  the delivery (`accept_message/3`'s `:receipt`), and a reply marks the
  requests it answers in that transaction too (`:answers`).

  ## Workspace threads

  A workspace thread is opened, or asked again, in one transaction
  (`open_workspace/2`): the thread, its opening row, the daily thread's
  pointer and the `workspace_open` record whose delivery opens the turn
  on that opening (`accept_message/3`'s `:opening_id`).

  One rule decides its state (`work_state!/2`), and every write that may
  move it asks the rule in its own transaction: a workspace thread is
  `open` while anything it accepted remains to run in it or in a crew
  thread under it; and once nothing does, how its work last ended since
  it last took new work (`workspace_outcome`): `done` or `needs_you` as
  Aqua reported it,
  `stopped` by the person, `error` when Aqua could not run, or `open`
  when nothing ended it. A turn that reported has no work left to run,
  a request asked of a crew member is left until its answer lands, and
  an opening until its turn starts. The writes that ask it:

    * a turn's report of its work as `done` or `needs_you`
      (`report_workspace/4`), once a turn, which records the
      `workspace_report` and its outcome;
    * a turn there that ends without a report of its own (`finish/4`):
      failed or uncertain, or cancelled because the server could neither
      resume nor start it (`:ended_by` `:recovery`), records an `error` report with
      the error as its summary; cancelled by an act of the person
      (`:ended_by` `:person`: a stop, a deletion of what it read, the
      consent restart, the athanor's archive) records `stopped` and no
      report; any other end records nothing;
    * the person's stop of the thread (`stop_work/3`), which ends all
      that remains to run there and in its crew threads and records
      `stopped`, and an opening whose delivery is refused for good
      (`refuse_opening/4`), which records an `error` report with no turn;
    * a skip of a turn's steps, a turn's end there or in a crew thread
      under it, and a row landing there (a crew member's answer among
      them), reporting nothing;
    * a person's message there, or a further opening, which is new work:
      how its work ended no longer ends it.

  A turn of a page's call (`page_call`) is never the thread's work and
  never speaks for it (`work_state!/2`). A crew member's answer to a
  request the person's stop ended is a row and opens no turn, whatever
  the thread reads when it lands (`accept_message/3`).

  A row that names a workspace thread (a report delivered to a daily
  thread) lands only while that thread stands. Taking more than one
  thread row, it takes them in the one order
  `Arca.ThreadStorage.lock_threads!/2` states, as does a write of a turn
  in a crew thread that may move its room (a workspace thread's state, or
  a room's archive): its turn, then the athanor's row, then the thread
  rows.

  ## The archive

  A daily or a workspace thread is archived only while no work remains in
  it or in a crew thread under it (`work_remains?/2`, the one rule's
  shared reading, `Arca.ThreadStorage.archive/2`), and new work there
  takes it out again, each write clearing it by its own statement in its
  own transaction, which holds the thread's row, archived or not, until
  the work commits, so an archive and new work there wait on each other
  (`Arca.ThreadStorage.unarchive!/2`): an acceptance that
  opens or steers a turn there or in a crew thread under it, a person's
  post or a report that starts work among them, and not a page's call
  (`accept_message/3`); and a further opening (`open_workspace/2`). A
  write in a crew thread takes the athanor's row before the thread rows
  (`work_lock!/2`; an acceptance there takes its room's row and its own
  together, `work_rows!/2`), as a write that may move a workspace
  thread's state does. A retired crew thread is another fact
  (`retired_at`): it admits nothing.

  ## The root's grant

  A write that resumes, recovers or ends a turn's root attempt runs under
  that attempt's grant (`Arca.ExecutionStanding`): `attrs[:grant]` —
  `:stored` for the stamp the root's current attempt carries — and
  `attrs[:verify]`, the identity domain's check over it. The check runs
  inside the transaction once the turn row is taken and read again — and,
  for the transitions that lock the turn's root execution (`lock_root!/2`),
  after that row too — before any step or attempt row is locked; the
  attempt is written only when it carries the grant's stamp. A resume, a completion, a
  recovery, a takeover and a set-down are refused
  `{:error, :missing_grant}` without both inputs, whatever the turn
  holds; a failure, a cancel or an uncertain end retires work and needs
  them only for a turn with a root attempt. A lease a write opens is
  read from the database's clock inside the transaction, never taken
  from the caller.

  ## Legality

  A transition is decided by the rows, not by the caller's map: every
  write takes the turn row first (`Arca.Repo.locking_transaction/2`),
  reads what it moves after that, and checks the move against the
  vocabulary in `Prima.TurnState` and against those rows. A start binds
  only the turn's own running root, its current attempt and its
  reservation; a pause names a reason a runner pauses for and, for a
  launch, a launch step of the turn; a step is recorded proposed or
  dispatched on a running turn; a step is opened again only when it was
  dispatched and its stored recovery is replay-safe; and a write on a
  turn's rows is refused once the turn is over
  (`:not_open`). A move
  the rows do not allow is `{:error, :illegal_transition}` and writes
  nothing.

  A turn is held to the recovery limit it stores, written from the
  policy its caller passes (`:recovery_limit`) when the turn starts, and
  never widened afterwards: a takeover past it is
  `{:error, :recovery_exhausted}`.
  """

  import Ecto.Query
  # Every function takes the `Prima.Actor` first and matches it in the
  # head; an actor whose athanor is nil OR the empty string is
  # `{:error, :no_athanor}` before any query, and `bind_child!/4`, which
  # runs inside admission's transaction, raises instead., only: [from: 2]

  alias Arca.Schemas.{Thread, Message, Turn, TurnStep}

  # The turn vocabulary is `Prima.TurnState`'s; these are its sets, bound
  # at compile time so guards can test membership.
  @open Prima.TurnState.open_statuses()
  @terminal Prima.TurnState.terminal_statuses()
  # What Aqua reports of a workspace thread's work; `error` and `stopped`
  # are the server's (the moduledoc's "Workspace threads").
  @reported ~w(done needs_you)
  # The states in which a workspace thread waits on its person, whose wait
  # its reminders name (`waits_since`).
  @waiting ~w(needs_you error)
  # Who cancelled a turn, as its end names it (`finish/4`'s `:ended_by`).
  @ended_by [:person, :recovery]
  @step_kinds Prima.TurnState.step_kinds()
  @outcomes Prima.TurnState.outcomes()
  # The open turns a takeover moves: an `accepted` turn has no root
  # attempt yet, so nothing of it is held to take over.
  @held @open -- ["accepted"]

  # The most ids one statement binds (`join_read/3`), under both adapters' bound.
  @ids_per_statement 5_000

  # ---------------------------------------------------------------------------
  # Acceptance
  # ---------------------------------------------------------------------------

  @doc """
  Accept a message, atomically with the work it opens. `attrs`:

  - `:message` — the row: `:author`, `:content`, `:payload`, optional
    `:id` (a caller-minted id, so attachments stored under it are found)
    and `:client_id` (the sender's retry identity).
  - `:turn` — `%{agent, requested_by, model, options, origin}` to open an
    `accepted` turn keyed by the message, `origin` the `Prima.Origin` it
    was admitted under, kept on the row so a turn recovered after a
    restart resumes under it; `nil` for room content. A turn naming no
    origin is refused `{:error, :no_origin}` with nothing written.
  - `:steer_turn_id` — attach the message to an open turn of the thread
    instead; a turn that has ended answers `{:error, :turn_over}`. The
    turn's row is locked before the message is written, so a steer and
    the turn's terminal write serialize: the steer lands on a turn that
    will answer it (`finish/4`), or is refused.
  - `:reply_address` — `%{asking_thread_id, request_id}` on a turn a
    delivered crew request opens, or steers when the turn has none yet (a
    turn a direct post opened): the turn then replies to it. A turn's
    `sent_by` is its opening message's.
  - `:request` — the row is a request to a crew member: `%{member, task,
    options, person_id, origin}`, recorded as its `crew_request`
    outbox record in this transaction (`Prima.OutboxRecord.crew_request/1`);
    the row's payload keeps `person_id` and `origin`, which its reply is
    recorded under.
  - `:answers` — the request ids of this thread the row answers: each one
    still `pending` and addressed to the row's `sent_by` becomes
    `answered`, resolved by the row.
  - `:opening_id` — the turn `:turn` names opens on this opening row of
    the workspace thread, which the opening's transaction wrote
    (`open_workspace/2`), in place of a new row; one that has its turn
    already is `{:error, :turn_exists}`.
  - `:receipt` — `%{receipt, claim, slot}`: the delivering consumer's
    receipt, written under its job claim and member slot
    (`Arca.ConsumerReceipts.record!/4`), so a delivery is receipted
    exactly when its row lands; a claim lost answers `{:error, :taken}`
    or `{:error, :lapsed}` and a receipt already written
    `{:error, :receipted}`, with nothing written.
  - `:standing` — `true` for a schedule's fire into the room it names
    (`Aqua.ScheduleTurns`): the thread must not be archived
    (`{:error, :thread_archived}`, with nothing written), and the fire
    never takes it out of the archive as other new work does.
  - `:wait` — `%{waits_since, quiet}`: the row is the server's post of a
    workspace thread's wait on its person (`Aqua.Nudge`), naming it in
    `:workspace_id`. It lands only while that wait stands under the
    workspace thread's lock: not archived (`{:error, :thread_archived}`),
    reading `needs_you` or `error` since exactly `waits_since`
    (`{:error, :wait_moved}`), for at least `quiet` seconds by the
    database's clock (`{:error, :not_quiet}`). The row's payload keeps the
    stamp. Its `client_id` names the wait, and a daily thread is one day's,
    so the row is its own receipt.
  - `:claim` — `%{claim, slot}`: the sending job's claim and this
    member's slot, judged last in the transaction as a receipt's are, so
    a claim or slot lost lands nothing (`{:error, :taken}`, `{:error,
    :lapsed}` or `{:error, :not_owner}`).

  A retired crew thread admits nothing (`{:error, :thread_retired}`). A
  person's message in a workspace thread is new work there: how its work
  ended no longer ends it. A crew member's answer (`:answers`) to a
  request the person's stop ended (`expired`) opens no turn, whatever
  the thread reads now: it lands as a row, and the acceptance answers
  `turn: nil`. A request delivered into
  its member's thread (`:reply_address`) lands only while the request
  still waits for its answer (`{:error, :request_ended}`), and a
  workspace thread's opening only while it waits for its turn
  (`{:error, :opening_ended}`). A row naming a workspace thread
  (`:workspace_id`, a report's or a wait's post) lands only while that
  thread stands
  (`{:error, :workspace_gone}`).

  Answers `{:ok, %{message: row, turn: row | nil}}`. A `client_id` this
  thread already accepted answers `{:error, :duplicate_client_id}`,
  a message `id` already taken `{:error, :message_id_reused}`
  (the caller reads the existing acceptance with `accepted/3`); a
  message that already opened a turn answers `{:error, :turn_exists}`.
  """
  @spec accept_message(Prima.Actor.t(), String.t(), map()) ::
          {:ok, %{message: map(), turn: map() | nil}} | {:error, term()}
  def accept_message(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.accept_message", fn ->
      message = Map.fetch!(attrs, :message)

      with_seq_retry(fn ->
        Arca.Repo.locking_transaction(fn ->
          steer_id = Map.get(attrs, :steer_turn_id)
          opens = Map.get(attrs, :turn)

          # The steered turn first and the thread after it, the order every
          # writer of both takes; the thread is read under its lock, so an
          # archive that committed first is seen.
          steered =
            if is_nil(opens) and steer_id,
              do: steered!(athanor_id, thread_id, steer_id, Map.get(attrs, :reply_address))

          # Work it may start in a crew member's thread takes its room out
          # of the archive, a second thread row (`work_rows!/2`).
          if opens || steered, do: work_rows!(actor, thread_id)
          workspace = from_workspace!(actor, thread_id, message)
          thread = locked_thread!(athanor_id, thread_id)
          if thread.retired_at, do: Arca.Repo.rollback(:thread_retired)

          if Map.get(attrs, :standing) == true and thread.archived_at,
            do: Arca.Repo.rollback(:thread_archived)

          still_waits!(workspace, thread, Map.get(attrs, :wait))
          still_asked!(athanor_id, Map.get(attrs, :reply_address))
          opens = if stopped_answer?(athanor_id, thread, attrs), do: nil, else: opens

          if (opens && Map.get(message, :kind) != "page_call") ||
               (steered && not page_call?(athanor_id, steered)),
             do: new_work!(actor, thread)

          thread = posted!(athanor_id, thread, message)

          row =
            case Map.get(attrs, :opening_id) do
              nil ->
                Arca.ThreadStorage.insert_message!(
                  actor,
                  thread,
                  message
                  |> with_identity(Map.get(attrs, :request))
                  |> with_wait(Map.get(attrs, :wait))
                  |> Map.put(:turn_id, steer_id)
                )

              opening_id ->
                opening!(athanor_id, thread, opening_id)
            end

          turn =
            case opens do
              nil -> steered
              %{} = t -> open_turn!(athanor_id, thread, row, t, Map.get(attrs, :reply_address))
            end

          answered!(athanor_id, thread, row, Map.get(attrs, :answers, []))
          requested!(actor, thread, row, Map.get(attrs, :request))
          receipted!(actor, Map.get(attrs, :receipt))
          if claim = Map.get(attrs, :claim), do: claimed!(claim)

          if thread.kind == "workspace",
            do: settle_work!(athanor_id, thread)

          %{message: %{row | turn_id: turn && turn.id}, turn: turn}
        end)
      end)
      |> case do
        {:error, %Ecto.Changeset{errors: errors} = changeset} ->
          cond do
            unique?(errors, :thread_id, "client_id") -> {:error, :duplicate_client_id}
            unique?(errors, :id, "messages") -> {:error, :message_id_reused}
            unique?(errors, :thread_id, "message_id") -> {:error, :turn_exists}
            true -> {:error, changeset}
          end

        other ->
          other
      end
    end)
    |> Arca.Data.project()
  end

  def accept_message(%Prima.Actor{}, _thread_id, _attrs), do: {:error, :no_athanor}

  # The opening a `workspace_open` delivery starts the turn of: a row of
  # this workspace thread, still with no turn. One that has its turn
  # already answers as a message that opened one does.
  # arca:db-raise-ok inside the caller's transaction
  defp opening!(athanor_id, %Thread{kind: "workspace", id: thread_id}, opening_id) do
    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.thread_id == ^thread_id,
      where: m.id == ^opening_id and m.kind == "opening"
    )
    |> Arca.Repo.one()
    |> case do
      %Message{turn_id: nil, status: nil} = row -> row
      %Message{turn_id: nil} -> Arca.Repo.rollback(:opening_ended)
      %Message{} -> Arca.Repo.rollback(:turn_exists)
      nil -> Arca.Repo.rollback(:not_found)
    end
  end

  defp opening!(_athanor_id, %Thread{}, _opening_id), do: Arca.Repo.rollback(:not_a_workspace)

  # A request delivered into its member's thread lands only while it
  # still waits for its answer: one the person's stop ended is not
  # delivered. Read under a lock the stop's write waits on.
  # arca:db-raise-ok inside the caller's transaction
  defp still_asked!(athanor_id, %{asking_thread_id: room, request_id: id})
       when is_binary(room) and is_binary(id) do
    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.thread_id == ^room and m.id == ^id,
      select: m.status
    )
    |> Arca.QueryHelpers.for_share()
    |> Arca.Repo.one()
    |> case do
      "pending" -> :ok
      _answered_ended_or_gone -> Arca.Repo.rollback(:request_ended)
    end
  end

  defp still_asked!(_athanor_id, _reply_address), do: :ok

  # A crew member's answer to a request the person's stop ended: what it
  # would start the person stopped, so it opens nothing, whatever the
  # thread reads now. The request says so, which new work there since
  # does not change.
  # arca:db-raise-ok inside the caller's transaction
  defp stopped_answer?(athanor_id, %Thread{id: thread_id}, attrs) do
    case Map.get(attrs, :answers, []) do
      [_ | _] = ids ->
        Arca.Repo.exists?(
          from(m in Message,
            where: m.athanor_id == ^athanor_id and m.thread_id == ^thread_id,
            where: m.id in ^ids and m.status == "expired"
          )
        )

      _none ->
        false
    end
  end

  @doc "The acceptance a sender's `client_id` already produced: its message and turn."
  @spec accepted(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, %{message: map(), turn: map() | nil}} | {:error, term()}
  def accepted(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id, client_id)
      when is_binary(athanor_id) and athanor_id != "" do
    with {:ok, message} <-
           Arca.ThreadStorage.get_by_client_id(actor, thread_id, client_id) do
      Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.accepted", fn ->
        turn =
          Arca.Repo.one(
            from(t in Turn,
              where: t.athanor_id == ^athanor_id and t.message_id == ^message.id
            )
          ) ||
            (message.turn_id &&
               Arca.Repo.one(
                 from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^message.turn_id)
               ))

        {:ok, %{message: message, turn: turn}}
      end)
    end
    |> Arca.Data.project()
  end

  def accepted(%Prima.Actor{}, _thread_id, _client_id), do: {:error, :no_athanor}

  # arca:db-raise-ok inside the caller's transaction
  defp open_turn!(athanor_id, %Thread{} = thread, %Message{} = row, attrs, reply_address) do
    now = DateTime.utc_now()
    address = reply_address || %{}

    turn =
      Arca.Repo.insert!(
        %Turn{}
        |> Ecto.Changeset.change(%{
          id: Prima.UUID7.generate_id("trn"),
          athanor_id: athanor_id,
          thread_id: thread.id,
          message_id: row.id,
          agent: Map.get(attrs, :agent),
          requested_by: Map.get(attrs, :requested_by),
          sent_by: row.sent_by,
          asking_thread_id: Map.get(address, :asking_thread_id),
          request_id: Map.get(address, :request_id),
          model: Map.get(attrs, :model),
          options: encode(Map.get(attrs, :options)),
          origin: origin!(Map.get(attrs, :origin)),
          fence: 1,
          runner_id: Prima.Boot.id(),
          status: "accepted",
          accepted_at: now
        })
        |> Ecto.Changeset.unique_constraint([:thread_id, :message_id])
      )

    # The initiating message belongs to its turn: attached, it is read by
    # this turn alone and by no other turn's projection.
    {1, _} =
      from(m in Message, where: m.athanor_id == ^athanor_id and m.id == ^row.id)
      |> Arca.Repo.update_all(set: [turn_id: turn.id])

    thread
    |> Thread.changeset(%{
      turn_seq: (thread.turn_seq || 0) + 1,
      agent: Map.get(attrs, :agent)
    })
    |> Arca.Repo.update!()

    turn
  end

  # The requests a reply answers: each still pending in this thread and
  # addressed to the reply's sender. A request already answered stays as
  # its first reply left it.
  # arca:db-raise-ok inside the caller's transaction
  defp answered!(_athanor_id, _thread, _row, []), do: :ok

  defp answered!(athanor_id, %Thread{id: thread_id}, %Message{} = row, ids) when is_list(ids) do
    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.thread_id == ^thread_id and m.id in ^ids,
      where: m.addressee == ^row.sent_by and m.status == "pending"
    )
    |> Arca.Repo.update_all(
      set: [status: "answered", resolved_by: row.id, resolved_at: row.inserted_at]
    )

    :ok
  end

  # A request row names whose request it is and how it started, in its
  # payload: the identity its reply is recorded under, whatever the turn
  # that answers it holds.
  # arca:db-raise-ok inside the caller's transaction
  defp with_identity(message, nil), do: message

  defp with_identity(message, %{} = request) do
    unless Prima.Origin.origin?(Map.get(request, :origin)), do: Arca.Repo.rollback(:no_origin)

    identity = %{
      "person_id" => Map.fetch!(request, :person_id),
      "origin" => Prima.Origin.to_wire(request.origin)
    }

    Map.update(message, :payload, identity, &Map.merge(&1 || %{}, identity))
  end

  # A request row's delivery, recorded with it.
  # arca:db-raise-ok inside the caller's transaction
  defp requested!(_actor, _thread, _row, nil), do: :ok

  defp requested!(actor, %Thread{} = thread, %Message{} = row, %{} = request) do
    record =
      Prima.OutboxRecord.crew_request(%{
        athanor_id: actor.athanor_id,
        request_id: row.id,
        inserted_at: row.inserted_at,
        room_thread_id: thread.id,
        member: Map.fetch!(request, :member),
        task: Map.fetch!(request, :task),
        options: Map.get(request, :options) || %{},
        person_id: Map.fetch!(request, :person_id),
        origin: Map.fetch!(request, :origin)
      })

    :ok = Arca.Outbox.put!(actor, record)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp receipted!(_actor, nil), do: :ok

  defp receipted!(actor, %{receipt: receipt, claim: claim, slot: slot}),
    do: Arca.ConsumerReceipts.record!(actor, claim, slot, receipt)

  # The origin a turn is accepted under (`Prima.Origin`, an atom or its
  # wire spelling), stored as the spelling. A turn with none, or with
  # anything outside the enum, rolls the acceptance back: no default
  # stands in for the admission path that accepted it.
  # arca:db-raise-ok inside the caller's transaction
  defp origin!(nil), do: Arca.Repo.rollback(:no_origin)

  defp origin!(origin) when is_atom(origin) do
    if Prima.Origin.origin?(origin),
      do: Prima.Origin.to_wire(origin),
      else: Arca.Repo.rollback({:invalid, %{origin: ["is not an origin"]}})
  end

  defp origin!(origin) do
    if origin in Prima.Origin.spellings(),
      do: origin,
      else: Arca.Repo.rollback({:invalid, %{origin: ["is not an origin"]}})
  end

  # ---------------------------------------------------------------------------
  # Workspace threads
  # ---------------------------------------------------------------------------

  @doc """
  Open a workspace thread, or open one again, in one transaction (the
  moduledoc's "Workspace threads"). `attrs`:

  - `:daily_id` — the daily thread whose post asked, where the pointer
    goes.
  - `:workspace_id` — an existing workspace thread to send the ask to,
    which is new work there whatever its state; absent for a new
    one, made with `:id` (minted by the caller, which may have files to
    store under it), `:title` and `:opened_from` (the asking post).
  - `:turn` — `%{id, fence}` of the daily thread's turn that opens it, a
    turn of `:daily_id` that must still be open and hold that fence
    (`{:error, :superseded}`, `{:error, :not_open}`); absent when the
    person opens it.
  - `:opening` — the opening row: `:id`, `:author`, `:content` (the
    ask) and `:payload` (its envelope). It is sent by the person.
  - `:pointer` — the pointer row on the daily thread: `:author`,
    `:sent_by`, `:content`, `:payload`.
  - `:files` — called with the workspace thread's and the opening's ids
    once the locks are held and before the thread or the opening is
    written: it stores the opening's files and answers `{:ok, refs}`,
    written as the opening's `"attachments"`, or `{:error, reason}`,
    which rolls the transaction back. It may be called again when the
    transaction is retried, and what it stored is the caller's to
    discard when the transaction does not commit. Under the athanor's
    row lock, the blob sweep cannot reclaim the files of a new thread
    before its row commits (`Arca.ThreadStorage.sweep_orphaned_blobs/1`).
  - `:person_id`, `:origin` — whose ask it is and how it started, which
    the `workspace_open` record carries.

  The asking turn is taken first, then the athanor's row, as every
  create of a thread takes it, and the daily and the workspace thread
  together (`Arca.ThreadStorage.lock_threads!/2`). Answers `%{workspace, opening, pointer}`;
  `{:error, :not_found}` for a thread that is not the athanor's,
  `{:error, :not_a_daily_thread}`, `{:error, :not_a_workspace}`, or the
  files' own refusal.
  """
  @spec open_workspace(Prima.Actor.t(), map()) ::
          {:ok, %{workspace: map(), opening: map(), pointer: map()}} | {:error, term()}
  def open_workspace(%Prima.Actor{athanor_id: athanor_id} = actor, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.open_workspace", fn ->
      with_seq_retry(fn ->
        Arca.Repo.locking_transaction(fn -> opened!(actor, attrs) end)
      end)
      |> case do
        {:error, :thread_not_found} -> {:error, :not_found}
        other -> other
      end
    end)
    |> Arca.Data.project()
  end

  def open_workspace(%Prima.Actor{}, _attrs), do: {:error, :no_athanor}

  # arca:db-raise-ok inside the caller's transaction
  defp opened!(%Prima.Actor{athanor_id: athanor_id} = actor, attrs) do
    asking =
      case Map.get(attrs, :turn) do
        nil -> nil
        %{id: turn_id} = held -> open!(own!(athanor_id, turn_id, held))
      end

    _held =
      Arca.ThreadStorage.lock_threads!(
        actor,
        Enum.reject([Map.fetch!(attrs, :daily_id), Map.get(attrs, :workspace_id)], &is_nil/1)
      )

    daily = locked_thread!(athanor_id, Map.fetch!(attrs, :daily_id))
    if daily.kind != "daily", do: Arca.Repo.rollback(:not_a_daily_thread)
    if asking && asking.thread_id != daily.id, do: Arca.Repo.rollback(:not_addressable)

    opening = Map.fetch!(attrs, :opening)

    # An existing thread is held before its opening's files are stored; a
    # new one is made after, so a refusal of its row finds the files
    # stored for the caller to discard.
    {workspace, refs} =
      case Map.get(attrs, :workspace_id) do
        nil ->
          refs = files!(attrs, Map.fetch!(attrs, :id), opening.id)

          {Arca.ThreadStorage.insert_thread!(actor, %{
             id: Map.fetch!(attrs, :id),
             kind: "workspace",
             title: Map.fetch!(attrs, :title),
             workspace_state: "open",
             opened_from: Map.get(attrs, :opened_from)
           }), refs}

        workspace_id ->
          case locked_thread!(athanor_id, workspace_id) do
            %Thread{kind: "workspace"} = workspace ->
              new_work!(actor, workspace)
              {reopened!(athanor_id, workspace), files!(attrs, workspace.id, opening.id)}

            %Thread{} ->
              Arca.Repo.rollback(:not_a_workspace)
          end
      end

    payload =
      if refs == [],
        do: opening.payload,
        else: Map.put(opening.payload, "attachments", refs)

    opening_row =
      Arca.ThreadStorage.insert_message!(actor, workspace, %{
        id: opening.id,
        kind: "opening",
        author: opening.author,
        sent_by: "person",
        content: opening.content,
        payload: payload
      })

    pointer = Map.fetch!(attrs, :pointer)

    pointer_row =
      Arca.ThreadStorage.insert_message!(
        actor,
        daily,
        Map.merge(pointer, %{kind: "pointer", workspace_id: workspace.id})
      )

    record =
      Prima.OutboxRecord.workspace_open(%{
        athanor_id: athanor_id,
        workspace_id: workspace.id,
        opening_id: opening_row.id,
        inserted_at: opening_row.inserted_at,
        person_id: Map.fetch!(attrs, :person_id),
        origin: Map.fetch!(attrs, :origin)
      })

    :ok = Arca.Outbox.put!(actor, record)
    _settled = settle_work!(athanor_id, workspace)

    %{workspace: thread!(athanor_id, workspace.id), opening: opening_row, pointer: pointer_row}
  end

  # The opening's files, stored by the caller's function under the
  # thread's and the opening's ids once the locks are held.
  # arca:db-raise-ok inside the caller's transaction
  defp files!(attrs, thread_id, opening_id) do
    case Map.fetch!(attrs, :files).(thread_id, opening_id) do
      {:ok, refs} when is_list(refs) -> refs
      {:error, reason} -> Arca.Repo.rollback(reason)
    end
  end

  # New work in a workspace thread, a person's post or a further opening:
  # how its work ended no longer ends it. The caller's transaction asks
  # the rule once the new work's row is written (`settle_work!/2`).
  # arca:db-raise-ok inside the caller's transaction
  defp reopened!(athanor_id, %Thread{kind: "workspace"} = thread) do
    {1, _} =
      from(c in Thread, where: c.athanor_id == ^athanor_id and c.id == ^thread.id)
      |> Arca.Repo.update_all(set: [workspace_outcome: nil])

    %{thread | workspace_outcome: nil}
  end

  @doc """
  Report the work of a running turn of a workspace thread as `outcome`
  (`done`, or `needs_you` for work that waits on its person's input)
  under the turn's fence, with its `workspace_report` record in the same
  transaction, under the thread's row: the thread is `outcome` once
  nothing else it accepted remains to run (the moduledoc's "Workspace
  threads"). `attrs`:
  `:fence`, `:summary`, `:attachments` (`[%{"message_id",
  "stored_name"}]`, files of the thread's own posts). A turn whose fence
  moved is `{:error, :superseded}`, one that is over `{:error,
  :not_open}`, a turn of any other kind of thread `{:error,
  :not_a_workspace}`, a turn that reported already `{:error,
  :reported}`, a thread whose work has ended `{:error,
  {:workspace_state, state}}`, and any other outcome `{:error,
  :illegal_transition}`, each with nothing written.
  """
  @spec report_workspace(Prima.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def report_workspace(%Prima.Actor{athanor_id: athanor_id}, turn_id, outcome, attrs)
      when is_binary(athanor_id) and athanor_id != "" and outcome in @reported and
             is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.report_workspace", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = open!(own!(athanor_id, turn_id, attrs))

        case locked_thread!(athanor_id, turn.thread_id) do
          %Thread{kind: "workspace", workspace_state: state} = thread
          when state in ["open", "needs_you"] ->
            if reported?(athanor_id, thread.id, turn.id), do: Arca.Repo.rollback(:reported)

            report!(athanor_id, thread, turn, outcome, %{
              summary: Map.get(attrs, :summary) || "",
              attachments: Map.get(attrs, :attachments, [])
            })

          %Thread{kind: "workspace", workspace_state: state} ->
            Arca.Repo.rollback({:workspace_state, state})

          %Thread{} ->
            Arca.Repo.rollback(:not_a_workspace)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def report_workspace(%Prima.Actor{athanor_id: athanor_id}, _turn_id, _outcome, _attrs)
      when is_binary(athanor_id) and athanor_id != "",
      do: {:error, :illegal_transition}

  def report_workspace(%Prima.Actor{}, _turn_id, _outcome, _attrs), do: {:error, :no_athanor}

  @doc """
  The person's stop of a workspace thread: everything of its work ends,
  in it and in the crew threads under it, in one transaction. Every open
  turn there is cancelled (`cancel_open!/4`, ended by the person), the
  workspace thread's own with their replies and the crew threads'
  silently, as a deletion cancels a room's; each request there still
  waiting for a crew member's answer, and each opening still waiting for
  its turn, is `expired`, so its delivery lands nothing
  (`accept_message/3`); and the thread is `stopped` with no report (the
  moduledoc's "Workspace threads"). A stop that finds nothing to end
  changes nothing.

  The turns are chosen before the locks and asked again under them, in
  the one order (`Arca.ThreadStorage.lock_threads!/2`): the turns, then
  the athanor's row, then the workspace thread's and its crew threads'
  rows together; a turn that opened in between sends the stop round
  again, at most three times, and then it is `{:error, :thread_in_use}`.
  `attrs` carry the root's grant as `finish/4` takes it and `:error`,
  the cancelled turns' error. Answers the cancelled turns with the steps
  their holders' runtime stops after the commit (`cancel_open!/4`); a
  thread that is no workspace thread is `{:error, :not_a_workspace}`.
  """
  @spec stop_work(Prima.Actor.t(), String.t(), map()) ::
          {:ok, %{cancelled: [map()]}} | {:error, term()}
  def stop_work(%Prima.Actor{athanor_id: athanor_id} = actor, workspace_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(workspace_id) and
             is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.stop_work", fn ->
      stop_round(actor, workspace_id, Map.put(attrs, :ended_by, :person), 3)
    end)
    |> Arca.Data.project()
  end

  def stop_work(%Prima.Actor{}, _workspace_id, _attrs), do: {:error, :no_athanor}

  defp stop_round(%Prima.Actor{athanor_id: athanor_id} = actor, workspace_id, attrs, tries) do
    chosen = Arca.Repo.all(work_turns(athanor_id, workspace_id))

    case Arca.Repo.locking_transaction(fn -> stopped!(actor, workspace_id, attrs, chosen) end) do
      {:ok, cancelled} -> {:ok, %{cancelled: cancelled}}
      {:error, :turns_moved} when tries > 1 -> stop_round(actor, workspace_id, attrs, tries - 1)
      {:error, :turns_moved} -> {:error, :thread_in_use}
      {:error, _} = refused -> refused
    end
  end

  # arca:db-raise-ok inside the caller's transaction
  defp stopped!(%Prima.Actor{athanor_id: athanor_id} = actor, workspace_id, attrs, chosen) do
    _held = hold_turns!(actor, chosen)

    crew =
      from(c in Thread,
        where: c.athanor_id == ^athanor_id and c.kind == "crew",
        where: c.parent_id == ^workspace_id,
        select: c.id
      )
      |> Arca.Repo.all()

    case actor
         |> Arca.ThreadStorage.lock_threads!([workspace_id | crew])
         |> by_id(workspace_id) do
      %Thread{kind: "workspace"} ->
        if Arca.Repo.all(work_turns(athanor_id, workspace_id)) -- chosen != [],
          do: Arca.Repo.rollback(:turns_moved)

        cancelled =
          cancel_open!(actor, workspace_id, attrs, :reply) ++
            Enum.flat_map(crew, &cancel_open!(actor, &1, attrs, :silent))

        expired = expire_waiting!(athanor_id, workspace_id)

        if cancelled != [] or expired > 0 do
          workspace = thread!(athanor_id, workspace_id)
          settle_work!(athanor_id, ended_as!(athanor_id, workspace, "stopped"))
        end

        cancelled

      %Thread{} ->
        Arca.Repo.rollback(:not_a_workspace)

      nil ->
        Arca.Repo.rollback(:thread_not_found)
    end
  end

  defp by_id(threads, id), do: Enum.find(threads, &(&1.id == id))

  # The open turns of a workspace thread and of the crew threads under it.
  defp work_turns(athanor_id, workspace_id) do
    from(t in Turn,
      join: c in Thread,
      on: c.id == t.thread_id and c.athanor_id == t.athanor_id,
      where: t.athanor_id == ^athanor_id and t.status in ^@open,
      where: c.id == ^workspace_id or (c.kind == "crew" and c.parent_id == ^workspace_id),
      select: t.id
    )
  end

  # The requests of a workspace thread still waiting for a crew member's
  # answer (`Arca.ThreadStorage.pending_requests/2`'s; a reply answers
  # one and is none), and its openings still
  # waiting for their turn, ended by the person's stop. Answers how many.
  # arca:db-raise-ok inside the caller's transaction
  defp expire_waiting!(athanor_id, workspace_id) do
    rows =
      from(m in Message,
        where: m.athanor_id == ^athanor_id and m.thread_id == ^workspace_id,
        where:
          (m.kind == "opening" and is_nil(m.turn_id) and is_nil(m.status)) or
            (not is_nil(m.addressee) and m.status == "pending" and is_nil(m.reply_to))
      )

    {expired, _} =
      Arca.Repo.update_all(rows, set: [status: "expired", resolved_at: DateTime.utc_now()])

    expired
  end

  @doc """
  An opening of a workspace thread whose delivery is refused for good
  (`Aqua.Crew`), with the delivering consumer's `:receipt` (`%{receipt,
  claim, slot}`) in the same transaction: the opening is `error`, so it
  waits for no turn, and the server's `error` report, with no turn,
  tells the daily thread why the work could not start (`:summary`),
  under the identity the opening was asked with (`:person_id`,
  `:origin`); the thread is `error` once nothing else of it remains to
  run. An opening that is no longer the thread's newest word, by the
  thread's own order under its row lock and by no clock (a person's post
  or a further opening after it in the thread's sequence, or how its
  work ended recorded since: Aqua's report, a stop, an error), ends on
  its own row alone: the newer word stands, and nothing is posted. An
  opening that has its turn or ended already is `{:error,
  :opening_ended}`, a thread gone `{:error, :thread_not_found}`, each
  with nothing written.
  """
  @spec refuse_opening(Prima.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def refuse_opening(
        %Prima.Actor{athanor_id: athanor_id} = actor,
        workspace_id,
        opening_id,
        attrs
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(workspace_id) and
             is_binary(opening_id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.refuse_opening", fn ->
      Arca.Repo.locking_transaction(fn ->
        case locked_thread!(athanor_id, workspace_id) do
          %Thread{kind: "workspace"} = workspace ->
            opening =
              from(m in Message,
                where: m.athanor_id == ^athanor_id and m.thread_id == ^workspace_id,
                where: m.id == ^opening_id and m.kind == "opening",
                where: is_nil(m.turn_id) and is_nil(m.status)
              )
              |> Arca.Repo.one() || Arca.Repo.rollback(:opening_ended)

            {1, _} =
              from(m in Message, where: m.athanor_id == ^athanor_id and m.id == ^opening.id)
              |> Arca.Repo.update_all(set: [status: "error", resolved_at: DateTime.utc_now()])

            receipted!(actor, Map.get(attrs, :receipt))

            if moved_past?(athanor_id, workspace, opening) do
              settle_work!(athanor_id, workspace)
            else
              report!(athanor_id, workspace, nil, "error", %{
                summary: Map.get(attrs, :summary) || "",
                person_id: Map.fetch!(attrs, :person_id),
                origin: Map.fetch!(attrs, :origin)
              })
            end

          %Thread{} ->
            Arca.Repo.rollback(:not_a_workspace)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def refuse_opening(%Prima.Actor{}, _workspace_id, _opening_id, _attrs),
    do: {:error, :no_athanor}

  # Whether `opening` is no longer the workspace thread's newest word,
  # read under the thread's row lock the caller holds, in the thread's own
  # serialized order and by no clock: a person's post or a further opening
  # stands after it in the thread's sequence, or the thread holds how its
  # work ended (`workspace_outcome`). Each opening and each post of the
  # person's clears that (`reopened!/2`), so one present now was written
  # after the latest of them: Aqua's report, a stop or an error since.
  # arca:db-raise-ok inside the caller's transaction
  defp moved_past?(athanor_id, %Thread{id: workspace_id} = workspace, %Message{} = opening) do
    not is_nil(workspace.workspace_outcome) or
      Arca.Repo.exists?(
        from(m in Message,
          where: m.athanor_id == ^athanor_id and m.thread_id == ^workspace_id,
          where: m.seq > ^opening.seq and (m.kind == "opening" or m.sent_by == "person")
        )
      )
  end

  # The workspace_report that tells the daily thread, recorded under the
  # identity of the reporting turn's person and origin, with the turn's
  # read threads; one with no turn (an opening refused before any started)
  # is the server's, under the identity the opening was asked with, and
  # carries none.
  # arca:db-raise-ok inside the caller's transaction
  defp reported!(athanor_id, %Thread{} = thread, turn, outcome, report) do
    {turn_id, person_id, wire, read_threads} =
      case turn do
        %Turn{} ->
          {turn.id, turn.requested_by, turn.origin,
           Arca.ThreadStorage.threads_of(turn.read_threads)}

        nil ->
          {nil, Map.fetch!(report, :person_id), Map.fetch!(report, :origin), []}
      end

    with {:ok, origin} <- Prima.Origin.from_wire(wire) do
      record =
        Prima.OutboxRecord.workspace_report(%{
          athanor_id: athanor_id,
          workspace_id: thread.id,
          title: thread.title,
          turn_id: turn_id,
          moved_at: DateTime.utc_now(),
          outcome: outcome,
          summary: Map.get(report, :summary) || "",
          attachments: Map.get(report, :attachments, []),
          read_threads: read_threads,
          person_id: person_id,
          origin: origin
        })

      :ok = Arca.Outbox.put!(Prima.Actor.in_athanor(athanor_id), record)
    else
      _no_origin -> Arca.Repo.rollback(:no_origin)
    end
  end

  # The one rule of a workspace thread's state, which every write that may
  # move it asks (a report, a skip, a turn's end, a stop, a crew member's
  # answer, new work): it is at work while work remains in it or in a
  # crew thread under it (`work!/3`); once nothing does, it is how its
  # work last ended since it last took new work (`workspace_outcome`), or
  # at work when nothing ended it. `except` names a turn the rule reads
  # the thread without (a nudge's turn asking, as it starts, whether its
  # line still stands).
  # arca:db-raise-ok inside the caller's transaction
  defp work_state!(athanor_id, %Thread{kind: "workspace"} = workspace, except \\ nil) do
    cond do
      work!(athanor_id, workspace, except) -> "open"
      workspace.workspace_outcome in Thread.workspace_outcomes() -> workspace.workspace_outcome
      true -> "open"
    end
  end

  @doc false
  # Whether work remains in the daily or workspace thread `room` or in a
  # crew thread under it (`work!/3`), the rule an archive asks
  # (`Arca.ThreadStorage.archive/2`). An in-transaction helper.
  @spec work_remains?(Prima.Actor.t(), Thread.t()) :: boolean()
  # arca:db-raise-ok inside the caller's transaction
  def work_remains?(%Prima.Actor{athanor_id: athanor_id}, %Thread{kind: kind} = room)
      when is_binary(athanor_id) and athanor_id != "" and kind in ["daily", "workspace"],
      do: work!(athanor_id, room)

  # What the one rule reads of a room, a daily or a workspace thread, and
  # the crew threads under it: whether work remains there. Work remains
  # while a turn of any of them is open, unless it has reported its work
  # (a workspace thread's turn reports once, and its row stays open until
  # it ends) or a page's call in any of them opened it (`page_call`, which
  # asks no model and is no work of the thread's); while a request it
  # asked a crew member is left until its answer lands; and while an
  # opening waits for its turn to start. `except` names one open turn read
  # as though it were not there.
  # arca:db-raise-ok inside the caller's transaction
  defp work!(athanor_id, %Thread{} = room, except \\ nil) do
    threads = room_threads(athanor_id, room.id)

    turns_run =
      from(t in room_turns(athanor_id, threads),
        where:
          t.status in ^@open and
            t.id not in ^Enum.reject([except | reported_turns(athanor_id, room.id)], &is_nil/1)
      )

    asked =
      from(m in Message,
        where: m.athanor_id == ^athanor_id and m.thread_id == ^room.id,
        where:
          (m.kind == "opening" and is_nil(m.turn_id) and is_nil(m.status)) or
            (not is_nil(m.addressee) and m.status == "pending")
      )

    Arca.Repo.exists?(turns_run) or Arca.Repo.exists?(asked)
  end

  # The threads of a room, a daily or a workspace thread, and the crew
  # threads under it: the scope of its work (`work!/3`) and of a workspace
  # thread's quiet (`quiet?/3`).
  defp room_threads(athanor_id, room_id) do
    from(c in Thread,
      where: c.athanor_id == ^athanor_id,
      where: c.id == ^room_id or (c.kind == "crew" and c.parent_id == ^room_id),
      select: c.id
    )
  end

  # The turns of a room's `threads` that no page's call in any of them
  # opened (`page_call`): such a turn asks no model, and is neither work
  # of the room's (`work!/3`) nor activity there (`quiet?/3`).
  defp room_turns(athanor_id, threads) do
    pages =
      from(m in Message,
        where: m.athanor_id == ^athanor_id and m.thread_id in subquery(threads),
        where: m.kind == "page_call",
        select: m.id
      )

    from(t in Turn,
      where: t.athanor_id == ^athanor_id and t.thread_id in subquery(threads),
      where: is_nil(t.message_id) or t.message_id not in subquery(pages)
    )
  end

  # The workspace thread's state as the rule now has it, written when it
  # moved, and the wait it waits on its person (`waited!/3`). Answers the
  # thread as it stands.
  # arca:db-raise-ok inside the caller's transaction
  defp settle_work!(athanor_id, %Thread{kind: "workspace"} = workspace) do
    moved =
      case work_state!(athanor_id, workspace) do
        same when same == workspace.workspace_state ->
          workspace

        state ->
          {1, _} =
            from(c in Thread, where: c.athanor_id == ^athanor_id and c.id == ^workspace.id)
            |> Arca.Repo.update_all(set: [workspace_state: state])

          %{workspace | workspace_state: state}
      end

    waited!(athanor_id, moved, moved.workspace_state != workspace.workspace_state)
  end

  # The one writer of `waits_since`: a thread that reads `needs_you` or
  # `error` and has just come to read so (from any other state, the other
  # of the two included) begins a new wait, stamped by the database's
  # clock and later than the wait before it whatever that clock did, so no
  # two waits of a thread share a stamp. A thread that stops waiting keeps
  # its last stamp. The server's post of a wait names it by it
  # (`accept_message/3`'s `:wait`).
  # arca:db-raise-ok inside the caller's transaction
  defp waited!(athanor_id, %Thread{workspace_state: state} = workspace, true)
       when state in @waiting do
    now = Arca.ServerMetaStorage.now!()

    since =
      case workspace.waits_since do
        %DateTime{} = last ->
          if DateTime.compare(now, last) == :gt,
            do: now,
            else: DateTime.add(last, 1, :microsecond)

        nil ->
          now
      end

    {1, _} =
      from(c in Thread, where: c.athanor_id == ^athanor_id and c.id == ^workspace.id)
      |> Arca.Repo.update_all(set: [waits_since: since])

    %{workspace | waits_since: since}
  end

  defp waited!(_athanor_id, %Thread{} = workspace, _began?), do: workspace

  # A report of the thread's work, Aqua's or the server's: how its work
  # ended, recorded, its record written, and the thread's state asked
  # again. `turn` is nil for the server's report of an opening refused
  # before any turn started.
  # arca:db-raise-ok inside the caller's transaction
  defp report!(athanor_id, %Thread{} = workspace, turn, outcome, report) do
    workspace = ended_as!(athanor_id, workspace, outcome)
    reported!(athanor_id, workspace, turn, outcome, report)
    settle_work!(athanor_id, workspace)
  end

  # How the thread's work ended, recorded with no report: what it becomes
  # once nothing of it remains to run.
  # arca:db-raise-ok inside the caller's transaction
  defp ended_as!(athanor_id, %Thread{} = workspace, outcome) do
    {1, _} =
      from(c in Thread, where: c.athanor_id == ^athanor_id and c.id == ^workspace.id)
      |> Arca.Repo.update_all(set: [workspace_outcome: outcome])

    %{workspace | workspace_outcome: outcome}
  end

  # Whether `turn` has reported its work already: each turn of a
  # workspace thread reports its own work once.
  # arca:db-raise-ok inside the caller's transaction
  defp reported?(athanor_id, workspace_id, turn_id),
    do: turn_id in reported_turns(athanor_id, workspace_id)

  # The turns of a workspace thread whose work a report ended: Aqua's
  # `done` or `needs_you`, or the server's `error`.
  # arca:db-raise-ok inside the caller's transaction
  defp reported_turns(athanor_id, workspace_id) do
    from(r in Arca.Schemas.OutboxRecord,
      where: r.athanor_id == ^athanor_id and r.kind == "workspace_report",
      where: r.source_kind == "thread" and r.source_id == ^workspace_id,
      select: r.snapshot
    )
    |> Arca.Repo.all()
    |> Enum.flat_map(fn text ->
      case Prima.Json.decode(text) do
        {:ok, %{"turn_id" => turn_id}} when is_binary(turn_id) ->
          [turn_id]

        _no_turn ->
          []
      end
    end)
  end

  # A turn's steps skipped: the thread's state asked again, reporting
  # nothing.
  # arca:db-raise-ok inside the caller's transaction
  defp settled!(athanor_id, thread_id) do
    case work_of(athanor_id, thread!(athanor_id, thread_id)) do
      %Thread{} = workspace -> settle_work!(athanor_id, workspace)
      nil -> :ok
    end

    :ok
  end

  # The workspace thread whose work a thread is: itself, or the room a
  # crew member's thread works under when that room is one.
  # arca:db-raise-ok inside the caller's transaction
  defp work_of(_athanor_id, %Thread{kind: "workspace"} = thread), do: thread

  defp work_of(athanor_id, %Thread{kind: "crew", parent_id: room_id}) when is_binary(room_id) do
    case Arca.Repo.get_by(Thread, id: room_id, athanor_id: athanor_id) do
      %Thread{kind: "workspace"} = workspace -> workspace
      _other -> nil
    end
  end

  defp work_of(_athanor_id, %Thread{}), do: nil

  # A turn of a workspace thread, or of a crew member's thread under it,
  # ended: the thread's state asked again. A turn of the workspace thread
  # itself that ended without a report of its own records how its work
  # ended first (`ending/2`): an `error` report with its error as the
  # summary, or `stopped` with none.
  # arca:db-raise-ok inside the caller's transaction
  defp ended_work!(athanor_id, %Turn{} = turn, status, attrs) do
    case work_of(athanor_id, thread!(athanor_id, turn.thread_id)) do
      %Thread{id: id, workspace_state: state} = workspace
      when id == turn.thread_id and state in ["open", "needs_you"] ->
        ending =
          if page_call?(athanor_id, turn) or reported?(athanor_id, workspace.id, turn.id),
            do: :none,
            else: ending(status, attrs)

        case ending do
          :none ->
            settle_work!(athanor_id, workspace)

          "stopped" ->
            settle_work!(athanor_id, ended_as!(athanor_id, workspace, "stopped"))

          # A turn whose stored origin reads as none has no identity a
          # report could be delivered under: nobody to tell, and the end
          # still lands.
          "error" ->
            if match?({:ok, _}, Prima.Origin.from_wire(turn.origin)),
              do:
                report!(athanor_id, workspace, turn, "error", %{
                  summary: Map.get(attrs, :error) || ""
                }),
              else: settle_work!(athanor_id, ended_as!(athanor_id, workspace, "error"))
        end

      %Thread{workspace_state: state} = workspace when state in ["open", "needs_you"] ->
        settle_work!(athanor_id, workspace)

      _finished_or_none ->
        :ok
    end
  end

  # How a workspace thread's own turn that did not report ended its work:
  # Aqua could not run it (failed, uncertain, or cancelled because a
  # recovery could not resume it), the person stopped it (cancelled by an
  # act of theirs), or nothing it says (completed, or cancelled by
  # anything else, such as a fence the turn lost).
  defp ending(status, _attrs) when status in ["failed", "uncertain"], do: "error"

  defp ending("cancelled", attrs) do
    case Map.get(attrs, :ended_by) do
      :person -> "stopped"
      :recovery -> "error"
      nil -> :none
    end
  end

  defp ending(_status, _attrs), do: :none

  # A turn a page's call opened: no work of the thread's, which reports
  # nothing of it (`work_state!/2`).
  # arca:db-raise-ok inside the caller's transaction
  defp page_call?(athanor_id, %Turn{message_id: id}) when is_binary(id),
    do:
      Arca.Repo.exists?(
        from(m in Message,
          where: m.athanor_id == ^athanor_id and m.id == ^id and m.kind == "page_call"
        )
      )

  defp page_call?(_athanor_id, %Turn{}), do: false

  # A person's post in a finished workspace thread opens it again.
  # arca:db-raise-ok inside the caller's transaction
  defp posted!(athanor_id, %Thread{kind: "workspace"} = thread, %{sent_by: "person"}),
    do: reopened!(athanor_id, thread)

  defp posted!(_athanor_id, %Thread{} = thread, _message), do: thread

  # A delivery from a workspace thread (a report naming it) lands only
  # while that thread stands. It takes two thread rows, the workspace
  # thread's and the one it lands on, in the one order
  # (`Arca.ThreadStorage.lock_threads!/2`), so a deletion or retention
  # that holds them first leaves the delivery nothing to land on, and one
  # that waits removes what landed.
  # arca:db-raise-ok inside the caller's transaction
  defp from_workspace!(actor, thread_id, %{workspace_id: workspace_id})
       when is_binary(workspace_id) do
    actor
    |> Arca.ThreadStorage.lock_threads!([workspace_id, thread_id])
    |> Enum.find(&(&1.id == workspace_id and &1.kind == "workspace"))
    |> case do
      %Thread{} = workspace -> workspace
      nil -> Arca.Repo.rollback(:workspace_gone)
    end
  end

  defp from_workspace!(_actor, _thread_id, _message), do: nil

  # A post of the server's naming a workspace thread's wait on its person
  # (`accept_message/3`'s `:wait`) lands only while that wait stands, read
  # under the workspace thread's lock `from_workspace!/3` holds: not
  # archived, reading `needs_you` or `error` since exactly the stamp the
  # post names, and for at least `quiet` seconds by the database's clock.
  # arca:db-raise-ok inside the caller's transaction
  defp still_waits!(_workspace, _thread, nil), do: :ok

  # A post of a wait takes neither thread out of the archive, as new work
  # would (`new_work!/2`): an archived one admits none.
  defp still_waits!(%Thread{archived_at: %DateTime{}}, _thread, %{}),
    do: Arca.Repo.rollback(:thread_archived)

  defp still_waits!(_workspace, %Thread{archived_at: %DateTime{}}, %{}),
    do: Arca.Repo.rollback(:thread_archived)

  defp still_waits!(
         %Thread{workspace_state: state, waits_since: %DateTime{} = since},
         _thread,
         %{waits_since: %DateTime{} = named, quiet: quiet}
       )
       when state in @waiting and is_integer(quiet) and quiet > 0 do
    cond do
      DateTime.compare(since, named) != :eq ->
        Arca.Repo.rollback(:wait_moved)

      DateTime.compare(since, DateTime.add(Arca.ServerMetaStorage.now!(), -quiet, :second)) ==
          :gt ->
        Arca.Repo.rollback(:not_quiet)

      true ->
        :ok
    end
  end

  defp still_waits!(_workspace, _thread, _wait), do: Arca.Repo.rollback(:wait_moved)

  # The row of a wait's post keeps the stamp it was checked against.
  defp with_wait(message, nil), do: message

  defp with_wait(message, %{waits_since: %DateTime{} = since}) do
    wait = %{"waits_since" => DateTime.to_iso8601(since)}
    Map.update(message, :payload, wait, &Map.merge(&1 || %{}, wait))
  end

  # ---------------------------------------------------------------------------
  # Nudges and reminders
  # ---------------------------------------------------------------------------

  @doc """
  The server's nudge of a quiet workspace thread (`Aqua.Nudge`), accepted
  in one transaction under the workspace thread's lock, which decides
  there afresh, by the rows and the database's clock, whether it stands:
  the thread reads `open`; no nudge of it is unanswered
  (`unanswered_nudge?/2`); and nothing has happened in it or in a crew
  thread under it for `:quiet` seconds (`quiet?/3`). Only then is the
  `nudge` row written, sent by `system` in the server's voice, and in the
  same transaction it joins the turn that holds the thread when that turn
  is Aqua's and asks a model (running, or paused around a launch),
  whatever waits behind it, attached as a steer is
  (`accept_message/3`'s `:steer_turn_id`), so the turn's next model round
  reads it from here on whichever member runs it (`drain_steer/3`) under
  its own person, origin and restrictions; or, with no turn open there
  and no opening waiting for its turn, opens one under `:turn` (`%{agent,
  requested_by, model, options, origin}`, the thread's current work's).
  Otherwise (a page's call's turn holds it, one paused on an uncertain
  call, a turn queued or an opening waiting with nothing
  holding it) it is refused `{:error, :busy}`. `:work` names the turn the
  caller bound it to (`nudge_view/3`'s `work`), the one it joins or whose
  person, origin and options `:turn` carries: it must be the one the
  thread's lock finds, or the nudge is refused `{:error, :work_moved}`,
  so a binding read earlier never lends a turn authority the thread's
  work no longer has. The nudge row reopens nothing and is no post.

  The rows are the serialized fact, so nothing about a nudge is derived
  from a time: two acceptances serialize on the thread's lock and the
  second finds the first unanswered, and a retry finds the same. A step
  that commits between the quiet read and the insert takes no lock of the
  thread; the nudge then lands in a thread that has just moved, and is
  answered once.

  `attrs`: `:message` (`:content`), `:turn`, `:work`, `:quiet`, `:claim` and
  `:slot` (the nudging job's claim, `Arca.JobClaims`, and this member's
  slot, judged last in the transaction as a delivery's receipt judges
  them, so a claim or slot lost lands nothing: `{:error, :taken}`,
  `{:error, :lapsed}` or `{:error, :not_owner}`) and
  `:join_only` (true refuses `{:error, :nothing_to_join}` rather than
  opening a turn). A thread no longer open is `{:error,
  {:workspace_state, state}}`, one with a nudge unanswered `{:error,
  :unanswered}`, one not quiet `{:error, :not_quiet}`, each with nothing
  written. Answers `{:ok, %{message: row, turn: row | nil, joined:
  boolean}}`: `turn` is the turn it opened, nil when it joined one.
  """
  @spec nudge(Prima.Actor.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def nudge(%Prima.Actor{athanor_id: athanor_id} = actor, workspace_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(workspace_id) and
             is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.nudge", fn ->
      nudge_round(actor, workspace_id, attrs, 3)
    end)
    |> Arca.Data.project()
  end

  def nudge(%Prima.Actor{}, _workspace_id, _attrs), do: {:error, :no_athanor}

  # The turn to join is chosen before the locks, since a turn's writers
  # take it before its thread, and asked again under them; one that moved
  # in between sends the round again, at most three times.
  defp nudge_round(%Prima.Actor{athanor_id: athanor_id} = actor, workspace_id, attrs, tries) do
    chosen = nudge_work(athanor_id, workspace_id)

    with_seq_retry(fn ->
      Arca.Repo.locking_transaction(fn -> nudged!(actor, workspace_id, attrs, chosen) end)
    end)
    |> case do
      {:error, :nudge_moved} when tries > 1 -> nudge_round(actor, workspace_id, attrs, tries - 1)
      {:error, :nudge_moved} -> {:error, :busy}
      answer -> answer
    end
  end

  # arca:db-raise-ok inside the caller's transaction
  defp nudged!(%Prima.Actor{athanor_id: athanor_id} = actor, workspace_id, attrs, chosen) do
    with {:join, turn_id} <- chosen, do: held_to_join!(athanor_id, workspace_id, turn_id)

    thread = locked_thread!(athanor_id, workspace_id)
    if thread.kind != "workspace", do: Arca.Repo.rollback(:not_a_workspace)
    if thread.archived_at, do: Arca.Repo.rollback(:thread_archived)

    if thread.workspace_state != "open",
      do: Arca.Repo.rollback({:workspace_state, thread.workspace_state})

    if nudge_work(athanor_id, workspace_id) != chosen, do: Arca.Repo.rollback(:nudge_moved)
    if unanswered_nudge?(athanor_id, workspace_id), do: Arca.Repo.rollback(:unanswered)

    unless quiet?(athanor_id, workspace_id, Map.fetch!(attrs, :quiet)),
      do: Arca.Repo.rollback(:not_quiet)

    message = Map.fetch!(attrs, :message)

    row = fn turn_id ->
      Arca.ThreadStorage.insert_message!(actor, thread, %{
        author: Message.system_author(),
        sent_by: Message.system_author(),
        kind: "nudge",
        content: Map.fetch!(message, :content),
        turn_id: turn_id
      })
    end

    answer =
      case chosen do
        {:join, turn_id} ->
          bound!(attrs, turn_id)
          %{message: row.(turn_id), turn: nil, joined: true}

        {:open, work_id} ->
          bound!(attrs, work_id)
          if Map.get(attrs, :join_only), do: Arca.Repo.rollback(:nothing_to_join)
          written = row.(nil)
          turn = open_turn!(athanor_id, thread, written, Map.fetch!(attrs, :turn), nil)
          %{message: %{written | turn_id: turn.id}, turn: turn, joined: false}

        :busy ->
          Arca.Repo.rollback(:busy)
      end

    settle_work!(athanor_id, thread)
    claimed!(attrs)
    answer
  end

  # The turn a nudge joins, taken first as every writer of a turn and its
  # thread takes them (`accept_message/3`'s steer); one that ended in
  # between sends the round again.
  # arca:db-raise-ok inside the caller's transaction
  defp held_to_join!(athanor_id, workspace_id, turn_id) do
    from(t in Turn,
      where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.thread_id == ^workspace_id,
      where: t.status in ^@open,
      update: [set: [status: t.status]]
    )
    |> Arca.Repo.update_all([])
    |> case do
      {1, _} -> :ok
      {0, _} -> Arca.Repo.rollback(:nudge_moved)
    end
  end

  # The sending job's claim and this member's slot, judged last in the
  # writing transaction as a delivery's receipt judges them
  # (`Arca.ConsumerReceipts.record!/4`): the claim held at its owner and
  # fence until the commit, the slot verified live, and the claim asked
  # again after the lease row's lock is won. A claim a peer took or that
  # lapsed, or a slot this member lost, lands nothing.
  # arca:db-raise-ok inside the caller's transaction
  defp claimed!(%{claim: claim, slot: slot}) do
    with {:ok, _held} <- Arca.JobClaims.hold(claim),
         :ok <- Arca.ControlPlane.verify_held(slot),
         {:ok, _still} <- Arca.JobClaims.hold(claim) do
      :ok
    else
      lost when lost in [:taken, :lapsed] -> Arca.Repo.rollback(lost)
      :lost -> Arca.Repo.rollback(:not_owner)
    end
  end

  # The work the caller bound the nudge to (`:work`) is the turn the
  # thread's lock found: one that moved since it was read lands nothing.
  # arca:db-raise-ok inside the caller's transaction
  defp bound!(attrs, turn_id) do
    if Map.fetch!(attrs, :work) != turn_id, do: Arca.Repo.rollback(:work_moved)
  end

  # What a nudge would do in the workspace thread now, naming the turn it
  # is bound to: join the turn that holds the thread when it is Aqua's and
  # asks a model, running or paused around a launch, whatever turns or
  # openings wait behind it, its row a steer that borrows nothing of that
  # turn's authority; with no turn open there and no opening waiting for
  # its turn, open one bound to the thread's current work, the newest turn
  # of Aqua's there by the thread's order, a page's call's aside; and
  # nothing otherwise. A turn paused on an uncertain call waits for the
  # person, whose acknowledgement a timer never stands in for, and
  # a queued turn or a waiting opening is the work, beside which no nudge
  # opens a turn. Read before the locks and again under them.
  # arca:db-raise-ok inside the caller's transaction
  defp nudge_work(athanor_id, workspace_id) do
    open =
      from(t in Turn,
        where: t.athanor_id == ^athanor_id and t.thread_id == ^workspace_id,
        where: t.status in ^@open,
        select: %{
          id: t.id,
          status: t.status,
          paused_reason: t.paused_reason,
          agent: t.agent,
          message_id: t.message_id
        }
      )
      |> Arca.Repo.all()

    holder =
      from(c in Thread,
        where: c.athanor_id == ^athanor_id and c.id == ^workspace_id,
        select: c.active_turn_id
      )
      |> Arca.Repo.one()

    case {open, Enum.find(open, &(&1.id == holder))} do
      {_open, %{} = turn} ->
        if joins?(athanor_id, turn), do: {:join, turn.id}, else: :busy

      {[], nil} ->
        case current_work(athanor_id, workspace_id) do
          %{id: id} -> {:open, id}
          nil -> :busy
        end

      _queued ->
        :busy
    end
  end

  defp joins?(athanor_id, %{agent: agent} = turn) do
    Prima.AgentRef.soul?(agent) and
      (turn.status == "running" or (turn.status == "paused" and turn.paused_reason == "launch")) and
      not page_call?(athanor_id, struct(Turn, turn))
  end

  # Whether a nudge of the workspace thread waits for its answer: its turn
  # is still open, and no model step of that turn has both carried it and
  # closed. A model step carries the nudges its turn had read by then
  # (`consumed!/3`), so after Aqua answered a nudge inside a long turn the
  # next quiet period nudges again; a nudge whose turn ended, however it
  # ended, answered or not, is retired with it.
  # arca:db-raise-ok inside the caller's transaction
  defp unanswered_nudge?(athanor_id, workspace_id) do
    from(m in Message,
      join: t in Turn,
      on: t.id == m.turn_id and t.athanor_id == m.athanor_id,
      left_join: s in TurnStep,
      on: s.id == m.resolved_by and s.athanor_id == m.athanor_id,
      where: m.athanor_id == ^athanor_id and m.thread_id == ^workspace_id,
      where: m.kind == "nudge" and t.status in ^@open,
      where: is_nil(s.id) or s.dispatch_state != "closed"
    )
    |> Arca.Repo.exists?()
  end

  # A model step opened on a turn carries what its request holds of the
  # posts written into the turn (`post?/2`), the boundary `drain_steer/3` moved
  # before the request was read bounding them: each post no step carried
  # yet names the step its `carried_by`, its place in every later reading
  # (`projection/2`), and each nudge still waiting names it its
  # `resolved_by` too. Taken under the turn's lock, in the step's own write,
  # so a post arriving after the request was read waits for the next step.
  # arca:db-raise-ok inside the caller's transaction
  defp consumed!(athanor_id, %Turn{} = turn, %{id: step_id, kind: "model", purpose: "chat"}) do
    window = turn.window_upto_seq || 0

    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.turn_id == ^turn.id,
      where: m.seq <= ^window and is_nil(m.carried_by),
      where: ^post(turn.agent)
    )
    |> Arca.Repo.update_all(set: [carried_by: step_id])

    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.turn_id == ^turn.id and m.kind == "nudge",
      where: m.seq <= ^window and is_nil(m.resolved_by)
    )
    |> Arca.Repo.update_all(set: [resolved_by: step_id, resolved_at: DateTime.utc_now()])

    :ok
  end

  defp consumed!(_athanor_id, _turn, _step), do: :ok

  # Whether nothing has happened in the workspace thread or a crew thread
  # under it for `seconds`, by the database's clock: no post, no step
  # starting or ending and no turn accepted or ended there since. A
  # nudge, a page's call and its result, a page's steps and a turn a
  # page's call opened in any of them are no activity
  # of the thread's, as they are no work of it (`room_turns/2`), and
  # neither is what is read, a read mark, the timer's own reads, a
  # delivery's receipt or output streamed and not recorded, none of which
  # is a row here.
  # arca:db-raise-ok inside the caller's transaction
  defp quiet?(athanor_id, workspace_id, seconds) when is_integer(seconds) and seconds > 0 do
    since = DateTime.add(Arca.ServerMetaStorage.now!(), -seconds, :second)
    threads = room_threads(athanor_id, workspace_id)
    turns = room_turns(athanor_id, threads)

    not Enum.any?(
      [
        from(m in Message,
          where: m.athanor_id == ^athanor_id and m.thread_id in subquery(threads),
          where: m.kind not in ["nudge", "page_call", "page_result"],
          where: m.inserted_at > ^since
        ),
        from(s in TurnStep,
          join: t in subquery(turns),
          on: t.id == s.turn_id,
          where: s.athanor_id == ^athanor_id,
          where: is_nil(s.purpose) or s.purpose != "page",
          where: s.kind != "input",
          where: s.started_at > ^since or s.ended_at > ^since
        ),
        from(t in subquery(turns), where: t.accepted_at > ^since or t.ended_at > ^since)
      ],
      &Arca.Repo.exists?/1
    )
  end

  @doc """
  As a turn a server's line opened first starts (`Aqua.Loop`), whether
  its line still stands to be answered, read and never written: a
  workspace thread's nudge while the thread, read without this turn,
  still reads `open` and is not archived. Any other turn's line stands,
  and a turn whose thread is gone asks nothing. Answers `{:ok, boolean}`,
  or `{:error, :database_error}` when the store cannot answer, on which
  the turn asks no model.
  """
  @spec line_stands(Prima.Actor.t(), map()) :: {:ok, boolean()} | {:error, term()}
  def line_stands(%Prima.Actor{athanor_id: athanor_id}, %{
        id: turn_id,
        sent_by: "system",
        thread_id: thread_id
      })
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.line_stands", fn ->
      case Arca.Repo.get_by(Thread, athanor_id: athanor_id, id: thread_id) do
        %Thread{kind: "workspace", archived_at: nil} = workspace ->
          {:ok, work_state!(athanor_id, workspace, turn_id) == "open"}

        %Thread{kind: "workspace"} ->
          {:ok, false}

        %Thread{} ->
          {:ok, true}

        nil ->
          {:ok, false}
      end
    end)
  end

  def line_stands(%Prima.Actor{athanor_id: athanor_id}, %{})
      when is_binary(athanor_id) and athanor_id != "",
      do: {:ok, true}

  def line_stands(%Prima.Actor{}, _turn), do: {:error, :no_athanor}

  @doc """
  A page of the cell's workspace threads a quiet period or a wait can
  make due, after `cursor` (`{athanor_id, id}`, or nil for the first),
  `limit` at most, in athanor and id order: the ones that read `open`,
  `needs_you` or `error` and are not archived. Each is `%{athanor_id,
  id}`.
  """
  @spec nudge_candidates({String.t(), String.t()} | nil, pos_integer()) ::
          {:ok, [map()]} | {:error, :database_error}
  # arca:unscoped-ok the nudging job reads across the cell; each thread is
  # then read and acted on under its own athanor's actor.
  def nudge_candidates(cursor, limit) when is_integer(limit) and limit > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.nudge_candidates", fn ->
      query =
        from(c in Thread,
          where: c.workspace_state in ["open", "needs_you", "error"] and is_nil(c.archived_at),
          order_by: [asc: c.athanor_id, asc: c.id],
          limit: ^limit,
          select: %{athanor_id: c.athanor_id, id: c.id}
        )

      query =
        case cursor do
          nil ->
            query

          {athanor_id, id} ->
            from(c in query,
              where: c.athanor_id > ^athanor_id or (c.athanor_id == ^athanor_id and c.id > ^id)
            )
        end

      {:ok, Arca.Repo.all(query)}
    end)
  end

  @doc """
  What the nudging job reads of one workspace thread: its `state`, its
  `title`, its wait (`waits_since`), whether it is archived (`archived?`,
  which is neither nudged nor reminded), whether it is quiet for `seconds`
  and has no nudge unanswered (`due?`, for a thread that reads `open`),
  and the turn a nudge is bound to now (`work`, as `%{id, person, origin,
  options}`): the turn of Aqua's it would join, or the one whose person,
  origin and options a turn it would open keeps (`nudge/3`); nil when it
  would do neither.
  """
  @spec nudge_view(Prima.Actor.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def nudge_view(%Prima.Actor{athanor_id: athanor_id}, workspace_id, seconds)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(workspace_id) and
             is_integer(seconds) and seconds > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.nudge_view", fn ->
      case Arca.Repo.get_by(Thread, athanor_id: athanor_id, id: workspace_id, kind: "workspace") do
        %Thread{} = thread ->
          due? =
            is_nil(thread.archived_at) and thread.workspace_state == "open" and
              not unanswered_nudge?(athanor_id, thread.id) and
              quiet?(athanor_id, thread.id, seconds)

          {:ok,
           %{
             id: thread.id,
             title: thread.title,
             state: thread.workspace_state,
             waits_since: thread.waits_since,
             archived?: not is_nil(thread.archived_at),
             due?: due?,
             work: if(due?, do: bound_work(athanor_id, nudge_work(athanor_id, thread.id)))
           }}

        nil ->
          {:error, :not_found}
      end
    end)
  end

  def nudge_view(%Prima.Actor{}, _workspace_id, _seconds), do: {:error, :no_athanor}

  # The turn a nudge's choice names, as the caller binds to it.
  # arca:db-raise-ok inside the caller's transaction
  defp bound_work(athanor_id, {_join_or_open, turn_id}) do
    from(t in Turn,
      where: t.athanor_id == ^athanor_id and t.id == ^turn_id,
      select: %{id: t.id, person: t.requested_by, origin: t.origin, options: t.options}
    )
    |> Arca.Repo.one()
  end

  defp bound_work(_athanor_id, :busy), do: nil

  # The thread's current work with nothing open there: none while an
  # opening still waits for its turn, since the opening is the work;
  # otherwise the newest of the thread's own turns by the thread's order,
  # a page's call's aside.
  # arca:db-raise-ok inside the caller's transaction
  defp current_work(athanor_id, workspace_id) do
    waiting =
      from(m in Message,
        where: m.athanor_id == ^athanor_id and m.thread_id == ^workspace_id,
        where: m.kind == "opening" and is_nil(m.turn_id) and is_nil(m.status)
      )

    unless Arca.Repo.exists?(waiting) do
      from(t in Turn,
        join: m in Message,
        on: m.id == t.message_id and m.athanor_id == t.athanor_id,
        where: t.athanor_id == ^athanor_id and t.thread_id == ^workspace_id,
        where: m.kind != "page_call",
        order_by: [desc: m.seq],
        limit: 1,
        select: %{id: t.id}
      )
      |> Arca.Repo.one()
    end
  end

  @doc """
  Whether the wait `waits_since` began at least `seconds` ago by the
  database's clock: a reminder of it is due no sooner.
  """
  @spec waited?(DateTime.t(), pos_integer()) :: boolean() | {:error, :database_error}
  def waited?(%DateTime{} = waits_since, seconds) when is_integer(seconds) and seconds > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.waited?", fn ->
      DateTime.compare(
        waits_since,
        DateTime.add(Arca.ServerMetaStorage.now!(), -seconds, :second)
      ) !=
        :gt
    end)
  end

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Start an accepted turn: `accepted → running` with its root execution,
  attempt, budget and pins (`:root_execution_id`, `:attempt`,
  `:budget_id`, `:profile_id`, `:consent_id`, `:agent_revision_digest`,
  `:agent_capability_digest`), its recovery limit (`:recovery_limit`, a
  positive count, required), the brain it runs on when it asks a catalyst
  brain's model (`:catalyst_ref`, `:brain_profile_id` and
  `:brain_consent_id`, all three or none: the release and the brain's own
  grant, written here and nowhere else), and the consumption boundary set
  to the highest seq the turn may read now.
  Event `turn.started`.

  The root is read from its rows, not taken from the map: it must be a
  running `turn` execution of this turn, and the attempt, reservation
  and profile the turn records are its current attempt (running), its
  open reservation and its profile. A value the caller names must be the
  row's, and a root the rows do not bear out is
  `{:error, :illegal_transition}`. A turn with no root names no attempt
  and no budget.

  The thread's claim is taken in the same transaction, naming the
  consumed sequence in `:turn_seq` — the value the caller read before it
  decided this turn runs next. A claim refused because a peer accepted
  the next message first answers `{:error, :stale}`, and the caller reads
  the thread again; one refused because another turn holds the thread
  answers `{:error, {:held_elsewhere, turn_id}}`. Without `:turn_seq` the sequence
  the transaction reads is used, which checks the holder and not the
  caller's view of the thread.
  """
  @spec start(Prima.Actor.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def start(%Prima.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.start", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        if turn.status != "accepted", do: Arca.Repo.rollback(:not_accepted)
        limit = recovery_limit!(turn, attrs)
        root = root_of!(athanor_id, turn, attrs)
        claim_thread!(athanor_id, turn, attrs)
        window = boundary(athanor_id, turn)

        sets =
          [
            status: "running",
            root_execution_id: root.execution_id,
            attempt: root.attempt,
            budget_id: root.budget_id,
            profile_id: root.profile_id,
            consent_id: Map.get(attrs, :consent_id),
            agent_revision_digest: Map.get(attrs, :agent_revision_digest),
            agent_capability_digest: Map.get(attrs, :agent_capability_digest),
            recovery_limit: limit,
            runner_id: Prima.Boot.id(),
            window_upto_seq: window
          ] ++ brain_pin!(attrs)

        moved =
          from(t in Turn,
            where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.status == "accepted"
          )
          |> Arca.Repo.update_all(set: sets)
          |> elem(0)

        if moved != 1, do: Arca.Repo.rollback(:not_accepted)
        turn = turn!(athanor_id, turn_id)
        event!(athanor_id, turn, "turn.started", nil, %{})
        turn
      end)
    end)
    |> Arca.Data.project()
  end

  def start(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  # The brain a turn pins with its start: a catalyst release with the
  # brain's own grant, all three or none.
  defp brain_pin!(%{catalyst_ref: ref, brain_profile_id: profile, brain_consent_id: consent})
       when is_binary(ref) and is_binary(profile) and is_binary(consent),
       do: [catalyst_ref: ref, brain_profile_id: profile, brain_consent_id: consent]

  defp brain_pin!(attrs) do
    if Enum.any?([:catalyst_ref, :brain_profile_id, :brain_consent_id], &Map.has_key?(attrs, &1)),
      do: Arca.Repo.rollback(:illegal_transition),
      else: []
  end

  @doc """
  Pin the program row a turn's brain runs on, once: the same row again is
  the turn as it stands, another is `{:error, :program_pinned}`.
  """
  @spec pin_program(Prima.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def pin_program(%Prima.Actor{athanor_id: athanor_id}, turn_id, row_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(row_id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pin_program", fn ->
      Arca.Repo.locking_transaction(fn ->
        case open!(own!(athanor_id, turn_id, attrs)) do
          %Turn{program: nil} ->
            {1, _} =
              from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
              |> Arca.Repo.update_all(set: [program: row_id])

            turn!(athanor_id, turn_id)

          %Turn{program: ^row_id} = turn ->
            turn

          %Turn{} ->
            Arca.Repo.rollback(:program_pinned)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def pin_program(%Prima.Actor{}, _turn_id, _row_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Pause a running turn: the turn, its root attempt and its root execution
  leave `running` together. `attrs`: `:fence`, `:reason`
  (`Prima.TurnState.pause_reasons/0`, required), and
  `:launch_step_id` — a `launch` step of this turn, named for a launch
  pause and for no other. A launch's pause dispatches its step in the
  same write, from `proposed` (`{:error, :not_proposed}` otherwise), and
  is refused while another step of the turn whose run is a child of its
  root is dispatched (`{:error, :child_running}`), a model's call among
  them: the root is never let go under a child's run, and the launch
  stays proposed for the turn to run once that child's step closes. A
  root attempt that is not the running owner refuses the pause
  (`{:error, :attempt_not_owner}`). The running interval is added to
  `active_ms`. Event `turn.paused`.
  """
  @spec pause(Prima.Actor.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def pause(actor, turn_id, attrs \\ %{})

  def pause(%Prima.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pause", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        if turn.status != "running", do: Arca.Repo.rollback(:not_running)
        lock_root!(athanor_id, turn)
        reason = Map.get(attrs, :reason)
        launch_step_id = launch_step!(athanor_id, turn, reason, Map.get(attrs, :launch_step_id))
        if launch_step_id, do: launch_dispatched!(athanor_id, turn, launch_step_id)
        ran = pause_owner!(athanor_id, turn)
        execution_status!(athanor_id, turn.root_execution_id, "running", "paused")
        now = DateTime.utc_now()

        {1, _} =
          from(t in Turn,
            where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.status == "running"
          )
          |> Arca.Repo.update_all(
            set: [
              status: "paused",
              paused_at: now,
              paused_reason: reason,
              launch_step_id: launch_step_id,
              active_ms: turn.active_ms + ran
            ]
          )

        turn = turn!(athanor_id, turn_id)
        event!(athanor_id, turn, "turn.paused", nil, %{"reason" => turn.paused_reason})
        turn
      end)
    end)
    |> Arca.Data.project()
  end

  def pause(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Resume a paused turn with a fresh lease read from the database's clock,
  under its root's grant (the moduledoc's "The root's grant", required):
  the turn, its root attempt and its root execution return to `running`
  together. Event `turn.resumed`.
  """
  @spec resume(Prima.Actor.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def resume(actor, turn_id, attrs \\ %{})

  def resume(%Prima.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.resume", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        if turn.status != "paused", do: Arca.Repo.rollback(:not_paused)
        lock_root!(athanor_id, turn)
        grant = stamp!(athanor_id, turn, standing!(athanor_id, turn, attrs, :required))
        until = Arca.ExecutionAttempts.lease_until()

        if Arca.ExecutionAttempts.resume!(
             Prima.Actor.in_athanor(athanor_id),
             turn.attempt,
             until,
             grant
           ) != 1,
           do: Arca.Repo.rollback(:attempt_not_paused)

        execution_status!(athanor_id, turn.root_execution_id, "paused", "running")

        {1, _} =
          from(t in Turn,
            where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.status == "paused"
          )
          |> Arca.Repo.update_all(
            set: [status: "running", paused_at: nil, paused_reason: nil, launch_step_id: nil]
          )

        turn = turn!(athanor_id, turn_id)
        event!(athanor_id, turn, "turn.resumed", nil, %{})
        turn
      end)
    end)
    |> Arca.Data.project()
  end

  def resume(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Append one row the turn owns but no step produced — a compaction, an
  aborted mark, a system note — inside the turn's fence. `attrs`: the
  message's own fields plus `:fence`.

  These rows are part of what the next request reads, so a runner whose
  fence has moved must not be able to add one: a superseded loop appending
  a compaction would change the projection its successor is working from.
  A turn that is over takes no row (`{:error, :not_open}`).
  """
  @spec append_turn_row(Prima.Actor.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def append_turn_row(%Prima.Actor{athanor_id: athanor_id} = actor, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.append_turn_row", fn ->
      with_seq_retry(fn ->
        Arca.Repo.locking_transaction(fn ->
          turn = open!(own!(athanor_id, turn_id, attrs))
          thread = thread!(athanor_id, turn.thread_id)

          Arca.ThreadStorage.insert_message!(
            actor,
            thread,
            attrs |> Map.drop([:fence]) |> Map.merge(%{turn_id: turn.id, sent_by: turn.agent})
          )
        end)
      end)
    end)
    |> Arca.Data.project()
  end

  def append_turn_row(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  End a turn: the one terminal transaction. `status` is
  `completed | failed | cancelled | uncertain`; `attrs`: `:fence`,
  `:error`, and on a cancel `:ended_by`, who cancelled it: `:person`
  for an act of the person's (a stop, a deletion of what it read, the
  consent restart, the athanor's archive) or `:recovery` for a turn the
  server could neither resume nor start for its sender, which a
  workspace thread's state reads (the
  moduledoc's "Workspace threads"); any other value, or one on another
  end, is `{:error, :illegal_transition}`. A turn with a reply address
  records its `crew_reply` here
  (the moduledoc's "Crew requests and replies"): outcome `done`,
  `failed`, `cancelled` or `uncertain`, the text its last own reply
  said, or for any end but a completion the error that ended it. The
  root attempt is closed with the matching outcome, the
  root execution leaves `running`/`paused`, the reservation is released
  and the open running interval is added to `active_ms`. A turn already
  over is answered `{:error, :already_finished}`; a turn with no root yet
  (still `accepted`) closes on its own. A turn with a steer no step
  carried refuses `completed` with `{:error, :steer_pending}`: its loop
  goes on to answer the steer; one with anything else of it open, a step
  proposed or dispatched of whatever kind or a delivery a program still
  owes an answer for, refuses it with `{:error, :call_pending}`: its loop
  goes on to dispatch the call, or to wait on its harness's work. A turn with a root attempt ends under its
  root's grant (the moduledoc's "The root's grant"), and a completion
  names one whatever the turn holds. Event `turn.<status>`.
  """
  @spec finish(Prima.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def finish(actor, turn_id, status, attrs \\ %{})

  def finish(%Prima.Actor{athanor_id: athanor_id}, turn_id, status, attrs)
      when is_binary(athanor_id) and athanor_id != "" and status in @terminal do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.finish", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        if turn.status in @terminal, do: Arca.Repo.rollback(:already_finished)
        work_lock!(athanor_id, turn)
        grant = granted!(athanor_id, turn, status, attrs)

        if status == "completed" and steer_rows(athanor_id, turn) != [],
          do: Arca.Repo.rollback(:steer_pending)

        if status == "completed" and calls_pending?(athanor_id, turn),
          do: Arca.Repo.rollback(:call_pending)

        ended!(athanor_id, turn, status, grant, attrs, :reply)
      end)
    end)
    |> Arca.Data.project()
  end

  def finish(%Prima.Actor{}, _turn_id, _status, _attrs), do: {:error, :no_athanor}

  # The turn's root locked and the grant its end runs under judged, before
  # anything else the end checks.
  # arca:db-raise-ok inside the caller's transaction
  defp granted!(athanor_id, %Turn{} = turn, status, attrs) do
    lock_root!(athanor_id, turn)
    standing!(athanor_id, turn, attrs, required_for(status))
  end

  # The one terminal write of a turn whose row the caller's transaction has
  # taken and whose grant it judged (`granted!/4`): the root attempt closed
  # with the matching outcome, the root execution out of `running`/`paused`
  # and its reservation released, the turn ended, its reply recorded
  # (`:reply`; `:silent` when the room it would answer is going), and the
  # thread's claim given up before the commit, so the thread is free the
  # moment the end is visible.
  # arca:db-raise-ok inside the caller's transaction
  defp ended!(athanor_id, %Turn{} = turn, status, grant, attrs, reply)
       when reply in [:reply, :silent] do
    ended_by!(status, Map.get(attrs, :ended_by))
    ended_at = DateTime.utc_now()

    ran =
      if turn.attempt do
        {attempt_state, outcome} = Prima.TurnState.attempt_end(status)

        Arca.ExecutionAttempts.close!(
          Prima.Actor.in_athanor(athanor_id),
          turn.attempt,
          attempt_state,
          outcome,
          stamp!(athanor_id, turn, grant)
        ) || 0
      else
        0
      end

    if turn.root_execution_id do
      execution_status!(
        athanor_id,
        turn.root_execution_id,
        Prima.ExecutionState.open_statuses(),
        Prima.TurnState.status_of(status),
        error: Map.get(attrs, :error)
      )

      Arca.BudgetReservations.close!(Prima.Actor.in_athanor(athanor_id), turn.root_execution_id)
    end

    {1, _} =
      from(t in Turn,
        where: t.athanor_id == ^athanor_id and t.id == ^turn.id and t.status in ^@open
      )
      |> Arca.Repo.update_all(
        set: [
          status: status,
          error: Map.get(attrs, :error),
          ended_at: ended_at,
          active_ms: turn.active_ms + ran,
          paused_at: nil,
          paused_reason: nil,
          launch_step_id: nil
        ]
      )

    if reply == :reply do
      replied!(
        athanor_id,
        turn,
        reply_outcome(status),
        ended_at,
        final_text(athanor_id, turn, status, attrs)
      )

      ended_work!(athanor_id, turn, status, attrs)
    end

    Arca.ThreadStorage.release_all!(Prima.Actor.in_athanor(athanor_id), turn.thread_id, turn.id)

    turn = turn!(athanor_id, turn.id)
    event!(athanor_id, turn, "turn." <> status, nil, %{"error" => Map.get(attrs, :error)})
    turn
  end

  # Who cancelled a turn is named on a cancel only (`finish/4`).
  # arca:db-raise-ok inside the caller's transaction
  defp ended_by!(_status, nil), do: :ok
  defp ended_by!("cancelled", by) when by in @ended_by, do: :ok
  defp ended_by!(_status, _by), do: Arca.Repo.rollback(:illegal_transition)

  @doc """
  Cancel every open turn of `thread_id` — accepted, running and paused
  alike — inside the caller's locking transaction, the way a
  retire ends them. Every open turn's row is taken first, before anything
  of the thread, the order the turn's own writers take them in, so a
  completion that holds its turn is waited on and its turn, ended by
  then, is left as it ended. Each taken turn's fence is raised, so no
  holder writes past it, its dispatched steps cancel-marked and settled
  by `Prima.TurnStep.unresolved/1`, its proposed ones skipped, and the
  turn ended `cancelled` with `attrs[:error]` by the one terminal write,
  its reply recorded (`:reply`) or not
  (`:silent`, for a room that is going), or, for `{:silent_to, ids}`,
  recorded when the thread that asked the turn is none of `ids`, the
  threads going with it. `attrs` carry the root's grant
  as `finish/4` takes it, `:ended_by` as `finish/4` takes it, and
  `:only`, when given, the ids of the open turns to cancel, the others
  left as they are.

  Answers each cancelled turn with the steps that were dispatched: what
  its holder's runtime cancels after the commit — the loop, an
  in-process handler, a child execution (`Aqua.Loop.abort_ended/4`).
  """
  @spec cancel_open!(
          Prima.Actor.t(),
          String.t(),
          map(),
          :reply | :silent | {:silent_to, [String.t()]}
        ) :: [
          %{turn_id: String.t(), thread_id: String.t(), steps: [map()]}
        ]
  # arca:db-raise-ok a step inside the caller's transaction; a raise rolls it back.
  def cancel_open!(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id, attrs, reply)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) do
    reason = Map.get(attrs, :error, "cancelled")
    now = DateTime.utc_now()

    taken =
      hold_turns!(
        actor,
        from(t in Turn, where: t.thread_id == ^thread_id, where: t.status in ^@open)
        |> only(Map.get(attrs, :only))
      )

    if taken != [], do: work_lock!(athanor_id, thread_id)

    if taken != [] do
      from(t in Turn, where: t.athanor_id == ^athanor_id and t.id in ^taken)
      |> Arca.Repo.update_all(inc: [fence: 1])
    end

    Enum.map(taken, fn turn_id ->
      turn = turn!(athanor_id, turn_id)

      dispatched =
        Arca.Repo.all(
          from(s in TurnStep,
            where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
            where: s.dispatch_state == "dispatched"
          )
        )

      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
        where: s.dispatch_state == "dispatched" and is_nil(s.cancel_requested_at)
      )
      |> Arca.Repo.update_all(set: [cancel_requested_at: now])

      Enum.each(dispatched, &settle_unresolved!(actor, athanor_id, turn, &1, reason))
      _skipped = skip_proposed!(actor, athanor_id, turn, reason)
      turn = turn!(athanor_id, turn_id)
      grant = granted!(athanor_id, turn, "cancelled", attrs)
      _ended = ended!(athanor_id, turn, "cancelled", grant, attrs, reply_to(reply, turn))

      %{
        turn_id: turn_id,
        thread_id: thread_id,
        steps: Enum.map(dispatched, &Map.take(&1, [:id, :generation, :kind, :child_execution_id]))
      }
    end)
  end

  def cancel_open!(%Prima.Actor{}, _thread_id, _attrs, _reply),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.cancel_open!/4")

  # Whether a cancelled turn answers its asker: a turn asked from a thread
  # that is going is answered by nobody.
  defp reply_to({:silent_to, going}, %Turn{asking_thread_id: asker})
       when is_binary(asker),
       do: if(asker in going, do: :silent, else: :reply)

  defp reply_to({:silent_to, _going}, %Turn{}), do: :silent
  defp reply_to(reply, %Turn{}), do: reply

  defp only_steps(query, nil), do: query
  defp only_steps(query, ids) when is_list(ids), do: where(query, [s], s.id in ^ids)

  defp only(query, nil), do: query
  defp only(query, ids) when is_list(ids), do: from(t in query, where: t.id in ^ids)

  @doc """
  Take over a running turn another runner lost: the one place a
  successor attempt is opened. `attrs`: `:fence` (the one the caller read)
  and the root's grant (required); the successor's lease is read from the
  database's clock. The turn's fence is compared and renewed first, then
  the thread's claim is taken — never from a live peer, which is
  `{:error, :held_elsewhere}` — the predecessor is retired, the successor opened
  with the next fence and the pointer moved, `recovery_attempts` counted
  and the predecessor's unaccounted running interval added. The claim and
  the count are the one transaction, so a member that did not take the
  claim cannot spend a recovery. Refused
  `{:error, :recovery_exhausted}` once the turn's stored limit is spent
  and `{:error, :not_open}` for a turn that is over.
  """
  @spec takeover(Prima.Actor.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def takeover(actor, turn_id, attrs \\ %{})

  def takeover(%Prima.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.takeover", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = take!(athanor_id, turn_id, attrs)
        if turn.status not in @held, do: Arca.Repo.rollback(:not_open)
        spend_recovery!(turn)
        if is_nil(turn.root_execution_id), do: Arca.Repo.rollback(:no_root)
        grant = standing!(athanor_id, turn, attrs, :required)

        thread = thread!(athanor_id, turn.thread_id)
        if thread.retired_at, do: Arca.Repo.rollback(:thread_retired)
        Arca.ThreadStorage.take_claim!(Prima.Actor.in_athanor(athanor_id), thread.id, turn_id)

        %{sets: sets, ran_ms: ran, attempt: attempt} = adopt_root!(athanor_id, turn, grant)

        {1, _} =
          from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
          |> Arca.Repo.update_all(
            set:
              sets ++
                [
                  runner_id: Prima.Boot.id(),
                  recovery_attempts: turn.recovery_attempts + 1,
                  active_ms: turn.active_ms + ran
                ]
          )

        turn = turn!(athanor_id, turn_id)
        event!(athanor_id, turn, "turn.recovered", nil, %{"attempt" => attempt})
        turn
      end)
    end)
    |> Arca.Data.project()
  end

  def takeover(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  # The attempt half of a takeover: the predecessor retired, a successor
  # opened under this boot with the predecessor's stamp and a lease read
  # from the database's clock, the root execution back to `running`. The
  # root is one `ExecutionAttempts.takeover!/3` admits: running, paused,
  # or failed by a lapse of its current attempt. Answers what the turn row
  # must be set to with it, the predecessor's unaccounted interval, and
  # the successor's id.
  # arca:db-raise-ok inside the caller's transaction
  defp adopt_root!(athanor_id, %Turn{} = turn, grant) do
    %{attempt: successor, ran_ms: ran} =
      Arca.ExecutionAttempts.takeover!(
        Prima.Actor.in_athanor(athanor_id),
        turn.root_execution_id,
        boot_id: Prima.Boot.id(),
        lease_until: Arca.ExecutionAttempts.lease_until(),
        grant: stamp!(athanor_id, turn, grant)
      )

    execution_status!(
      athanor_id,
      turn.root_execution_id,
      Prima.ExecutionState.from(:execution, "running"),
      "running"
    )

    %{
      sets: [
        status: "running",
        attempt: successor.attempt,
        paused_at: nil,
        paused_reason: nil,
        launch_step_id: nil
      ],
      ran_ms: ran,
      attempt: successor.attempt
    }
  end

  @doc """
  Raise the fence of the turn and mark every step it has dispatched
  cancel-requested, before the loop is stopped: a
  later write from an old fence and a later admission of those steps are
  refused. `attrs`: `:fence`, the one the caller read. Answers the turn
  with its new fence.
  """
  @spec supersede(Prima.Actor.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def supersede(%Prima.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.supersede", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = take!(athanor_id, turn_id, attrs)
        if turn.status not in @open, do: Arca.Repo.rollback(:not_open)
        now = DateTime.utc_now()

        from(s in TurnStep,
          where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
          where: s.dispatch_state == "dispatched" and is_nil(s.cancel_requested_at)
        )
        |> Arca.Repo.update_all(set: [cancel_requested_at: now])

        turn!(athanor_id, turn_id)
      end)
    end)
    |> Arca.Data.project()
  end

  def supersede(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @aborted_content "a call's outcome is unknown; tools may have partially executed"

  @doc """
  Stop a root turn on a call whose outcome is unknown, in one transaction:
  the step `:step_id` at `:generation` is marked `uncertain` with
  `:reason`; a running turn, its root attempt and its root execution
  leave `running` together (a turn paused around a launch keeps its
  released root); every other dispatched step is cancel-marked, so a
  sibling not yet admitted cannot admit; every proposed step is skipped;
  a `turn_aborted` row is appended whose payload `covers` names every
  step that was dispatched or uncertain at that moment; the turn is
  `paused` with reason `uncertain` and its boundary moved to that row.
  `:fence` is required. Answers the turn and the aborted row.
  """
  @spec pause_uncertain(Prima.Actor.t(), String.t(), map()) ::
          {:ok, %{turn: map(), aborted: map()}} | {:error, term()}
  def pause_uncertain(%Prima.Actor{athanor_id: athanor_id} = actor, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pause_uncertain", fn ->
      with_seq_retry(fn ->
        Arca.Repo.locking_transaction(fn ->
          turn = own!(athanor_id, turn_id, attrs)
          work_lock!(athanor_id, turn)
          lock_root!(athanor_id, turn)
          now = DateTime.utc_now()
          step = step!(athanor_id, Map.fetch!(attrs, :step_id))
          if step.turn_id != turn.id, do: Arca.Repo.rollback(:step_not_found)

          mark_uncertain!(
            athanor_id,
            turn,
            step,
            Map.fetch!(attrs, :generation),
            Map.get(attrs, :reason)
          )

          ran =
            case turn do
              %Turn{status: "running"} ->
                ran =
                  Arca.ExecutionAttempts.pause!(Prima.Actor.in_athanor(athanor_id), turn.attempt) ||
                    0

                execution_status!(athanor_id, turn.root_execution_id, "running", "paused")
                ran

              %Turn{status: "paused", paused_reason: "launch"} ->
                0

              _ ->
                Arca.Repo.rollback(:not_open)
            end

          content = Map.get(attrs, :content, @aborted_content)
          cancel_dispatched!(athanor_id, turn, step.id, now)
          _skipped = skip_proposed!(actor, athanor_id, turn, content)
          aborted = aborted_row!(actor, athanor_id, turn, content)

          {1, _} =
            from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
            |> Arca.Repo.update_all(
              set: [
                status: "paused",
                paused_at: now,
                paused_reason: "uncertain",
                launch_step_id: nil,
                window_upto_seq: aborted.seq,
                active_ms: turn.active_ms + ran
              ]
            )

          turn = turn!(athanor_id, turn_id)
          event!(athanor_id, turn, "turn.paused", nil, %{"reason" => "uncertain"})
          %{turn: turn, aborted: aborted}
        end)
      end)
    end)
    |> Arca.Data.project()
  end

  def pause_uncertain(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  A running turn a dead runner left holding an unacknowledged
  uncertainty is set down as paused `uncertain`, resumable: the
  predecessor attempt is retired with its running interval bounded by
  its lease (as a takeover does) and a successor is opened already
  paused, without counting a recovery; every dispatched step is settled
  by `TurnStep.unresolved/1`, every proposed step skipped, and — when an
  `uncertain` step is not yet covered — a covering `turn_aborted` row
  appended and the boundary moved to it. `attrs`: `:fence` (the one the
  caller read), the root's grant (required), `:content`. The root is one
  `Arca.ExecutionAttempts.takeover!/3` admits: running, paused, or failed
  by a lapse of its current attempt. Answers the turn.
  """
  @spec pause_recovered(Prima.Actor.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def pause_recovered(%Prima.Actor{athanor_id: athanor_id} = actor, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pause_recovered", fn ->
      with_seq_retry(fn ->
        Arca.Repo.locking_transaction(fn ->
          turn = take!(athanor_id, turn_id, attrs)
          if turn.status != "running", do: Arca.Repo.rollback(:not_running)
          if is_nil(turn.root_execution_id), do: Arca.Repo.rollback(:no_root)
          work_lock!(athanor_id, turn)
          grant = standing!(athanor_id, turn, attrs, :required)

          # Setting a turn down is recovery, so it is admitted by the same
          # row: never from a live peer, and in this transaction.
          thread = thread!(athanor_id, turn.thread_id)
          if thread.retired_at, do: Arca.Repo.rollback(:thread_retired)
          Arca.ThreadStorage.take_claim!(Prima.Actor.in_athanor(athanor_id), thread.id, turn_id)

          now = DateTime.utc_now()

          %{attempt: successor, ran_ms: ran} =
            Arca.ExecutionAttempts.takeover!(
              Prima.Actor.in_athanor(athanor_id),
              turn.root_execution_id,
              boot_id: Prima.Boot.id(),
              lease_until: Arca.ExecutionAttempts.lease_until(),
              grant: stamp!(athanor_id, turn, grant)
            )

          _ = Arca.ExecutionAttempts.pause!(Prima.Actor.in_athanor(athanor_id), successor.attempt)

          execution_status!(
            athanor_id,
            turn.root_execution_id,
            Prima.ExecutionState.from(:execution, "paused"),
            "paused"
          )

          content = Map.get(attrs, :content, @aborted_content)

          Arca.Repo.all(
            from(s in TurnStep,
              where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
              where: s.dispatch_state == "dispatched"
            )
          )
          |> Enum.each(&settle_unresolved!(actor, athanor_id, turn, &1, content))

          _skipped = skip_proposed!(actor, athanor_id, turn, content)

          window =
            if uncovered_uncertain(athanor_id, turn) != [],
              do: aborted_row!(actor, athanor_id, turn, content).seq,
              else: turn.window_upto_seq

          {1, _} =
            from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
            |> Arca.Repo.update_all(
              set: [
                status: "paused",
                attempt: successor.attempt,
                runner_id: Prima.Boot.id(),
                paused_at: now,
                paused_reason: "uncertain",
                launch_step_id: nil,
                window_upto_seq: window,
                active_ms: turn.active_ms + ran
              ]
            )

          turn = turn!(athanor_id, turn_id)
          event!(athanor_id, turn, "turn.paused", nil, %{"reason" => "uncertain"})
          turn
        end)
      end)
    end)
    |> Arca.Data.project()
  end

  def pause_recovered(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Whether the turn holds an uncertainty nobody has acknowledged: an
  `uncertain` step no `turn_aborted` row covers, or a covering row with
  no later row from the turn's sender. A covered, acknowledged
  uncertainty is a restricted continuation, not an open episode.
  """
  @spec unacknowledged_episode?(Prima.Actor.t(), String.t()) :: boolean() | {:error, term()}
  def unacknowledged_episode?(%Prima.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.unacknowledged_episode?", fn ->
      turn = turn!(athanor_id, turn_id)

      uncovered_uncertain(athanor_id, turn) != [] or
        Enum.any?(covering_rows(athanor_id, turn), fn row ->
          not Arca.Repo.exists?(
            from(m in Message,
              where: m.athanor_id == ^athanor_id and m.turn_id == ^turn.id,
              where: m.sent_by == ^turn.sent_by and m.seq > ^row.seq
            )
          )
        end)
    end)
    |> Arca.Data.project()
  end

  def unacknowledged_episode?(%Prima.Actor{}, _turn_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.unacknowledged_episode?/2")

  @doc "Whether any step of the turn is `uncertain`: the continuation runs replay-safe reads only."
  @spec restricted?(Prima.Actor.t(), String.t()) :: boolean() | {:error, term()}
  def restricted?(%Prima.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.restricted?", fn ->
      Arca.Repo.exists?(
        from(s in TurnStep,
          where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
          where: s.dispatch_state == "uncertain"
        )
      )
    end)
    |> Arca.Data.project()
  end

  def restricted?(%Prima.Actor{}, _turn_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.restricted?/2")

  # arca:db-raise-ok inside the caller's transaction
  defp cancel_dispatched!(athanor_id, %Turn{} = turn, except_step_id, now) do
    from(s in TurnStep,
      where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
      where: s.dispatch_state == "dispatched" and is_nil(s.cancel_requested_at),
      where: s.id != ^except_step_id
    )
    |> Arca.Repo.update_all(set: [cancel_requested_at: now])
  end

  # The covering aborted row: every step dispatched or uncertain now.
  # arca:db-raise-ok inside the caller's transaction
  defp aborted_row!(actor, athanor_id, %Turn{} = turn, content) do
    covers =
      Arca.Repo.all(
        from(s in TurnStep,
          where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
          where: s.dispatch_state in ["dispatched", "uncertain"],
          order_by: [asc: s.seq],
          select: %{"step_id" => s.id, "generation" => s.generation}
        )
      )

    thread = thread!(athanor_id, turn.thread_id)

    Arca.ThreadStorage.insert_message!(actor, thread, %{
      author: Message.system_author(),
      sent_by: turn.agent,
      kind: "turn_aborted",
      content: content,
      payload: %{"covers" => covers},
      turn_id: turn.id,
      execution_id: turn.root_execution_id
    })
  end

  defp covering_rows(athanor_id, %Turn{} = turn) do
    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.turn_id == ^turn.id,
      where: m.kind == "turn_aborted",
      order_by: [asc: m.seq]
    )
    |> Arca.Repo.all()
    |> Enum.map(fn row ->
      covers =
        row
        |> Arca.ThreadStorage.payload()
        |> Map.get("covers", [])
        |> Enum.map(&{&1["step_id"], &1["generation"]})

      %{seq: row.seq, covers: covers}
    end)
    |> Enum.reject(&(&1.covers == []))
  end

  defp uncovered_uncertain(athanor_id, %Turn{} = turn) do
    covered =
      athanor_id
      |> covering_rows(turn)
      |> Enum.flat_map(& &1.covers)
      |> MapSet.new()

    from(s in TurnStep,
      where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
      where: s.dispatch_state == "uncertain",
      select: {s.id, s.generation}
    )
    |> Arca.Repo.all()
    |> Enum.reject(&MapSet.member?(covered, &1))
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  @doc """
  Record one step of a turn at the next `seq`. `attrs`: `:kind`,
  `:purpose` (default `chat`), `:tool`, `:action`, `:idempotency_key`, `:authority_digest`,
  `:request_digest`, `:recovery`, `:excluded` (a list), `:message_id`,
  `:child_execution_id`, `:dispatch_state`
  (`Prima.TurnState.opening_states/0`, default `proposed`), `:fence`,
  and the read threads the step opens with: `:threads` (thread ids) and
  `:threads_from` (the ids of the athanor's turns whose words the rows
  the step sends carry, each turn's read threads joined as it stands; a
  turn not found adds nothing), and `:call`:
  the row the step carries its call in (`:kind`, `:content`, `:payload`,
  `:client_id`), written in the same transaction as a row of the turn's
  thread with the turn's agent as its sender, and named by the step's
  `message_id` (a page's call the host proposes, `page_call`). A step is
  recorded on a running turn only; any other state or turn is
  `{:error, :illegal_transition}`. A step named by a page's call whose
  request ended (`end_call/4`) is `{:error, :call_ended}`.
  """
  @spec put_step(Prima.Actor.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put_step(%Prima.Actor{athanor_id: athanor_id} = actor, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.put_step", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        if turn.status != "running", do: Arca.Repo.rollback(:illegal_transition)

        if Map.get(attrs, :dispatch_state, "proposed") not in Prima.TurnState.opening_states(),
          do: Arca.Repo.rollback(:illegal_transition)

        if ended_call?(athanor_id, attrs), do: Arca.Repo.rollback(:call_ended)

        turn = join_threads!(athanor_id, turn, opened_threads!(athanor_id, attrs))
        step = insert_step!(athanor_id, turn, carried!(actor, athanor_id, turn, attrs))
        :ok = consumed!(athanor_id, turn, step)
        step
      end)
    end)
    |> Arca.Data.project()
  end

  def put_step(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  # Whether the row a step is named by is a page's call whose request
  # ended, read under the turn's lock `end_call/4` takes too.
  # arca:db-raise-ok inside the caller's transaction
  defp ended_call?(athanor_id, %{message_id: id}) when is_binary(id) do
    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.id == ^id,
      where: m.kind == "page_call" and not is_nil(m.resolved_at)
    )
    |> Arca.Repo.exists?()
  end

  defp ended_call?(_athanor_id, _attrs), do: false

  # The row a step's call is carried in, when the step brings its own.
  # arca:db-raise-ok inside the caller's transaction
  defp carried!(actor, athanor_id, %Turn{} = turn, %{call: %{} = call} = attrs) do
    row = call_row!(actor, athanor_id, turn, call)
    attrs |> Map.delete(:call) |> Map.put(:message_id, row.id)
  end

  defp carried!(_actor, _athanor_id, _turn, attrs), do: attrs

  # arca:db-raise-ok inside the caller's transaction
  defp call_row!(actor, athanor_id, %Turn{} = turn, call) do
    Arca.ThreadStorage.insert_message!(actor, thread!(athanor_id, turn.thread_id), %{
      author: Message.agent_author(),
      sent_by: turn.agent,
      kind: Map.fetch!(call, :kind),
      content: Map.get(call, :content, ""),
      payload: Map.get(call, :payload),
      client_id: Map.get(call, :client_id),
      turn_id: turn.id,
      execution_id: turn.root_execution_id
    })
  end

  @doc """
  Flip a proposed step to `dispatched` in its own commit. Answers the
  step, or `{:error, :not_proposed}` when it was not proposed (dispatched
  already, closed, or cancel-requested).
  """
  @spec dispatch_step(Prima.Actor.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def dispatch_step(actor, step_id, attrs \\ %{})

  def dispatch_step(%Prima.Actor{athanor_id: athanor_id}, step_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.dispatch_step", fn ->
      Arca.Repo.locking_transaction(fn ->
        _ = own_step!(athanor_id, step_id, attrs)

        {count, _} =
          from(s in TurnStep,
            where: s.athanor_id == ^athanor_id and s.id == ^step_id,
            where: s.dispatch_state == "proposed" and is_nil(s.cancel_requested_at)
          )
          |> Arca.Repo.update_all(
            set: [dispatch_state: "dispatched", started_at: DateTime.utc_now()]
          )

        if count != 1, do: Arca.Repo.rollback(:not_proposed)
        step!(athanor_id, step_id)
      end)
    end)
    |> Arca.Data.project()
  end

  def dispatch_step(%Prima.Actor{}, _step_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Close a step with its result: the `tool_result` row, the step's
  `outcome`, `execution_id` and error, and the `step.closed` event, in
  one transaction. `attrs`: `:result` (`%{content, payload}` for the
  row, which names the call it answers, its `tool_call_id` and `name`,
  as the call's row does where the payload gives none, and its `status`
  where it has one, `proposed` for a result that waits on the person;
  omitted for a step that produced none), `:execution_id`, `:error`,
  `:fence`, `:threads`, the ids of the threads whose posts the result
  carries, joined into the turn's read threads in the same transaction
  and recorded on the result row as its payload's `threads`. A step
  closes from `dispatched`, or from `proposed` for `denied` and
  `skipped`.
  """
  @spec close_step(Prima.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, %{step: map(), result: map() | nil}} | {:error, term()}
  def close_step(actor, step_id, outcome, attrs \\ %{})

  def close_step(%Prima.Actor{athanor_id: athanor_id} = actor, step_id, outcome, attrs)
      when is_binary(athanor_id) and athanor_id != "" and outcome in @outcomes do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.close_step", fn ->
      with_seq_retry(fn ->
        Arca.Repo.locking_transaction(fn ->
          turn = own_step!(athanor_id, step_id, attrs)
          step = step!(athanor_id, step_id)
          close_step!(actor, athanor_id, turn, step, outcome, attrs)
        end)
      end)
    end)
    |> Arca.Data.project()
  end

  def close_step(%Prima.Actor{}, _step_id, _outcome, _attrs), do: {:error, :no_athanor}

  @doc """
  Forget the brain's session of the turn's thread, which its program
  reported gone (`Aqua.Harness.Program`) or the turn's program row is no longer
  the one it is stored with (`Aqua.Loop`):
  `brain_session` is cleared and `brain_generation` raised in one
  statement, as `Arca.ThreadStorage.forget_sessions/2` forgets a home's,
  and only while the thread is at `:generation`, the one the turn read.
  `attrs`: `:fence` (the turn's) and `:generation`, both required.
  Answers the generation the turn keeps a session under from here: the
  raised one, so the session its next start opens is kept, or the one
  it read when the thread was forgotten meanwhile, under which nothing it
  answers with is kept.

  The program's word speaks for the folder of the row it ran on, the
  turn's `program`. A session stored with
  another row (`brain_progress`'s `row`), its agent's program moved
  since, may still have its transcript there, and is owed its removal
  first, in the same transaction (`Arca.ThreadStorage.owe_forgets!/2`);
  one stored with the turn's own row is absent from its folder, and owes
  nothing.
  """
  @spec forget_session(Prima.Actor.t(), String.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def forget_session(%Prima.Actor{athanor_id: athanor_id} = actor, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.forget_session", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        generation = Map.get(attrs, :generation)
        if not is_integer(generation), do: Arca.Repo.rollback(:generation_required)
        thread = locked_thread!(athanor_id, turn.thread_id)

        if thread.brain_generation == generation and progress(thread)["row"] != turn.program,
          do: _owed = Arca.ThreadStorage.owe_forgets!(actor, [thread])

        # The comparison is the statement's own, so a forget committed
        # after the turn read the thread still holds.
        {forgotten, _} =
          from(c in Thread,
            where: c.athanor_id == ^athanor_id and c.id == ^turn.thread_id,
            where: c.brain_generation == ^generation
          )
          |> Arca.Repo.update_all(set: [brain_session: nil], inc: [brain_generation: 1])

        generation + forgotten
      end)
    end)
    |> Arca.Data.project()
  end

  def forget_session(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Mark a dispatched step as `uncertain`: its effect may have happened and
  its result is not known. `attrs`: `:fence` (the turn's, required) and
  `:generation` (the step's, required), so a superseded runner or a stale
  generation marks nothing. Answers `{:error, :not_dispatched}` for a
  step in any other state. Event `step.uncertain`.
  """
  @spec mark_step_uncertain(Prima.Actor.t(), String.t(), String.t() | nil, map()) ::
          {:ok, map()} | {:error, term()}
  def mark_step_uncertain(%Prima.Actor{athanor_id: athanor_id}, step_id, reason, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.mark_step_uncertain", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own_step!(athanor_id, step_id, attrs)
        step = step!(athanor_id, step_id)
        mark_uncertain!(athanor_id, turn, step, Map.fetch!(attrs, :generation), reason)
        step!(athanor_id, step_id)
      end)
    end)
    |> Arca.Data.project()
  end

  def mark_step_uncertain(%Prima.Actor{}, _step_id, _reason, _attrs), do: {:error, :no_athanor}

  # A dispatched step no runner will answer, by `TurnStep.unresolved/1`.
  # A closed call with no result row reads to the model as an unknown
  # outcome (`Aqua.Loop.Request`).
  # arca:db-raise-ok inside the caller's transaction
  # A delivery to a program brain is no call whose outcome is unknown: it
  # stays dispatched for the attendant to reconcile with what the resumed
  # transcript holds (`reconcile_brain/3`).
  defp settle_unresolved!(_actor, _athanor_id, _turn, %TurnStep{kind: "input"}, _reason), do: :ok

  defp settle_unresolved!(actor, athanor_id, %Turn{} = turn, %TurnStep{} = step, reason) do
    case TurnStep.unresolved(step) do
      :uncertain ->
        mark_uncertain!(athanor_id, turn, step, step.generation, reason)

      :unknown ->
        close_step!(actor, athanor_id, turn, step, "uncertain", %{error: reason})

      _unanswered_or_replay ->
        close_step!(actor, athanor_id, turn, step, "error", %{error: reason})
    end
  end

  # arca:db-raise-ok inside the caller's transaction
  defp mark_uncertain!(athanor_id, %Turn{} = turn, %TurnStep{} = step, generation, reason) do
    {count, _} =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.id == ^step.id,
        where: s.dispatch_state == "dispatched" and s.generation == ^generation
      )
      |> Arca.Repo.update_all(
        set: [
          dispatch_state: "uncertain",
          outcome: "uncertain",
          error: reason,
          ended_at: DateTime.utc_now()
        ]
      )

    if count != 1, do: Arca.Repo.rollback(:not_dispatched)
    event!(athanor_id, turn, "step.uncertain", step.id, %{"reason" => reason})
    :ok
  end

  @doc """
  Close every unstarted step of a turn as `skipped` with a synthetic
  result; with `attrs[:only]`, the ids of the steps to skip, those of
  them still unstarted and no other. Answers the steps skipped.
  """
  @spec skip_steps(Prima.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, [map()]} | {:error, term()}
  def skip_steps(actor, turn_id, reason, attrs \\ %{})

  def skip_steps(%Prima.Actor{athanor_id: athanor_id} = actor, turn_id, reason, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(reason) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.skip_steps", fn ->
      with_seq_retry(fn ->
        Arca.Repo.locking_transaction(fn ->
          turn = own!(athanor_id, turn_id, attrs)
          work_lock!(athanor_id, turn)
          skip_proposed!(actor, athanor_id, turn, reason, Map.get(attrs, :only))
        end)
      end)
    end)
    |> Arca.Data.project()
  end

  def skip_steps(%Prima.Actor{}, _turn_id, _reason, _attrs), do: {:error, :no_athanor}

  @doc """
  The page's call `request` in thread `thread_id` ended unanswered,
  however it ended: its `page_call` row records the end (`resolved_at`),
  and its step, while still proposed, is skipped with `reason`, in one
  transaction under its turn's lock. From
  then on no step of that call is recorded (`put_step/3` refuses
  `{:error, :call_ended}`) and none is dispatched, since none stays
  proposed: whichever of the end, a step's recording and its dispatch
  takes the turn's lock first, the others read what it wrote. The end is
  no transition of the turn, so it holds no fence. Answers the call's
  turn and the steps skipped, or `nil` for a request with no row, a call
  that waits in its runner and is no step yet.
  """
  @spec end_call(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{turn_id: String.t(), skipped: [map()]} | nil} | {:error, term()}
  def end_call(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id, request, reason)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and
             is_binary(request) and is_binary(reason) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.end_call", fn ->
      with_seq_retry(fn ->
        Arca.Repo.locking_transaction(fn ->
          case call_row(athanor_id, thread_id, request) do
            nil -> nil
            row -> end_call!(actor, athanor_id, row, reason)
          end
        end)
      end)
    end)
    |> Arca.Data.project()
  end

  def end_call(%Prima.Actor{}, _thread_id, _request, _reason), do: {:error, :no_athanor}

  # A page's call's row in its thread, named by its request.
  # arca:db-raise-ok inside the caller's transaction
  defp call_row(athanor_id, thread_id, request) do
    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.thread_id == ^thread_id,
      where: m.client_id == ^request and m.kind == "page_call"
    )
    |> Arca.Repo.one()
  end

  # The turn a call's row opened, or the one it is a step of, locked; the
  # row marked ended; its proposed step skipped.
  # arca:db-raise-ok inside the caller's transaction
  defp end_call!(actor, athanor_id, %Message{} = row, reason) do
    turn = locked_turn!(athanor_id, call_turn_id(athanor_id, row))
    work_lock!(athanor_id, turn)

    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.id == ^row.id and is_nil(m.resolved_at)
    )
    |> Arca.Repo.update_all(set: [resolved_at: DateTime.utc_now()])

    proposed =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
        where: s.message_id == ^row.id and s.dispatch_state == "proposed",
        select: s.id
      )
      |> Arca.Repo.all()

    skipped =
      if proposed == [], do: [], else: skip_proposed!(actor, athanor_id, turn, reason, proposed)

    %{turn_id: turn.id, skipped: skipped}
  end

  defp call_turn_id(athanor_id, %Message{id: id, turn_id: turn_id}) do
    Arca.Repo.one(
      from(t in Turn, where: t.athanor_id == ^athanor_id and t.message_id == ^id, select: t.id)
    ) || turn_id || Arca.Repo.rollback(:turn_not_found)
  end

  # A turn's row, held until the caller's transaction ends, whoever holds
  # the turn.
  # arca:db-raise-ok inside the caller's transaction
  defp locked_turn!(athanor_id, turn_id) do
    from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> case do
      nil -> Arca.Repo.rollback(:turn_not_found)
      turn -> turn
    end
  end

  # arca:db-raise-ok inside the caller's transaction
  defp skip_proposed!(actor, athanor_id, %Turn{} = turn, reason, only \\ nil) do
    steps =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
        where: s.dispatch_state == "proposed" and s.kind != "input",
        order_by: [asc: s.seq]
      )
      |> only_steps(only)
      |> Arca.Repo.all()

    Enum.map(steps, fn step ->
      %{step: closed} =
        close_step!(actor, athanor_id, turn, step, "skipped", %{
          result: %{content: reason, payload: %{"skipped" => true}}
        })

      closed
    end)
    |> tap(fn _skipped -> settled!(athanor_id, turn.thread_id) end)
  end

  @doc """
  Rewrite a step's bookkeeping (`:excluded`, `:request_digest`, `:error`,
  `:authority_digest`) under `:fence`, on a turn that is not over
  (`{:error, :not_open}` otherwise). Answers the rows written.
  """
  @spec update_step(Prima.Actor.t(), String.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def update_step(%Prima.Actor{athanor_id: athanor_id}, step_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.update_step", fn ->
      sets =
        attrs
        |> Map.take([:excluded, :request_digest, :error, :authority_digest])
        |> Enum.map(fn
          {:excluded, list} -> {:excluded, encode(list)}
          other -> other
        end)

      Arca.Repo.locking_transaction(fn ->
        _ = open!(own_step!(athanor_id, step_id, attrs))

        from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step_id)
        |> Arca.Repo.update_all(set: sets)
        |> elem(0)
      end)
    end)
    |> Arca.Data.project()
  end

  def update_step(%Prima.Actor{}, _step_id, _attrs), do: {:error, :no_athanor}

  @doc """
  The step barrier, run inside admission's transaction: bind the child
  execution to its step while the step is dispatched, on this generation,
  not cancel-requested, and the child id is the one the step pre-minted.
  Answers the rows bound — 0 when admission must abort.
  """
  @spec bind_child!(Prima.Actor.t(), String.t(), non_neg_integer(), String.t()) ::
          non_neg_integer()
  # arca:db-raise-ok inside the caller's transaction
  def bind_child!(%Prima.Actor{athanor_id: athanor_id}, step_id, generation, execution_id)
      when is_binary(athanor_id) and athanor_id != "" do
    {count, _} =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.id == ^step_id,
        where: s.generation == ^generation and s.dispatch_state == "dispatched",
        where: is_nil(s.cancel_requested_at) and s.child_execution_id == ^execution_id
      )
      |> Arca.Repo.update_all(set: [execution_id: execution_id])

    count
  end

  def bind_child!(%Prima.Actor{}, _step_id, _generation, _execution_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.bind_child!/4")

  @doc """
  Open the next generation of a step for a replay-safe re-dispatch: the
  old generation is cancel-marked so its late admission is refused, and
  the step returns to `proposed` with `generation + 1` and a fresh child
  execution id. `attrs`: `:child_execution_id`, `:fence`. Only a
  `dispatched` step is opened again (`{:error, :not_dispatched}`
  otherwise), and only one its stored row calls a replay
  (`Prima.TurnStep.unresolved/1`; `{:error, :illegal_transition}`
  otherwise) — the caller's reading of the step decides nothing. Answers
  the step.
  """
  @spec next_generation(Prima.Actor.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def next_generation(%Prima.Actor{athanor_id: athanor_id}, step_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.next_generation", fn ->
      Arca.Repo.locking_transaction(fn ->
        _ = own_step!(athanor_id, step_id, attrs)
        step = step!(athanor_id, step_id)
        if step.dispatch_state != "dispatched", do: Arca.Repo.rollback(:not_dispatched)

        if TurnStep.unresolved(step) != :replay,
          do: Arca.Repo.rollback(:illegal_transition)

        {1, _} =
          from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step_id)
          |> Arca.Repo.update_all(
            set: [
              generation: step.generation + 1,
              dispatch_state: "proposed",
              cancel_requested_at: nil,
              child_execution_id: Map.fetch!(attrs, :child_execution_id),
              execution_id: nil,
              started_at: nil
            ]
          )

        step!(athanor_id, step_id)
      end)
    end)
    |> Arca.Data.project()
  end

  def next_generation(%Prima.Actor{}, _step_id, _attrs), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # Read threads
  # ---------------------------------------------------------------------------

  @doc """
  The read threads of the turns whose root execution is
  `root_execution_id`, sorted and without duplicates. `{:ok, []}` when no
  turn of the caller's athanor runs on that execution.
  """
  @spec chain_threads(Prima.Actor.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def chain_threads(%Prima.Actor{athanor_id: athanor_id} = actor, root_execution_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(root_execution_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.chain_threads", fn ->
      {:ok, chain_threads!(actor, root_execution_id)}
    end)
  end

  def chain_threads(%Prima.Actor{}, _root_execution_id), do: {:error, :no_athanor}

  @doc """
  `chain_threads/2` inside the caller's transaction, raising as the
  transaction's own reads do.
  """
  @spec chain_threads!(Prima.Actor.t(), String.t()) :: [String.t()]
  # arca:db-raise-ok inside the caller's transaction
  def chain_threads!(%Prima.Actor{athanor_id: athanor_id}, root_execution_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(root_execution_id) do
    from(t in Turn,
      where: t.athanor_id == ^athanor_id and t.root_execution_id == ^root_execution_id,
      select: t.read_threads
    )
    |> Arca.Repo.all()
    |> Enum.flat_map(&Arca.ThreadStorage.threads_of/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def chain_threads!(%Prima.Actor{}, _root_execution_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.chain_threads!/2")

  @doc """
  The read threads of the turn the step `step_id` belongs to, as they
  stand inside the caller's transaction: `{:ok, threads}` when that turn
  runs on `root_execution_id`, `:none` for a step of no turn on it. What a
  child a loop step admits under a turn root starts from: the step's own
  turn, with every thread its step opened with already joined.
  """
  @spec step_threads!(Prima.Actor.t(), String.t(), String.t()) :: {:ok, [String.t()]} | :none
  # arca:db-raise-ok inside the caller's transaction
  def step_threads!(%Prima.Actor{athanor_id: athanor_id}, step_id, root_execution_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(step_id) and
             is_binary(root_execution_id) do
    from(s in TurnStep,
      join: t in Turn,
      on: t.id == s.turn_id and t.athanor_id == s.athanor_id,
      where: s.athanor_id == ^athanor_id and s.id == ^step_id,
      where: t.root_execution_id == ^root_execution_id,
      select: t.read_threads
    )
    |> Arca.Repo.one()
    |> case do
      nil -> :none
      stored -> {:ok, Arca.ThreadStorage.threads_of(stored)}
    end
  end

  def step_threads!(%Prima.Actor{}, _step_id, _root_execution_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.step_threads!/3")

  @doc """
  Join the thread ids `threads` into the turn `turn_id`'s read threads,
  under the turn's row lock and only while the caller still holds the
  turn at `attrs[:fence]` (`{:error, :superseded}` otherwise): what a
  model or hand child's read threads bring into its turn before the turn
  uses its answer. The list only grows.
  """
  @spec join_threads(Prima.Actor.t(), String.t(), [String.t()], map()) ::
          :ok | {:error, term()}
  def join_threads(%Prima.Actor{athanor_id: athanor_id}, turn_id, threads, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) and
             is_list(threads) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.join_threads", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        _turn = join_threads!(athanor_id, turn, threads!(threads))
        :ok
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def join_threads(%Prima.Actor{}, _turn_id, _threads, _attrs), do: {:error, :no_athanor}

  @doc """
  Of the posts `ids`, those a program refused: carried by an `input` step
  closed `error`, which is a delivery the driver said it did not write.
  A delivery still dispatched or closed `uncertain` is none, and neither
  is a post whose carrier is a model step, however that step ended.
  """
  @spec refused_posts(Prima.Actor.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def refused_posts(%Prima.Actor{athanor_id: athanor_id}, ids)
      when is_binary(athanor_id) and athanor_id != "" and is_list(ids) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.refused_posts", fn ->
      {:ok,
       Arca.Repo.all(
         from(m in Message,
           join: s in TurnStep,
           on: s.id == m.carried_by and s.athanor_id == m.athanor_id,
           where: m.athanor_id == ^athanor_id and m.id in ^ids,
           where: s.kind == "input" and s.dispatch_state == "closed" and s.outcome == "error",
           select: m.id
         )
       )}
    end)
  end

  def refused_posts(%Prima.Actor{}, _ids), do: {:error, :no_athanor}

  @typedoc """
  What a row says in its owner's grammar (`join_read/3`'s `also:`): the
  threads it names, the read threads copied into it (a report's kept, a
  copied file's), the turns whose words it carries (`from`) and, for an
  opening, the posts it cites and their thread.
  """
  @type said :: %{
          names: [String.t()],
          copies: [String.t()],
          from: [String.t()],
          cites: %{thread: String.t(), posts: [String.t()]} | nil
        }

  @doc """
  The one decision of what a turn reads of the athanor's threads, made and
  recorded before it is read (a request's rows, a program's post and
  context, `thread.search`, `thread.events`): under the turn's row lock
  and only while the caller still holds the turn at `attrs[:fence]` and
  the turn is open.

  `attrs[:rows]` are ids alone. The athanor's row is held first, which a
  deletion takes first too, and then each row is read once, as it stands:
  the text handed over, what it depends on and what it cites are that one
  version's, so nothing a deletion removed or blanked, and no source list
  older than its text, is handed over from an earlier reading. What a row
  says of itself is its owner's to read: `attrs[:also]` answers it
  (`t:said/0`) from that row, reading nothing else and writing nothing.

  A row depends on the threads it names, the read threads copied into it,
  those of the turns whose words it is (`from`, and its own turn when
  that turn wrote it: a post written into a turn, a person's among them,
  is not the turn's words, `post?/2`), a reply also on the thread of the
  turn it came from, which is its helper's, and, when it is brought in,
  on its own thread.

    * A row of the turn's own thread, read as its history
      (`attrs[:history?]`), is handed over as it now reads. A deletion
      takes with it the rows that name the deleted workspace thread and
      the summaries made of what it held.
    * A row brought in (a citation, and all a reread or a search answers)
      is handed over only when every thread it depends on stands and
      every turn it came from is still there, as a turn goes only with
      its thread. Of those, `attrs[:most]` are handed over at most, the
      first in order.
    * A citation (`attrs[:cite?]`) is a post (`Arca.ThreadStorage.post?/1`)
      of the thread its opening names, and counts only with an opening
      handed over that quotes it.

  What joins is the threads `attrs[:read]` names, which the turn asked to
  read, and what the rows handed over depend on, each while it stands.
  Only the read threads copied into a row of the turn's own history join
  as stored, standing or not, since those words are the thread's to keep.
  A row not handed over records nothing, and neither does its citation.

  Answers the rows handed over, in their order (`rows`), the posts they
  cite (`cited`), the open turns of the threads asked for and cited, as
  they stood before those threads' posts were read (`open`), the ids of `attrs[:read]` that stood (`threads`), and every
  id the read joined (`read_threads`). A thread deleted before this takes
  its row is not among them; one deleted after finds this turn by its
  read threads, as a deletion finds every turn that read it.
  `{:error, :superseded}` for a caller whose fence moved,
  `{:error, :not_open}` for a turn that ended.
  """
  @spec join_read(Prima.Actor.t(), String.t(), map()) ::
          {:ok,
           %{
             rows: [map()],
             cited: [map()],
             open: [String.t()],
             threads: [String.t()],
             read_threads: [String.t()]
           }}
          | {:error, term()}
  def join_read(%Prima.Actor{athanor_id: athanor_id} = actor, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.join_read", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)

        unless turn.status in Prima.TurnState.open_statuses(),
          do: Arca.Repo.rollback(:not_open)

        also = Map.fetch!(attrs, :also)
        read = threads!(Map.get(attrs, :read, []))
        history? = Map.get(attrs, :history?, false)
        # The athanor's row alone, before any row is read: the threads
        # follow in their one order once the rows say which they are.
        [] = Arca.ThreadStorage.lock_threads!(actor, [])
        # Each thread's open turns are read before its posts are: a turn
        # that ends meanwhile still reads open, so a post it took is never
        # read as not taken.
        open = open_in!(athanor_id, read)

        asked =
          sources!(
            athanor_id,
            for row <- rows_now!(athanor_id, Map.get(attrs, :rows, [])) do
              {row, history? and row.thread_id == turn.thread_id}
            end,
            also
          )

        citing = if Map.get(attrs, :cite?, false), do: Enum.filter(asked, & &1.cites), else: []
        open = open ++ open_in!(athanor_id, Enum.uniq(Enum.map(citing, & &1.cites.thread)))
        quoted = quoted!(athanor_id, citing)
        quotable = quoted |> Map.values() |> Enum.concat() |> Enum.uniq_by(& &1.id)
        citations = sources!(athanor_id, Enum.map(quotable, &{&1, false}), also)
        wanted = Enum.uniq(read ++ Enum.flat_map(asked ++ citations, & &1.depends))

        standing =
          MapSet.new(Arca.ThreadStorage.lock_threads!(actor, wanted), & &1.id)

        handed = asked |> Enum.filter(&handed?(&1, standing)) |> at_most(Map.get(attrs, :most))
        quoting = for %{row: row} <- handed, post <- Map.get(quoted, row.id, []), do: post.id

        cited = Enum.filter(citations, &(&1.row.id in quoting and handed?(&1, standing)))

        needed = read ++ Enum.flat_map(handed ++ cited, & &1.depends)
        stored = for %{held?: true, copies: copies} <- handed, id <- copies, do: id
        joined = Enum.filter(needed, &(&1 in standing)) ++ threads!(stored)
        _turn = join_threads!(athanor_id, turn, joined)

        %{
          rows: Enum.map(handed, & &1.row),
          cited: Enum.map(cited, & &1.row),
          open: Enum.uniq(open),
          threads: Enum.filter(read, &(&1 in standing)),
          read_threads: joined |> Enum.uniq() |> Enum.sort()
        }
      end)
    end)
    |> Arca.Data.project()
  end

  def join_read(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  # Each row as `join_read/3` judges it, all of it from the one version of
  # the row it is given.
  # arca:db-raise-ok inside the caller's transaction
  defp sources!(athanor_id, placed, also) do
    said = for {row, held?} <- placed, do: {row, held?, also.(row)}

    turns =
      said
      |> Enum.flat_map(fn {row, _held?, %{from: from}} -> [row.turn_id | from] end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.chunk_every(@ids_per_statement)
      |> Enum.flat_map(fn ids ->
        Arca.Repo.all(
          from(t in Turn,
            where: t.athanor_id == ^athanor_id and t.id in ^ids,
            select: {t.id, {t.agent, t.thread_id, t.read_threads}}
          )
        )
      end)
      |> Map.new(fn {id, {agent, thread, read}} ->
        {id, {agent, thread, Arca.ThreadStorage.threads_of(read)}}
      end)

    for {row, held?, says} <- said do
      wrote =
        case turns[row.turn_id] do
          {agent, _thread, read} -> if post?(row, agent), do: [], else: read
          nil -> []
        end

      came = Enum.map(says.from, &turns[&1])
      carried = for {_agent, _thread, read} <- came, id <- read, do: id
      reply? = is_binary(row.reply_to)
      helper = for {_agent, thread, _read} <- came, reply?, do: thread
      own = if held?, do: [], else: [row.thread_id]

      %{
        row: row,
        held?: held?,
        lost?: nil in came,
        copies: says.copies,
        cites: says.cites,
        depends: threads!(own ++ says.names ++ says.copies ++ wrote ++ carried ++ helper)
      }
    end
  end

  defp handed?(%{held?: true}, _standing), do: true
  defp handed?(%{lost?: true}, _standing), do: false
  defp handed?(%{depends: depends}, standing), do: Enum.all?(depends, &(&1 in standing))

  defp at_most(handed, nil), do: handed
  defp at_most(handed, most) when is_integer(most), do: Enum.take(handed, most)

  # By opening id, the posts it cites of the thread it names, as they
  # stand: a person's, an agent's and the server's alike.
  # arca:db-raise-ok inside the caller's transaction
  defp quoted!(athanor_id, sources) do
    citing = for %{row: row, cites: cites} <- sources, do: {row.id, cites}
    ids = citing |> Enum.flat_map(fn {_id, cites} -> cites.posts end) |> Enum.uniq()
    posts = Map.new(rows_now!(athanor_id, ids), &{&1.id, &1})

    Map.new(citing, fn {id, %{thread: thread, posts: cited}} ->
      {id,
       for(
         post_id <- cited,
         %{thread_id: ^thread} = post <- [posts[post_id]],
         Arca.ThreadStorage.post?(post),
         do: post
       )}
    end)
  end

  # The rows of `ids` as they stand, in that order.
  # arca:db-raise-ok inside the caller's transaction
  defp rows_now!(athanor_id, ids) do
    now =
      ids
      |> Enum.chunk_every(@ids_per_statement)
      |> Enum.flat_map(fn ids ->
        Arca.Repo.all(from(m in Message, where: m.athanor_id == ^athanor_id and m.id in ^ids))
      end)
      |> Map.new(&{&1.id, &1})

    for id <- ids, row = now[id], do: row
  end

  # arca:db-raise-ok inside the caller's transaction
  defp open_in!(_athanor_id, []), do: []

  defp open_in!(athanor_id, threads) do
    Arca.Repo.all(
      from(t in Turn,
        where: t.athanor_id == ^athanor_id and t.thread_id in ^threads,
        where: t.status in ^@open,
        select: t.id
      )
    )
  end

  @doc """
  Whether the caller still holds the turn `turn_id`, open, at `fence`,
  asked inside the caller's own transaction and holding the turn's row
  until it ends: `:ok`, `{:error, :superseded}` for a fence that moved and
  `{:error, :not_open}` for a turn that ended. It writes nothing and rolls
  nothing back, so a publication's owner check (`Arca.FencedPublication`'s
  `verify:`) answers with it where the publication commits, taking the
  turn's row first, before the publication's own locks.
  """
  @spec hold(Prima.Actor.t(), String.t(), non_neg_integer()) ::
          :ok | {:error, :superseded | :not_open}
  # arca:db-raise-ok inside the caller's transaction
  def hold(%Prima.Actor{athanor_id: athanor_id}, turn_id, fence)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) and
             is_integer(fence) do
    case from(t in Turn,
           where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.fence == ^fence
         )
         |> Arca.Repo.update_all(set: [fence: fence]) do
      {1, _} ->
        if turn!(athanor_id, turn_id).status in @open, do: :ok, else: {:error, :not_open}

      {0, _} ->
        {:error, :superseded}
    end
  end

  def hold(%Prima.Actor{}, _turn_id, _fence),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.hold/3")

  @doc """
  Write the notes of the workspace thread the turn `turn_id` runs in:
  `notes`, the bytes `Aqua.Notes` encodes, or nil to clear them, under
  the turn's row lock and only while the caller still holds the turn at
  `attrs[:fence]` and the turn is open. The turn names the thread, so no
  caller names another. `{:error, :not_a_workspace}` for a turn of any
  other kind of thread; `{:error, :superseded}` and `{:error, :not_open}`
  as `join_read/3`.
  """
  @spec write_notes(Prima.Actor.t(), String.t(), String.t() | nil, map()) ::
          :ok | {:error, term()}
  def write_notes(%Prima.Actor{athanor_id: athanor_id}, turn_id, notes, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) and
             (is_binary(notes) or is_nil(notes)) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.write_notes", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)

        unless turn.status in Prima.TurnState.open_statuses(),
          do: Arca.Repo.rollback(:not_open)

        case from(c in Thread,
               where: c.athanor_id == ^athanor_id and c.id == ^turn.thread_id,
               where: c.kind == "workspace"
             )
             |> Arca.Repo.update_all(set: [notes: notes]) do
          {1, _} -> :ok
          {0, _} -> Arca.Repo.rollback(:not_a_workspace)
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def write_notes(%Prima.Actor{}, _turn_id, _notes, _attrs), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # A turn's posts
  # ---------------------------------------------------------------------------

  # The kinds of row a turn's agent writes that are posts of a turn, never
  # its own words: a workspace thread's report, which Aqua writes on the
  # daily thread, opening a turn of Aqua's or joining the one that runs.
  @handed_in ~w(report)

  @doc """
  Whether `row`, of a turn whose agent is `agent`, is a post: written into
  the turn rather than by it. Every row a turn writes itself carries its
  agent as `sent_by`, so a row of any other sender is a post, and so is a
  report its agent wrote. What a turn takes in is read by this rule
  alone: what a model step carries (`consumed!/3`), a steer
  (`steer_rows/2`), a program's waiting posts (`brain_posts/2`), the
  projection and a post's place in it (`projection/2`), and a later
  post's files (`Aqua.Loop`).
  """
  @spec post?(map(), String.t()) :: boolean()
  def post?(%{sent_by: sent_by, kind: kind}, agent), do: sent_by != agent or kind in @handed_in

  # `post?/2` as a condition on a query's message.
  defp post(agent), do: dynamic([m], m.sent_by != ^agent or m.kind in ^@handed_in)

  # ---------------------------------------------------------------------------
  # The consumption boundary
  # ---------------------------------------------------------------------------

  @doc """
  Move the turn's boundary past every post attached to it that arrived
  while it worked and no step carried yet, and answer those rows in `seq`
  order: the steer the loop drains before its next model request, which
  its model step carries (`consumed!/3`). A post drained by a round that
  died before its step is drained again by the next, and the boundary
  never moves back: a post older than rows the turn already reads leaves
  them read. A turn that is over drains nothing (`{:error, :not_open}`).
  """
  @spec drain_steer(Prima.Actor.t(), String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def drain_steer(actor, turn_id, attrs \\ %{})

  def drain_steer(%Prima.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.drain_steer", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = open!(own!(athanor_id, turn_id, attrs))
        rows = steer_rows(athanor_id, turn)

        case rows do
          [] ->
            []

          rows ->
            newest = rows |> Enum.map(& &1.seq) |> Enum.max() |> max(turn.window_upto_seq || 0)

            {1, _} =
              from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
              |> Arca.Repo.update_all(set: [window_upto_seq: newest])

            rows
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def drain_steer(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Whether a post written into the turn after its opening waits for a step
  to carry it, past the boundary of a turn stopped on an uncertain call
  (`steer_rows/2`).
  """
  @spec steer_pending?(Prima.Actor.t(), String.t()) :: boolean() | {:error, term()}
  def steer_pending?(%Prima.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.steer_pending?", fn ->
      turn = turn!(athanor_id, turn_id)
      steer_rows(athanor_id, turn) != []
    end)
    |> Arca.Data.project()
  end

  def steer_pending?(%Prima.Actor{}, _turn_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.steer_pending?/2")

  @doc """
  The rows a turn may read, in the order it reads them: its own rows
  except an undrained steer, plus — behind its boundary — unattached rows
  and the rows of terminal turns of the thread. Rows attached to other
  open turns are never read, nor an opening still waiting for its own
  turn, whose ask is read under that turn's person, origin and
  restrictions alone.

  The order is `seq`'s, but for a post (`post?/2`), which stands where the model step that carried it placed it
  (`carried_by`, `consumed!/3`): right before the first answer, a reply or
  a call, of that step or of a later one of its turn. Every row that step's
  request held reads before it, the results of the calls open when it
  arrived among them, and no answer reads before it that did not read it.
  A post no model step carried yet stands after the rest of its turn, and
  in the turn read here after every row: its next round carries it. The
  server's mark of a restart (`turn_aborted`) stands before the next
  answer, after the results written since, so a call's results follow it.
  A post a program's `input` step carried stays where it arrived. Only
  rows move later, never earlier, so each turn's order is the one its last
  request held, with the newer rows after it.
  """
  @spec projection(Prima.Actor.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def projection(%Prima.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.projection", fn ->
      turn = turn!(athanor_id, turn_id)
      window = turn.window_upto_seq || 0
      settled = settled_turns(athanor_id, turn.thread_id)

      rows =
        Arca.Repo.all(
          from(m in Message,
            where: m.athanor_id == ^athanor_id and m.thread_id == ^turn.thread_id,
            # The turn's own rows and, once taken in, its posts (`post?/2`);
            # behind the boundary, unattached rows and settled turns' rows.
            where:
              (m.turn_id == ^turn_id and
                 ((m.sent_by == ^turn.agent and m.kind not in ^@handed_in) or m.seq <= ^window or
                    not is_nil(m.carried_by))) or
                (m.seq <= ^window and (is_nil(m.turn_id) or m.turn_id in subquery(settled))),
            where: not (m.kind == "opening" and is_nil(m.turn_id) and is_nil(m.status)),
            order_by: [asc: m.seq]
          )
        )

      {:ok, placed(athanor_id, turn_id, rows)}
    end)
    |> Arca.Data.project()
  end

  def projection(%Prima.Actor{}, _turn_id), do: {:error, :no_athanor}

  # `rows`, in `seq` order, as `projection/2` reads them: each held row (a
  # post, a restart's mark) leaves its place and waits for the first answer
  # of its turn that releases it, for a post an answer of a model step at
  # or after its carrier, for a mark any answer; one its turn never
  # releases follows that turn's last row that waits for nothing, or every
  # row in the turn read (`open`). A row of a settled turn with nothing of
  # its turn after it to wait for keeps its place.
  # arca:db-raise-ok inside the caller's transaction
  defp placed(_athanor_id, _open, []), do: []

  defp placed(athanor_id, open, rows) do
    agents = turn_agents(athanor_id, rows)
    steps = step_seqs(athanor_id, rows, agents)
    indexed = rows |> Enum.map(&{&1, waits(&1, agents, steps)}) |> Enum.with_index()
    last = for {{%{turn_id: id}, nil}, at} <- indexed, is_binary(id), into: %{}, do: {id, at}

    {out, held} =
      Enum.reduce(indexed, {[], %{}}, fn {{row, wait}, at}, {out, held} ->
        case held_from(wait, at, open, last) do
          {turn_id, from} ->
            {out, Map.update(held, turn_id, [{from, row}], &[{from, row} | &1])}

          nil ->
            emit(
              row,
              out,
              held,
              answer(row, agents, steps),
              open != row.turn_id and last[row.turn_id] == at
            )
        end
      end)

    Enum.reverse(
      out,
      held |> Map.values() |> Enum.concat() |> rows_of() |> Enum.sort_by(& &1.seq)
    )
  end

  # `row` read in its place, after the rows waiting in its turn that it
  # releases, and before the rest of them when it is a settled turn's last.
  defp emit(row, out, held, answer, last?) do
    {ready, held} = release(held, row.turn_id, answer)
    out = [row | ready ++ out]

    if last?,
      do: {rows_of(Map.get(held, row.turn_id, [])) ++ out, Map.delete(held, row.turn_id)},
      else: {out, held}
  end

  # A row waits in the turn read, and in a settled turn only while a row of
  # its turn that waits for nothing still follows it.
  defp held_from(nil, _at, _open, _last), do: nil
  defp held_from({open, _from} = wait, _at, open, _last), do: wait

  defp held_from({turn_id, _from} = wait, at, _open, last),
    do: if(Map.get(last, turn_id, -1) > at, do: wait)

  # The rows waiting in `turn_id` that an answer of its model step `at`
  # releases (a program's answer is 0), newest first as `placed/3` keeps
  # them.
  defp release(held, _turn_id, nil), do: {[], held}

  defp release(held, turn_id, at) do
    {ready, waiting} =
      held
      |> Map.get(turn_id, [])
      |> Enum.split_with(fn {from, _row} -> is_integer(from) and from <= at end)

    {rows_of(ready), Map.put(held, turn_id, waiting)}
  end

  defp rows_of(held), do: Enum.map(held, &elem(&1, 1))

  # Whether `row` waits, and from which step on: a post (`post?/2`), from
  # its carrier's seq (`:never` while no model step carried
  # it), and a restart's mark from the first answer; nil for every other
  # row, and for a post a program's `input` step carried.
  defp waits(%{turn_id: nil}, _agents, _steps), do: nil

  defp waits(%{kind: "turn_aborted"} = row, _agents, _steps), do: {row.turn_id, 0}

  defp waits(%{sent_by: sent_by} = row, agents, steps) when is_binary(sent_by) do
    cond do
      not post?(row, agents[row.turn_id]) -> nil
      is_nil(row.carried_by) -> {row.turn_id, :never}
      true -> carrier(row, steps)
    end
  end

  defp waits(_row, _agents, _steps), do: nil

  defp carrier(row, steps) do
    case steps[row.carried_by] do
      {"model", seq} -> {row.turn_id, seq}
      {_input, _seq} -> nil
      nil -> {row.turn_id, :never}
    end
  end

  # The seq of the model step whose answer `row` is, a reply or a call its
  # turn's agent wrote; 0 for one no model step wrote (a program's); nil
  # for any other row.
  defp answer(%{kind: kind, turn_id: turn_id, sent_by: sent_by} = row, agents, steps)
       when kind in ["text", "tool_call"] and is_binary(turn_id) do
    if sent_by == agents[turn_id] do
      case steps[step_id(row)] do
        {"model", seq} -> seq
        _none -> 0
      end
    end
  end

  defp answer(_row, _agents, _steps), do: nil

  defp step_id(%{payload: payload}) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"step_id" => id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp step_id(_row), do: nil

  # arca:db-raise-ok inside the caller's transaction
  defp turn_agents(athanor_id, rows) do
    ids = for %{turn_id: id} <- rows, is_binary(id), uniq: true, do: id

    from(t in Turn, where: t.athanor_id == ^athanor_id and t.id in ^ids, select: {t.id, t.agent})
    |> Arca.Repo.all()
    |> Map.new()
  end

  # The kind and seq of each step the rows name: the posts' carriers and the
  # model steps whose answers the agents' rows are.
  # arca:db-raise-ok inside the caller's transaction
  defp step_seqs(athanor_id, rows, agents) do
    ids =
      Enum.uniq(
        for(%{carried_by: id} <- rows, is_binary(id), do: id) ++
          for(
            row <- rows,
            row.kind in ["text", "tool_call"],
            row.sent_by == agents[row.turn_id],
            id = step_id(row),
            is_binary(id),
            do: id
          )
      )

    from(s in TurnStep,
      where: s.athanor_id == ^athanor_id and s.id in ^ids,
      select: {s.id, {s.kind, s.seq}}
    )
    |> Arca.Repo.all()
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # A program brain's session
  # ---------------------------------------------------------------------------

  # The kinds of row a program brain is delivered as a post: what a person,
  # the server or a crew member writes into a turn.
  @brain_posts ~w(text opening report nudge)
  # The result identities a session's usage is told apart by, the newest
  # kept: a resumed session repeats nothing (T1's probe), so these guard a
  # line handed again within one driver process.
  @counted_results 64

  @doc """
  The idempotency key of the step that admits a turn's harness: the
  engine gives it to the start a harness proposes (`Aqua.Loop`), a
  program's `program.start` of its row among them. An ask of a program
  for CYFR's own `program` tool is keyed apart (`brain_ask_key/2`), so
  the two are never confused.
  """
  @spec admission_key(String.t()) :: String.t()
  def admission_key(turn_id) when is_binary(turn_id), do: "brain:#{turn_id}:start"

  @doc "The idempotency key of the step an ask `ask` of a program brain is recorded as."
  @spec brain_ask_key(String.t(), String.t()) :: String.t()
  def brain_ask_key(turn_id, ask) when is_binary(turn_id) and is_binary(ask),
    do: "brain:#{turn_id}:ask:#{ask}"

  @doc """
  A program brain's session as its thread keeps it: `progress`, the
  thread's `brain_progress` map (`Arca.Schemas.Thread`, `%{}` for none),
  `session` and `generation`, and `now`, the database's clock.
  """
  @spec brain(Prima.Actor.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def brain(%Prima.Actor{athanor_id: athanor_id}, thread_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.brain", fn ->
      case Arca.Repo.get_by(Thread, id: thread_id, athanor_id: athanor_id) do
        nil ->
          {:error, :thread_not_found}

        thread ->
          {:ok,
           %{
             progress: progress(thread),
             session: thread.brain_session,
             generation: thread.brain_generation,
             now: Arca.ServerMetaStorage.now!()
           }}
      end
    end)
  end

  def brain(%Prima.Actor{}, _thread_id), do: {:error, :no_athanor}

  @doc """
  What the thread's native session was given, derived from its deliveries
  in the session's generation, whatever each carried (a post, a recovery
  prompt or an answer): `seq`, the seq of the row of the first delivery the
  program took (an `input` step closed `ok`) in the newest turn that has
  one, or nil for none, since that delivery carried the thread before it;
  and `taken`, the rows after it the program took. Nothing else counts as
  given: a delivery refused, uncertain or never sent leaves both where
  they were.
  """
  @spec brain_given(Prima.Actor.t(), String.t()) ::
          {:ok, %{seq: integer() | nil, taken: [String.t()]}} | {:error, term()}
  def brain_given(%Prima.Actor{athanor_id: athanor_id}, thread_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.brain_given", fn ->
      case Arca.Repo.get_by(Thread, id: thread_id, athanor_id: athanor_id) do
        nil -> {:error, :thread_not_found}
        thread -> {:ok, given(athanor_id, thread)}
      end
    end)
  end

  def brain_given(%Prima.Actor{}, _thread_id), do: {:error, :no_athanor}

  defp given(athanor_id, %Thread{} = thread) do
    taken =
      from(s in TurnStep,
        join: t in Turn,
        on: t.id == s.turn_id and t.athanor_id == s.athanor_id,
        join: m in Message,
        on: m.id == s.message_id and m.athanor_id == s.athanor_id,
        where: s.athanor_id == ^athanor_id and t.thread_id == ^thread.id,
        # A delivery's key names the generation it was carried in (`carry/3`).
        where: s.kind == "input" and like(s.idempotency_key, ^"#{thread.brain_generation}:%"),
        where: s.dispatch_state == "closed" and s.outcome == "ok",
        select: %{turn: t.id, accepted_at: t.accepted_at, seq: m.seq, row: m.id}
      )
      |> Arca.Repo.all()

    case taken do
      [] ->
        %{seq: nil, taken: []}

      taken ->
        # The newest turn, as a thread orders its turns (`latest/2`).
        newest = Enum.max_by(taken, &{&1.accepted_at, &1.turn}, &newer?/2).turn
        seq = taken |> Enum.filter(&(&1.turn == newest)) |> Enum.map(& &1.seq) |> Enum.min()

        %{
          seq: seq,
          taken: taken |> Enum.filter(&(&1.seq > seq)) |> Enum.map(& &1.row) |> Enum.uniq()
        }
    end
  end

  defp newer?({at, id}, {other_at, other_id}) do
    case DateTime.compare(at, other_at) do
      :gt -> true
      :lt -> false
      :eq -> id >= other_id
    end
  end

  @doc """
  Record one delivery to a program brain before its command is written:
  an `input` step, `dispatched`, whose id the command carries, so a
  delivery is attempted once whatever restarts follow. In one transaction
  under the turn's lock (`:fence`), which the round's drain, a step's
  close, the turn's end and a take-over take too, then its thread's:

    * the turn is running, or paused for a `post` or an `answer` of its
      own work (a paused turn's proof is narrow), else `:not_running`;
    * its `program.start` step (`admission_key/1`) was decided allow and
      is not asked to stop (`:not_admitted`), and the thread is at
      `:generation` (`:generation_moved`);
    * nothing was recorded under the delivery's key, the generation, what
      it delivers and the row's id (`:carried`);
    * `:row_id` is what `:deliver` delivers: for `"post"` a post of the
      turn that waits (none carried it, `:not_waiting`), which it marks
      `carried_by` the step; for `"answer"` the result row of an ask of
      the turn that closed (`:not_closed`); for `"notice"`, the recovery
      prompt, a post the turn carried or such a result row (running only).

  What the delivery brings in joined the turn's read threads before it
  was read (`join_read/3`). A post or a notice joins the posts owed an
  answer, and the silence clock runs over the delivery's acknowledgement,
  which the program owes (`brain_progress`). A notice leaves the recovery obligation it answers
  (`reconcile_brain/3`) where it stands until the driver answers for its
  write (`commit_events/3`) or a reconcile settles it; until then its step
  alone keeps another notice of its row from being offered
  (`brain_notices/2`).
  Answers `%{step: step, row: row}`.
  """
  @spec carry(Prima.Actor.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def carry(%Prima.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.carry", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        deliver = Map.fetch!(attrs, :deliver)
        carrying!(turn, deliver)
        admitted_start!(athanor_id, turn)
        thread = locked_thread!(athanor_id, turn.thread_id)
        generation = Map.fetch!(attrs, :generation)
        if thread.brain_generation != generation, do: Arca.Repo.rollback(:generation_moved)
        row_id = Map.fetch!(attrs, :row_id)
        key = "#{generation}:#{deliver}:#{row_id}"

        if Arca.Repo.exists?(
             from(s in TurnStep,
               where: s.athanor_id == ^athanor_id and s.idempotency_key == ^key,
               where: s.kind == "input"
             )
           ),
           do: Arca.Repo.rollback(:carried)

        row = delivered!(athanor_id, turn, deliver, row_id)

        step =
          insert_step!(athanor_id, turn, %{
            kind: "input",
            purpose: "brain",
            tool: "program",
            action: deliver,
            idempotency_key: key,
            dispatch_state: "dispatched",
            message_id: row.id
          })

        if deliver == "post" do
          {1, _} =
            from(m in Message,
              where: m.athanor_id == ^athanor_id and m.id == ^row.id and is_nil(m.carried_by)
            )
            |> Arca.Repo.update_all(set: [carried_by: step.id])
        end

        progress = progress(thread)
        progress = if deliver == "answer", do: progress, else: owe(progress, step.id)
        progress = clocked(progress, athanor_id, turn, Map.fetch!(attrs, :silence_ms), false)
        :ok = put_progress!(athanor_id, thread.id, progress)
        %{step: step, row: row}
      end)
    end)
    |> Arca.Data.project()
  end

  def carry(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Take back a delivery `carry/3` recorded whose command was certainly not
  written (the holder refused it before writing): its `input` step goes,
  a post it carried waits again, and it owes no answer; a notice's
  recovery obligation, which it had not taken over, is owed again as it
  stood, a fresh session's context with it. Under the turn's
  lock (`:fence`) and its thread's; a step no longer `dispatched`, or of
  another turn, is `:not_dispatched`.
  """
  @spec uncarry(Prima.Actor.t(), String.t(), map()) :: :ok | {:error, term()}
  def uncarry(%Prima.Actor{athanor_id: athanor_id}, turn_id, %{step_id: step_id} = attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.uncarry", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        thread = locked_thread!(athanor_id, turn.thread_id)

        case from(s in TurnStep,
               where: s.athanor_id == ^athanor_id and s.id == ^step_id and s.turn_id == ^turn.id,
               where: s.kind == "input" and s.dispatch_state == "dispatched"
             )
             |> Arca.Repo.delete_all() do
          {1, _} -> :ok
          {0, _} -> Arca.Repo.rollback(:not_dispatched)
        end

        from(m in Message, where: m.athanor_id == ^athanor_id and m.carried_by == ^step_id)
        |> Arca.Repo.update_all(set: [carried_by: nil])

        progress = Map.update(progress(thread), "owed", [], &List.delete(&1, step_id))
        put_progress!(athanor_id, thread.id, progress)
      end)
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _} = refused -> refused
    end
  end

  def uncarry(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  @doc """
  What a program turn owes its brain next, chosen from one view of its
  rows: the first recovery prompt it owes (`brain_notices/2`), else the
  first result of its asks, else the first post that waits
  (`brain_posts/2`), or `:none`. One read transaction holds the turn's row
  against its writers, so a result and a post that commit around the read
  are both seen or neither is: a post never overtakes a result that was
  owed before it.
  """
  @spec brain_owed(Prima.Actor.t(), String.t()) ::
          {:ok, :none | {:notice | :answer | :post, map()}} | {:error, term()}
  def brain_owed(%Prima.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.brain_owed", fn ->
      Arca.Repo.read_transaction(fn ->
        turn = shared_turn!(athanor_id, turn_id)
        progress = progress(thread!(athanor_id, turn.thread_id))

        with [] <- {:notice, owed_notices(athanor_id, turn, progress)} |> owed_first(),
             [] <- {:answer, owed_results(athanor_id, turn)} |> owed_first(),
             [] <- {:post, waiting_posts(athanor_id, turn)} |> owed_first() do
          :none
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def brain_owed(%Prima.Actor{}, _turn_id), do: {:error, :no_athanor}

  defp owed_first({_owed, []}), do: []
  defp owed_first({owed, [item | _]}), do: {owed, item}

  # The turn's row, held against its writers to the read's end
  # (`Arca.QueryHelpers.for_share/1`).
  # arca:db-raise-ok inside the caller's transaction
  defp shared_turn!(athanor_id, turn_id) do
    from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
    |> Arca.QueryHelpers.for_share()
    |> Arca.Repo.one()
    |> case do
      nil -> Arca.Repo.rollback(:turn_not_found)
      turn -> turn
    end
  end

  # The results a program turn owes its brain, in order: each ask of the
  # turn that closed with a result row no `input` step carried yet, as
  # `%{step: step, row: row, call: call_row}`.
  # arca:db-raise-ok inside the caller's transaction
  defp owed_results(athanor_id, %Turn{} = turn) do
    carried =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id and s.kind == "input",
        select: s.message_id
      )

    Arca.Repo.all(
      from(s in TurnStep,
        join: r in Message,
        on: r.id == s.result_message_id and r.athanor_id == s.athanor_id,
        left_join: c in Message,
        on: c.id == s.message_id and c.athanor_id == s.athanor_id,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
        where: s.purpose == "brain" and s.kind != "input",
        where: s.idempotency_key != ^admission_key(turn.id),
        where: s.dispatch_state == "closed",
        where: s.result_message_id not in subquery(carried),
        order_by: [asc: s.seq],
        select: %{step: s, row: r, call: c}
      )
    )
  end

  @doc """
  Reconcile a program turn's deliveries with what a resumed native
  session's transcript holds (`started.held`), before any other recovery
  of the turn runs. In one transaction under the turn's lock (`:fence`,
  running) and its thread's, at `:generation`: of the turn's post and
  notice steps owed an answer or still `dispatched`, each named in
  `:held` was delivered and its answer is not established, and each not
  named is uncertain; a dispatched one closes `ok` or `uncertain`
  accordingly. An answer step still `dispatched` closes `uncertain`: no
  transcript says whether it was taken. What the thread owes from other
  turns' steps is dropped, as those turns are over.

  A held post and an uncertain answer each owe one recovery prompt
  (`brain_notices/2`), and the obligation stays recorded until the
  driver answers for that prompt's write (`commit_events/3`) or a
  reconcile finds the prompt's step recorded, as it may have been
  written: either settles it, and it is never prompted again. Until then
  a held post stays owed an answer, and a reconcile run again answers
  both again. A notice it reports, held or not, and a post not held stay
  owed too, until their turn is over: each ends the turn, and a reconcile
  run again before that end is recorded reports them again, with no
  prompt for them.
  Answers `%{held: [step], absent: [step], answers: [step]}`.

  With `fresh: true` the session was started anew because its transcript
  is gone, so nothing holds the turn's deliveries: each still
  `dispatched` closes `uncertain`, nothing stays owed, and when the turn
  delivered a post the turn owes one prompt that carries the thread so
  far, recorded as the others are. Answers the same map, every list
  empty.
  """
  @spec reconcile_brain(Prima.Actor.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def reconcile_brain(%Prima.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.reconcile_brain", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        if turn.status != "running", do: Arca.Repo.rollback(:not_running)
        thread = locked_thread!(athanor_id, turn.thread_id)

        if thread.brain_generation != Map.fetch!(attrs, :generation),
          do: Arca.Repo.rollback(:generation_moved)

        steps =
          Arca.Repo.all(
            from(s in TurnStep,
              where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id and s.kind == "input",
              order_by: [asc: s.seq]
            )
          )

        # A notice recorded may have been written: it settles what it
        # answers, which is never prompted again.
        progress =
          taken_over(
            progress(thread),
            athanor_id,
            for(s <- steps, s.action == "notice", do: s.id)
          )

        # The prompts this turn still owes; other turns' are dropped.
        ids = MapSet.new(steps, & &1.id)
        noticed = Enum.filter(progress["notices"] || [], &MapSet.member?(ids, &1["step"]))

        {reconciled, progress} =
          if Map.get(attrs, :fresh) == true,
            do: started_fresh!(athanor_id, steps, progress),
            else: resumed!(athanor_id, steps, noticed, progress, Map.get(attrs, :held, []))

        :ok = put_progress!(athanor_id, thread.id, progress)
        reconciled
      end)
    end)
    |> Arca.Data.project()
  end

  def reconcile_brain(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  # A resumed transcript's word on the turn's deliveries; each held post
  # and uncertain answer owes a prompt until that prompt's step is
  # recorded.
  # arca:db-raise-ok inside the caller's transaction
  defp resumed!(athanor_id, steps, noticed, progress, held) do
    owed = progress["owed"] || []

    pending =
      Enum.filter(steps, fn s ->
        s.action in ["post", "notice"] and (s.id in owed or s.dispatch_state == "dispatched")
      end)

    {held_steps, absent} = Enum.split_with(pending, &(&1.id in held))
    owes = Enum.map(noticed, & &1["step"])

    answers =
      Enum.filter(steps, fn s ->
        s.action == "answer" and (s.dispatch_state == "dispatched" or s.id in owes)
      end)

    close_inputs!(athanor_id, held_steps, "ok")
    close_inputs!(athanor_id, absent ++ answers, "uncertain")

    notices =
      Enum.uniq_by(
        noticed ++ for(s <- held_steps ++ answers, s.action != "notice", do: %{"step" => s.id}),
        & &1["step"]
      )

    # Every delivery it reports stays owed: a held post its answer; a
    # notice, held or not, and a post the transcript lacks end the turn
    # (`Aqua.Harness.Program`), so until the turn is over a reconcile run again
    # reports them again, and prompts nothing for them.
    progress =
      progress
      |> Map.put("owed", Enum.map(pending, & &1.id))
      |> Map.put("notices", notices)

    {%{held: held_steps, absent: absent, answers: answers}, progress}
  end

  # A session started anew owes the turn one prompt with the thread so
  # far, for the newest post it delivered, and nothing else of before.
  # arca:db-raise-ok inside the caller's transaction
  defp started_fresh!(athanor_id, steps, progress) do
    close_inputs!(athanor_id, steps, "uncertain")

    notices =
      case steps |> Enum.filter(&(&1.action == "post")) |> List.last() do
        nil -> []
        post -> [%{"step" => post.id, "context" => true}]
      end

    {%{held: [], absent: [], answers: []},
     progress |> Map.put("owed", []) |> Map.put("notices", notices)}
  end

  # arca:db-raise-ok inside the caller's transaction
  defp close_inputs!(athanor_id, steps, outcome) do
    now = DateTime.utc_now()

    for step <- steps, step.dispatch_state == "dispatched" do
      from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step.id)
      |> Arca.Repo.update_all(set: [dispatch_state: "closed", outcome: outcome, ended_at: now])
    end

    :ok
  end

  @doc """
  The recovery prompts a program turn owes, in order (`reconcile_brain/3`):
  each `%{action: "post" | "answer", message_id: row, context?: boolean}`,
  the row it continues (the post, or the result row of the answer) and
  whether it carries the thread so far, for a session started anew.
  """
  @spec brain_notices(Prima.Actor.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def brain_notices(%Prima.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.brain_notices", fn ->
      turn = turn!(athanor_id, turn_id)
      {:ok, owed_notices(athanor_id, turn, progress(thread!(athanor_id, turn.thread_id)))}
    end)
  end

  def brain_notices(%Prima.Actor{}, _turn_id), do: {:error, :no_athanor}

  # arca:db-raise-ok inside the caller's transaction
  defp owed_notices(athanor_id, %Turn{} = turn, progress) do
    case progress["notices"] || [] do
      [] ->
        []

      noticed ->
        steps =
          Arca.Repo.all(
            from(s in TurnStep,
              where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id and s.kind == "input",
              where: s.id in ^Enum.map(noticed, & &1["step"]) or s.action == "notice"
            )
          )

        # A row a notice was recorded for is offered no second one.
        recorded = for %{action: "notice", message_id: row} <- steps, do: row
        steps = Map.new(steps, &{&1.id, &1})

        for notice <- noticed,
            step = steps[notice["step"]],
            step != nil and step.message_id not in recorded,
            do: %{
              action: step.action,
              message_id: step.message_id,
              context?: notice["context"] == true
            }
    end
  end

  @doc """
  The ids a resuming start names as `pending` (`Opus.Brain.Wire`): the
  turn's post and notice steps owed an answer or still `dispatched`,
  whose delivery its transcript says.
  """
  @spec brain_pending(Prima.Actor.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def brain_pending(%Prima.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.brain_pending", fn ->
      turn = turn!(athanor_id, turn_id)
      owed = progress(thread!(athanor_id, turn.thread_id))["owed"] || []

      ids =
        Arca.Repo.all(
          from(s in TurnStep,
            where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id and s.kind == "input",
            where: s.action in ["post", "notice"],
            where: s.id in ^owed or s.dispatch_state == "dispatched",
            order_by: [asc: s.seq],
            select: s.id
          )
        )

      {:ok, ids}
    end)
  end

  def brain_pending(%Prima.Actor{}, _turn_id), do: {:error, :no_athanor}

  # The recovery prompts `notice_ids` take over the obligations they
  # answer (`reconcile_brain/3`), once the driver answered for their write
  # or a reconcile found them recorded: the post or the answer each
  # continues owes it no longer, and the post leaves the posts owed an
  # answer to the prompt.
  # arca:db-raise-ok inside the caller's transaction
  defp taken_over(progress, _athanor_id, []), do: progress

  defp taken_over(progress, athanor_id, notice_ids) do
    ids =
      Arca.Repo.all(
        from(n in TurnStep,
          join: s in TurnStep,
          on:
            s.athanor_id == n.athanor_id and s.turn_id == n.turn_id and
              s.message_id == n.message_id,
          where: n.athanor_id == ^athanor_id and n.id in ^notice_ids,
          where: n.kind == "input" and n.action == "notice",
          where: s.kind == "input" and s.action != "notice",
          select: s.id
        )
      )

    progress
    |> Map.update("notices", [], &Enum.reject(&1, fn notice -> notice["step"] in ids end))
    |> Map.update("owed", [], &(&1 -- ids))
  end

  # A running turn takes any delivery; a paused one only a post or an
  # answer of its own work.
  defp carrying!(%Turn{status: "running"}, _deliver), do: :ok
  defp carrying!(%Turn{status: "paused"}, deliver) when deliver in ["post", "answer"], do: :ok
  defp carrying!(%Turn{}, _deliver), do: Arca.Repo.rollback(:not_running)

  # The turn's `program.start` step, decided allow: dispatched or closed
  # as it ran, and not asked to stop.
  # arca:db-raise-ok inside the caller's transaction
  defp admitted_start!(athanor_id, %Turn{} = turn) do
    key = admission_key(turn.id)

    from(s in TurnStep,
      where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
      where: s.idempotency_key == ^key and s.tool == "program" and s.action == "start",
      where: s.dispatch_state in ["dispatched", "closed"],
      where: is_nil(s.outcome) or s.outcome == "ok",
      where: is_nil(s.cancel_requested_at)
    )
    |> Arca.Repo.one() || Arca.Repo.rollback(:not_admitted)
  end

  # The row a delivery delivers, as it stands now.
  # arca:db-raise-ok inside the caller's transaction
  defp delivered!(athanor_id, %Turn{} = turn, "post", row_id) do
    Enum.find(waiting_posts(athanor_id, turn), &(&1.id == row_id)) ||
      Arca.Repo.rollback(:not_waiting)
  end

  defp delivered!(athanor_id, %Turn{} = turn, "answer", row_id) do
    if row_id in closed_results(athanor_id, turn),
      do: Arca.Repo.get_by!(Message, id: row_id, athanor_id: athanor_id),
      else: Arca.Repo.rollback(:not_closed)
  end

  defp delivered!(athanor_id, %Turn{} = turn, "notice", row_id) do
    carried =
      from(m in Message,
        where: m.athanor_id == ^athanor_id and m.id == ^row_id and m.turn_id == ^turn.id,
        where: not is_nil(m.carried_by)
      )
      |> Arca.Repo.one()

    cond do
      carried != nil -> carried
      row_id in closed_results(athanor_id, turn) -> delivered!(athanor_id, turn, "answer", row_id)
      true -> Arca.Repo.rollback(:not_closed)
    end
  end

  @doc """
  The posts of a program turn that wait for their delivery, in order
  (`carry/3`): its rows that are posts (`post?/2`) of the kinds a program
  is handed, that no step carried yet.
  """
  @spec brain_posts(Prima.Actor.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def brain_posts(%Prima.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.brain_posts", fn ->
      {:ok, waiting_posts(athanor_id, turn!(athanor_id, turn_id))}
    end)
    |> Arca.Data.project()
  end

  def brain_posts(%Prima.Actor{}, _turn_id), do: {:error, :no_athanor}

  # The posts of a program turn no step carried yet, in order: of what the
  # program is handed, every row but its own words, a text of its agent's
  # (`said!/4`).
  # arca:db-raise-ok inside the caller's transaction
  defp waiting_posts(athanor_id, %Turn{} = turn) do
    Arca.Repo.all(
      from(m in Message,
        where: m.athanor_id == ^athanor_id and m.turn_id == ^turn.id,
        where: m.kind in ^@brain_posts and is_nil(m.carried_by),
        where: ^post(turn.agent),
        order_by: [asc: m.seq]
      )
    )
  end

  # The result rows of the turn's asks that closed: the steps the host
  # recorded for the program's asks, never its `program.start`.
  # arca:db-raise-ok inside the caller's transaction
  defp closed_results(athanor_id, %Turn{} = turn) do
    Arca.Repo.all(
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
        where: s.purpose == "brain" and s.kind != "input",
        where: s.idempotency_key != ^admission_key(turn.id),
        where: s.dispatch_state == "closed" and not is_nil(s.result_message_id),
        select: s.result_message_id
      )
    )
  end

  @doc """
  Commit what a harness said, with its position, in one transaction: the
  one writer of a turn's text, its asks, the deliveries a program took and
  every usage. It always locks the scope's thread (`:thread`); with a turn
  (`:turn`, `%{id, fence}`) it is held to that turn's fence and the turn
  is open, and with none it takes only usage and deliveries.

  `events`, in order:

    * `{:text, %{text: text, message: id | nil}}`, a post of the scope's
      agent in the turn;
    * `{:ask, proposal}`, an ask: a step proposal with its `tool_call` row
      (`put_step/3`'s attrs: `:kind`, `:tool`, `:action`, `:recovery`,
      `:child_execution_id`, `:idempotency_key`, `:call`), recorded once by
      its key as a `proposed` step and never dispatched by being recorded.
      A `recovery` is none or one of `Prima.TurnState.recoveries/0`
      (`{:error, :illegal_transition}` otherwise), and the step's stored
      value alone later decides a replay (`next_generation/3`);
    * `{:took, step_id}` and `{:refused, step_id}`, `input` steps a
      program answered: taken closes one `ok`, refused closes it `error`,
      and neither is an answer; a notice among them takes over the
      recovery obligation it answers (`reconcile_brain/3`);
    * `{:usage, usage}`, what a model ran and its counts
      (`%{"models" => [%{"model", "counts"}], "accounting"}`), counted once
      onto the step it is of: a model step's own, or the `program.start`
      step of the work a session's usage names (`"work"`), each by its
      result's identity (`"result"`) or against its native thread's last
      usable total (`"total"`); a session's usage of no such work is kept
      as the session's, unattributed, never charged to later work;
    * `{:stop, reason}`, why a model's response ended.

  `position` is where the harness stands after them:

    * `{:step, id}`, a `model` step of the turn (`:step_not_found`
      otherwise), dispatched: it closes `ok` with its text row and its
      usage, and one event records it. A text row names the step;
    * `{:session, progress}`, a program's session: every member the
      thread's `brain_progress` checks or stores. `:generation`, the
      thread's session generation (`:generation_moved`); `:row_id` and
      `:epoch`, the session's owner, the program row at an epoch no older
      than the last committed batch's (`:row_changed`); `:boot` and
      `:seq`, the driver process and its last line: the boot becomes the
      session's only once the batch holds its `hello` (`:hello`), any
      other batch of a boot that is not the committed one is
      `:superseded`, and one at or before the committed position of the
      same boot commits nothing and answers `seen: true`; `:session`, the
      native session `started` named, kept with `:row_id` and `:epoch` as
      the row it is stored with; `:answered`, the post and notice steps a
      native `idle` named, which leave the posts owed an answer (a nudge
      among them is answered); `:busy`, whether the program owes output
      after the batch; `:native` and `:hello`, which restart the silence
      clock's interval (`:silence_ms`). A text row names its native
      message.

  The rows it writes, a text's and an ask's call, are written in the order
  the events are given. Answers `%{seen: boolean, said: [row], asks:
  [%{message: row, step: step}], rows: [row]}`, `rows` being every row
  written in that order. Each ask answered is the step its own proposal
  made, with that proposal's call row; an ask whose key was already
  recorded makes none and is not answered.
  """
  @spec commit_events(Prima.Actor.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def commit_events(
        %Prima.Actor{athanor_id: athanor_id} = actor,
        %{thread: thread_id} = scope,
        %{events: events, position: position}
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) and
             is_list(events) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.commit_events", fn ->
      with_seq_retry(fn ->
        Arca.Repo.locking_transaction(fn ->
          turn =
            case Map.get(scope, :turn) do
              nil -> nil
              %{id: id} = held -> open!(own!(athanor_id, id, held))
            end

          thread = locked_thread!(athanor_id, thread_id)
          if turn && turn.thread_id != thread.id, do: Arca.Repo.rollback(:wrong_turn)
          committed!(actor, athanor_id, thread, turn, scope, events, position)
        end)
      end)
    end)
    |> Arca.Data.project()
  end

  def commit_events(%Prima.Actor{}, _scope, _commit), do: {:error, :no_athanor}

  # arca:db-raise-ok inside the caller's transaction
  defp committed!(actor, athanor_id, thread, turn, _scope, events, {:step, step_id}) do
    if is_nil(turn), do: Arca.Repo.rollback(:step_not_found)
    step = step!(athanor_id, step_id)
    if step.turn_id != turn.id or step.kind != "model", do: Arca.Repo.rollback(:step_not_found)
    illegal_recovery!(events)

    written = written!(actor, athanor_id, thread, turn, step, events)
    said = for {:text, row} <- written, do: row
    asks = for {:ask, ask} <- written, do: ask

    usage =
      for({:usage, usage} <- events, reduce: nil, do: (acc -> add_usage(acc, counts(usage))))

    {1, _} =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.id == ^step_id,
        where: s.turn_id == ^turn.id and s.dispatch_state in ["proposed", "dispatched"]
      )
      |> Arca.Repo.update_all(
        set: [
          dispatch_state: "closed",
          outcome: "ok",
          usage: encode(usage),
          result_message_id: List.first(Enum.map(said, & &1.id)),
          ended_at: DateTime.utc_now()
        ]
      )

    event!(athanor_id, turn, "model.completed", step_id, %{
      "usage" => usage,
      "stop_reason" => List.last(for {:stop, reason} <- events, do: reason),
      "calls" => length(asks)
    })

    %{seen: false, said: said, asks: asks, rows: rows(written)}
  end

  defp committed!(actor, athanor_id, thread, turn, scope, events, {:session, progress_attrs}) do
    # Strict, so a generation of another type (0.0 for 0) is refused
    # here: the session's write after it holds to no generation of its
    # own (`keep_session!/3`).
    generation = Map.fetch!(progress_attrs, :generation)
    if thread.brain_generation !== generation, do: Arca.Repo.rollback(:generation_moved)
    progress = progress(thread)
    owner!(progress, progress_attrs)

    if seen?(progress, progress_attrs) do
      %{seen: true, said: [], asks: [], rows: []}
    else
      illegal_recovery!(events)
      session!(actor, athanor_id, thread, turn, scope, events, progress, progress_attrs)
    end
  end

  defp illegal_recovery!(events) do
    if Enum.any?(events, fn
         {:ask, ask} -> Map.get(ask, :recovery) not in [nil | Prima.TurnState.recoveries()]
         _other -> false
       end),
       do: Arca.Repo.rollback(:illegal_transition)
  end

  # The session's owner: the program row the last committed batch ran on
  # (`driver`), at an epoch no older than that batch's, and the driver
  # process the committed position is of, which a batch holding a new
  # process's hello replaces. It is not the row the native session is
  # stored with (`row`), which a hello never moves.
  defp owner!(progress, attrs) do
    row = Map.fetch!(attrs, :row_id)
    epoch = Map.fetch!(attrs, :epoch)
    driver = progress["driver"] || %{}

    cond do
      driver["row"] == row and is_integer(driver["epoch"]) and epoch < driver["epoch"] ->
        Arca.Repo.rollback(:row_changed)

      progress["boot"] not in [nil, Map.fetch!(attrs, :boot)] and
          Map.get(attrs, :hello) != true ->
        Arca.Repo.rollback(:superseded)

      true ->
        :ok
    end
  end

  defp seen?(progress, attrs),
    do: progress["boot"] == attrs.boot and (progress["seq"] || 0) >= Map.fetch!(attrs, :seq)

  # arca:db-raise-ok inside the caller's transaction
  defp session!(actor, athanor_id, thread, turn, scope, events, progress, attrs) do
    session = Map.get(attrs, :session)
    keep_session!(athanor_id, thread, session)

    written = if turn, do: written!(actor, athanor_id, thread, turn, nil, events), else: []
    said = for {:text, row} <- written, do: row
    asks = for {:ask, ask} <- written, do: ask

    took = for {:took, id} <- events, do: id
    refused = for {:refused, id} <- events, do: id
    :ok = inputs_closed!(athanor_id, thread, took, "ok")
    :ok = inputs_closed!(athanor_id, thread, refused, "error")
    answered = Map.get(attrs, :answered, [])
    :ok = nudges_answered!(athanor_id, thread, answered)
    usages = for {:usage, usage} <- events, do: usage

    progress =
      progress
      |> taken_over(athanor_id, took ++ refused)
      |> Map.update("owed", [], &(&1 -- answered))
      |> counted!(athanor_id, thread, turn, Map.fetch!(scope, :agent), usages)
      |> then(fn p ->
        case Map.get(attrs, :busy) do
          nil -> p
          busy -> Map.put(p, "busy", busy)
        end
      end)
      |> clocked(athanor_id, turn, Map.fetch!(attrs, :silence_ms), whole_interval?(attrs))
      |> Map.merge(%{
        "driver" => %{"row" => attrs.row_id, "epoch" => attrs.epoch},
        "boot" => attrs.boot,
        "seq" => attrs.seq
      })
      # The row the native session is stored with moves with the session
      # alone, in this write, so a forget reads where its transcript is
      # until the write that replaces the session.
      |> Map.merge(if session, do: %{"row" => attrs.row_id, "epoch" => attrs.epoch}, else: %{})

    :ok = put_progress!(athanor_id, thread.id, progress)
    %{seen: false, said: said, asks: asks, rows: rows(written)}
  end

  # The rows the events write, a text's and an ask's call, in the order
  # the events were given, which is the order of their seq.
  # arca:db-raise-ok inside the caller's transaction
  defp written!(actor, athanor_id, thread, turn, step, events) do
    Enum.flat_map(events, fn
      {:text, text} ->
        [{:text, said!(actor, thread, turn, text, step && step.id)}]

      {:ask, ask} ->
        for asked <- ask!(actor, athanor_id, turn, step, ask), do: {:ask, asked}

      _other ->
        []
    end)
  end

  defp rows(written) do
    Enum.map(written, fn
      {:text, row} -> row
      {:ask, %{message: row}} -> row
    end)
  end

  # What the harness said in the open turn: a post of its agent, naming
  # the model step it is of or the native message.
  # arca:db-raise-ok inside the caller's transaction
  defp said!(actor, thread, %Turn{} = turn, %{text: text} = said, step_id) do
    payload =
      if step_id,
        do: %{"step_id" => step_id},
        else: %{"brain_message" => Map.get(said, :message)}

    Arca.ThreadStorage.insert_message!(actor, thread, %{
      author: Message.agent_author(),
      sent_by: turn.agent,
      kind: "text",
      content: text,
      payload: payload,
      turn_id: turn.id,
      execution_id: turn.root_execution_id
    })
  end

  # An ask of the open turn, recorded once by its key with the row of its
  # call, on a running or a paused turn: being recorded dispatches
  # nothing, and the turn's loop decides it. An ask serves what the model
  # step that made it served; a program's serves the program.
  # arca:db-raise-ok inside the caller's transaction
  defp ask!(actor, athanor_id, %Turn{} = turn, step, %{idempotency_key: key} = attrs) do
    if Arca.Repo.exists?(
         from(s in TurnStep,
           where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
           where: s.idempotency_key == ^key
         )
       ) do
      []
    else
      purpose = if step, do: step.purpose, else: "brain"
      attrs = Map.merge(attrs, %{purpose: purpose, dispatch_state: "proposed"})
      row = call_row!(actor, athanor_id, turn, Map.fetch!(attrs, :call))
      attrs = attrs |> Map.delete(:call) |> Map.put(:message_id, row.id)
      [%{message: row, step: insert_step!(athanor_id, turn, attrs)}]
    end
  end

  # The `input` steps of the thread's turns the driver answered for, each
  # closed from `dispatched` once.
  # arca:db-raise-ok inside the caller's transaction
  defp inputs_closed!(_athanor_id, _thread, [], _outcome), do: :ok

  defp inputs_closed!(athanor_id, thread, ids, outcome) do
    turns =
      from(t in Turn,
        where: t.athanor_id == ^athanor_id and t.thread_id == ^thread.id,
        select: t.id
      )

    from(s in TurnStep,
      where: s.athanor_id == ^athanor_id and s.id in ^ids and s.kind == "input",
      where: s.dispatch_state == "dispatched" and s.turn_id in subquery(turns)
    )
    |> Arca.Repo.update_all(
      set: [
        dispatch_state: "closed",
        outcome: outcome,
        error: if(outcome == "error", do: "the program refused it"),
        ended_at: DateTime.utc_now()
      ]
    )

    :ok
  end

  # A nudge its post step carried is answered once the program's `idle`
  # names that step: `accepted` only says the write was taken.
  # arca:db-raise-ok inside the caller's transaction
  defp nudges_answered!(_athanor_id, _thread, []), do: :ok

  defp nudges_answered!(athanor_id, thread, ids) do
    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.thread_id == ^thread.id and m.kind == "nudge",
      where: m.carried_by in ^ids and is_nil(m.resolved_by),
      update: [set: [resolved_by: m.carried_by, resolved_at: ^DateTime.utc_now()]]
    )
    |> Arca.Repo.update_all([])

    :ok
  end

  # Each usage event counted once: a result by its identity, among the
  # newest kept, a total against its native thread's last usable one (one
  # below it is a reset). What it counts goes to the work it names when
  # that work is the open turn's or another of this thread's and agent's,
  # else it stays the session's, unattributed.
  # arca:db-raise-ok inside the caller's transaction
  defp counted!(progress, athanor_id, thread, turn, agent, usages) do
    Enum.reduce(usages, progress, fn usage, progress ->
      case fresh(progress, usage) do
        {:seen, progress} ->
          progress

        {:fresh, counts, progress} ->
          case usage_step(athanor_id, thread, turn, agent, usage["work"]) do
            nil ->
              Map.put(progress, "unattributed", add_usage(progress["unattributed"], counts))

            step ->
              {1, _} =
                from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step.id)
                |> Arca.Repo.update_all(
                  set: [usage: encode(add_usage(decode(step.usage), counts))]
                )

              progress
          end
      end
    end)
  end

  # What a usage event adds, and the baseline after it.
  defp fresh(progress, %{"result" => result} = usage) do
    baseline = progress["baseline"] || %{}
    results = baseline["results"] || []

    if result in results do
      {:seen, progress}
    else
      results = Enum.take([result | results], @counted_results)

      {:fresh, counts(usage),
       Map.put(progress, "baseline", Map.put(baseline, "results", results))}
    end
  end

  # A total is its native thread's four counts so far across every model
  # it ran, under the one it runs now (`brain_wire.json`): compared with
  # that thread's last usable total whatever model either came under, one
  # below it is a reset, and another thread's starts a baseline of its
  # own. One with no counts is unknown and leaves the baseline as it was.
  defp fresh(progress, %{"total" => thread, "models" => [_ | _] = models} = usage) do
    baseline = progress["baseline"] || %{}

    total =
      Enum.reduce(models, %{}, fn %{"counts" => counts}, sum ->
        Map.merge(sum, counts, fn _name, a, b -> a + b end)
      end)

    last =
      case baseline["total"] do
        %{"thread" => ^thread, "counts" => counts} -> counts
        _another_thread_or_none -> %{}
      end

    added =
      if Enum.any?(last, fn {name, n} -> (total[name] || 0) < n end),
        do: total,
        else: Map.new(total, fn {name, n} -> {name, n - (last[name] || 0)} end)

    baseline = Map.put(baseline, "total", %{"thread" => thread, "counts" => total})

    {:fresh, %{counts(usage) | "models" => %{List.last(models)["model"] => added}},
     Map.put(progress, "baseline", baseline)}
  end

  defp fresh(progress, %{"total" => _} = usage), do: {:fresh, counts(usage), progress}

  # An event's counts as one usage map: each model's four counts, and
  # whether the accounting was partial or unavailable, which is unknown and
  # never zero.
  defp counts(%{"accounting" => accounting} = usage) do
    models =
      for %{"model" => model, "counts" => counts} <- usage["models"] || [],
          into: %{},
          do: {model, counts}

    %{
      "models" => models,
      "results" => 1,
      "partial" => if(accounting == "partial", do: 1, else: 0),
      "unknown" => if(accounting == "unavailable", do: 1, else: 0)
    }
  end

  # Two usage maps added: counts by model and name, and the results, the
  # partial and the unknown ones counted.
  defp add_usage(nil, counts), do: add_usage(%{}, counts)

  defp add_usage(usage, counts) do
    models =
      Map.merge(usage["models"] || %{}, counts["models"] || %{}, fn _model, a, b ->
        Map.merge(a, b, fn _name, x, y -> x + y end)
      end)

    %{
      "models" => models,
      "results" => (usage["results"] || 0) + (counts["results"] || 0),
      "partial" => (usage["partial"] || 0) + (counts["partial"] || 0),
      "unknown" => (usage["unknown"] || 0) + (counts["unknown"] || 0)
    }
  end

  # The `program.start` step of the work a usage names: the open turn's,
  # or a turn of this thread and agent that is over, whose usage it
  # counts without reopening it. None for a work that is neither.
  # arca:db-raise-ok inside the caller's transaction
  defp usage_step(athanor_id, thread, turn, agent, work) when is_binary(work) do
    open = (turn && turn.id) || ""

    from(s in TurnStep,
      join: t in Turn,
      on: t.id == s.turn_id and t.athanor_id == s.athanor_id,
      where: s.athanor_id == ^athanor_id and s.turn_id == ^work,
      where: s.idempotency_key == ^admission_key(work),
      where: t.thread_id == ^thread.id and t.agent == ^agent,
      where: t.id == ^open or t.status in ^@terminal
    )
    |> Arca.Repo.one()
  end

  defp usage_step(_athanor_id, _thread, _turn, _agent, _work), do: nil

  # The silence clock (`brain_progress`'s `clock`): it runs whenever the
  # program owes an open turn something (`owes?/3`), banks what ran when it
  # pauses, and
  # restarts whole at a line of the program's own and at a process's hello
  # (`whole_interval?/1`). Read by the database's clock.
  # arca:db-raise-ok inside the caller's transaction
  defp clocked(progress, athanor_id, turn, silence_ms, whole?) do
    now = Arca.ServerMetaStorage.now!()
    clock = progress["clock"] || %{"since" => nil, "left_ms" => silence_ms}

    left =
      cond do
        whole? -> silence_ms
        is_binary(clock["since"]) -> max(clock["left_ms"] - elapsed_ms(clock["since"], now), 0)
        true -> clock["left_ms"]
      end

    since = if owes?(athanor_id, turn, progress), do: DateTime.to_iso8601(now)
    Map.put(progress, "clock", %{"since" => since, "left_ms" => left})
  end

  defp whole_interval?(attrs),
    do: Map.get(attrs, :native, false) or Map.get(attrs, :hello, false)

  defp elapsed_ms(since, now) do
    {:ok, at, _offset} = DateTime.from_iso8601(since)
    max(DateTime.diff(now, at, :millisecond), 0)
  end

  # Whether the program owes something: never with no turn open, since a
  # program lives for one turn; with one, whenever a delivery sent to it
  # is not acknowledged, whatever waits behind it, since nothing more is
  # written until it answers. Else when a delivery was taken
  # since its last `idle`, or a post or notice of the turn it took is
  # still owed an answer, and neither CYFR nor the person owes it
  # anything: no ask undecided or running, no closed result whose answer
  # is not yet sent, no post waiting to be, no recovery
  # prompt not yet recorded.
  # arca:db-raise-ok inside the caller's transaction
  defp owes?(_athanor_id, nil, _progress), do: false

  defp owes?(athanor_id, %Turn{} = turn, progress) do
    unacknowledged?(athanor_id, turn) or
      ((progress["busy"] == true or answer_owed?(athanor_id, turn, progress)) and
         owed_notices(athanor_id, turn, progress) == [] and
         not owed_to_program?(athanor_id, turn))
  end

  defp unacknowledged?(athanor_id, %Turn{} = turn) do
    Arca.Repo.exists?(
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
        where: s.kind == "input" and s.dispatch_state == "dispatched"
      )
    )
  end

  defp answer_owed?(athanor_id, %Turn{} = turn, %{"owed" => [_ | _] = owed}) do
    Arca.Repo.exists?(
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id and s.kind == "input",
        where: s.id in ^owed
      )
    )
  end

  defp answer_owed?(_athanor_id, _turn, _progress), do: false

  defp owed_to_program?(athanor_id, %Turn{} = turn) do
    start = admission_key(turn.id)

    asks_open =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
        where: s.purpose == "brain" and s.idempotency_key != ^start,
        where: s.dispatch_state in ["proposed", "dispatched"]
      )

    delivering =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id and s.kind == "input",
        select: s.message_id
      )

    undelivered =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
        where: s.purpose == "brain" and s.kind != "input" and s.idempotency_key != ^start,
        where: s.dispatch_state == "closed" and not is_nil(s.result_message_id),
        where: s.result_message_id not in subquery(delivering)
      )

    Enum.any?([asks_open, undelivered], &Arca.Repo.exists?/1) or
      waiting_posts(athanor_id, turn) != []
  end

  @doc """
  Whether a program brain's silence ran out, by the database's clock:
  `expired?`, and `due_ms`, the milliseconds left of its interval while
  the clock runs (nil while it is paused), read from the thread's
  `brain_progress`. It is the open turn's clock: only that turn's
  attendant reads it, after its process's hello began the interval.
  """
  @spec brain_silence(Prima.Actor.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def brain_silence(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id)
      when is_binary(athanor_id) and athanor_id != "" do
    with {:ok, %{progress: progress, now: now}} <- brain(actor, thread_id) do
      case progress["clock"] do
        %{"since" => since, "left_ms" => left} when is_binary(since) ->
          due = left - elapsed_ms(since, now)
          {:ok, %{expired?: due <= 0, due_ms: max(due, 0)}}

        _paused ->
          {:ok, %{expired?: false, due_ms: nil}}
      end
    end
  end

  def brain_silence(%Prima.Actor{}, _thread_id), do: {:error, :no_athanor}

  # The thread's `brain_progress` map.
  defp progress(%Thread{brain_progress: nil}), do: %{}
  defp progress(%Thread{brain_progress: json}), do: Jason.decode!(json)

  defp owe(progress, id), do: Map.update(progress, "owed", [id], &Enum.uniq(&1 ++ [id]))

  # arca:db-raise-ok inside the caller's transaction
  defp put_progress!(athanor_id, thread_id, progress) do
    {1, _} =
      from(c in Thread, where: c.athanor_id == ^athanor_id and c.id == ^thread_id)
      |> Arca.Repo.update_all(set: [brain_progress: Jason.encode!(progress)])

    :ok
  end

  defp decode(nil), do: nil
  defp decode(json) when is_binary(json), do: Jason.decode!(json)

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc "One turn of the athanor."
  @spec get(Prima.Actor.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(%Prima.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.get", fn ->
      case Arca.Repo.one(from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)) do
        nil -> {:error, :not_found}
        turn -> {:ok, turn}
      end
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _turn_id), do: {:error, :no_athanor}

  @doc "The steps of a turn in `seq` order."
  @spec steps(Prima.Actor.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def steps(%Prima.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.steps", fn ->
      {:ok,
       Arca.Repo.all(
         from(s in TurnStep,
           where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id,
           order_by: [asc: s.seq]
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def steps(%Prima.Actor{}, _turn_id), do: {:error, :no_athanor}

  @thread_steps_max 100

  @doc """
  The steps of a thread across its turns, newest first: what its turns
  did, each a call of a tool, a hand or a launch, and none of the model
  steps a turn thinks in nor the deliveries to a program brain (`carry/3`). A turn's steps follow its
  `seq`, and the turns their acceptance. `opts`: `:limit` (at most
  #{@thread_steps_max}, the default) and `:before` (a step's id: the page
  after it, older; one that is no step of the thread reads as none). A
  thread of another athanor has none.
  """
  @spec thread_steps(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def thread_steps(actor, thread_id, opts \\ [])

  def thread_steps(%Prima.Actor{athanor_id: athanor_id}, thread_id, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) do
    limit = opts |> Keyword.get(:limit, @thread_steps_max) |> min(@thread_steps_max) |> max(1)

    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.thread_steps", fn ->
      query =
        from(s in TurnStep,
          join: t in Turn,
          on: t.id == s.turn_id and t.athanor_id == s.athanor_id,
          where: s.athanor_id == ^athanor_id and t.thread_id == ^thread_id,
          where: s.kind not in ["model", "input"],
          order_by: [desc: t.accepted_at, desc: t.id, desc: s.seq],
          limit: ^limit
        )

      case before(athanor_id, thread_id, Keyword.get(opts, :before)) do
        :first ->
          {:ok, Arca.Repo.all(query)}

        {at, turn_id, seq} ->
          {:ok,
           Arca.Repo.all(
             from([s, t] in query,
               where:
                 t.accepted_at < ^at or
                   (t.accepted_at == ^at and
                      (t.id < ^turn_id or (t.id == ^turn_id and s.seq < ^seq)))
             )
           )}

        :none ->
          {:ok, []}
      end
    end)
    |> Arca.Data.project()
  end

  def thread_steps(%Prima.Actor{}, _thread_id, _opts), do: {:error, :no_athanor}

  # Where a cursor step stands in its thread's order.
  # arca:db-raise-ok inside the caller's rescue.
  defp before(_athanor_id, _thread_id, nil), do: :first

  defp before(athanor_id, thread_id, step_id) when is_binary(step_id) do
    from(s in TurnStep,
      join: t in Turn,
      on: t.id == s.turn_id and t.athanor_id == s.athanor_id,
      where: s.athanor_id == ^athanor_id and s.id == ^step_id and t.thread_id == ^thread_id,
      select: {t.accepted_at, t.id, s.seq}
    )
    |> Arca.Repo.one()
    |> case do
      nil -> :none
      position -> position
    end
  end

  defp before(_athanor_id, _thread_id, _cursor), do: :none

  @doc "One step of the athanor."
  @spec step(Prima.Actor.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def step(%Prima.Actor{athanor_id: athanor_id}, step_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.step", fn ->
      case Arca.Repo.one(
             from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step_id)
           ) do
        nil -> {:error, :not_found}
        step -> {:ok, step}
      end
    end)
    |> Arca.Data.project()
  end

  def step(%Prima.Actor{}, _step_id), do: {:error, :no_athanor}

  @doc """
  The newest turn of a thread that has started, running, paused or over,
  or nil when none has. A turn that started holds the recovery limit only
  its start writes (`start/3`); one still waiting behind another, or
  cancelled while it waited, never started.
  """
  @spec latest(Prima.Actor.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def latest(%Prima.Actor{athanor_id: athanor_id}, thread_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(thread_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.latest", fn ->
      {:ok,
       Arca.Repo.one(
         from(t in Turn,
           where: t.athanor_id == ^athanor_id and t.thread_id == ^thread_id,
           where: not is_nil(t.recovery_limit),
           order_by: [desc: t.accepted_at, desc: t.id],
           limit: 1
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def latest(%Prima.Actor{}, _thread_id), do: {:error, :no_athanor}

  @doc "The open turns of a thread (accepted, running or paused), oldest first."
  @spec open_turns(Prima.Actor.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def open_turns(%Prima.Actor{athanor_id: athanor_id}, thread_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.open_turns", fn ->
      {:ok,
       Arca.Repo.all(
         from(t in Turn,
           where: t.athanor_id == ^athanor_id and t.thread_id == ^thread_id,
           where: t.status in ^@open,
           order_by: [asc: t.accepted_at]
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def open_turns(%Prima.Actor{}, _thread_id), do: {:error, :no_athanor}

  @doc """
  Every thread holding an open root turn, across all tenants, as
  `{athanor_id, thread_id}` pairs — the boot's recovery scan.
  `{:error, :unavailable}` when the database cannot answer, never an
  empty list a caller would read as nothing to recover.
  System-internal only.
  """
  @spec with_open_turns() :: {:ok, [{String.t(), String.t()}]} | {:error, :unavailable}
  def with_open_turns do
    Arca.Repo.Errors.with_db_rescue(
      "Arca.TurnStorage.with_open_turns",
      {:error, :unavailable},
      fn ->
        # arca:unscoped-ok the boot recovers open turns of every tenant when
        # no tenant context exists yet; system-internal only.
        {:ok,
         Arca.Repo.all(
           from(t in Turn,
             where: t.status in ^@open,
             distinct: true,
             select: {t.athanor_id, t.thread_id}
           )
         )}
      end
    )
    |> Arca.Data.project()
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  @doc """
  Run `fun` (a transaction that appends a message) again, up to three
  times, when it fails on the `(thread_id, seq)` unique race.
  """
  @spec with_seq_retry((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def with_seq_retry(fun) when is_function(fun, 0), do: with_seq_retry(fun, 3)

  defp with_seq_retry(_fun, 0), do: {:error, :seq_conflict}

  defp with_seq_retry(fun, retries) do
    try do
      fun.()
    rescue
      e in Ecto.InvalidChangesetError ->
        if unique?(e.changeset.errors, :thread_id, "seq"),
          do: with_seq_retry(fun, retries - 1),
          else: {:error, e.changeset}
    end
  end

  # A unique violation on a composite index reports on its first field;
  # the index name tells the races apart.
  defp unique?(errors, field, index_word) do
    errors
    |> Keyword.get_values(field)
    |> Enum.any?(fn
      {_msg, meta} when is_list(meta) ->
        Keyword.get(meta, :constraint) == :unique and
          String.contains?(to_string(Keyword.get(meta, :constraint_name, "")), index_word)

      _ ->
        false
    end)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp close_step!(actor, athanor_id, turn, step, outcome, attrs) do
    from_states =
      if outcome in ["denied", "skipped"], do: ["dispatched", "proposed"], else: ["dispatched"]

    now = DateTime.utc_now()
    threads = threads!(Map.get(attrs, :threads, []))

    result =
      case Map.get(attrs, :result) do
        nil ->
          nil

        %{} = result ->
          thread = thread!(athanor_id, turn.thread_id)

          Arca.ThreadStorage.insert_message!(actor, thread, %{
            author: Message.system_author(),
            sent_by: turn.agent,
            kind: result_kind(step),
            status: Map.get(result, :status),
            content: Map.get(result, :content, ""),
            payload: result_payload(athanor_id, result, step, threads),
            turn_id: turn.id,
            execution_id: Map.get(attrs, :execution_id)
          })
      end

    {count, _} =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.id == ^step.id,
        where: s.dispatch_state in ^from_states
      )
      |> Arca.Repo.update_all(
        set: [
          dispatch_state: "closed",
          outcome: outcome,
          result_message_id: result && result.id,
          execution_id: Map.get(attrs, :execution_id) || step.execution_id,
          error: Map.get(attrs, :error),
          ended_at: now
        ]
      )

    if count != 1, do: Arca.Repo.rollback(:not_open)

    _turn = join_threads!(athanor_id, turn, threads)

    event!(athanor_id, turn, "step.closed", step.id, %{
      "outcome" => outcome,
      "execution_id" => Map.get(attrs, :execution_id),
      "result_message_id" => result && result.id
    })

    %{step: step!(athanor_id, step.id), result: result}
  end

  # A page's call is answered in a row of its own, which no model's
  # request carries, as its call is.
  defp result_kind(%TurnStep{purpose: "page"}), do: "page_result"
  defp result_kind(%TurnStep{}), do: "tool_result"

  # A result row's payload: the call's own, the step it closes, and the
  # threads its answer carried, as the step joins them, which a deletion
  # of one of them finds the row by to blank it
  # (`Arca.ThreadStorage.delete/3`). The wire's id and name of the call it
  # answers come from the call's row where the caller gives none, as a
  # step skipped before it ran has no call in hand: a result that names no
  # call is one no brain can pair with its call.
  # arca:db-raise-ok inside the caller's transaction
  defp result_payload(athanor_id, result, step, threads) do
    payload =
      athanor_id
      |> call_identity(step)
      |> Map.merge(Map.get(result, :payload) || %{}, fn _key, row, given -> given || row end)
      |> Map.put("step_id", step.id)

    case threads |> Enum.uniq() |> Enum.sort() do
      [] -> payload
      threads -> Map.put(payload, "threads", threads)
    end
  end

  # The wire's id and name of the call a step's row records.
  # arca:db-raise-ok inside the caller's transaction
  defp call_identity(_athanor_id, %TurnStep{message_id: nil}), do: %{}

  defp call_identity(athanor_id, %TurnStep{message_id: id}) do
    from(m in Message, where: m.athanor_id == ^athanor_id and m.id == ^id)
    |> Arca.Repo.one()
    |> case do
      nil -> %{}
      row -> row |> Arca.ThreadStorage.payload() |> Map.take(["tool_call_id", "name"])
    end
  end

  # The turn's read threads joined by `threads`, under the row lock
  # `own!/3` took: the list is read and written again inside that lock, so
  # it only grows and no concurrent writer's additions are lost.
  # arca:db-raise-ok inside the caller's transaction
  defp join_threads!(athanor_id, %Turn{} = turn, threads) do
    joined =
      Arca.ThreadStorage.threads_text(Arca.ThreadStorage.threads_of(turn.read_threads) ++ threads)

    if joined == turn.read_threads do
      turn
    else
      {1, _} =
        from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn.id)
        |> Arca.Repo.update_all(set: [read_threads: joined])

      %{turn | read_threads: joined}
    end
  end

  # What a step opens with: the threads it names and the read threads of
  # the turns whose words its rows carry.
  # arca:db-raise-ok inside the caller's transaction
  defp opened_threads!(athanor_id, attrs) do
    threads!(Map.get(attrs, :threads, [])) ++
      turns_threads!(athanor_id, Map.get(attrs, :threads_from, []))
  end

  # The read threads of the turns `ids` names, as each stands — of any
  # thread of the athanor, since a reply or a request carries a turn's
  # words across threads. A turn the athanor holds no row of adds nothing.
  # arca:db-raise-ok inside the caller's transaction
  defp turns_threads!(_athanor_id, []), do: []

  defp turns_threads!(athanor_id, ids) when is_list(ids) do
    from(t in Turn, where: t.athanor_id == ^athanor_id and t.id in ^ids, select: t.read_threads)
    |> Arca.Repo.all()
    |> Enum.flat_map(&Arca.ThreadStorage.threads_of/1)
  end

  defp turns_threads!(_athanor_id, _other), do: Arca.Repo.rollback(:invalid_read_threads)

  # arca:db-raise-ok inside the caller's transaction
  defp threads!(threads) when is_list(threads) do
    if Enum.all?(threads, &is_binary/1),
      do: threads,
      else: Arca.Repo.rollback(:invalid_read_threads)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp threads!(_threads), do: Arca.Repo.rollback(:invalid_read_threads)

  # arca:db-raise-ok inside the caller's transaction
  defp insert_step!(athanor_id, %Turn{} = turn, attrs) do
    seq =
      Arca.Repo.one(
        from(s in TurnStep,
          where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
          select: coalesce(max(s.seq), 0)
        )
      ) + 1

    kind = Map.get(attrs, :kind, "tool")
    if kind not in @step_kinds, do: Arca.Repo.rollback({:invalid_step_kind, kind})
    purpose = Map.get(attrs, :purpose, "chat")

    if purpose not in TurnStep.purposes(),
      do: Arca.Repo.rollback({:invalid_step_purpose, purpose})

    Arca.Repo.insert!(%TurnStep{
      id: Map.get(attrs, :id) || Prima.UUID7.generate_id("stp"),
      athanor_id: athanor_id,
      turn_id: turn.id,
      seq: seq,
      kind: kind,
      purpose: purpose,
      idempotency_key: Map.get(attrs, :idempotency_key),
      tool: Map.get(attrs, :tool),
      action: Map.get(attrs, :action),
      dispatch_state: Map.get(attrs, :dispatch_state, "proposed"),
      message_id: Map.get(attrs, :message_id),
      authority_digest: Map.get(attrs, :authority_digest),
      request_digest: Map.get(attrs, :request_digest),
      recovery: Map.get(attrs, :recovery),
      excluded: encode(Map.get(attrs, :excluded)),
      child_execution_id: Map.get(attrs, :child_execution_id),
      started_at: if(Map.get(attrs, :dispatch_state) == "dispatched", do: DateTime.utc_now())
    })
  end

  # arca:db-raise-ok inside the caller's transaction
  defp event!(_athanor_id, %Turn{root_execution_id: nil}, _type, _step_id, _data), do: :ok

  defp event!(athanor_id, %Turn{} = turn, type, step_id, data) do
    Arca.ExecutionEvents.append!(Prima.Actor.in_athanor(athanor_id), turn.root_execution_id, type,
      turn_id: turn.id,
      step_id: step_id,
      data: reject_nil(data)
    )

    :ok
  end

  # The turn's root execution row, locked once the turn's own row is and
  # before any step or attempt row: every execution write takes the
  # execution row before any attempt row (`Arca.Execution.record_end/6`,
  # `Arca.Execution.mark_failed_if_running/3`,
  # `Arca.ExecutionAttempts.takeover!/3`), and an admission that locks the
  # root takes it before the step it binds, so a turn's transition and a
  # lapse, an end or an admission on its root never wait on each other in
  # opposite order. A turn with no root yet locks nothing.
  # arca:db-raise-ok inside the caller's transaction
  defp lock_root!(_athanor_id, %Turn{root_execution_id: nil}), do: :ok

  defp lock_root!(athanor_id, %Turn{root_execution_id: execution_id}) do
    from(e in Arca.Schemas.Execution,
      where: e.athanor_id == ^athanor_id and e.id == ^execution_id,
      select: e.id
    )
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.all()

    :ok
  end

  # Move the root execution between statuses, fenced on the turn's own
  # attempt being the pointer. `error:` sets the message on a terminal move.
  # arca:db-raise-ok inside the caller's transaction
  defp execution_status!(athanor_id, execution_id, from, to, opts \\ [])

  defp execution_status!(_athanor_id, nil, _from, _to, _opts), do: :ok

  # A write states the move its operation makes, which stays within
  # `Prima.ExecutionState`'s table: a move outside it is this module's
  # mistake and raises, rolling the caller's transaction back.
  defp execution_status!(athanor_id, execution_id, from, to, opts) do
    from = List.wrap(from)

    unless Enum.all?(from, &Prima.ExecutionState.transition?(:execution, &1, to)),
      do: raise(ArgumentError, "no execution status write moves #{Enum.join(from, "|")} to #{to}")

    sets =
      if to in Prima.ExecutionState.terminal_statuses(),
        do: [
          status: to,
          completed_at: DateTime.utc_now(),
          error_message: Keyword.get(opts, :error)
        ],
        else: [status: to]

    {count, _} =
      from(e in Arca.Schemas.Execution,
        where: e.id == ^execution_id and e.athanor_id == ^athanor_id,
        where: e.status in ^from
      )
      |> Arca.Repo.update_all(set: sets)

    if count != 1, do: Arca.Repo.rollback({:execution_not_in, from})
    :ok
  end

  # The highest seq a turn may read when it starts: its own initiating
  # message, and every unattached row or row of a settled turn.
  # arca:db-raise-ok inside the caller's transaction
  defp boundary(athanor_id, %Turn{} = turn) do
    settled = settled_turns(athanor_id, turn.thread_id)

    history =
      Arca.Repo.one(
        from(m in Message,
          where: m.athanor_id == ^athanor_id and m.thread_id == ^turn.thread_id,
          where: is_nil(m.turn_id) or m.turn_id in subquery(settled),
          select: coalesce(max(m.seq), 0)
        )
      )

    own =
      if turn.message_id do
        Arca.Repo.one(
          from(m in Message,
            where: m.athanor_id == ^athanor_id and m.id == ^turn.message_id,
            select: m.seq
          )
        ) || 0
      else
        0
      end

    max(history, own)
  end

  defp settled_turns(athanor_id, thread_id) do
    from(t in Turn,
      where: t.athanor_id == ^athanor_id and t.thread_id == ^thread_id,
      where: t.status in ^@terminal,
      select: t.id
    )
  end

  # Whether anything of the turn is still open, read in the transaction
  # that would write its end: a step proposed or dispatched, of whatever
  # kind (a page's call, an ask, a launch, a model's call, a delivery), or
  # a delivery a program still owes an answer for. A harness that said its
  # work was done asks for the end; this decides it.
  # arca:db-raise-ok inside the caller's transaction
  defp calls_pending?(athanor_id, %Turn{} = turn) do
    Arca.Repo.exists?(
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
        where: s.dispatch_state in ["proposed", "dispatched"]
      )
    ) or brain_owed?(athanor_id, turn)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp brain_owed?(athanor_id, %Turn{} = turn) do
    inputs =
      Arca.Repo.all(
        from(s in TurnStep,
          where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id and s.kind == "input",
          select: {s.id, s.dispatch_state, s.message_id}
        )
      )

    progress = progress(thread!(athanor_id, turn.thread_id))
    owed = progress["owed"] || []
    delivered = MapSet.new(inputs, &elem(&1, 2))

    Enum.any?(inputs, fn {id, state, _row} -> state == "dispatched" or id in owed end) or
      Enum.any?(closed_results(athanor_id, turn), &(not MapSet.member?(delivered, &1))) or
      owed_notices(athanor_id, turn, progress) != []
  end

  # A steer is a post (`post?/2`) written into the turn after the one that
  # opened it, that no step carried yet (`consumed!/3`, `carry/3`). A post
  # a round took in waits until that round's step carries it, so one whose
  # round died first is still owed a round. A turn stopped on an uncertain
  # call goes on only on a line past the boundary its stop moved, so while
  # it is so paused a post written before the stop is none.
  # arca:db-raise-ok inside the caller's transaction
  defp steer_rows(athanor_id, %Turn{} = turn) do
    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.turn_id == ^turn.id,
      where: is_nil(m.carried_by),
      where: ^post(turn.agent),
      order_by: [asc: m.seq]
    )
    |> steers_of(turn)
    |> Arca.Repo.all()
  end

  defp steers_of(query, %Turn{status: "paused", paused_reason: "uncertain"} = turn),
    do: from(m in query, where: m.seq > ^(turn.window_upto_seq || 0))

  defp steers_of(query, %Turn{message_id: opening}) when is_binary(opening),
    do: from(m in query, where: m.id != ^opening)

  defp steers_of(query, _turn), do: query

  # The thread's row, held until the caller's transaction ends.
  # arca:db-raise-ok inside the caller's transaction
  defp locked_thread!(athanor_id, thread_id) do
    from(c in Thread, where: c.athanor_id == ^athanor_id and c.id == ^thread_id)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> case do
      nil -> Arca.Repo.rollback(:thread_not_found)
      thread -> thread
    end
  end

  # arca:db-raise-ok inside the caller's transaction
  defp turn!(athanor_id, turn_id) do
    Arca.Repo.one(from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)) ||
      Arca.Repo.rollback(:turn_not_found)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp step!(athanor_id, step_id) do
    Arca.Repo.one(from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step_id)) ||
      Arca.Repo.rollback(:step_not_found)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp thread!(athanor_id, thread_id) do
    Arca.Repo.get_by(Thread, id: thread_id, athanor_id: athanor_id) ||
      Arca.Repo.rollback(:thread_not_found)
  end

  # The root's grant a turn write runs under, asked in the caller's
  # locking transaction once the turn row is taken and read again (and the
  # root execution's row, where the transition takes it through
  # `lock_root!/2`), before any step or attempt row is locked:
  # `attrs[:grant]` (`:stored` for
  # the stamp the turn's root attempt carries) checked by `attrs[:verify]`.
  # A write that must stand (`:required`) is refused without both inputs;
  # any other write names them only when the turn has a root attempt,
  # which `stamp!/3` enforces. Nil when the turn has no root attempt to
  # read a stamp from.
  # arca:db-raise-ok inside the caller's transaction
  defp standing!(athanor_id, %Turn{attempt: attempt}, attrs, need) do
    stored = fn ->
      if is_binary(attempt),
        do: Arca.ExecutionStanding.stored(Prima.Actor.in_athanor(athanor_id), attempt)
    end

    case Arca.ExecutionStanding.inputs(attrs, stored) do
      {:ok, %Prima.ExecutionGrant{athanor_id: ^athanor_id} = grant, verify} ->
        Arca.ExecutionStanding.verify!(grant, verify)
        grant

      {:ok, nil, _verify} ->
        nil

      {:ok, %Prima.ExecutionGrant{}, _verify} ->
        Arca.Repo.rollback(:not_standing)

      {:error, :missing_grant} when need == :required ->
        Arca.Repo.rollback(:missing_grant)

      {:error, :missing_grant} ->
        nil
    end
  end

  # A completion reports success, so it must stand; a failure, a cancel
  # and an uncertain end retire work.
  defp required_for("completed"), do: :required
  defp required_for(_retiring), do: :if_rooted

  # The grant the turn's root attempt is written under: the one checked
  # first, which must be the stamp that attempt carries. A root write that
  # named no grant is `:missing_grant`.
  # arca:db-raise-ok inside the caller's transaction
  defp stamp!(_athanor_id, %Turn{}, nil), do: Arca.Repo.rollback(:missing_grant)

  defp stamp!(athanor_id, %Turn{attempt: attempt}, %Prima.ExecutionGrant{} = grant)
       when is_binary(attempt) do
    if Arca.ExecutionStanding.stored(Prima.Actor.in_athanor(athanor_id), attempt) == grant,
      do: grant,
      else: Arca.Repo.rollback(:not_standing)
  end

  defp stamp!(_athanor_id, %Turn{}, %Prima.ExecutionGrant{}),
    do: Arca.Repo.rollback(:missing_grant)

  # The first write of a runner-owned transaction: the turn row, updated on
  # the fence the runner holds, which takes the row's lock for the rest of
  # the transaction. A fence another process moved matches no row.
  # arca:db-raise-ok inside the caller's transaction
  defp own!(athanor_id, turn_id, attrs) do
    fence = held_fence!(attrs)

    case from(t in Turn,
           where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.fence == ^fence
         )
         |> Arca.Repo.update_all(set: [fence: fence]) do
      {1, _} -> turn!(athanor_id, turn_id)
      {0, _} -> Arca.Repo.rollback(:superseded)
    end
  end

  # The thread's claim, taken for a root turn that is starting. One
  # statement naming the turn and the consumed sequence the caller read,
  # so of two members starting a turn on one thread exactly one write
  # matches; a claimant that reads no sequence of its own is held only to
  # the holder. A thread this turn already holds is answered, so a start
  # retried after a crash claims what it already had.
  # arca:db-raise-ok inside the caller's transaction
  defp claim_thread!(athanor_id, %Turn{} = turn, attrs) do
    thread = thread!(athanor_id, turn.thread_id)
    if thread.retired_at, do: Arca.Repo.rollback(:thread_retired)
    expected = Map.get(attrs, :turn_seq) || thread.turn_seq || 0

    # The statement checks the retirement again: one that commits after
    # the read above is seen by the write, which waits on its lock.
    claimed =
      from(c in Thread,
        where: c.id == ^turn.thread_id and c.athanor_id == ^athanor_id,
        where: c.turn_seq == ^expected and is_nil(c.retired_at),
        where: is_nil(c.active_turn_id) or c.active_turn_id == ^turn.id
      )
      |> Arca.Repo.update_all(set: [active_turn_id: turn.id])

    case claimed do
      {1, _} ->
        :ok

      # Read the row again before saying why: a peer's claim may have
      # committed between the read above and this statement, which is
      # exactly the race the statement is here to lose.
      {0, _} ->
        case thread!(athanor_id, turn.thread_id) do
          %Thread{retired_at: %DateTime{}} ->
            Arca.Repo.rollback(:thread_retired)

          %Thread{active_turn_id: held} when is_binary(held) ->
            Arca.Repo.rollback({:held_elsewhere, held})

          %Thread{} ->
            Arca.Repo.rollback(:stale)
        end
    end
  end

  # `own!/3` for a write keyed by one of the turn's steps.
  # arca:db-raise-ok inside the caller's transaction
  defp own_step!(athanor_id, step_id, attrs) do
    turn_id =
      Arca.Repo.one(
        from(s in TurnStep,
          where: s.athanor_id == ^athanor_id and s.id == ^step_id,
          select: s.turn_id
        )
      ) || Arca.Repo.rollback(:step_not_found)

    own!(athanor_id, turn_id, attrs)
  end

  # A host transition that takes the turn from whoever held it: the fence
  # the caller read is raised by one in the same write, so of two
  # transitions racing over one turn only the first lands.
  # arca:db-raise-ok inside the caller's transaction
  defp take!(athanor_id, turn_id, attrs) do
    fence = held_fence!(attrs)

    case from(t in Turn,
           where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.fence == ^fence
         )
         |> Arca.Repo.update_all(inc: [fence: 1]) do
      {1, _} ->
        turn!(athanor_id, turn_id)

      {0, _} ->
        Arca.Repo.rollback(:superseded)
    end
  end

  # A write of a turn in a crew member's thread that may move its room,
  # the workspace thread's state (`settle_work!/2`) or the room's archive
  # (`new_work!/2`), takes a second thread row, so it takes the athanor's
  # row after its turn and before any thread row: the order
  # `Arca.ThreadStorage.lock_threads!/2` states. Its callers are those
  # writes alone, a skip, a turn's end, its cancel and its set-downs (an
  # acceptance that opens or steers a turn there takes `work_rows!/2`);
  # any other write of a turn takes no second
  # thread row and no athanor lock, nor does a write of a turn that is
  # over, which skips and ends nothing. A thread's kind and room never
  # change, so they are read unlocked.
  # arca:db-raise-ok inside the caller's transaction
  defp work_lock!(athanor_id, %Turn{status: status, thread_id: thread_id}),
    do: if(status in @open, do: work_lock!(athanor_id, thread_id), else: :ok)

  defp work_lock!(athanor_id, thread_id) when is_binary(thread_id) do
    crew =
      from(c in Thread,
        where: c.athanor_id == ^athanor_id and c.id == ^thread_id and c.kind == "crew"
      )

    if Arca.Repo.exists?(crew),
      do: Arca.ThreadStorage.lock_athanor!(Prima.Actor.in_athanor(athanor_id))

    :ok
  end

  # An acceptance that may start work in a crew member's thread clears its
  # room's archive (`new_work!/2`), a second thread row: it takes the
  # athanor's row, then the room's row and its own together, in the one
  # order (`Arca.ThreadStorage.lock_threads!/2`). Any other thread takes
  # only its own row, which the acceptance reads under its lock. A
  # thread's kind and room never change, so they are read unlocked.
  # arca:db-raise-ok inside the caller's transaction
  defp work_rows!(%Prima.Actor{athanor_id: athanor_id} = actor, thread_id) do
    room =
      from(c in Thread,
        where: c.athanor_id == ^athanor_id and c.id == ^thread_id and c.kind == "crew",
        select: c.parent_id
      )
      |> Arca.Repo.one()

    if is_binary(room), do: Arca.ThreadStorage.lock_threads!(actor, [room, thread_id])
    :ok
  end

  # New work in `thread` takes its room, the thread itself or the room a
  # crew member's thread works under, out of the archive, by its own
  # statement in the work's transaction (`Arca.ThreadStorage.unarchive!/2`;
  # the moduledoc's "The archive"). A crew thread's caller holds the
  # athanor's row first (`work_lock!/2`).
  # arca:db-raise-ok inside the caller's transaction
  defp new_work!(%Prima.Actor{} = actor, %Thread{kind: "crew", parent_id: room})
       when is_binary(room),
       do: Arca.ThreadStorage.unarchive!(actor, room)

  defp new_work!(%Prima.Actor{} = actor, %Thread{id: id}),
    do: Arca.ThreadStorage.unarchive!(actor, id)

  @doc false
  # The one function a write that takes more than one turn takes them
  # through, in the one order: when each was accepted, then its id, the
  # order a thread's cancel always kept (`Arca.ThreadStorage.lock_threads!/2`
  # states the whole order). `turns` is a query over the turns to take, or
  # their ids; each is held until the caller's transaction ends, and their
  # ids are answered in that order. An in-transaction helper.
  @spec hold_turns!(Prima.Actor.t(), Ecto.Query.t() | [String.t()]) :: [String.t()]
  # arca:db-raise-ok inside the caller's transaction
  def hold_turns!(%Prima.Actor{} = actor, turn_ids) when is_list(turn_ids),
    do: hold_turns!(actor, from(t in Turn, where: t.id in ^turn_ids))

  # arca:db-raise-ok inside the caller's transaction
  def hold_turns!(%Prima.Actor{athanor_id: athanor_id}, %Ecto.Query{} = turns)
      when is_binary(athanor_id) and athanor_id != "" do
    from(t in turns,
      where: t.athanor_id == ^athanor_id,
      order_by: [asc: t.accepted_at, asc: t.id],
      select: t.id
    )
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  def hold_turns!(%Prima.Actor{}, _turn_ids),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.hold_turns!/2")

  # A turn that is over takes no further row or bookkeeping.
  # arca:db-raise-ok inside the caller's transaction
  defp open!(%Turn{status: status} = turn) when status in @open, do: turn
  defp open!(%Turn{}), do: Arca.Repo.rollback(:not_open)

  # The recovery limit a turn is held to: the one it stores, else the
  # policy the caller passes, which must be a positive count. A stored
  # limit is never replaced.
  # arca:db-raise-ok inside the caller's transaction
  defp recovery_limit!(%Turn{recovery_limit: limit}, _attrs) when is_integer(limit), do: limit

  defp recovery_limit!(%Turn{}, attrs) do
    case Map.get(attrs, :recovery_limit) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> Arca.Repo.rollback(:illegal_transition)
    end
  end

  # A takeover spends one of the recoveries the turn's row stores.
  # arca:db-raise-ok inside the caller's transaction
  defp spend_recovery!(%Turn{recovery_limit: limit, recovery_attempts: spent})
       when is_integer(limit) do
    if spent >= limit, do: Arca.Repo.rollback(:recovery_exhausted), else: :ok
  end

  defp spend_recovery!(%Turn{}), do: Arca.Repo.rollback(:illegal_transition)

  # The root a starting turn binds, read from its rows under the turn's
  # lock: a running `turn` execution of this turn, its current attempt
  # running, its open reservation and its profile. A value the caller
  # names must be the row's. A rootless turn binds no attempt and no
  # budget.
  # arca:db-raise-ok inside the caller's transaction
  defp root_of!(athanor_id, %Turn{id: turn_id}, attrs) do
    named = fn key -> Map.get(attrs, key) end

    case named.(:root_execution_id) do
      nil ->
        if named.(:attempt) || named.(:budget_id), do: Arca.Repo.rollback(:illegal_transition)
        %{execution_id: nil, attempt: nil, budget_id: nil, profile_id: named.(:profile_id)}

      execution_id when is_binary(execution_id) ->
        execution =
          from(e in Arca.Schemas.Execution,
            where: e.athanor_id == ^athanor_id and e.id == ^execution_id
          )
          |> Arca.QueryHelpers.for_update()
          |> Arca.Repo.one()

        case execution do
          %Arca.Schemas.Execution{
            kind: "turn",
            turn_id: ^turn_id,
            status: "running",
            current_attempt: attempt
          }
          when is_binary(attempt) ->
            running_attempt!(athanor_id, attempt)
            budget_id = open_reservation(athanor_id, execution_id)
            profile_id = execution.profile_id || named.(:profile_id)

            unless named?(named.(:attempt), attempt) and named?(named.(:budget_id), budget_id) and
                     named?(named.(:profile_id), profile_id),
                   do: Arca.Repo.rollback(:illegal_transition)

            %{
              execution_id: execution_id,
              attempt: attempt,
              budget_id: budget_id,
              profile_id: profile_id
            }

          _ ->
            Arca.Repo.rollback(:illegal_transition)
        end

      _ ->
        Arca.Repo.rollback(:illegal_transition)
    end
  end

  defp named?(nil, _stored), do: true
  defp named?(value, stored), do: value == stored

  # arca:db-raise-ok inside the caller's transaction
  defp running_attempt!(athanor_id, attempt) do
    from(a in Arca.Schemas.ExecutionAttempt,
      where: a.athanor_id == ^athanor_id and a.attempt == ^attempt and a.state == "running"
    )
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one() || Arca.Repo.rollback(:illegal_transition)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp open_reservation(athanor_id, execution_id) do
    Arca.Repo.one(
      from(r in Arca.Schemas.BudgetReservation,
        where: r.athanor_id == ^athanor_id and r.root_execution_id == ^execution_id,
        where: is_nil(r.released_at),
        select: r.id
      )
    )
  end

  # The step a pause names: a launch pause names a `launch` step of the
  # turn, and no other pause names one.
  # arca:db-raise-ok inside the caller's transaction
  defp launch_step!(athanor_id, %Turn{id: turn_id}, "launch", step_id) when is_binary(step_id) do
    case step!(athanor_id, step_id) do
      %TurnStep{turn_id: ^turn_id, kind: "launch"} -> step_id
      %TurnStep{} -> Arca.Repo.rollback(:illegal_transition)
    end
  end

  defp launch_step!(_athanor_id, %Turn{}, reason, nil) when reason != "launch" do
    if reason in Prima.TurnState.pause_reasons(),
      do: nil,
      else: Arca.Repo.rollback(:illegal_transition)
  end

  defp launch_step!(_athanor_id, %Turn{}, _reason, _step_id),
    do: Arca.Repo.rollback(:illegal_transition)

  # A launch lets its turn's root go: not while another step whose run is a
  # child of that root is dispatched, and its own step is dispatched in the
  # pause's write.
  # arca:db-raise-ok inside the caller's transaction
  defp launch_dispatched!(athanor_id, %Turn{id: turn_id}, step_id) do
    running =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn_id and s.id != ^step_id,
        where: s.dispatch_state == "dispatched" and not is_nil(s.child_execution_id)
      )

    if Arca.Repo.exists?(running), do: Arca.Repo.rollback(:child_running)

    {count, _} =
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.id == ^step_id,
        where: s.dispatch_state == "proposed" and is_nil(s.cancel_requested_at)
      )
      |> Arca.Repo.update_all(set: [dispatch_state: "dispatched", started_at: DateTime.utc_now()])

    if count != 1, do: Arca.Repo.rollback(:not_proposed)
    :ok
  end

  # A running turn's root attempt leaves `running` with it; an attempt
  # that is not the running owner refuses the pause. A rootless turn has
  # no interval to close.
  # arca:db-raise-ok inside the caller's transaction
  defp pause_owner!(_athanor_id, %Turn{attempt: nil}), do: 0

  defp pause_owner!(athanor_id, %Turn{attempt: attempt}) do
    Arca.ExecutionAttempts.pause!(Prima.Actor.in_athanor(athanor_id), attempt) ||
      Arca.Repo.rollback(:attempt_not_owner)
  end

  # The `crew_reply` of a turn with a reply address, recorded in the
  # transaction that ends it: the requests it answers
  # are every request delivered into it, opening one first, each named
  # by its delivered row's payload.
  # arca:db-raise-ok inside the caller's transaction
  defp replied!(_athanor_id, %Turn{asking_thread_id: nil}, _outcome, _at, _text), do: :ok

  defp replied!(athanor_id, %Turn{} = turn, outcome, %DateTime{} = at, text) do
    requests =
      from(m in Message,
        where: m.athanor_id == ^athanor_id and m.turn_id == ^turn.id,
        where: m.sent_by != ^turn.agent and not is_nil(m.payload),
        order_by: [asc: m.seq],
        select: m.payload
      )
      |> Arca.Repo.all()
      |> Enum.flat_map(fn json ->
        case Arca.ThreadStorage.payload(%{payload: json}) do
          %{"request_id" => id} when is_binary(id) and id != "" -> [id]
          _ -> []
        end
      end)

    # Recorded under the identity of the request it answers, which the
    # asking turn wrote: never the answering turn's own, so a damaged
    # child row still answers. A request gone with its room is answered
    # by nobody.
    case asked_by(athanor_id, turn.request_id) do
      {:ok, person_id, origin} ->
        reply!(athanor_id, turn, outcome, at, text, requests, person_id, origin)

      :gone ->
        :ok
    end
  end

  # arca:db-raise-ok inside the caller's transaction
  defp asked_by(athanor_id, request_id) do
    with %Message{} = row <-
           Arca.Repo.one(
             from(m in Message, where: m.athanor_id == ^athanor_id and m.id == ^request_id)
           ),
         %{"person_id" => person_id, "origin" => wire} when is_binary(person_id) <-
           Arca.ThreadStorage.payload(row),
         {:ok, origin} <- Prima.Origin.from_wire(wire) do
      {:ok, person_id, origin}
    else
      _ -> :gone
    end
  end

  # arca:db-raise-ok inside the caller's transaction
  defp reply!(athanor_id, %Turn{} = turn, outcome, at, text, requests, person_id, origin) do
    record =
      Prima.OutboxRecord.crew_reply(%{
        athanor_id: athanor_id,
        turn_id: turn.id,
        ended_at: at,
        asking_thread_id: turn.asking_thread_id,
        request_ids: Enum.uniq([turn.request_id | requests]),
        member: turn.agent,
        outcome: outcome,
        text: text || "",
        person_id: person_id,
        origin: origin
      })

    :ok = Arca.Outbox.put!(Prima.Actor.in_athanor(athanor_id), record)
  end

  defp reply_outcome("completed"), do: "done"
  defp reply_outcome("failed"), do: "failed"
  defp reply_outcome("cancelled"), do: "cancelled"
  defp reply_outcome("uncertain"), do: "uncertain"

  # What a reply says: a completed turn's last own reply, and for any
  # other end the error that ended it.
  # arca:db-raise-ok inside the caller's transaction
  defp final_text(_athanor_id, %Turn{asking_thread_id: nil}, _status, _attrs), do: nil

  defp final_text(athanor_id, %Turn{} = turn, "completed", _attrs) do
    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.turn_id == ^turn.id,
      where: m.kind == "text" and m.sent_by == ^turn.agent,
      order_by: [desc: m.seq],
      limit: 1,
      select: m.content
    )
    |> Arca.Repo.one()
    |> case do
      text when is_binary(text) and text != "" -> text
      _ -> "#{turn.agent} answered nothing."
    end
  end

  defp final_text(_athanor_id, %Turn{} = turn, status, attrs) do
    case Map.get(attrs, :error) do
      error when is_binary(error) and error != "" -> error
      _ -> "#{turn.agent}'s turn ended #{status}."
    end
  end

  # The program's native session a batch's `started` names, kept on the
  # thread for its next start. `commit_events/3` holds the thread's lock and
  # has refused a batch whose generation moved, so a forget committed since
  # the turn read the thread (`Arca.ThreadStorage.forget_sessions/2`,
  # `forget_session/3`) refused the batch before this write.
  # arca:db-raise-ok inside the caller's transaction
  defp keep_session!(athanor_id, %Thread{id: thread_id, brain_session: current}, session) do
    if is_binary(session) and session != "" and session != current do
      {_kept, _} =
        from(c in Thread, where: c.athanor_id == ^athanor_id and c.id == ^thread_id)
        |> Arca.Repo.update_all(set: [brain_session: session])
    end

    :ok
  end

  defp held_fence!(attrs) do
    case Map.get(attrs, :fence) do
      fence when is_integer(fence) -> fence
      _ -> Arca.Repo.rollback(:fence_required)
    end
  end

  # A steer's turn, its row locked as the transaction's first write — the
  # order every runner-owned write follows (turn, then thread).
  # arca:db-raise-ok inside the caller's transaction
  # A steer's turn, held; a delivered request that steers a turn with no
  # reply address yet gives it one, so the turn replies to every request
  # it carries.
  # arca:db-raise-ok inside the caller's transaction
  defp steered!(athanor_id, thread_id, turn_id, nil),
    do: hold_open_turn!(athanor_id, thread_id, turn_id)

  defp steered!(athanor_id, thread_id, turn_id, %{} = address) do
    case hold_open_turn!(athanor_id, thread_id, turn_id) do
      %Turn{asking_thread_id: nil} ->
        {1, _} =
          from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
          |> Arca.Repo.update_all(
            set: [
              asking_thread_id: Map.fetch!(address, :asking_thread_id),
              request_id: Map.fetch!(address, :request_id)
            ]
          )

        turn!(athanor_id, turn_id)

      %Turn{} = turn ->
        turn
    end
  end

  defp hold_open_turn!(athanor_id, thread_id, turn_id) do
    held =
      from(t in Turn,
        where: t.athanor_id == ^athanor_id and t.id == ^turn_id and t.thread_id == ^thread_id,
        where: t.status in ^@open,
        update: [set: [status: t.status]]
      )
      |> Arca.Repo.update_all([])

    case held do
      {1, _} -> turn!(athanor_id, turn_id)
      {0, _} -> Arca.Repo.rollback(:turn_over)
    end
  end

  defp encode(nil), do: nil
  defp encode(value) when is_binary(value), do: value
  defp encode(value), do: Jason.encode!(value)

  defp reject_nil(map) when is_map(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end
end
