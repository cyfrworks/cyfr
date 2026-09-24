# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RateWindows do
  @moduledoc """
  A bucket's consented invocation rate, claimed in the row every member
  of the cell shares (`Arca.Schemas.RateWindow`).

  One row per `(athanor, bucket)`, and the row *is* the window. Nothing
  here is claimed, leased or fenced: a counter has no owner, so there is
  nothing to take over and nothing to recover. Two consequences follow,
  and they are the point of this module. N members admit an athanor's
  consented rate once between them rather than once each. And a member
  that restarts forgets nothing, because it was holding nothing — where a
  counter in a boot's memory gave a bucket a fresh window on every
  restart.

  ## The arithmetic

  Two adjacent fixed windows, so a claim costs one read and one write and
  keeps no row per request. The row holds the current window's
  `window_start` and `count`, the width `window_ms` they are counted
  under, and `prior_count`, what the window before this one admitted.
  With `elapsed = now − window_start` in milliseconds, a claim against a
  cap of `cap` is admitted while

      prior_count × (window_ms − elapsed) + count × window_ms  <  cap × window_ms

  which is `prior_count × (window_ms − elapsed) ÷ window_ms + count < cap`
  with the division cleared, so the decision is exact integer arithmetic
  and nothing rounds in the admitting direction.

  Two properties of that estimate matter:

    * The prior term is never negative, so the estimate is never below
      `count`. At most `cap` claims land in one window of `window_ms`,
      whatever came before it — the count alone already holds the
      ceiling, and the prior term can only raise it.
    * At a boundary the window before still counts, by the fraction of it
      still in view. A claim a plain fixed window would have admitted at
      the start of a new window is refused while the one before was full.
      Refusing at a boundary is the direction a consented ceiling accepts;
      admitting twice over it is not.

  When `elapsed` has passed `window_ms` the window rotates before the
  claim is weighed: one width on, `prior_count` takes `count` and `count`
  starts from zero at `window_start + window_ms`; two widths or more on,
  nothing the row holds is still in view, so both counts start from zero.
  The rotation is computed, never stored on its own — a refused claim
  writes nothing at all, and the next claim rotates the same row the same
  way.

  The cap and the width come from the caller's consent on every claim and
  are not stored as policy. `window_ms` is on the row only so a count
  knows what it is a count of: a claim carrying a different width opens a
  window at its own width rather than rescaling a count that was never
  taken under it.

  ## Two members, one bucket

  A claim reads the row to know which window it is in, and then counts
  itself in one statement that carries the admission with it: the count
  is weighed against the cap and raised by one together, against the row
  as it stands when the store applies it. Two members claiming in the
  same instant are two such statements applied one after the other, each
  weighed against what the one before it left — never two increments of
  one count, and never one admitted on a count another member had
  already spent.

  A statement the condition refuses changes nothing; its claim reads the
  row again and decides again, where it is either refused by the ceiling
  or counted into the window that has since rotated. Opening a bucket and
  rotating its window are the two writes that cannot be expressed that
  way: the first is an insert the unique index decides, the second a
  compare-and-set on the row as it was read. Both are rare — once per
  bucket, once per window — and a member that loses either reads again.
  Past a bounded number of rounds a claim is refused without a verdict,
  never admitted.

  ## The clock

  `Arca.ServerMetaStorage.now!/0`, the cell's clock, decides which window
  a claim falls in. Two members reading their own clocks could disagree
  about where a boundary is and each open a window of its own, which is
  exactly the disagreement that admits a tenant's rate twice.

  ## Refusing when the store cannot answer

  A store that cannot answer admits nothing, and the three refusals stay
  distinguishable: `{:refused, retry_after_ms}` is the consented ceiling,
  `{:error, :contended}` a claim the row would not settle, and
  `{:error, :database_error}` a store that could not be read or written.

  ## What keeps the table from growing

  A bucket is whatever the caller names, and some callers name the
  address a request came from, so the set of buckets an athanor can
  create is as wide as the addresses that reach it. A claim that opens a
  *new* bucket's row therefore first deletes that athanor's rows of the
  same width whose window and prior window are both past — the rows a
  claim would open a fresh window over anyway. Reclamation is paid for by
  the claims that cause the growth. `purge_expired/0` is the same delete
  across every athanor and width, for the rows of a tenant that has
  stopped claiming altogether.
  """

  import Ecto.Query

  alias Arca.Schemas.RateWindow

  # A claim whose write the row would not take reads it and decides
  # again. Eight rounds is far past what a bucket needs on either
  # adapter — a round is spent only on an insert, a rotation or a
  # ceiling another member reached first, and the reread after it
  # usually settles the claim outright. One that still cannot settle is
  # refused without a verdict rather than admitted on a count it did not
  # write.
  @rounds 8

  @type refusal :: {:error, :no_athanor | :contended | :database_error}

  @doc """
  Claim one of `bucket`'s allowance for the actor's athanor, against a cap
  of `cap` in a window of `window_ms`.

  `{:ok, remaining}` admits the claim and counts it in the row, where
  `remaining` is how many more the same window would still admit.
  `{:refused, retry_after_ms}` is the ceiling: `retry_after_ms` is how
  long until the weighted estimate falls back under the cap.
  """
  @spec claim(Prima.Actor.t(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:refused, non_neg_integer()} | refusal()
  def claim(%Prima.Actor{athanor_id: athanor_id} = actor, bucket, cap, window_ms)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(bucket) and bucket != "" and
             is_integer(cap) and cap >= 0 and is_integer(window_ms) and window_ms > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.RateWindows.claim", fn ->
      claim_at(actor, bucket, cap, window_ms, Arca.ServerMetaStorage.now!())
    end)
    |> Arca.Data.project()
  end

  def claim(%Prima.Actor{}, _bucket, _cap, _window_ms), do: {:error, :no_athanor}

  # `claim/4` at an explicit instant, for tests that pin a claim to a
  # window's edge. Production reads the cell's clock in `claim/4` above:
  # an instant a caller chose decides no window in a running cell.
  @doc false
  @spec claim_at(Prima.Actor.t(), String.t(), non_neg_integer(), pos_integer(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:refused, non_neg_integer()} | refusal()
  def claim_at(%Prima.Actor{athanor_id: athanor_id}, bucket, cap, window_ms, %DateTime{} = now)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(bucket) and bucket != "" and
             is_integer(cap) and cap >= 0 and is_integer(window_ms) and window_ms > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.RateWindows.claim_at", fn ->
      # A cap of zero admits nothing, so it reads and writes nothing: the
      # window it would wait for is a whole one.
      if cap == 0,
        do: {:refused, window_ms},
        else: take(facts(athanor_id, bucket, cap, window_ms, now), @rounds)
    end)
    |> Arca.Data.project()
  end

  def claim_at(%Prima.Actor{}, _bucket, _cap, _window_ms, _now), do: {:error, :no_athanor}

  @doc """
  What `bucket` reads now, without claiming: `{:ok, used, remaining,
  window_ms}`, where `used` is the weighted estimate rounded down and
  `remaining` how many claims it would still admit.

  A read only — it neither counts a claim nor rotates the window.
  """
  @spec estimate(Prima.Actor.t(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, non_neg_integer(), non_neg_integer(), pos_integer()} | refusal()
  def estimate(%Prima.Actor{athanor_id: athanor_id}, bucket, cap, window_ms)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(bucket) and bucket != "" and
             is_integer(cap) and cap >= 0 and is_integer(window_ms) and window_ms > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.RateWindows.estimate", fn ->
      now = Arca.ServerMetaStorage.now!()
      {_start, prior, count, elapsed} = view(read(athanor_id, bucket), window_ms, now)

      used = div(prior * (window_ms - elapsed) + count * window_ms, window_ms)
      {:ok, used, remaining(prior, count, elapsed, window_ms, cap), window_ms}
    end)
    |> Arca.Data.project()
  end

  def estimate(%Prima.Actor{}, _bucket, _cap, _window_ms), do: {:error, :no_athanor}

  @doc """
  Forget `bucket`'s window: the row goes, and the next claim opens a
  fresh one. Administrative, and what a test uses to start a bucket from
  nothing.
  """
  @spec clear(Prima.Actor.t(), String.t()) :: :ok | {:error, :no_athanor | :database_error}
  def clear(%Prima.Actor{athanor_id: athanor_id}, bucket)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(bucket) and bucket != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.RateWindows.clear", fn ->
      Arca.Repo.delete_all(
        from(w in RateWindow, where: w.athanor_id == ^athanor_id and w.bucket == ^bucket)
      )

      :ok
    end)
    |> Arca.Data.project()
  end

  def clear(%Prima.Actor{}, _bucket), do: {:error, :no_athanor}

  @doc """
  Delete every row whose window and prior window are both past, across
  every athanor and width: the buckets nobody claims any more. Answers
  how many rows went.

  Deliberate default: housekeeping. A sweep the store could not answer is
  0 and is retried on the next cadence, and no row it would have deleted
  admits anything it should not — a claim rotates such a row to a fresh
  window of its own before weighing itself against it.
  """
  @spec purge_expired() :: non_neg_integer()
  def purge_expired do
    Arca.Repo.Errors.with_db_rescue("Arca.RateWindows.purge_expired", 0, fn ->
      now = Arca.ServerMetaStorage.now!()
      Enum.sum(Enum.map(widths(), &purge_width(&1, now)))
    end)
    |> Arca.Data.project()
  end

  # ---- internal --------------------------------------------------------------

  # One claim's own facts, carried whole rather than as five arguments
  # that could be passed in the wrong order.
  defp facts(athanor_id, bucket, cap, window_ms, now),
    do: %{athanor_id: athanor_id, bucket: bucket, cap: cap, window_ms: window_ms, now: now}

  defp take(_claim, 0), do: {:error, :contended}

  defp take(claim, rounds) do
    row = read(claim.athanor_id, claim.bucket)
    {_start, prior, count, elapsed} = window = view(row, claim.window_ms, claim.now)

    if admit?(prior, count, elapsed, claim.window_ms, claim.cap) do
      case count_claim(row, claim, window) do
        {:ok, remaining} ->
          {:ok, remaining}

        :again ->
          # The row moved between this claim's read and its write: another
          # member opened the bucket, rotated its window, or filled the
          # count this claim was weighed against. Read it again and decide
          # again on what landed.
          take(claim, rounds - 1)
      end
    else
      {:refused, retry_after(prior, count, elapsed, claim.window_ms, claim.cap)}
    end
  end

  # The window a claim of `window_ms` falls in, as the row reads at `now`:
  # `{window_start, prior_count, count, elapsed}`, rotated forward as far
  # as the clock has taken it. An absent row and a row of another width
  # both open a window at the claim's own width and instant — a count
  # taken under one width is never rescaled to another.
  defp view(nil, _window_ms, now), do: {now, 0, 0, 0}

  defp view(%RateWindow{window_ms: width}, window_ms, now) when width != window_ms,
    do: {now, 0, 0, 0}

  defp view(%RateWindow{} = row, window_ms, now) do
    elapsed = max(DateTime.diff(now, row.window_start, :millisecond), 0)

    case div(elapsed, window_ms) do
      0 ->
        {row.window_start, row.prior_count, row.count, elapsed}

      1 ->
        {DateTime.add(row.window_start, window_ms, :millisecond), row.count, 0,
         elapsed - window_ms}

      widths ->
        {DateTime.add(row.window_start, widths * window_ms, :millisecond), 0, 0,
         elapsed - widths * window_ms}
    end
  end

  # The weighted estimate against the cap, with the division by
  # `window_ms` cleared: `prior × (w − e) ÷ w + count < cap`.
  defp admit?(prior, count, elapsed, window_ms, cap),
    do: prior * (window_ms - elapsed) + count * window_ms < cap * window_ms

  # How many further claims the window would admit, given a state it has
  # already counted: the integer `k` where the estimate plus `k` is still
  # under the cap.
  defp remaining(prior, count, elapsed, window_ms, cap) do
    slack = (cap - count) * window_ms - prior * (window_ms - elapsed)
    if slack > 0, do: div(slack + window_ms - 1, window_ms), else: 0
  end

  # How long until this bucket admits again. While `count` alone is at the
  # cap nothing admits before the window rotates — and the window after it
  # carries this one's count as its prior, which has to decay in turn.
  defp retry_after(_prior, count, elapsed, window_ms, cap) when count >= cap,
    do: window_ms - elapsed + retry_after(count, 0, 0, window_ms, cap)

  defp retry_after(prior, count, elapsed, window_ms, cap) do
    # The first millisecond `e` at which `prior × (w − e) < (cap − count) × w`.
    # `prior` is above zero here: a claim refused with `count` under the
    # cap was refused by the prior window's weight.
    max(div(prior * window_ms - (cap - count) * window_ms, prior) + 1 - elapsed, 0)
  end

  # The write that counts an admitted claim: `{:ok, remaining}` when it
  # landed, `:again` when the row moved under it.
  defp count_claim(row, claim, {window_start, prior, count, elapsed}) do
    cond do
      is_nil(row) ->
        open(claim, window_start)

      rotated?(row, window_start, claim.window_ms) ->
        rotate(row, claim, window_start, prior, elapsed)

      true ->
        increment(claim, window_start, prior, count, elapsed)
    end
  end

  defp rotated?(%RateWindow{} = row, window_start, window_ms),
    do: row.window_ms != window_ms or DateTime.compare(row.window_start, window_start) != :eq

  # A bucket with no row yet. The unique index on `(athanor_id, bucket)`
  # decides a race between two first claims: the loser writes nothing and
  # decides again on the winner's row.
  defp open(claim, window_start) do
    reclaim(claim.athanor_id, claim.window_ms, claim.now)

    row = %{
      id: Prima.UUID7.generate_id("rw"),
      athanor_id: claim.athanor_id,
      bucket: claim.bucket,
      window_start: window_start,
      window_ms: claim.window_ms,
      count: 1,
      prior_count: 0,
      inserted_at: claim.now,
      updated_at: claim.now
    }

    if match?({1, _}, Arca.Repo.insert_all(RateWindow, [row], on_conflict: :nothing)),
      do: {:ok, remaining(0, 1, 0, claim.window_ms, claim.cap)},
      else: :again
  end

  # A window that has run out, or a width the consent changed, is opened
  # by the claim that finds it — and only on the row as it was read, so
  # two members rotating one window write one of them and the other
  # decides again on what landed.
  defp rotate(%RateWindow{} = row, claim, window_start, prior, elapsed) do
    query =
      from(w in RateWindow,
        where: w.athanor_id == ^claim.athanor_id and w.bucket == ^claim.bucket,
        where: w.window_start == ^row.window_start and w.window_ms == ^row.window_ms,
        where: w.count == ^row.count and w.prior_count == ^row.prior_count
      )

    landed? =
      match?(
        {1, _},
        Arca.Repo.update_all(query,
          set: [
            window_start: window_start,
            window_ms: claim.window_ms,
            prior_count: prior,
            count: 1,
            updated_at: claim.now
          ]
        )
      )

    if landed?,
      do: {:ok, remaining(prior, 1, elapsed, claim.window_ms, claim.cap)},
      else: :again
  end

  # The claim in the window the row already holds. The count is read,
  # weighed against the cap and raised by one inside ONE statement, whose
  # condition the store evaluates against the row as it stands: two
  # members claiming in the same instant are two increments applied one
  # after the other, each weighed against what the one before it left, and
  # never two increments of the same count. A claim the condition refuses
  # changes nothing, and is decided again on a fresh read — where it is
  # either refused by the ceiling or admitted into a window that has since
  # rotated.
  #
  # `remaining` is measured on the count this claim was weighed against,
  # so a member's claim landing in the same instant may not be in it. It
  # reports; it does not admit.
  defp increment(claim, window_start, prior, count, elapsed) do
    in_view = claim.window_ms - elapsed
    ceiling = claim.cap * claim.window_ms

    query =
      from(w in RateWindow,
        where: w.athanor_id == ^claim.athanor_id and w.bucket == ^claim.bucket,
        where: w.window_start == ^window_start and w.window_ms == ^claim.window_ms,
        where: w.prior_count * ^in_view + w.count * ^claim.window_ms < ^ceiling
      )

    if match?({1, _}, Arca.Repo.update_all(query, inc: [count: 1], set: [updated_at: claim.now])),
      do: {:ok, remaining(prior, count + 1, elapsed, claim.window_ms, claim.cap)},
      else: :again
  end

  defp read(athanor_id, bucket) do
    Arca.Repo.one(
      from(w in RateWindow, where: w.athanor_id == ^athanor_id and w.bucket == ^bucket)
    )
  end

  # The athanor's dead windows of this width, deleted by the claim that is
  # about to open a bucket of its own: the buckets that grow this table
  # are the ones that pay to reclaim it.
  defp reclaim(athanor_id, window_ms, now) do
    Arca.Repo.delete_all(
      from(w in RateWindow,
        where: w.athanor_id == ^athanor_id and w.window_ms == ^window_ms,
        where: w.window_start < ^DateTime.add(now, -2 * window_ms, :millisecond)
      )
    )
  end

  # arca:unscoped-ok the sweep reclaims dead windows across every athanor,
  # by width, because a row's own width decides when it is dead.
  defp purge_width(window_ms, now) do
    {count, _} =
      Arca.Repo.delete_all(
        from(w in RateWindow,
          where: w.window_ms == ^window_ms,
          where: w.window_start < ^DateTime.add(now, -2 * window_ms, :millisecond)
        )
      )

    count
  end

  # arca:unscoped-ok the widths in the table, cell-wide, so the sweep can
  # ask each of them when its rows are dead. Reads no tenant's counts.
  defp widths do
    Arca.Repo.all(from(w in RateWindow, distinct: true, select: w.window_ms))
  end
end
