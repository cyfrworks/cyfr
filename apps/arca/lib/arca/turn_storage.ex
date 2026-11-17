# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TurnStorage do
  @moduledoc """
  The durable turn: `turns`, `turn_steps`, `approvals`, the message rows
  a turn writes and the events it records, each transition one
  transaction.

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
  A step is proposed before its effect (`record_response/4`), flipped to
  `dispatched` in its own commit (`dispatch_step/3`), and closed with its
  result row, outcome and event together (`close_step/4`). Pause and
  resume flip the turn, its root attempt and its root execution in one
  transaction; `finish/4` is the one terminal write.

  Multi-row writes that append a message run under `with_seq_retry/1`:
  the `(thread_id, seq)` race surfaces as a changeset raise inside
  the transaction and the whole transaction is retried, since a retry
  inside an aborted Postgres transaction cannot land.

  ## The turn's sources

  `turns.sources` is every source the turn has read (`Prima.Source`), a
  set that only grows. It grows in the transaction that writes the step
  a read belongs to, after the turn row is taken: `put_step/3` joins the
  sources the step opens with (`:sources`) and the sources of the turns
  whose words the rows it sends carry (`:sources_from`): the thread's
  earlier turns, and a crew member's turn whose reply, or the soul's turn
  whose request, a row brings across threads. `close_step/4` joins
  the sources of its result (`:sources`), and of a component it launched
  (`:launched`): outside, named by its reference, unless the launch's
  completion result says no run of its tree was admitted with egress.

  ## The thread claim

  Which root turn may run at all is the thread's, not the turn's:
  `threads.active_turn_id` (`Arca.ThreadStorage`). `start/3` takes it in
  the transaction that moves the turn to `running`, naming the consumed
  sequence the caller read; `finish/4` gives it up; `takeover/3` and
  `pause_recovered/3` take it from a turn whose holder is not a live
  member, in the same transaction that counts the recovery — so a member
  that did not take the claim cannot spend one.
  An approval pause keeps the claim: the turn is still this member's work.

  ## Crew requests and replies

  A request to a crew member is a row of its room accepted with the
  `crew_request` outbox record that delivers it (`accept_message/3`'s
  `:request`), and a turn a delivered request opens stores the reply
  address. Every terminal write of such a turn (`finish/4`) records its
  `crew_reply` in that transaction, and a card it opens
  (`open_approval/3`) records a `needs_you` one, so a crash after the
  commit loses no answer. The consumer's receipt is written in the
  transaction that lands the delivery (`accept_message/3`'s `:receipt`),
  and a reply marks the requests it answers in that transaction too
  (`:answers`).

  ## Workspace threads

  A workspace thread is opened, or asked again, in one transaction
  (`open_workspace/2`): the thread, its opening row, the daily thread's
  pointer and the `workspace_open` record whose delivery opens the turn
  on that opening (`accept_message/3`'s `:opening_id`).

  One rule decides its state (`work_state!/2`), and every write that may
  move it asks the rule in its own transaction: a workspace thread is
  `needs_you` while a card waits in it or in a crew thread under it;
  otherwise `open` while anything it accepted remains to run there; and
  once nothing does, how its work last ended since it last took new work
  (`workspace_outcome`): `done` or `needs_you` as Aqua reported it,
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
    * a card opened there or in a crew thread under it (`open_approval/3`),
      which records a `needs_you` report, a notice naming the card, when
      the thread comes to wait; a notice is no report of the turn's work;
    * a card left `pending` by a decision, a skip or an invalidation, a
      turn's end there or in a crew thread under it, and a row landing
      there (a crew member's answer among them), reporting nothing;
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
  post, a report or a card's notice that starts work among them, and not
  a page's call (`accept_message/3`); a further opening
  (`open_workspace/2`); and a decision that resumes a turn there or in a
  crew thread under it (`resolve_approval/4`). A write in a crew thread
  takes the athanor's row before the thread rows (`work_lock!/2`; an
  acceptance there takes its room's row and its own together,
  `work_rows!/2`), as a write that may move a workspace thread's state
  does. A retired crew
  thread is another fact (`retired_at`): it admits nothing.

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
  dispatched and its stored recovery is replay-safe; a decision writes
  the one resolution its step's kind allows and never changes that kind;
  and a write on a turn's rows is refused once the turn is over
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

  alias Arca.Schemas.{Approval, Thread, Message, Turn, TurnStep}

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
  @decisions Prima.TurnState.decisions()
  @invalidated Prima.TurnState.invalidated()
  # The open turns a takeover moves: an `accepted` turn has no root
  # attempt yet, so nothing of it is held to take over.
  @held @open -- ["accepted"]

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
    tools, options, person_id, origin}`, recorded as its `crew_request`
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

  A card's notice (a `needs_you` row naming its `:approval_id`, written
  `pending`) is written only while its approval waits: read under a lock
  the decision's write waits on, so a decision committed first refuses it
  `{:error, :card_decided}` with nothing written, and one after it
  resolves it (`resolve_approval/4`).

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
          still_waits!(workspace, thread, Map.get(attrs, :wait))
          card_waits!(athanor_id, message)
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
            do: settle_work!(athanor_id, thread, acted?(message))

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

  # arca:db-raise-ok inside the caller's transaction
  defp card_waits!(athanor_id, %{outcome: "needs_you", approval_id: id}) when is_binary(id) do
    from(a in Approval, where: a.athanor_id == ^athanor_id and a.id == ^id, select: a.status)
    |> Arca.QueryHelpers.for_share()
    |> Arca.Repo.one()
    |> case do
      "pending" -> :ok
      _decided_or_gone -> Arca.Repo.rollback(:card_decided)
    end
  end

  defp card_waits!(_athanor_id, _message), do: :ok

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
        tools: Map.get(request, :tools),
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
  nothing else it accepted remains to run and no card waits (the
  moduledoc's "Workspace threads"). `attrs`:
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
  # answer (`Arca.ThreadStorage.pending_requests/2`'s; a notice, which
  # answers one, waits with its card instead), and its openings still
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
  # after the latest of them: Aqua's report, a stop or an error since. A
  # card's notice writes none.
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
  # sources; one with no turn (an opening refused before any started) is
  # the server's, under the identity the opening was asked with, and
  # carries no sources.
  # arca:db-raise-ok inside the caller's transaction
  defp reported!(athanor_id, %Thread{} = thread, turn, outcome, report) do
    {turn_id, person_id, wire, sources} =
      case turn do
        %Turn{} ->
          {turn.id, turn.requested_by, turn.origin, Prima.Source.decode(turn.sources)}

        nil ->
          {nil, Map.fetch!(report, :person_id), Map.fetch!(report, :origin), []}
      end

    with {:ok, origin} <- Prima.Origin.from_wire(wire) do
      record =
        Prima.OutboxRecord.workspace_report(%{
          approval_id: Map.get(report, :approval_id),
          athanor_id: athanor_id,
          workspace_id: thread.id,
          title: thread.title,
          turn_id: turn_id,
          moved_at: DateTime.utc_now(),
          outcome: outcome,
          summary: Map.get(report, :summary) || "",
          attachments: Map.get(report, :attachments, []),
          sources: sources,
          person_id: person_id,
          origin: origin
        })

      :ok = Arca.Outbox.put!(Prima.Actor.in_athanor(athanor_id), record)
    else
      _no_origin -> Arca.Repo.rollback(:no_origin)
    end
  end

  # The one rule of a workspace thread's state, which every write that may
  # move it asks (a report, a card opened or settled, a turn's end, a
  # stop, a crew member's answer, new work): it waits on its person while
  # a card waits in it or in a crew thread under it; otherwise it is at
  # work while work remains there (`work!/3`); once nothing does, it is
  # how its work last ended since it last took new work
  # (`workspace_outcome`), or at work when nothing ended it. `except`
  # names a turn the rule reads the thread without (a nudge's turn asking,
  # as it starts, whether its line still stands).
  # arca:db-raise-ok inside the caller's transaction
  defp work_state!(athanor_id, %Thread{kind: "workspace"} = workspace, except \\ nil) do
    %{card_waits: card_waits, work_remains: work_remains} =
      work!(athanor_id, workspace, except)

    cond do
      card_waits -> "needs_you"
      work_remains -> "open"
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
      do: work!(athanor_id, room).work_remains

  # What the one rule reads of a room, a daily or a workspace thread, and
  # the crew threads under it: whether a card waits in any of them, and
  # whether work remains there. Work remains while a turn of any of them
  # is open, unless it waits on a card that waits, it has reported its
  # work (a workspace thread's turn reports once, and its row stays open
  # until it ends) or a page's call in any of them opened it (`page_call`,
  # which asks no model and is no work of the thread's, while a card it
  # raises waits on the person as any card does); while a request it
  # asked a crew member is left until its answer lands; and while an
  # opening waits for its turn to start. `except` names one open turn read
  # as though it were not there.
  # arca:db-raise-ok inside the caller's transaction
  defp work!(athanor_id, %Thread{} = room, except \\ nil) do
    threads =
      from(c in Thread,
        where: c.athanor_id == ^athanor_id,
        where: c.id == ^room.id or (c.kind == "crew" and c.parent_id == ^room.id),
        select: c.id
      )

    card_waits =
      from(a in Approval,
        where: a.athanor_id == ^athanor_id and a.thread_id in subquery(threads),
        where: a.status == "pending"
      )

    pages =
      from(m in Message,
        where: m.athanor_id == ^athanor_id and m.thread_id in subquery(threads),
        where: m.kind == "page_call",
        select: m.id
      )

    turns_run =
      from(t in Turn,
        where: t.athanor_id == ^athanor_id and t.thread_id in subquery(threads),
        where:
          t.status in ^@open and
            t.id not in ^Enum.reject([except | reported_turns(athanor_id, room.id)], &is_nil/1),
        where: is_nil(t.message_id) or t.message_id not in subquery(pages),
        where:
          t.id not in subquery(
            from(a in card_waits, where: not is_nil(a.turn_id), select: a.turn_id)
          )
      )

    asked =
      from(m in Message,
        where: m.athanor_id == ^athanor_id and m.thread_id == ^room.id,
        where:
          (m.kind == "opening" and is_nil(m.turn_id) and is_nil(m.status)) or
            (not is_nil(m.addressee) and m.status == "pending")
      )

    %{
      card_waits: Arca.Repo.exists?(card_waits),
      work_remains: Arca.Repo.exists?(turns_run) or Arca.Repo.exists?(asked)
    }
  end

  # The workspace thread's state as the rule now has it, written when it
  # moved, and the wait it waits on its person (`waited!/3`). `acted?` is an
  # act of the person's on the thread: a post of theirs there, or a card
  # of it they decided. Answers the thread as it stands.
  # arca:db-raise-ok inside the caller's transaction
  defp settle_work!(athanor_id, %Thread{kind: "workspace"} = workspace, acted? \\ false) do
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

    waited!(athanor_id, moved, moved.workspace_state != workspace.workspace_state or acted?)
  end

  # The one writer of `waits_since`: a thread that reads `needs_you` or
  # `error` and has just come to read so (from any other state, the other
  # of the two included), or that the person has just acted on while it
  # still waits, begins a new wait, stamped by the database's clock and
  # later than the wait before it whatever that clock did, so no two waits
  # of a thread share a stamp. A thread that stops waiting keeps its last
  # stamp. The server's post of a wait names it by it
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

  # A person's post in a workspace thread is an act of theirs on it.
  defp acted?(%{sent_by: "person"}), do: true
  defp acted?(_message), do: false

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
  # `done` or `needs_you`, or the server's `error`. A card's notice (a
  # `needs_you` record naming its approval) reports no turn's work.
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
        {:ok, %{"approval_id" => _card}} ->
          []

        {:ok, %{"turn_id" => turn_id}} when is_binary(turn_id) ->
          [turn_id]

        _no_turn ->
          []
      end
    end)
  end

  # A card opened in a workspace thread, or in a crew member's thread
  # under it, whose job is part of its work: the thread waits on its
  # person, and the daily thread is told when it did not already.
  # arca:db-raise-ok inside the caller's transaction
  defp waits!(athanor_id, %Thread{} = thread, turn, approval_id) do
    case work_of(athanor_id, thread) do
      %Thread{workspace_state: was} = workspace ->
        settled = settle_work!(athanor_id, workspace)

        if was != "needs_you" and settled.workspace_state == "needs_you",
          do: reported!(athanor_id, workspace, turn, "needs_you", %{approval_id: approval_id})

      nil ->
        :ok
    end
  end

  # A card left `pending` by any way, a decision, a skip or an
  # invalidation: the thread's state asked again, reporting nothing. A
  # card the person decided (`acted?`) is an act of theirs on the thread.
  # arca:db-raise-ok inside the caller's transaction
  defp settled!(athanor_id, thread_id, acted? \\ false) do
    case work_of(athanor_id, thread!(athanor_id, thread_id)) do
      %Thread{} = workspace -> settle_work!(athanor_id, workspace, acted?)
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
  Otherwise (a page's call's turn holds it, one paused on a card or an
  uncertain call, a turn queued or an opening waiting with nothing
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
  # nothing otherwise. A turn paused on a card or an uncertain call waits
  # for the person, whose acknowledgement a timer never stands in for, and
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

  # A model step opened on a turn carries the nudges the turn had read by
  # then, past its boundary or not: each still waiting names the step.
  # Taken under the turn's lock, after `drain_steer/3` moved the boundary
  # past what the step's request carries.
  # arca:db-raise-ok inside the caller's transaction
  defp consumed!(athanor_id, %Turn{} = turn, %{id: step_id, kind: "model", purpose: "chat"}) do
    from(m in Message,
      where: m.athanor_id == ^athanor_id and m.turn_id == ^turn.id and m.kind == "nudge",
      where: m.seq <= ^(turn.window_upto_seq || 0) and is_nil(m.resolved_by)
    )
    |> Arca.Repo.update_all(set: [resolved_by: step_id, resolved_at: DateTime.utc_now()])

    :ok
  end

  defp consumed!(_athanor_id, _turn, _step), do: :ok

  # Whether nothing has happened in the workspace thread or a crew thread
  # under it for `seconds`, by the database's clock: no post, no step
  # starting or ending, no card made or decided and no turn accepted or
  # ended there since. A nudge, a page's call and its result, a page's
  # steps and a turn a page's call opened are no activity of the thread's
  # (`page_call?/2`), and neither is what is read, a read mark, the
  # timer's own reads, a delivery's receipt or output streamed and not
  # recorded, none of which is a row here.
  # arca:db-raise-ok inside the caller's transaction
  defp quiet?(athanor_id, workspace_id, seconds) when is_integer(seconds) and seconds > 0 do
    since = DateTime.add(Arca.ServerMetaStorage.now!(), -seconds, :second)

    threads =
      from(c in Thread,
        where: c.athanor_id == ^athanor_id,
        where: c.id == ^workspace_id or (c.kind == "crew" and c.parent_id == ^workspace_id),
        select: c.id
      )

    pages =
      from(m in Message,
        where: m.athanor_id == ^athanor_id and m.thread_id == ^workspace_id,
        where: m.kind == "page_call",
        select: m.id
      )

    turns =
      from(t in Turn,
        where: t.athanor_id == ^athanor_id and t.thread_id in subquery(threads),
        where: is_nil(t.message_id) or t.message_id not in subquery(pages)
      )

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
          where: s.started_at > ^since or s.ended_at > ^since
        ),
        from(a in Approval,
          where: a.athanor_id == ^athanor_id and a.thread_id in subquery(threads),
          where: a.inserted_at > ^since or a.decided_at > ^since
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
  positive count, required), and the consumption boundary set to the
  highest seq the turn may read now. Event `turn.started`.

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

        sets = [
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
        ]

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

  @doc """
  Pin the exact catalyst release the turn runs on, under `:fence`. A turn
  pins once: pinning the release already pinned answers the turn, and a
  different one is `{:error, :catalyst_pinned}`; a turn that is over pins
  nothing (`{:error, :not_open}`).
  """
  @spec pin_catalyst(Prima.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def pin_catalyst(%Prima.Actor{athanor_id: athanor_id}, turn_id, catalyst_ref, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(catalyst_ref) and
             is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pin_catalyst", fn ->
      Arca.Repo.locking_transaction(fn ->
        case open!(own!(athanor_id, turn_id, attrs)) do
          %Turn{catalyst_ref: nil} ->
            {1, _} =
              from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn_id)
              |> Arca.Repo.update_all(set: [catalyst_ref: catalyst_ref])

            turn!(athanor_id, turn_id)

          %Turn{catalyst_ref: ^catalyst_ref} = turn ->
            turn

          %Turn{} ->
            Arca.Repo.rollback(:catalyst_pinned)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def pin_catalyst(%Prima.Actor{}, _turn_id, _catalyst_ref, _attrs), do: {:error, :no_athanor}

  @doc """
  Pause a running turn: the turn, its root attempt and its root execution
  leave `running` together. `attrs`: `:fence`, `:reason`
  (`Prima.TurnState.pause_reasons/0`, `"approval"` when absent), and
  `:launch_step_id` — a `launch` step of this turn, named for a launch
  pause and for no other. A root attempt that is not the running owner
  refuses the pause (`{:error, :attempt_not_owner}`). The running
  interval is added to `active_ms`. Event `turn.paused`.
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
        reason = Map.get(attrs, :reason) || "approval"
        launch_step_id = launch_step!(athanor_id, turn, reason, Map.get(attrs, :launch_step_id))
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
  (still `accepted`) closes on its own. A turn with a steer past its
  boundary refuses `completed` with `{:error, :steer_pending}`: its loop
  goes on to answer the steer; one with a page's call the host proposed
  in it and nobody dispatched yet refuses it with
  `{:error, :call_pending}`: its loop goes on to dispatch the call. A turn with a root attempt ends under its
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
  by `Prima.TurnStep.unresolved/1`, its proposed ones skipped with their
  cards invalidated, and the turn ended `cancelled` with `attrs[:error]`
  by the one terminal write, its reply recorded (`:reply`) or not
  (`:silent`, for a room that is going). `attrs` carry the root's grant
  as `finish/4` takes it, `:ended_by` as `finish/4` takes it, and
  `:only`, when given, the ids of the open turns to cancel, the others
  left as they are.

  Answers each cancelled turn with the steps that were dispatched: what
  its holder's runtime cancels after the commit — the loop, an
  in-process handler, a child execution (`Aqua.Loop.abort_ended/4`).
  """
  @spec cancel_open!(Prima.Actor.t(), String.t(), map(), :reply | :silent) :: [
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
      _ended = ended!(athanor_id, turn, "cancelled", grant, attrs, reply)

      %{
        turn_id: turn_id,
        thread_id: thread_id,
        steps: Enum.map(dispatched, &Map.take(&1, [:id, :generation, :kind, :child_execution_id]))
      }
    end)
  end

  def cancel_open!(%Prima.Actor{}, _thread_id, _attrs, _reply),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.cancel_open!/4")

  defp only_steps(query, nil), do: query
  defp only_steps(query, ids) when is_list(ids), do: where(query, [s], s.id in ^ids)

  defp only(query, nil), do: query
  defp only(query, ids) when is_list(ids), do: from(t in query, where: t.id in ^ids)

  @doc """
  The child threads of `thread_ids` holding a turn paused on a card, by
  their member: what a room's deletion waits on, inside the caller's
  transaction.
  """
  @spec awaiting_card!(Prima.Actor.t(), [String.t()]) :: [String.t()]
  # arca:db-raise-ok a step inside the caller's transaction
  def awaiting_card!(%Prima.Actor{athanor_id: athanor_id}, thread_ids)
      when is_binary(athanor_id) and athanor_id != "" and is_list(thread_ids) do
    from(t in Turn,
      join: c in Thread,
      on: c.id == t.thread_id and c.athanor_id == t.athanor_id,
      where: t.athanor_id == ^athanor_id and t.thread_id in ^thread_ids,
      where: t.status == "paused" and t.paused_reason == "approval",
      distinct: true,
      select: c.agent
    )
    |> Arca.Repo.all()
  end

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
  `:request_digest`, `:proposal_digest`, `:recovery`, `:excluded` (a
  list), `:message_id`, `:child_execution_id`, `:dispatch_state`
  (`Prima.TurnState.opening_states/0`, default `proposed`), `:fence`,
  and the sources the step opens with: `:sources` (`Prima.Source`s) and
  `:sources_from` (the ids of the athanor's turns whose words the rows the
  step sends carry, each turn's sources joined as it stands), and `:call`:
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

        turn = join_sources!(athanor_id, turn, opened_sources!(athanor_id, turn, attrs))
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
    row =
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

    attrs |> Map.delete(:call) |> Map.put(:message_id, row.id)
  end

  defp carried!(_actor, _athanor_id, _turn, attrs), do: attrs

  @doc """
  Persist a model response before any of its calls run: the model step
  closes with its usage, the reply and every tool call become message
  rows, every call becomes a `proposed` step, and one event records it.
  `response`: `:text`, `:usage`, `:stop_reason`, `:session` (the
  brain's session, kept on the thread as `brain_session` for its next
  request) with `:generation` (the thread's `brain_generation` the turn
  read; required with a session), `:tool_calls` — each
  `%{tool_call_id, name, tool, action, arguments, provider_data, kind,
  recovery, child_execution_id}`; `:fence`. The model step must be a
  `model` step of this turn (`{:error, :step_not_found}` otherwise), and
  a call's `recovery` is none or one of `Prima.TurnState.recoveries/0`
  (`{:error, :illegal_transition}` otherwise): it is stored with the
  step, and the step's stored value alone later decides a replay
  (`next_generation/3`). Answers
  `{:ok, %{text: row | nil, calls: [%{message: row, step: step}]}}`.
  """
  @spec record_response(Prima.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, %{text: map() | nil, calls: [map()]}} | {:error, term()}
  def record_response(
        %Prima.Actor{athanor_id: athanor_id} = actor,
        turn_id,
        model_step_id,
        response
      )
      when is_binary(athanor_id) and athanor_id != "" and is_map(response) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.record_response", fn ->
      with_seq_retry(fn ->
        Arca.Repo.locking_transaction(fn ->
          turn = own!(athanor_id, turn_id, response)
          model_step = step!(athanor_id, model_step_id)

          if model_step.turn_id != turn.id or model_step.kind != "model",
            do: Arca.Repo.rollback(:step_not_found)

          calls = Map.get(response, :tool_calls, [])

          if Enum.any?(
               calls,
               &(Map.get(&1, :recovery) not in [nil | Prima.TurnState.recoveries()])
             ),
             do: Arca.Repo.rollback(:illegal_transition)

          thread = thread!(athanor_id, turn.thread_id)
          now = DateTime.utc_now()
          keep_session!(athanor_id, thread, response)

          text =
            case Map.get(response, :text) do
              nil ->
                nil

              "" ->
                nil

              content ->
                Arca.ThreadStorage.insert_message!(actor, thread, %{
                  author: Message.agent_author(),
                  sent_by: turn.agent,
                  kind: "text",
                  content: content,
                  payload: %{"step_id" => model_step_id},
                  turn_id: turn_id,
                  execution_id: turn.root_execution_id
                })
            end

          {1, _} =
            from(s in TurnStep,
              where: s.athanor_id == ^athanor_id and s.id == ^model_step_id,
              where: s.turn_id == ^turn_id and s.dispatch_state in ["proposed", "dispatched"]
            )
            |> Arca.Repo.update_all(
              set: [
                dispatch_state: "closed",
                outcome: "ok",
                usage: encode(Map.get(response, :usage)),
                result_message_id: text && text.id,
                ended_at: now
              ]
            )

          # A call serves what the request that proposed it served.
          purpose = model_step.purpose

          calls =
            Enum.map(calls, fn call ->
              row =
                Arca.ThreadStorage.insert_message!(actor, thread, %{
                  author: Message.agent_author(),
                  sent_by: turn.agent,
                  kind: "tool_call",
                  content: Map.get(call, :name, ""),
                  payload:
                    %{
                      "tool_call_id" => Map.get(call, :tool_call_id),
                      "name" => Map.get(call, :name),
                      "tool" => Map.get(call, :tool),
                      "action" => Map.get(call, :action),
                      "arguments" => Map.get(call, :arguments),
                      "provider_data" => Map.get(call, :provider_data),
                      "kind" => Map.get(call, :kind),
                      "step_id" => model_step_id
                    }
                    |> reject_nil(),
                  turn_id: turn_id,
                  execution_id: turn.root_execution_id
                })

              step =
                insert_step!(athanor_id, turn, %{
                  kind: Map.get(call, :step_kind, "tool"),
                  purpose: purpose,
                  tool: Map.get(call, :tool),
                  action: Map.get(call, :action),
                  idempotency_key: Map.get(call, :idempotency_key),
                  proposal_digest: Map.get(call, :proposal_digest),
                  recovery: Map.get(call, :recovery),
                  message_id: row.id,
                  child_execution_id: Map.get(call, :child_execution_id),
                  authority_digest: Map.get(call, :authority_digest)
                })

              %{message: row, step: step}
            end)

          event!(athanor_id, turn, "model.completed", model_step_id, %{
            "usage" => Map.get(response, :usage),
            "stop_reason" => Map.get(response, :stop_reason),
            "calls" => length(calls)
          })

          %{text: text, calls: calls}
        end)
      end)
    end)
    |> Arca.Data.project()
  end

  def record_response(%Prima.Actor{}, _turn_id, _model_step_id, _response),
    do: {:error, :no_athanor}

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
  row; omitted for a step that produced none), `:execution_id`, `:error`,
  `:fence`, `:sources`, the `Prima.Source`s the result carries, joined
  into the turn's in the same transaction, the threads among them
  recorded on the result row as its payload's `threads`, and `:session`, the brain's
  session a model step's refusal named, with `:generation`, kept on the
  thread as `record_response/4` keeps a response's. `:launched` (`%{reference, reached_outside}`, the
  latter from the launch's completion result) names a component the step
  launched: outside, under its reference, unless `reached_outside` is
  `false`. A step closes from `dispatched`, or from
  `proposed` for `denied` and `skipped`.
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
  Forget the brain's session of the turn's thread, which its brain
  reported it no longer holds (`Prima.Model`'s `unknown_session`):
  `brain_session` is cleared and `brain_generation` raised in one
  statement, as `Arca.ThreadStorage.forget_sessions/2` forgets a home's,
  and only while the thread is at `:generation`, the one the turn read.
  `attrs`: `:fence` (the turn's) and `:generation`, both required.
  Answers the generation the turn keeps a session under from here: the
  raised one, so the session its next request opens is kept, or the one
  it read when the thread was forgotten meanwhile, under which nothing it
  answers with is kept.
  """
  @spec forget_session(Prima.Actor.t(), String.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def forget_session(%Prima.Actor{athanor_id: athanor_id}, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.forget_session", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        generation = Map.get(attrs, :generation)
        if not is_integer(generation), do: Arca.Repo.rollback(:generation_required)

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
  result, and invalidate their pending approvals; with `attrs[:only]`,
  the ids of the steps to skip, those of them still unstarted and no
  other. Answers the steps skipped.
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
  and its step, while still proposed, is skipped with `reason` and its
  approval invalidated, in one transaction under its turn's lock. From
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
        where: s.dispatch_state == "proposed",
        order_by: [asc: s.seq]
      )
      |> only_steps(only)
      |> Arca.Repo.all()

    Enum.map(steps, fn step ->
      if step.approval_id do
        from(a in Approval,
          where: a.athanor_id == ^athanor_id and a.id == ^step.approval_id,
          where: a.status == "pending"
        )
        |> Arca.Repo.update_all(set: [status: @invalidated, decided_at: DateTime.utc_now()])

        from(m in Message,
          where: m.athanor_id == ^athanor_id and m.approval_id == ^step.approval_id,
          where: m.status == "pending"
        )
        |> Arca.Repo.update_all(set: [status: @invalidated])
      end

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
  # Approvals
  # ---------------------------------------------------------------------------

  @doc """
  Open an approval for a proposed step: the `approvals` row, the card
  message row that references it, and the step's `approval_id`, in one
  transaction. `attrs`: `:proposal_digest` (required: the digest the card
  is consumed by), `:expires_at`, `:scope`, `:card` (`%{content, payload}`
  — the payload the console card reads), `:fence`. The step must be
  `proposed` on a turn that is not over (`{:error, :not_proposed}`,
  `{:error, :not_open}`). A turn with a reply address records a
  `needs_you` reply carrying the card's text in the same transaction.
  Answers `{:ok, %{approval: row, card: row}}`,
  or `{:error, :proposal_digest_required}`.
  """
  @spec open_approval(Prima.Actor.t(), String.t(), map()) ::
          {:ok, %{approval: map(), card: map()}} | {:error, term()}
  def open_approval(%Prima.Actor{athanor_id: athanor_id} = actor, step_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.open_approval", fn ->
      with_seq_retry(fn ->
        Arca.Repo.locking_transaction(fn ->
          digest = Map.get(attrs, :proposal_digest)

          unless is_binary(digest) and digest != "",
            do: Arca.Repo.rollback(:proposal_digest_required)

          turn = open!(own_step!(athanor_id, step_id, attrs))
          work_lock!(athanor_id, turn)
          step = step!(athanor_id, step_id)
          if step.dispatch_state != "proposed", do: Arca.Repo.rollback(:not_proposed)
          thread = thread!(athanor_id, turn.thread_id)
          card = Map.get(attrs, :card, %{})
          approval_id = Map.get(attrs, :id) || Prima.UUID7.generate_id("apr")
          now = DateTime.utc_now()

          card_row =
            Arca.ThreadStorage.insert_message!(actor, thread, %{
              id: Map.get(card, :id),
              author: Message.agent_author(),
              sent_by: turn.agent,
              kind: "approval",
              content: Map.get(card, :content, ""),
              payload: Map.get(card, :payload),
              status: "pending",
              turn_id: turn.id,
              approval_id: approval_id,
              execution_id: turn.root_execution_id
            })

          approval =
            Arca.Repo.insert!(%Approval{
              id: approval_id,
              athanor_id: athanor_id,
              turn_id: turn.id,
              step_id: step.id,
              message_id: card_row.id,
              thread_id: turn.thread_id,
              status: "pending",
              scope: Map.get(attrs, :scope),
              proposal_digest: digest,
              expires_at: Map.get(attrs, :expires_at),
              inserted_at: now
            })

          {1, _} =
            from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step_id)
            |> Arca.Repo.update_all(set: [approval_id: approval_id])

          replied!(athanor_id, turn, "needs_you", now, card_row.content, approval_id)
          waits!(athanor_id, thread, turn, approval_id)
          event!(athanor_id, turn, "approval.opened", step_id, %{"approval_id" => approval_id})
          %{approval: approval, card: card_row}
        end)
      end)
    end)
    |> Arca.Data.project()
  end

  def open_approval(%Prima.Actor{}, _step_id, _attrs), do: {:error, :no_athanor}

  @doc """
  Resolve a pending approval in one transaction. `decision` is
  `approved | declined | expired | error`; `attrs`: `:decided_by`,
  `:scope` (`Prima.TurnState.approval_scopes/0`), `:resolution_kind` —
  the one `Prima.TurnState.resolution_kind/2` names for the decision and
  the step's kind —, `:resolution` (a map, stored as JSON), `:denied_result`
  (`%{content, payload}` — the `tool_result` row a declined, expired or
  errored step leaves), `:grants` (rows `Sanctum.ToolGrants.grant_row/2` built, for
  `Arca.ToolGrantStorage.put/1`, written here so the standing answer lands
  with the decision), `:fence`. Each grant must be this turn's: its
  athanor, its agent, the step's tool and action, and for a thread-scope
  grant its thread. A resolution kind, scope or grant the rows do not bear
  out is `{:error, :illegal_transition}`.
  An approved step returns to `proposed`, its kind unchanged; any other
  decision closes it `denied`. The card's pending notices on the threads
  that asked for the turn are decided with it (`notices/2` reads them).
  Answers `{:ok, %{approval, step, card}}`;
  a decision already made answers `{:error, {:already_resolved, approval}}`.
  """
  @spec resolve_approval(Prima.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, %{approval: map(), step: map(), card: map()}}
          | {:error, term()}
  def resolve_approval(%Prima.Actor{athanor_id: athanor_id} = actor, approval_id, decision, attrs)
      when is_binary(athanor_id) and athanor_id != "" and decision in @decisions and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.resolve_approval", fn ->
      with_seq_retry(fn ->
        Arca.Repo.locking_transaction(fn ->
          approval = approval!(athanor_id, approval_id)
          turn = own!(athanor_id, approval.turn_id, attrs)
          work_lock!(athanor_id, turn)
          approval = approval!(athanor_id, approval_id)
          if approval.status != "pending", do: Arca.Repo.rollback({:already_resolved, approval})
          # The decision resumes the turn's work.
          if turn.status in @open and not page_call?(athanor_id, turn),
            do: new_work!(actor, thread!(athanor_id, turn.thread_id))

          step = step!(athanor_id, approval.step_id)
          now = DateTime.utc_now()
          resolution_kind = Map.get(attrs, :resolution_kind)

          if resolution_kind != Prima.TurnState.resolution_kind(decision, step.kind),
            do: Arca.Repo.rollback(:illegal_transition)

          if Map.get(attrs, :scope) not in [nil | Prima.TurnState.approval_scopes()],
            do: Arca.Repo.rollback(:illegal_transition)

          grants = Map.get(attrs, :grants, [])

          unless Enum.all?(grants, &grant_of?(&1, athanor_id, turn, step)),
            do: Arca.Repo.rollback(:illegal_transition)

          {1, _} =
            from(a in Approval,
              where: a.athanor_id == ^athanor_id and a.id == ^approval_id,
              where: a.status == "pending"
            )
            |> Arca.Repo.update_all(
              set: [
                status: decision,
                scope: Map.get(attrs, :scope, approval.scope),
                decided_by: Map.get(attrs, :decided_by),
                decided_at: now,
                resolution_kind: resolution_kind,
                resolution: encode(Map.get(attrs, :resolution))
              ]
            )

          from(m in Message,
            where: m.athanor_id == ^athanor_id and m.id == ^approval.message_id
          )
          |> Arca.Repo.update_all(
            set: [
              status: decision,
              resolved_by: Map.get(attrs, :decided_by),
              resolved_at: now,
              resolution: encode(Map.get(attrs, :resolution))
            ]
          )

          # The notices of the card on the threads that asked for the turn
          # are decided with it: none waits on the person any more.
          from(m in Message,
            where: m.athanor_id == ^athanor_id and m.approval_id == ^approval_id,
            where: m.outcome == "needs_you" and m.status == "pending"
          )
          |> Arca.Repo.update_all(
            set: [status: decision, resolved_by: Map.get(attrs, :decided_by), resolved_at: now]
          )

          if decision == "approved" do
            {1, _} =
              from(s in TurnStep, where: s.athanor_id == ^athanor_id and s.id == ^step.id)
              |> Arca.Repo.update_all(set: [dispatch_state: "proposed"])
          else
            close_step!(actor, athanor_id, turn, step, "denied", %{
              result: Map.get(attrs, :denied_result),
              error: Map.get(attrs, :reason)
            })
          end

          Enum.each(grants, fn grant ->
            case Arca.ToolGrantStorage.put(grant) do
              {:ok, _} -> :ok
              {:error, reason} -> Arca.Repo.rollback({:grant_failed, reason})
            end
          end)

          settled!(athanor_id, turn.thread_id, decision in ["approved", "declined"])

          event!(athanor_id, turn, "approval.resolved", step.id, %{
            "approval_id" => approval_id,
            "decision" => decision,
            "resolution_kind" => resolution_kind
          })

          %{
            approval: approval!(athanor_id, approval_id),
            step: step!(athanor_id, step.id),
            card: Arca.Repo.get_by!(Message, id: approval.message_id, athanor_id: athanor_id)
          }
        end)
      end)
    end)
    |> Arca.Data.project()
  end

  def resolve_approval(%Prima.Actor{}, _approval_id, _decision, _attrs), do: {:error, :no_athanor}

  @doc """
  The notices of the cards of the turns `turn_ids`: each `needs_you` row
  naming one of their approvals, on the thread that asked for the turn,
  as it stands. Every write that settles a card settles its notices in the
  same transaction: its decision (`resolve_approval/4`), and the skip that
  invalidates it when its turn is cancelled, paused or retired.
  """
  @spec notices(Prima.Actor.t(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def notices(%Prima.Actor{athanor_id: athanor_id}, turn_ids)
      when is_binary(athanor_id) and athanor_id != "" and is_list(turn_ids) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.notices", fn ->
      {:ok,
       Arca.Repo.all(
         from(m in Message,
           join: a in Approval,
           on: a.athanor_id == m.athanor_id and a.id == m.approval_id,
           where: m.athanor_id == ^athanor_id and a.turn_id in ^turn_ids,
           where: m.outcome == "needs_you",
           order_by: [asc: m.thread_id, asc: m.seq]
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def notices(%Prima.Actor{}, _turn_ids), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # Sources
  # ---------------------------------------------------------------------------

  @doc """
  The sources the turn whose root execution is `root_execution_id` has
  read. `{:ok, []}` when no turn of the caller's athanor runs on that
  execution.
  """
  @spec chain_sources(Prima.Actor.t(), String.t()) ::
          {:ok, [Prima.Source.t()]} | {:error, term()}
  def chain_sources(%Prima.Actor{athanor_id: athanor_id}, root_execution_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(root_execution_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.chain_sources", fn ->
      sources =
        from(t in Turn,
          where: t.athanor_id == ^athanor_id and t.root_execution_id == ^root_execution_id,
          select: t.sources
        )
        |> Arca.Repo.all()
        |> Enum.flat_map(&Prima.Source.decode/1)
        |> Prima.Source.set()

      {:ok, sources}
    end)
  end

  def chain_sources(%Prima.Actor{}, _root_execution_id), do: {:error, :no_athanor}

  @doc """
  `chain_sources/2` inside the caller's transaction, raising as the
  transaction's own reads do.
  """
  @spec chain_sources!(Prima.Actor.t(), String.t()) :: [Prima.Source.t()]
  # arca:db-raise-ok inside the caller's transaction
  def chain_sources!(%Prima.Actor{athanor_id: athanor_id}, root_execution_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(root_execution_id) do
    from(t in Turn,
      where: t.athanor_id == ^athanor_id and t.root_execution_id == ^root_execution_id,
      select: t.sources
    )
    |> Arca.Repo.all()
    |> Enum.flat_map(&Prima.Source.decode/1)
    |> Prima.Source.set()
  end

  def chain_sources!(%Prima.Actor{}, _root_execution_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.chain_sources!/2")

  @doc """
  The sources of the turn the step `step_id` belongs to, as they stand
  inside the caller's transaction: `{:ok, sources}` when that turn runs on
  `root_execution_id`, `:none` for a step of no turn on it. What a child a
  loop step admits under a turn root starts from: the step's own turn,
  with every source its step opened with already joined.
  """
  @spec step_sources!(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, [Prima.Source.t()]} | :none
  # arca:db-raise-ok inside the caller's transaction
  def step_sources!(%Prima.Actor{athanor_id: athanor_id}, step_id, root_execution_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(step_id) and
             is_binary(root_execution_id) do
    from(s in TurnStep,
      join: t in Turn,
      on: t.id == s.turn_id and t.athanor_id == s.athanor_id,
      where: s.athanor_id == ^athanor_id and s.id == ^step_id,
      where: t.root_execution_id == ^root_execution_id,
      select: t.sources
    )
    |> Arca.Repo.one()
    |> case do
      nil -> :none
      stored -> {:ok, Prima.Source.decode(stored)}
    end
  end

  def step_sources!(%Prima.Actor{}, _step_id, _root_execution_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.TurnStorage.step_sources!/3")

  @doc """
  Join `sources` into the turn `turn_id`'s, under the turn's row lock and
  only while the caller still holds the turn at `attrs[:fence]`
  (`{:error, :superseded}` otherwise): what a model or hand child's
  persisted ledger brings into its turn before the turn uses its answer.
  The set only grows.
  """
  @spec join_sources(Prima.Actor.t(), String.t(), [Prima.Source.t()], map()) ::
          :ok | {:error, term()}
  def join_sources(%Prima.Actor{athanor_id: athanor_id}, turn_id, sources, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) and
             is_list(sources) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.join_sources", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)
        _turn = join_sources!(athanor_id, turn, sources!(sources))
        :ok
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def join_sources(%Prima.Actor{}, _turn_id, _sources, _attrs), do: {:error, :no_athanor}

  @doc """
  Join what a turn read of the athanor's threads into its sources, before
  its read answers (`thread.search`, `thread.events`): under the turn's
  row lock and only while the caller still holds the turn at
  `attrs[:fence]` and the turn is open, the thread rows `attrs[:threads]`
  names are taken in the one order (`Arca.ThreadStorage.lock_threads!/2`),
  and each that stands joins as a `thread` source
  (`Prima.Source.thread/1`), with `attrs[:sources]` and the sources of the
  turns `attrs[:sources_from]` names, as a step's opening joins them; a
  turn named there that is not found is an unnamed outside source, so a
  post whose writer cannot be read never reads as the athanor's own.

  Answers the ids of the threads that stood, whose posts the read may
  answer, with the sources joined. A thread deleted before this takes its
  row is not among them; one deleted after finds this turn by its source,
  as a deletion finds every turn that read it. `{:error, :superseded}`
  for a caller whose fence moved, `{:error, :not_open}` for a turn that
  ended.
  """
  @spec join_read(Prima.Actor.t(), String.t(), map()) ::
          {:ok, %{threads: [String.t()], sources: [Prima.Source.t()]}} | {:error, term()}
  def join_read(%Prima.Actor{athanor_id: athanor_id} = actor, turn_id, attrs)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(turn_id) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.join_read", fn ->
      Arca.Repo.locking_transaction(fn ->
        turn = own!(athanor_id, turn_id, attrs)

        unless turn.status in Prima.TurnState.open_statuses(),
          do: Arca.Repo.rollback(:not_open)

        standing =
          for thread <- Arca.ThreadStorage.lock_threads!(actor, Map.get(attrs, :threads, [])),
              do: thread.id

        sources =
          Prima.Source.set(
            Enum.map(standing, &Prima.Source.thread/1) ++
              sources!(Map.get(attrs, :sources, [])) ++
              read_turns!(athanor_id, Map.get(attrs, :sources_from, []))
          )

        _turn = join_sources!(athanor_id, turn, sources)
        %{threads: standing, sources: sources}
      end)
    end)
  end

  def join_read(%Prima.Actor{}, _turn_id, _attrs), do: {:error, :no_athanor}

  # The sources of the turns `ids` names, and an unnamed outside source for
  # each the athanor holds no row of.
  # arca:db-raise-ok inside the caller's transaction
  defp read_turns!(_athanor_id, []), do: []

  defp read_turns!(athanor_id, ids) when is_list(ids) do
    ids = Enum.uniq(ids)

    found =
      from(t in Turn, where: t.athanor_id == ^athanor_id and t.id in ^ids, select: t.sources)
      |> Arca.Repo.all()

    missing = if length(found) < length(ids), do: [Prima.Source.outside(nil)], else: []
    Enum.flat_map(found, &Prima.Source.decode/1) ++ missing
  end

  defp read_turns!(_athanor_id, _other), do: Arca.Repo.rollback(:invalid_sources)

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
  # The consumption boundary
  # ---------------------------------------------------------------------------

  @doc """
  Move the turn's boundary past every human row attached to it that
  arrived while it worked, and answer those rows in `seq` order: the
  steer the loop drains before its next model request. A turn that is
  over drains nothing (`{:error, :not_open}`).
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
            newest = rows |> Enum.map(& &1.seq) |> Enum.max()

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

  @doc "Whether a human row attached to the turn waits past its boundary."
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
  The rows a turn may read, in `seq` order: its own rows except an
  undrained steer, plus — behind its boundary — unattached rows and the
  rows of terminal turns of the thread. Rows attached to other open
  turns are never read, nor an opening still waiting for its own turn,
  whose ask is read under that turn's person, origin and restrictions
  alone.
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
            where:
              (m.turn_id == ^turn_id and (m.sent_by == ^turn.agent or m.seq <= ^window)) or
                (m.seq <= ^window and (is_nil(m.turn_id) or m.turn_id in subquery(settled))),
            where: not (m.kind == "opening" and is_nil(m.turn_id) and is_nil(m.status)),
            order_by: [asc: m.seq]
          )
        )

      {:ok, rows}
    end)
    |> Arca.Data.project()
  end

  def projection(%Prima.Actor{}, _turn_id), do: {:error, :no_athanor}

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
  did, each a call of a tool, a hand, a launch or a card's decision, and
  none of the model steps a turn thinks in. A turn's steps follow its
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
          where: s.kind != "model",
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

  @doc "One approval of the athanor."
  @spec approval(Prima.Actor.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def approval(%Prima.Actor{athanor_id: athanor_id}, approval_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.approval", fn ->
      case Arca.Repo.one(
             from(a in Approval, where: a.athanor_id == ^athanor_id and a.id == ^approval_id)
           ) do
        nil -> {:error, :not_found}
        approval -> {:ok, approval}
      end
    end)
    |> Arca.Data.project()
  end

  def approval(%Prima.Actor{}, _approval_id), do: {:error, :no_athanor}

  @doc "The approval a card message references."
  @spec approval_by_message(Prima.Actor.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def approval_by_message(%Prima.Actor{athanor_id: athanor_id}, message_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.approval_by_message", fn ->
      case Arca.Repo.one(
             from(a in Approval,
               where: a.athanor_id == ^athanor_id and a.message_id == ^message_id
             )
           ) do
        nil -> {:error, :not_found}
        approval -> {:ok, approval}
      end
    end)
    |> Arca.Data.project()
  end

  def approval_by_message(%Prima.Actor{}, _message_id), do: {:error, :no_athanor}

  @doc "The pending approvals of a turn, oldest first."
  @spec pending_approvals(Prima.Actor.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def pending_approvals(%Prima.Actor{athanor_id: athanor_id}, turn_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.pending_approvals", fn ->
      {:ok,
       Arca.Repo.all(
         from(a in Approval,
           where: a.athanor_id == ^athanor_id and a.turn_id == ^turn_id,
           where: a.status == "pending",
           order_by: [asc: a.inserted_at]
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def pending_approvals(%Prima.Actor{}, _turn_id), do: {:error, :no_athanor}

  @doc "The athanor's pending approvals whose `expires_at` passed."
  @spec expired_approvals(Prima.Actor.t(), DateTime.t()) ::
          {:ok, [map()]} | {:error, term()}
  def expired_approvals(%Prima.Actor{athanor_id: athanor_id}, %DateTime{} = now)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.expired_approvals", fn ->
      {:ok,
       Arca.Repo.all(
         from(a in Approval,
           where: a.athanor_id == ^athanor_id and a.status == "pending",
           where: not is_nil(a.expires_at) and a.expires_at < ^now,
           order_by: [asc: a.expires_at]
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def expired_approvals(%Prima.Actor{}, _now), do: {:error, :no_athanor}

  @doc """
  The athanor's approvals still waiting on a decision at `now`, oldest
  first: pending and not past an expiry, each as its id, the thread it
  waits in, that thread's title and its day (a daily thread's date, nil
  for any other) and when it opened, and nothing of the proposal. `approval_id:` narrows it to that one approval.
  """
  @spec waiting_approvals(Prima.Actor.t(), DateTime.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def waiting_approvals(actor, now, opts \\ [])

  def waiting_approvals(%Prima.Actor{athanor_id: athanor_id}, %DateTime{} = now, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.TurnStorage.waiting_approvals", fn ->
      query =
        from(a in Approval,
          join: t in Thread,
          on: t.athanor_id == a.athanor_id and t.id == a.thread_id,
          where: a.athanor_id == ^athanor_id and a.status == "pending",
          where: is_nil(a.expires_at) or a.expires_at > ^now,
          order_by: [asc: a.inserted_at, asc: a.id],
          select: %{
            id: a.id,
            thread_id: a.thread_id,
            title: t.title,
            day: t.day,
            inserted_at: a.inserted_at
          }
        )

      query =
        case Keyword.fetch(opts, :approval_id) do
          {:ok, id} when is_binary(id) -> where(query, [a], a.id == ^id)
          :error -> query
        end

      {:ok, Arca.Repo.all(query)}
    end)
    |> Arca.Data.project()
  end

  def waiting_approvals(%Prima.Actor{}, _now, _opts), do: {:error, :no_athanor}

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
            content: Map.get(result, :content, ""),
            payload: result_payload(result, step, Map.get(attrs, :sources, [])),
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

    if Map.get(attrs, :session),
      do: keep_session!(athanor_id, thread!(athanor_id, turn.thread_id), attrs)

    _turn = join_sources!(athanor_id, turn, closed_sources!(athanor_id, attrs))

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
  # threads its answer carried, by the thread sources the step joins
  # (`Prima.Source.thread/1`), which a deletion of one of them finds the
  # row by to blank it (`Arca.ThreadStorage.delete/3`).
  defp result_payload(result, step, sources) do
    payload = Map.merge(Map.get(result, :payload) || %{}, %{"step_id" => step.id})

    case sources |> sources!() |> Prima.Source.threads() do
      [] -> payload
      threads -> Map.put(payload, "threads", threads)
    end
  end

  # The turn's sources joined by `sources`, under the row lock `own!/3`
  # took: the set is read and written again inside that lock, so it only
  # grows and no concurrent writer's additions are lost.
  # arca:db-raise-ok inside the caller's transaction
  defp join_sources!(athanor_id, %Turn{} = turn, sources) do
    joined = Prima.Source.encode(Prima.Source.union(Prima.Source.decode(turn.sources), sources))

    if joined == turn.sources do
      turn
    else
      {1, _} =
        from(t in Turn, where: t.athanor_id == ^athanor_id and t.id == ^turn.id)
        |> Arca.Repo.update_all(set: [sources: joined])

      %{turn | sources: joined}
    end
  end

  # What a step opens with: the sources it names and those of the turns
  # whose words its rows carry, as each turn stands — of any thread of the
  # athanor, since a reply or a request carries a turn's words across
  # threads; a join only ever adds. A turn of another athanor joins
  # nothing.
  # arca:db-raise-ok inside the caller's transaction
  defp opened_sources!(athanor_id, %Turn{} = turn, attrs) do
    sources!(Map.get(attrs, :sources, [])) ++
      case Map.get(attrs, :sources_from, []) do
        [] ->
          []

        ids when is_list(ids) ->
          from(t in Turn,
            where: t.athanor_id == ^athanor_id,
            where: t.id in ^ids and t.id != ^turn.id,
            select: t.sources
          )
          |> Arca.Repo.all()
          |> Enum.flat_map(&Prima.Source.decode/1)

        _other ->
          Arca.Repo.rollback(:invalid_sources)
      end
  end

  # What a closing step's result carries.
  # arca:db-raise-ok inside the caller's transaction
  defp closed_sources!(athanor_id, attrs) do
    sources!(Map.get(attrs, :sources, [])) ++
      launched_sources!(athanor_id, Map.get(attrs, :launched))
  end

  # A launched component is outside, named by its reference, unless the
  # completion result its launcher was handed says no run of its tree was
  # admitted with egress. That fact lives on the tree's root row, marked in
  # each run's admission transaction (`Arca.Execution.admit/2`) and carried
  # into the result, because a child's own row may be pruned by retention
  # before the launch closes; nothing here reads an execution row. A launch
  # with no result, or one whose result does not say, is outside.
  defp launched_sources!(_athanor_id, nil), do: []

  defp launched_sources!(_athanor_id, %{reference: _reference, reached_outside: false}),
    do: []

  defp launched_sources!(_athanor_id, %{reference: reference}),
    do: [Prima.Source.outside(reference)]

  # arca:db-raise-ok inside the caller's transaction
  defp launched_sources!(_athanor_id, _launched), do: Arca.Repo.rollback(:invalid_sources)

  # arca:db-raise-ok inside the caller's transaction
  defp sources!(sources) when is_list(sources) do
    if Enum.all?(sources, &is_struct(&1, Prima.Source)),
      do: sources,
      else: Arca.Repo.rollback(:invalid_sources)
  end

  # arca:db-raise-ok inside the caller's transaction
  defp sources!(_sources), do: Arca.Repo.rollback(:invalid_sources)

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
      proposal_digest: Map.get(attrs, :proposal_digest),
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

  # A page's call the host proposed into the turn that is still to be
  # dispatched, its card's answer awaited among them.
  # arca:db-raise-ok inside the caller's transaction
  defp calls_pending?(athanor_id, %Turn{} = turn) do
    Arca.Repo.exists?(
      from(s in TurnStep,
        where: s.athanor_id == ^athanor_id and s.turn_id == ^turn.id,
        where: s.purpose == "page" and s.dispatch_state == "proposed"
      )
    )
  end

  # A steer is what someone other than the turn's agent wrote into it
  # past its boundary: every row the turn writes itself carries its agent.
  # arca:db-raise-ok inside the caller's transaction
  defp steer_rows(athanor_id, %Turn{} = turn) do
    window = turn.window_upto_seq || 0

    Arca.Repo.all(
      from(m in Message,
        where: m.athanor_id == ^athanor_id and m.turn_id == ^turn.id,
        where: m.sent_by != ^turn.agent and m.seq > ^window,
        order_by: [asc: m.seq]
      )
    )
  end

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
  defp approval!(athanor_id, approval_id) do
    Arca.Repo.one(
      from(a in Approval, where: a.athanor_id == ^athanor_id and a.id == ^approval_id)
    ) ||
      Arca.Repo.rollback(:approval_not_found)
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
  # writes alone, a card opened, decided or skipped, a turn's end, its
  # cancel and its set-downs (an acceptance that opens or steers a turn
  # there takes `work_rows!/2`); any other write of a turn takes no second
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
  # transaction that ends it or opens its card: the requests it answers
  # are every request delivered into it, opening one first, each named
  # by its delivered row's payload.
  # arca:db-raise-ok inside the caller's transaction
  defp replied!(athanor_id, turn, outcome, at, text, approval_id \\ nil)

  defp replied!(_athanor_id, %Turn{asking_thread_id: nil}, _outcome, _at, _text, _approval_id),
    do: :ok

  defp replied!(athanor_id, %Turn{} = turn, outcome, %DateTime{} = at, text, approval_id) do
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
        reply!(athanor_id, turn, {outcome, approval_id}, at, text, requests, person_id, origin)

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
  defp reply!(
         athanor_id,
         %Turn{} = turn,
         {outcome, approval_id},
         at,
         text,
         requests,
         person_id,
         origin
       ) do
    record =
      Prima.OutboxRecord.crew_reply(%{
        approval_id: approval_id,
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

  # The brain's own session, kept on the thread for its next request only
  # under the generation the turn read (`:generation`): a turn whose
  # session was forgotten meanwhile (`Arca.ThreadStorage.forget_sessions/2`
  # raises the generation) keeps nothing it answers with afterwards, the
  # session it resumed or one it opened in the home the forget emptied. A
  # turn that forgot the session itself writes under the generation that
  # forget answered (`forget_session/3`). A session without a generation
  # is refused, as a write without a fence is.
  # arca:db-raise-ok inside the caller's transaction
  defp keep_session!(athanor_id, %Thread{id: thread_id, brain_session: current}, attrs) do
    session = Map.get(attrs, :session)
    generation = Map.get(attrs, :generation)

    if session != nil and not is_integer(generation),
      do: Arca.Repo.rollback(:generation_required)

    if is_binary(session) and session != "" and session != current do
      # The comparison is the statement's own, so a forget committed after
      # the thread was read still holds.
      {_kept_or_not, _} =
        from(c in Thread,
          where: c.athanor_id == ^athanor_id and c.id == ^thread_id,
          where: c.brain_generation == ^generation
        )
        |> Arca.Repo.update_all(set: [brain_session: session])
    end

    :ok
  end

  # A standing answer written with a decision is this turn's: its athanor,
  # its agent, the step's tool and action, and a thread-scope answer names
  # the turn's thread.
  defp grant_of?(grant, athanor_id, %Turn{} = turn, %TurnStep{} = step) when is_map(grant) do
    Map.get(grant, :athanor_id) == athanor_id and Map.get(grant, :agent_name) == turn.agent and
      Map.get(grant, :tool) == step.tool and Map.get(grant, :action) == step.action and
      (Map.get(grant, :scope) != "thread" or Map.get(grant, :thread_id) == turn.thread_id)
  end

  defp grant_of?(_grant, _athanor_id, _turn, _step), do: false

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
