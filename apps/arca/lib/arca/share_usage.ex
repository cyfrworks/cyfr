# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ShareUsage do
  @moduledoc """
  The count of a share's use, by person and by day, kept in the share's
  owner's athanor. Use is counted in requests, never spent, and counted
  whatever the caps, so the owner's view of who used the share is always
  complete.

  Each day has one row per person who used the share and one row of the
  share's own total, under the empty `user_id`, keyed by the athanor, the
  share, the person and the day. The day is the database's current UTC
  date, read inside the claim's transaction and never taken from the
  caller, so every member of a cell counts the same day.

  `claim/4` is one locking transaction (`Arca.Repo.locking_transaction/2`)
  under the owner's actor: the share's row is read shared
  (`Arca.QueryHelpers.for_share/1`), so a revoke, which takes it
  exclusive, and a claim serialize and a claim after the revoke refuses;
  the audience the caller admitted the person under is compared with the
  locked row's, so a narrowing that landed after the caller read the
  share, which takes no lock of its own, refuses the claim rather than
  counting a use outside the audience;
  both day rows are made present and read under a lock in a fixed order
  (the share's total first, then the person's); and both are raised by
  one. Each cap is the share's own, read from that locked row: `nil` is
  no limit and is never checked, `0` admits no use and `N` admits at most `N` that day, and the
  claim is refused `{:error, {:connection_cap, reset_at}}` only under a
  set cap that is reached. Two claims racing for the last request of a
  day admit one. `reset_at` is the next UTC midnight after the claimed
  day.

  `usage/3` is the owner's read and `used_today/3` one person's count of
  today; `sweep/1` deletes the rows of days older than thirty-five, in
  every athanor.
  """

  import Ecto.Query

  alias Arca.Schemas.Share
  alias Arca.Schemas.ShareUsage, as: Usage

  @total ""
  @kept_days 35

  defguardp resolved(athanor_id) when is_binary(athanor_id) and athanor_id != ""
  defguardp platform(actor) when is_struct(actor, Prima.Actor) and actor.scope == :platform

  @doc """
  Count one use of the share `share_id` of the actor's athanor by
  `user_id` today, held to the caps the share's row holds when the claim
  reads it under its lock, and to `admitted`, the audience
  (`%{audience: _, group_id: _}`) the caller read the share at when it
  admitted the person.

  Answers the day and both counts after the claim. Refused, with nothing
  counted: `{:error, {:connection_cap, reset_at}}` when a set cap is
  reached; `{:error, {:share_unavailable, status}}` for a share no longer
  active; `{:error, :audience_changed}` for a share whose audience is no
  longer `admitted`; and `{:error, :not_found}` for a share the athanor
  does not hold. The caps were held to their rule where they were set
  (`Arca.Schemas.Share.changeset/1`, `Arca.Shares.set_caps/4`).
  """
  @spec claim(Prima.Actor.t(), String.t(), String.t(), Arca.Shares.audience()) ::
          {:ok, %{day: Date.t(), person: pos_integer(), total: pos_integer()}}
          | {:error,
             {:connection_cap, DateTime.t()}
             | {:share_unavailable, String.t()}
             | :audience_changed
             | :not_found
             | :no_athanor
             | term()}
  def claim(%Prima.Actor{athanor_id: athanor_id}, share_id, user_id, %{} = admitted)
      when resolved(athanor_id) and is_binary(share_id) and is_binary(user_id) and user_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ShareUsage.claim", fn ->
      Arca.Repo.locking_transaction(fn ->
        with {:ok, {person_cap, total_cap}} <- claimable(athanor_id, share_id, admitted) do
          day = DateTime.to_date(Arca.ServerMetaStorage.now!())
          now = now()

          ensure_rows!(athanor_id, share_id, user_id, day, now)

          total = locked_count!(athanor_id, share_id, @total, day)
          person = locked_count!(athanor_id, share_id, user_id, day)

          if reached?(total, total_cap) or reached?(person, person_cap) do
            {:error, {:connection_cap, reset_at(day)}}
          else
            raise!(athanor_id, share_id, @total, day, total, now)
            raise!(athanor_id, share_id, user_id, day, person, now)
            {:ok, %{day: day, person: person + 1, total: total + 1}}
          end
        end
        |> Arca.Repo.committed()
      end)
    end)
  end

  def claim(%Prima.Actor{}, share_id, user_id, %{})
      when is_binary(share_id) and is_binary(user_id),
      do: {:error, :no_athanor}

  # The share's row, read shared, and its caps: a revoke holds it
  # exclusive and is waited for, a share revoked since admits nothing, an
  # audience moved since admits nothing, and caps set since are the ones
  # the claim is held to.
  defp claimable(athanor_id, share_id, admitted) do
    from(s in Share,
      where: s.id == ^share_id,
      select: {s.status, s.audience, s.group_id, s.person_daily, s.total_daily}
    )
    |> Arca.QueryHelpers.where_athanor(athanor_id)
    |> Arca.QueryHelpers.for_share()
    |> Arca.Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      {"active", audience, group_id, person_daily, total_daily} ->
        if Arca.Shares.same_audience?(%{audience: audience, group_id: group_id}, admitted),
          do: {:ok, {person_daily, total_daily}},
          else: {:error, :audience_changed}

      {status, _audience, _group_id, _person_daily, _total_daily} ->
        {:error, {:share_unavailable, status}}
    end
  end

  @doc """
  The share's use over the last `days` days (today included, on the
  database's date), for its owner: each person's count by day (`people`)
  and the share's day totals (`totals`), oldest first.
  """
  @spec usage(Prima.Actor.t(), String.t(), pos_integer()) ::
          {:ok,
           %{
             people: [%{user_id: String.t(), day: Date.t(), count: non_neg_integer()}],
             totals: [%{day: Date.t(), count: non_neg_integer()}]
           }}
          | {:error, :no_athanor | term()}
  def usage(%Prima.Actor{athanor_id: athanor_id}, share_id, days)
      when resolved(athanor_id) and is_binary(share_id) and is_integer(days) and days > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.ShareUsage.usage", fn ->
      today = DateTime.to_date(Arca.ServerMetaStorage.now!())
      since = Date.add(today, -(days - 1))

      rows =
        from(u in Usage,
          where: u.share_id == ^share_id and u.day >= ^since,
          order_by: [u.day, u.user_id]
        )
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.all()

      {totals, people} = Enum.split_with(rows, &(&1.user_id == @total))

      {:ok,
       %{
         people: Enum.map(people, &%{user_id: &1.user_id, day: &1.day, count: &1.count}),
         totals: Enum.map(totals, &%{day: &1.day, count: &1.count})
       }}
    end)
  end

  def usage(%Prima.Actor{}, share_id, days)
      when is_binary(share_id) and is_integer(days) and days > 0,
      do: {:error, :no_athanor}

  @doc """
  How many times `user_id` used the share `share_id` of the actor's
  athanor today, on the database's date as a claim counts it: `0` when
  they have not.
  """
  @spec used_today(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | term()}
  def used_today(%Prima.Actor{athanor_id: athanor_id}, share_id, user_id)
      when resolved(athanor_id) and is_binary(share_id) and is_binary(user_id) and user_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ShareUsage.used_today", fn ->
      day = DateTime.to_date(Arca.ServerMetaStorage.now!())

      count =
        from(u in Usage,
          where: u.share_id == ^share_id and u.user_id == ^user_id and u.day == ^day,
          select: u.count
        )
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.one()

      {:ok, count || 0}
    end)
  end

  def used_today(%Prima.Actor{}, share_id, user_id)
      when is_binary(share_id) and is_binary(user_id),
      do: {:error, :no_athanor}

  @doc """
  Delete the rows of days more than #{@kept_days} days before the
  database's current date, in every athanor, answering how many went.
  Platform scope only.
  """
  @spec sweep(Prima.Actor.t()) :: {:ok, non_neg_integer()} | {:error, :cross_tenant | term()}
  # arca:unscoped-ok the use counts of every athanor's shares, swept by age
  # alone: a day past the window is no owner's to keep.
  def sweep(actor) when platform(actor) do
    Arca.Repo.Errors.with_db_rescue("Arca.ShareUsage.sweep", fn ->
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

  # An absent cap is no limit and is never reached.
  defp reached?(_count, nil), do: false
  defp reached?(count, cap), do: count >= cap

  defp reset_at(day), do: DateTime.new!(Date.add(day, 1), ~T[00:00:00.000000], "Etc/UTC")

  defp ensure_rows!(athanor_id, share_id, user_id, day, now) do
    rows =
      for who <- [@total, user_id] do
        %{
          athanor_id: athanor_id,
          share_id: share_id,
          user_id: who,
          day: day,
          count: 0,
          updated_at: now
        }
      end

    Arca.Repo.insert_all(Usage, rows,
      on_conflict: :nothing,
      conflict_target: [:athanor_id, :share_id, :user_id, :day]
    )
  end

  defp locked_count!(athanor_id, share_id, user_id, day) do
    from(u in Usage,
      where: u.share_id == ^share_id and u.user_id == ^user_id and u.day == ^day,
      select: u.count
    )
    |> Arca.QueryHelpers.where_athanor(athanor_id)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one!()
  end

  # The count read under the lock is the precondition: a write that finds
  # another count landed in between refuses rather than over-counting.
  defp raise!(athanor_id, share_id, user_id, day, count, now) do
    {1, _} =
      from(u in Usage,
        where:
          u.share_id == ^share_id and u.user_id == ^user_id and u.day == ^day and
            u.count == ^count
      )
      |> Arca.QueryHelpers.where_athanor(athanor_id)
      |> Arca.Repo.update_all(set: [count: count + 1, updated_at: now])

    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
