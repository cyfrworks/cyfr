# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.BudgetReservations do
  @moduledoc """
  The `budget_reservations` and `budget_charges` rows: a root's
  invocation capacity and the holds against it.

  A charge is identified by the dispatch that made it, so a retry of the
  same dispatch is one charge: the row is inserted first (a conflict is
  the retry and changes nothing), and only a fresh row increments the
  reservation under its cap — an atomic row update, refused when the cap
  is full. A charge is bound to its authorizing attempt, which must own
  its execution, and names the child that will consume the capacity.

  Holds are deadlines, not ages: a charge must be admitted by `admit_by`
  (`admit_hold!/3` is the barrier admission runs), and a charge with no
  holder is reclaimable past `holder_deadline`. `sweep/1` reclaims by
  conditional writes on the same rows admission updates, so either side
  of a race sees the other's commit.

  ## Tenancy

  Every function but `fetch/1` takes the `Cyfr.Actor` first and matches
  it in its head, so the athanor comes from the caller and never from an
  argument. An actor whose athanor is nil or the empty string is refused
  before any query — `{:error, :no_athanor}` from an entry point, a
  raise from a `!` function inside a caller's transaction. `fetch/1` is
  the exception and says why where it stands: the id is the wire's
  identity of one root's reservation, and the row answers with its own
  athanor.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{BudgetCharge, BudgetReservation, ExecutionAttempt}

  @admission_window_seconds 60

  @type charge :: %{
          id: String.t(),
          attempt: String.t(),
          generation: non_neg_integer(),
          holder_execution_id: String.t() | nil
        }

  @doc "How long a charged dispatch has to reach admission, in seconds."
  def admission_window_seconds, do: @admission_window_seconds

  @doc """
  Mint the reservation of a root execution inside the caller's
  admission transaction.
  """
  @spec mint!(Cyfr.Actor.t(), String.t(), String.t(), pos_integer()) :: BudgetReservation.t()
  # arca:db-raise-ok inside the caller's transaction
  def mint!(%Cyfr.Actor{athanor_id: athanor_id}, root_execution_id, budget_id, cap)
      when is_binary(athanor_id) and athanor_id != "" and is_integer(cap) and cap >= 0 do
    Arca.Repo.insert!(%BudgetReservation{
      id: budget_id,
      athanor_id: athanor_id,
      root_execution_id: root_execution_id,
      cap: cap,
      charged: 0,
      inserted_at: DateTime.utc_now()
    })
  end

  def mint!(%Cyfr.Actor{}, _root_execution_id, _budget_id, _cap),
    do: Arca.QueryHelpers.no_athanor!("Arca.BudgetReservations.mint!/4")

  @doc "Entry-point form of `mint!/4`."
  @spec mint(Cyfr.Actor.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, BudgetReservation.t()} | {:error, term()}
  def mint(%Cyfr.Actor{athanor_id: athanor_id} = actor, root_execution_id, budget_id, cap)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.BudgetReservations.mint", fn ->
      Arca.Repo.transaction(fn -> mint!(actor, root_execution_id, budget_id, cap) end)
    end)
  end

  def mint(%Cyfr.Actor{}, _root_execution_id, _budget_id, _cap), do: {:error, :no_athanor}

  @doc """
  Charge `n` against `reservation_id` for one dispatch. `:ok` when the
  charge stands (a retry of the same charge id is `:ok` without a second
  increment); `:exhausted` when the cap is full; `:stale_attempt` when
  the authorizing attempt does not own its execution; `:released` when
  the reservation is closed. `opts`: `:holder_deadline` for a charge
  without a holder execution.
  """
  @spec charge(Cyfr.Actor.t(), String.t(), charge(), pos_integer(), keyword()) ::
          :ok | :exhausted | :stale_attempt | :released | {:error, term()}
  def charge(actor, reservation_id, charge, n, opts \\ [])

  def charge(
        %Cyfr.Actor{athanor_id: athanor_id},
        reservation_id,
        %{id: id, attempt: attempt} = charge,
        n,
        opts
      )
      when is_binary(athanor_id) and athanor_id != "" and is_integer(n) and n > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.BudgetReservations.charge", fn ->
      Arca.Repo.transaction(fn ->
        now = DateTime.utc_now()

        cond do
          not attempt_owns?(athanor_id, attempt) ->
            Arca.Repo.rollback(:stale_attempt)

          released?(athanor_id, reservation_id) ->
            Arca.Repo.rollback(:released)

          true ->
            row = %{
              id: id,
              athanor_id: athanor_id,
              reservation_id: reservation_id,
              attempt: attempt,
              generation: Map.get(charge, :generation, 0),
              holder_execution_id: Map.get(charge, :holder_execution_id),
              n: n,
              runner_id: Cyfr.Boot.id(),
              admit_by:
                if(Map.get(charge, :holder_execution_id),
                  do: DateTime.add(now, @admission_window_seconds, :second)
                ),
              holder_deadline: Keyword.get(opts, :holder_deadline),
              inserted_at: now
            }

            {inserted, _} =
              Arca.Repo.insert_all(BudgetCharge, [row],
                on_conflict: :nothing,
                conflict_target: [:reservation_id, :id]
              )

            if inserted == 0 do
              :ok
            else
              {count, _} =
                from(r in BudgetReservation,
                  where: r.id == ^reservation_id and r.athanor_id == ^athanor_id,
                  where: r.charged + ^n <= r.cap and is_nil(r.released_at)
                )
                |> Arca.Repo.update_all(inc: [charged: n])

              if count == 1 do
                :ok
              else
                Arca.Repo.delete_all(
                  from(c in BudgetCharge,
                    where: c.reservation_id == ^reservation_id and c.id == ^id,
                    where: c.athanor_id == ^athanor_id
                  )
                )

                Arca.Repo.rollback(:exhausted)
              end
            end
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} when reason in [:exhausted, :stale_attempt, :released] -> reason
        other -> other
      end
    end)
  end

  def charge(%Cyfr.Actor{}, _reservation_id, _charge, _n, _opts), do: {:error, :no_athanor}

  @doc """
  Release the charge `id` on `reservation_id`: the row goes and the
  reservation is decremented by what it held. Idempotent: a charge
  already released answers `:ok` and changes nothing.
  """
  @spec release(Cyfr.Actor.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def release(%Cyfr.Actor{athanor_id: athanor_id}, reservation_id, id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.BudgetReservations.release", fn ->
      Arca.Repo.transaction(fn -> release!(athanor_id, reservation_id, id) end)
      |> case do
        {:ok, _} -> :ok
        other -> other
      end
    end)
  end

  def release(%Cyfr.Actor{}, _reservation_id, _id), do: {:error, :no_athanor}

  @doc """
  The hold barrier, run inside admission's transaction: stamp the charge
  admitted while its hold stands. Answers the rows stamped — 0 when the
  hold expired or was reclaimed, and admission must abort.
  """
  @spec admit_hold!(Cyfr.Actor.t(), String.t(), String.t()) :: non_neg_integer()
  # arca:db-raise-ok inside the caller's transaction
  def admit_hold!(%Cyfr.Actor{athanor_id: athanor_id}, reservation_id, id)
      when is_binary(athanor_id) and athanor_id != "" do
    now = DateTime.utc_now()

    {count, _} =
      from(c in BudgetCharge,
        where: c.athanor_id == ^athanor_id and c.reservation_id == ^reservation_id,
        where: c.id == ^id and is_nil(c.admitted_at) and c.admit_by > ^now
      )
      |> Arca.Repo.update_all(set: [admitted_at: now])

    count
  end

  def admit_hold!(%Cyfr.Actor{}, _reservation_id, _id),
    do: Arca.QueryHelpers.no_athanor!("Arca.BudgetReservations.admit_hold!/3")

  @doc "Close a root's reservation inside the caller's transaction."
  @spec close!(Cyfr.Actor.t(), String.t()) :: non_neg_integer()
  # arca:db-raise-ok inside the caller's transaction
  def close!(%Cyfr.Actor{athanor_id: athanor_id}, root_execution_id)
      when is_binary(athanor_id) and athanor_id != "" do
    {count, _} =
      from(r in BudgetReservation,
        where: r.athanor_id == ^athanor_id and r.root_execution_id == ^root_execution_id,
        where: is_nil(r.released_at)
      )
      |> Arca.Repo.update_all(set: [released_at: DateTime.utc_now()])

    count
  end

  def close!(%Cyfr.Actor{}, _root_execution_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.BudgetReservations.close!/2")

  @doc """
  A reservation by its id alone — the identity an Authority carries over
  the wire, whose row names the athanor it belongs to.
  """
  @spec fetch(String.t()) :: {:ok, BudgetReservation.t()} | {:error, :not_found | term()}
  # arca:unscoped-ok the id is the wire's identity of one root's
  # reservation; the row answers with its own athanor.
  def fetch(id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.BudgetReservations.fetch", fn ->
      case Arca.Repo.get(BudgetReservation, id) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
  end

  @doc "A reservation by its id, within the athanor."
  @spec lookup(Cyfr.Actor.t(), String.t()) :: BudgetReservation.t() | nil | {:error, term()}
  def lookup(%Cyfr.Actor{athanor_id: athanor_id}, id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.BudgetReservations.lookup", fn ->
      Arca.Repo.one(
        from(r in BudgetReservation, where: r.athanor_id == ^athanor_id and r.id == ^id)
      )
    end)
  end

  def lookup(%Cyfr.Actor{}, _id), do: {:error, :no_athanor}

  @doc "The live charges of a reservation."
  @spec charges(Cyfr.Actor.t(), String.t()) :: {:ok, [BudgetCharge.t()]} | {:error, term()}
  def charges(%Cyfr.Actor{athanor_id: athanor_id}, reservation_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.BudgetReservations.charges", fn ->
      {:ok,
       Arca.Repo.all(
         from(c in BudgetCharge,
           where: c.athanor_id == ^athanor_id and c.reservation_id == ^reservation_id,
           order_by: [asc: c.inserted_at]
         )
       )}
    end)
  end

  def charges(%Cyfr.Actor{}, _reservation_id), do: {:error, :no_athanor}

  @doc """
  Reclaim the athanor's dead holds and recount every open reservation.
  Three conditional rules, each a write on the row admission also
  updates: an admitted charge whose holder's current attempt is terminal;
  an unadmitted hold past `admit_by`; a charge with no holder past its
  `holder_deadline`, or whose authorizing attempt is terminal. Answers
  the number of charges reclaimed.
  """
  @spec sweep(Cyfr.Actor.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep(%Cyfr.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.BudgetReservations.sweep", fn ->
      Arca.Repo.transaction(fn ->
        now = DateTime.utc_now()
        terminal = Arca.ExecutionAttempts.terminal_states()

        dead_holders =
          from(a in ExecutionAttempt,
            join: e in Arca.Execution,
            on: e.current_attempt == a.attempt,
            where: a.athanor_id == ^athanor_id and a.state in ^terminal,
            select: e.id
          )

        dead_attempts =
          from(a in ExecutionAttempt,
            where: a.athanor_id == ^athanor_id and a.state in ^terminal,
            select: a.attempt
          )

        reclaimable =
          from(c in BudgetCharge,
            where: c.athanor_id == ^athanor_id,
            where:
              (not is_nil(c.admitted_at) and c.holder_execution_id in subquery(dead_holders)) or
                (is_nil(c.admitted_at) and not is_nil(c.admit_by) and c.admit_by < ^now) or
                (is_nil(c.holder_execution_id) and
                   ((not is_nil(c.holder_deadline) and c.holder_deadline < ^now) or
                      c.attempt in subquery(dead_attempts)))
          )

        rows = Arca.Repo.all(reclaimable)

        Enum.each(rows, fn c ->
          release!(athanor_id, c.reservation_id, c.id)
        end)

        recount!(athanor_id)
        length(rows)
      end)
    end)
  end

  def sweep(%Cyfr.Actor{}), do: {:error, :no_athanor}

  # arca:db-raise-ok inside the caller's transaction
  defp release!(athanor_id, reservation_id, id) do
    row =
      Arca.Repo.one(
        from(c in BudgetCharge,
          where: c.athanor_id == ^athanor_id and c.reservation_id == ^reservation_id,
          where: c.id == ^id
        )
      )

    case row do
      nil ->
        0

      %BudgetCharge{n: n} ->
        {1, _} =
          Arca.Repo.delete_all(
            from(c in BudgetCharge,
              where: c.athanor_id == ^athanor_id and c.reservation_id == ^reservation_id,
              where: c.id == ^id
            )
          )

        from(r in BudgetReservation,
          where: r.athanor_id == ^athanor_id and r.id == ^reservation_id
        )
        |> Arca.Repo.update_all(inc: [charged: -n])

        1
    end
  end

  # The reservation's charged total is the sum of its surviving rows.
  # arca:db-raise-ok inside the caller's transaction
  defp recount!(athanor_id) do
    reservations =
      Arca.Repo.all(
        from(r in BudgetReservation,
          where: r.athanor_id == ^athanor_id and is_nil(r.released_at),
          select: r.id
        )
      )

    Enum.each(reservations, fn id ->
      sum =
        Arca.Repo.one(
          from(c in BudgetCharge,
            where: c.athanor_id == ^athanor_id and c.reservation_id == ^id,
            select: coalesce(sum(c.n), 0)
          )
        )

      from(r in BudgetReservation, where: r.athanor_id == ^athanor_id and r.id == ^id)
      |> Arca.Repo.update_all(set: [charged: sum])
    end)

    :ok
  end

  # arca:db-raise-ok inside the caller's transaction
  defp attempt_owns?(athanor_id, attempt) do
    Arca.Repo.exists?(
      from(a in ExecutionAttempt,
        join: e in Arca.Execution,
        on: e.id == a.execution_id,
        where: a.athanor_id == ^athanor_id and a.attempt == ^attempt,
        where: e.current_attempt == ^attempt and a.state in ["running", "paused"]
      )
    )
  end

  # arca:db-raise-ok inside the caller's transaction
  defp released?(athanor_id, reservation_id) do
    not Arca.Repo.exists?(
      from(r in BudgetReservation,
        where: r.athanor_id == ^athanor_id and r.id == ^reservation_id,
        where: is_nil(r.released_at)
      )
    )
  end
end
