# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.InstanceEntryUsage do
  @moduledoc """
  The count of an instance entry's use, by person and by day: a
  Sanctum-only store (`Cyfr.Boundaries`' security-store roster), asked by
  `Sanctum.InstanceEntries` at each attach. Use is counted in requests,
  never spent.

  Each day has one row per person who used the entry and one row of the
  entry's own total, under the empty `user_id`, keyed by the entry, the
  person and the day. The day is the database's current UTC date, read
  inside the claim's transaction and never taken from the caller, so every
  member of a cell counts the same day.

  `claim/4` is one locking transaction (`Arca.Repo.locking_transaction/2`):
  both day rows are made present, then read under a lock in a fixed order
  (the entry's total first, then the person's), and the claim is refused
  `{:error, {:connection_cap, reset_at}}` when either already holds its
  cap, else both are raised by one with conditional writes. Two claims
  racing for the last request of a day admit one. `reset_at` is the next
  UTC midnight after the claimed day.

  The caps are the caller's resolved values, each an integer from 0 to
  `Arca.Schemas.InstanceEntry.max_cap/0`, `0` admitting no use: no claim
  is uncapped, and an entry's unset cap takes its platform setting's
  default above this module. `sweep/1` deletes the rows of days older
  than thirty-five.

  Not an athanor's: no row carries a tenant, so every query here crosses
  athanors by design, under the platform's actor alone.
  """

  import Ecto.Query

  alias Arca.Schemas.InstanceEntryUsage, as: Usage

  @total ""
  @kept_days 35

  @typedoc "The caps a claim is held to, each an integer (`0` admits none)."
  @type caps :: %{person_daily: non_neg_integer(), total_daily: non_neg_integer()}

  defguardp platform(actor) when is_struct(actor, Prima.Actor) and actor.scope == :platform

  @doc """
  Count one use of `entry_id` by `user_id` today, held to `caps`.

  Answers the day and both counts after the claim, or
  `{:error, {:connection_cap, reset_at}}` with nothing counted when either
  cap is reached. A cap that is not an integer from 0 to
  `Arca.Schemas.InstanceEntry.max_cap/0`, `nil` included, is refused
  `{:error, {:invalid, _}}` before any query. Platform scope only.
  """
  @spec claim(Prima.Actor.t(), String.t(), String.t(), caps()) ::
          {:ok, %{day: Date.t(), person: pos_integer(), total: pos_integer()}}
          | {:error, {:connection_cap, DateTime.t()} | :cross_tenant | {:invalid, map()} | term()}
  def claim(actor, entry_id, user_id, %{person_daily: person_cap, total_daily: total_cap})
      when platform(actor) and is_binary(entry_id) and is_binary(user_id) and user_id != "" do
    if cap?(person_cap) and cap?(total_cap) do
      Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntryUsage.claim", fn ->
        Arca.Repo.locking_transaction(fn ->
          day = DateTime.to_date(Arca.ServerMetaStorage.now!())
          now = now()

          ensure_rows!(entry_id, user_id, day, now)

          total = locked_count!(entry_id, @total, day)
          person = locked_count!(entry_id, user_id, day)

          if reached?(total, total_cap) or reached?(person, person_cap) do
            Arca.Repo.rollback({:connection_cap, reset_at(day)})
          else
            raise!(entry_id, @total, day, total, now)
            raise!(entry_id, user_id, day, person, now)
            %{day: day, person: person + 1, total: total + 1}
          end
        end)
      end)
    else
      {:error,
       {:invalid, %{caps: ["are integers from 0 to #{Arca.Schemas.InstanceEntry.max_cap()}"]}}}
    end
  end

  def claim(%Prima.Actor{}, entry_id, user_id, %{person_daily: _, total_daily: _})
      when is_binary(entry_id) and is_binary(user_id),
      do: {:error, :cross_tenant}

  @doc """
  The entry's use over the last `days` days (today included, on the
  database's date), for the administrator's read: each person's count by
  day (`people`) and the entry's day totals (`totals`), oldest first.
  """
  @spec usage(Prima.Actor.t(), String.t(), pos_integer()) ::
          {:ok,
           %{
             people: [%{user_id: String.t(), day: Date.t(), count: non_neg_integer()}],
             totals: [%{day: Date.t(), count: non_neg_integer()}]
           }}
          | {:error, :cross_tenant | term()}
  # arca:unscoped-ok an instance entry's use is read by the entry, in no
  # athanor: the instance's own credentials are offered to athanors and
  # deleted with none of them.
  def usage(actor, entry_id, days)
      when platform(actor) and is_binary(entry_id) and is_integer(days) and days > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntryUsage.usage", fn ->
      today = DateTime.to_date(Arca.ServerMetaStorage.now!())
      since = Date.add(today, -(days - 1))

      rows =
        from(u in Usage,
          where: u.instance_entry_id == ^entry_id and u.day >= ^since,
          order_by: [u.day, u.user_id]
        )
        |> Arca.Repo.all()

      {totals, people} = Enum.split_with(rows, &(&1.user_id == @total))

      {:ok,
       %{
         people: Enum.map(people, &%{user_id: &1.user_id, day: &1.day, count: &1.count}),
         totals: Enum.map(totals, &%{day: &1.day, count: &1.count})
       }}
    end)
  end

  def usage(%Prima.Actor{}, entry_id, days)
      when is_binary(entry_id) and is_integer(days) and days > 0,
      do: {:error, :cross_tenant}

  @doc """
  Delete the rows of days more than #{@kept_days} days before the
  database's current date, answering how many went.
  """
  @spec sweep(Prima.Actor.t()) :: {:ok, non_neg_integer()} | {:error, :cross_tenant | term()}
  # arca:unscoped-ok the instance's own use counts, swept by age across
  # every entry; no athanor holds them.
  def sweep(actor) when platform(actor) do
    Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntryUsage.sweep", fn ->
      cutoff = Date.add(DateTime.to_date(Arca.ServerMetaStorage.now!()), -@kept_days)
      {count, _} = Arca.Repo.delete_all(from(u in Usage, where: u.day < ^cutoff))
      {:ok, count}
    end)
  end

  def sweep(%Prima.Actor{}), do: {:error, :cross_tenant}

  @doc "How many days of use rows `sweep/1` keeps."
  @spec kept_days() :: pos_integer()
  def kept_days, do: @kept_days

  # ---------------------------------------------------------------------------

  defp cap?(cap), do: is_integer(cap) and cap >= 0 and cap <= Arca.Schemas.InstanceEntry.max_cap()

  defp reached?(count, cap), do: count >= cap

  defp reset_at(day), do: DateTime.new!(Date.add(day, 1), ~T[00:00:00.000000], "Etc/UTC")

  # arca:unscoped-ok an instance entry's use is counted by the entry and the
  # person, in no athanor: the instance's own credentials are offered to
  # athanors and deleted with none of them.
  defp ensure_rows!(entry_id, user_id, day, now) do
    rows =
      for who <- [@total, user_id],
          do: %{instance_entry_id: entry_id, user_id: who, day: day, count: 0, updated_at: now}

    Arca.Repo.insert_all(Usage, rows,
      on_conflict: :nothing,
      conflict_target: [:instance_entry_id, :user_id, :day]
    )
  end

  # arca:unscoped-ok an instance entry's use is counted by the entry and the
  # person, in no athanor: the instance's own credentials are offered to
  # athanors and deleted with none of them.
  defp locked_count!(entry_id, user_id, day) do
    from(u in Usage,
      where: u.instance_entry_id == ^entry_id and u.user_id == ^user_id and u.day == ^day,
      select: u.count
    )
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one!()
  end

  # The count read under the lock is the precondition: a write that finds
  # another count landed in between refuses rather than over-counting.
  # arca:unscoped-ok an instance entry's use is counted by the entry and the
  # person, in no athanor: the instance's own credentials are offered to
  # athanors and deleted with none of them.
  defp raise!(entry_id, user_id, day, count, now) do
    {1, _} =
      from(u in Usage,
        where:
          u.instance_entry_id == ^entry_id and u.user_id == ^user_id and u.day == ^day and
            u.count == ^count
      )
      |> Arca.Repo.update_all(set: [count: count + 1, updated_at: now])

    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
