# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Questions do
  @moduledoc """
  Persistence for component questions (`Arca.Schemas.Question`) and the
  standing answers a person gives them (`Arca.Schemas.QuestionAnswer`).
  The decision, the match of a standing answer and the telemetry are
  `Sanctum.Questions`', the only caller above this layer; Arca announces
  nothing.

  ## Binding

  Every function takes the actor first. Every read, answer and deletion is
  bound to the actor's athanor, and to the actor's person or the `user_id`
  it is handed; an actor with no person is `{:error, :no_person}`.
  `delete_component/3` alone is bound to the athanor only: it is the
  component leaving the athanor, and the cascade calling it may hold no
  person.

  ## A question's life

  `admit/2` writes a question with the first state the decision chose, in
  a transaction that locks the run's row and checks the asking attempt is
  its current one and the run open: an ask whose run ended a moment
  before leaves no row. `answer/5` decides an open question under the
  run's lock and then the question's, the order every run-ending write
  keeps, while its deadline is to come on the database's clock and its
  attempt is current and its run open. The writes that end a run close
  that run's own open questions in their own transaction (`close_run!/2`)
  and answer which; a declared restore ends every open one and deletes
  every standing allow itself (`Arca.SecurityTransitions`).

  ## Standing answers

  An answer's identity is the athanor, person, publisher, name, action and
  caller (`any`, `Prima.Question.Caller.any/0`, for every caller). A new
  answer with the same identity replaces the old one; a deny for any
  caller also deletes that action's allows for single callers, in the same
  transaction.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{Execution, ExecutionAttempt, Question, QuestionAnswer}

  @answers ~w(allowed denied)
  @standing_fields [
    :publisher,
    :name,
    :action,
    :declaration_digest,
    :caller,
    :effect,
    :until,
    :question_ref
  ]

  # What a write replaces on its identity: everything but the identity.
  @replaced [:id, :declaration_digest, :effect, :until, :answered_at, :question_ref]

  @typedoc "A question or a standing answer, as a plain map."
  @type row :: map()

  @typedoc "A question a run-ending write closed."
  @type closed :: %{ref: String.t(), user_id: String.t(), deadline: DateTime.t()}

  defguardp person(actor)
            when is_struct(actor, Prima.Actor) and is_binary(actor.athanor_id) and
                   actor.athanor_id != "" and is_binary(actor.user_id) and actor.user_id != ""

  defguardp athanor(actor)
            when is_struct(actor, Prima.Actor) and is_binary(actor.athanor_id) and
                   actor.athanor_id != ""

  # ---------------------------------------------------------------------------
  # Questions
  # ---------------------------------------------------------------------------

  @doc """
  Insert the keyed question `question` (a map of the table's columns but
  the athanor, person, when it opened and who decided it, which are the
  actor's, the database's clock or none) with the first state the
  decision chose, in a transaction that locks the run's row and checks
  the attempt is its current one and the run open. Every admitted row is
  stamped `opened_at` with the database's clock, and a decided first
  state `decided_at` with the same time.

  `{:ok, row}`; `{:error, :closed}` when the run has ended or another
  attempt owns it; `{:error, :exists}` when the key
  `(attempt_id, ask_no)` is taken; `{:error, {:invalid, errors}}` for a
  row outside the table's rules.
  """
  @spec admit(Prima.Actor.t(), map()) :: {:ok, row()} | {:error, term()}
  def admit(actor, question) when person(actor) and is_map(question) do
    Arca.Repo.Errors.with_db_rescue("Arca.Questions.admit", fn ->
      Arca.Repo.locking_transaction(fn ->
        now = Arca.ServerMetaStorage.now!()

        changeset =
          question
          |> Map.take(Question.__schema__(:fields))
          |> Map.drop([:decided_by, :decided_at])
          |> Map.merge(%{athanor_id: actor.athanor_id, user_id: actor.user_id, opened_at: now})
          |> decided_at(now)
          |> Question.admit_changeset()

        with :ok <- valid(changeset),
             :ok <- attempt_current(actor.athanor_id, changeset.changes),
             :ok <- key_free(actor.athanor_id, changeset.changes) do
          insert(changeset)
        end
        |> Arca.Repo.committed()
      end)
    end)
    |> Arca.Data.project()
  end

  def admit(actor, question) when athanor(actor) and is_map(question), do: {:error, :no_person}
  def admit(%Prima.Actor{}, question) when is_map(question), do: {:error, :no_athanor}

  defp decided_at(%{state: "open"} = attrs, _now), do: attrs
  defp decided_at(attrs, now), do: Map.put(attrs, :decided_at, now)

  defp valid(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid(changeset), do: {:error, Arca.Data.invalid(changeset)}

  # The run's row under lock, then its attempt: the order every execution
  # write keeps, so an admission and the run's end serialize.
  # arca:db-raise-ok inside the caller's transaction
  defp attempt_current(athanor_id, %{execution_id: execution_id, attempt_id: attempt_id}) do
    case lock_run(athanor_id, execution_id) do
      %Execution{current_attempt: ^attempt_id} ->
        if attempt_open?(athanor_id, execution_id, attempt_id),
          do: :ok,
          else: {:error, :closed}

      _ended_or_moved ->
        {:error, :closed}
    end
  end

  # arca:db-raise-ok inside the caller's transaction
  defp lock_run(athanor_id, execution_id) do
    from(e in Execution,
      where:
        e.athanor_id == ^athanor_id and e.id == ^execution_id and
          e.status in ^Prima.ExecutionState.open_statuses()
    )
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  # arca:db-raise-ok inside the caller's transaction
  defp attempt_open?(athanor_id, execution_id, attempt_id) do
    from(a in ExecutionAttempt,
      where:
        a.athanor_id == ^athanor_id and a.attempt == ^attempt_id and
          a.execution_id == ^execution_id and
          a.state in ^Prima.ExecutionState.open_attempt_states()
    )
    |> Arca.Repo.exists?()
  end

  # arca:db-raise-ok inside the caller's transaction
  defp key_free(athanor_id, %{attempt_id: attempt_id, ask_no: ask_no}) do
    if Arca.Repo.exists?(keyed(athanor_id, attempt_id, ask_no)),
      do: {:error, :exists},
      else: :ok
  end

  # A racing admission of the same key loses on the unique index and is
  # answered as the key being taken.
  # arca:db-raise-ok inside the caller's transaction
  defp insert(changeset) do
    case Arca.Repo.insert(changeset) do
      {:ok, row} ->
        {:ok, row}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Enum.any?(errors, fn {_field, {_message, meta}} -> meta[:constraint] == :unique end),
          do: {:error, :exists},
          else: {:error, Arca.Data.invalid(changeset)}
    end
  end

  defp keyed(athanor_id, attempt_id, ask_no) do
    from(q in Question,
      where: q.athanor_id == ^athanor_id and q.attempt_id == ^attempt_id and q.ask_no == ^ask_no
    )
  end

  @doc "The question the key `(attempt_id, ask_no)` names: `{:ok, row}` or `{:error, :not_found}`."
  @spec by_key(Prima.Actor.t(), String.t(), pos_integer()) :: {:ok, row()} | {:error, term()}
  def by_key(actor, attempt_id, ask_no)
      when person(actor) and is_binary(attempt_id) and is_integer(ask_no) do
    Arca.Repo.Errors.with_db_rescue("Arca.Questions.by_key", fn ->
      keyed(actor.athanor_id, attempt_id, ask_no)
      |> where([q], q.user_id == ^actor.user_id)
      |> Arca.Repo.one()
      |> found()
    end)
    |> Arca.Data.project()
  end

  def by_key(actor, _attempt_id, _ask_no) when athanor(actor), do: {:error, :no_person}
  def by_key(%Prima.Actor{}, _attempt_id, _ask_no), do: {:error, :no_athanor}

  @doc "The question `ref`: `{:ok, row}` or `{:error, :not_found}`."
  @spec get(Prima.Actor.t(), String.t()) :: {:ok, row()} | {:error, term()}
  def get(actor, ref) when person(actor) and is_binary(ref) do
    Arca.Repo.Errors.with_db_rescue("Arca.Questions.get", fn ->
      actor |> own(ref) |> Arca.Repo.one() |> found()
    end)
    |> Arca.Data.project()
  end

  def get(actor, _ref) when athanor(actor), do: {:error, :no_person}
  def get(%Prima.Actor{}, _ref), do: {:error, :no_athanor}

  @doc "The person's open questions in the actor's athanor, soonest deadline first."
  @spec list_open(Prima.Actor.t(), String.t()) :: {:ok, [row()]} | {:error, term()}
  def list_open(actor, user_id) when person(actor) and is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Questions.list_open", fn ->
      {:ok,
       Question
       |> QueryHelpers.where_tenant(actor)
       |> where([q], q.user_id == ^user_id and q.state == "open")
       |> order_by([q], asc: q.deadline, asc: q.ref)
       |> Arca.Repo.all()}
    end)
    |> Arca.Data.project()
  end

  def list_open(actor, _user_id) when athanor(actor), do: {:error, :no_person}
  def list_open(%Prima.Actor{}, _user_id), do: {:error, :no_athanor}

  @doc """
  Answer the open question `ref` with `answer` (`"allowed"` or
  `"denied"`), decided by the actor's person on the database's clock, and,
  when `standing` is not nil, write that standing answer (a map of
  `question_answers`' columns, `put_standing/3`'s) naming `ref` as the
  question it came from. Under the run's lock, then the question's: the
  question still open, its deadline to come, its attempt current and its
  run open. `opts[:verify]` (required) then runs in the same transaction:
  `:ok`, or `{:error, reason}`, which rolls every write back and is
  answered.

  `{:ok, row}`; `{:error, :closed}` when the question can no longer be
  answered; `{:error, :not_found}` when `ref` is not the actor's;
  `{:error, {:invalid, errors}}` for a standing answer outside the
  table's rules; or the closure's refusal.
  """
  @spec answer(Prima.Actor.t(), String.t(), String.t(), map() | nil, keyword()) ::
          {:ok, row()} | {:error, term()}
  def answer(actor, ref, answer, standing, opts)
      when person(actor) and is_binary(ref) and answer in @answers and
             (is_nil(standing) or is_map(standing)) and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)

    Arca.Repo.Errors.with_db_rescue("Arca.Questions.answer", fn ->
      Arca.Repo.locking_transaction(fn ->
        with {:ok, question} <- found(Arca.Repo.one(own(actor, ref))),
             :ok <- answerable(actor, question),
             {:ok, answered} <- decide(actor, question, answer),
             :ok <- stand(actor, standing, ref),
             :ok <- verify.() do
          {:ok, answered}
        end
        |> Arca.Repo.committed()
      end)
    end)
    |> Arca.Data.project()
  end

  def answer(actor, _ref, _answer, _standing, _opts) when athanor(actor), do: {:error, :no_person}

  def answer(%Prima.Actor{}, _ref, _answer, _standing, _opts), do: {:error, :no_athanor}

  # The run's row, then the question's, each under lock, then the checks
  # read under both.
  # arca:db-raise-ok inside the caller's transaction
  defp answerable(actor, %Question{} = question) do
    run = lock_run(actor.athanor_id, question.execution_id)

    locked =
      own(actor, question.ref)
      |> QueryHelpers.where_tenant(actor)
      |> QueryHelpers.for_update()
      |> Arca.Repo.one()

    cond do
      is_nil(locked) or locked.state != "open" -> {:error, :closed}
      DateTime.compare(locked.deadline, Arca.ServerMetaStorage.now!()) != :gt -> {:error, :closed}
      is_nil(run) or run.current_attempt != locked.attempt_id -> {:error, :closed}
      not attempt_open?(actor.athanor_id, run.id, locked.attempt_id) -> {:error, :closed}
      true -> :ok
    end
  end

  # arca:db-raise-ok inside the caller's transaction
  defp decide(actor, question, answer) do
    {1, [answered]} =
      own(actor, question.ref)
      |> where([q], q.state == "open")
      |> select([q], q)
      |> Arca.Repo.update_all(
        set: [state: answer, decided_by: actor.user_id, decided_at: Arca.ServerMetaStorage.now!()]
      )

    {:ok, answered}
  end

  defp stand(_actor, nil, _ref), do: :ok

  defp stand(actor, standing, ref) do
    case put_standing_in(actor, Map.put(standing, :question_ref, ref)) do
      {:ok, _row} -> :ok
      {:error, _} = refused -> refused
    end
  end

  defp own(actor, ref) do
    Question
    |> QueryHelpers.where_tenant(actor)
    |> where([q], q.ref == ^ref and q.user_id == ^actor.user_id)
  end

  @doc """
  The distinct callers the person's questions for the catalyst `publisher`
  and `name` have had, sorted.
  """
  @spec callers(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def callers(actor, user_id, publisher, name)
      when person(actor) and is_binary(user_id) and is_binary(publisher) and is_binary(name) do
    Arca.Repo.Errors.with_db_rescue("Arca.Questions.callers", fn ->
      rows =
        Question
        |> QueryHelpers.where_tenant(actor)
        |> where([q], q.user_id == ^user_id)
        |> distinct(true)
        |> select([q], {q.component_ref, q.caller})
        |> Arca.Repo.all()

      {:ok,
       for {ref, caller} <- rows, component?(ref, publisher, name), uniq: true do
         caller
       end
       |> Enum.sort()}
    end)
  end

  def callers(actor, _user_id, _publisher, _name) when athanor(actor), do: {:error, :no_person}
  def callers(%Prima.Actor{}, _user_id, _publisher, _name), do: {:error, :no_athanor}

  # A question names its component by its reference; only a catalyst asks.
  defp component?(ref, publisher, name) do
    match?(
      {:ok, %Prima.ComponentRef{type: "catalyst", namespace: ^publisher, name: ^name}},
      Prima.ComponentRef.parse(ref)
    )
  end

  # ---------------------------------------------------------------------------
  # Standing answers
  # ---------------------------------------------------------------------------

  @doc "The person's standing answers for the component `publisher` and `name`."
  @spec standing(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, [row()]} | {:error, term()}
  def standing(actor, user_id, publisher, name)
      when person(actor) and is_binary(user_id) and is_binary(publisher) and is_binary(name) do
    Arca.Repo.Errors.with_db_rescue("Arca.Questions.standing", fn ->
      {:ok,
       QuestionAnswer
       |> QueryHelpers.where_tenant(actor)
       |> where([a], a.user_id == ^user_id and a.publisher == ^publisher and a.name == ^name)
       |> order_by([a], asc: a.action, asc: a.caller)
       |> Arca.Repo.all()}
    end)
    |> Arca.Data.project()
  end

  def standing(actor, _user_id, _publisher, _name) when athanor(actor), do: {:error, :no_person}
  def standing(%Prima.Actor{}, _user_id, _publisher, _name), do: {:error, :no_athanor}

  @doc """
  Write the standing answer `standing` (a map of `question_answers`'
  columns: `publisher`, `name`, `action`, `declaration_digest`, `caller`,
  `effect`, `until` and `question_ref`; the athanor and person are the
  actor's, the id is minted here and the time is the database's clock),
  replacing the answer of the same identity, and, when it is a deny for
  any caller, deleting that action's allows for single callers.
  `opts[:verify]` (required) then runs in the same transaction: `:ok`, or
  `{:error, reason}`, which rolls the write back and is answered.

  `{:ok, row}`, `{:error, {:invalid, errors}}`, or the closure's refusal.
  """
  @spec put_standing(Prima.Actor.t(), map(), keyword()) :: {:ok, row()} | {:error, term()}
  def put_standing(actor, standing, opts)
      when person(actor) and is_map(standing) and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)

    Arca.Repo.Errors.with_db_rescue("Arca.Questions.put_standing", fn ->
      Arca.Repo.locking_transaction(fn ->
        with {:ok, row} <- put_standing_in(actor, standing),
             :ok <- verify.() do
          {:ok, row}
        end
        |> Arca.Repo.committed()
      end)
    end)
    |> Arca.Data.project()
  end

  def put_standing(actor, _standing, _opts) when athanor(actor), do: {:error, :no_person}

  def put_standing(%Prima.Actor{}, _standing, _opts), do: {:error, :no_athanor}

  # One statement on the identity: an upsert on its unique index, so a
  # second write of one identity waits for the first and replaces it, and
  # neither is lost or refused. A deny for any caller then deletes the
  # action's allows for single callers in the same transaction; one written
  # after it stands.
  # arca:db-raise-ok inside the caller's transaction
  defp put_standing_in(actor, standing) do
    changeset =
      standing
      |> Map.take(@standing_fields)
      |> Map.merge(%{
        id: Prima.UUID7.generate_id("qan"),
        athanor_id: actor.athanor_id,
        user_id: actor.user_id,
        answered_at: Arca.ServerMetaStorage.now!()
      })
      |> QuestionAnswer.changeset()

    if changeset.valid? do
      {:ok, stored} =
        Arca.Repo.insert(changeset,
          on_conflict: {:replace, @replaced},
          conflict_target: identity(),
          returning: true
        )

      if stored.effect == "deny" and stored.caller == Prima.Question.Caller.any() do
        Arca.Repo.delete_all(
          from(a in same_action(stored),
            where: a.effect == "allow" and a.caller != ^Prima.Question.Caller.any()
          )
        )
      end

      {:ok, stored}
    else
      {:error, Arca.Data.invalid(changeset)}
    end
  end

  defp identity, do: [:athanor_id, :user_id, :publisher, :name, :action, :caller]

  defp same_action(row) do
    from(a in QuestionAnswer,
      where:
        a.athanor_id == ^row.athanor_id and a.user_id == ^row.user_id and
          a.publisher == ^row.publisher and a.name == ^row.name and a.action == ^row.action
    )
  end

  @doc "Remove the person's standing answer `id`: `:ok`, or `{:error, :not_found}`."
  @spec delete_standing(Prima.Actor.t(), String.t()) :: :ok | {:error, term()}
  def delete_standing(actor, id) when person(actor) and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Questions.delete_standing", fn ->
      QuestionAnswer
      |> QueryHelpers.where_tenant(actor)
      |> where([a], a.id == ^id and a.user_id == ^actor.user_id)
      |> Arca.Repo.delete_all()
      |> case do
        {0, _} -> {:error, :not_found}
        {_one, _} -> :ok
      end
    end)
  end

  def delete_standing(actor, _id) when athanor(actor), do: {:error, :no_person}
  def delete_standing(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  @doc """
  Remove every standing answer of the component `publisher` and `name` in
  the actor's athanor, whoever gave it: the component has left the
  athanor. `{:ok, count}`.
  """
  @spec delete_component(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def delete_component(actor, publisher, name)
      when athanor(actor) and is_binary(publisher) and is_binary(name) do
    Arca.Repo.Errors.with_db_rescue("Arca.Questions.delete_component", fn ->
      {count, _} =
        QuestionAnswer
        |> QueryHelpers.where_tenant(actor)
        |> where([a], a.publisher == ^publisher and a.name == ^name)
        |> Arca.Repo.delete_all()

      {:ok, count}
    end)
  end

  def delete_component(%Prima.Actor{}, _publisher, _name), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # The writes that end a run
  # ---------------------------------------------------------------------------

  @doc """
  Close the open questions of the run `execution_id`, never another run's,
  inside the transaction of the write that ends it, and answer them
  (`t:closed/0`), by ref.
  """
  @spec close_run!(Prima.Actor.t(), String.t()) :: [closed()]
  # arca:db-raise-ok a transaction step: the run-ending writes rescue around their transaction.
  def close_run!(actor, execution_id) when athanor(actor) and is_binary(execution_id) do
    Question
    |> QueryHelpers.where_tenant(actor)
    |> where([q], q.execution_id == ^execution_id and q.state == "open")
    |> close!()
  end

  # arca:db-raise-ok inside the caller's transaction
  defp close!(query) do
    {_count, rows} =
      query
      |> select([q], %{ref: q.ref, user_id: q.user_id, deadline: q.deadline})
      |> Arca.Repo.update_all(set: [state: "ended", decided_at: Arca.ServerMetaStorage.now!()])

    Enum.sort_by(rows || [], & &1.ref)
  end

  defp found(nil), do: {:error, :not_found}
  defp found(row), do: {:ok, row}
end
