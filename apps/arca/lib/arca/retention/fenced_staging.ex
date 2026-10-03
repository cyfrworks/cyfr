# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.FencedStaging do
  @moduledoc """
  The sweep of content staged for a fenced publication
  (`Arca.Storage.stage/3`, `Arca.FencedPublication`): reservations that
  ran out unpublished, bytes a publication has replaced, and bytes no row
  names. Named apart from `Arca.Retention.StagedRevisions`, which collects
  the overlay's staged unit revisions.

  One sweep of one athanor, in this order:

    1. the athanor's `staging/` root is listed with the adapter's prefix
       listing (`Arca.Storage.list_prefix/2`), before any row is read;
    2. every `deleting` row has its bytes deleted, then the row: a row a
       sweep claimed and stopped short on, and the row of bytes a later
       publication of the same document replaced
       (`Arca.FencedPublication.publish/3` marks it in its own
       transaction);
    3. a `reserved` row past its `expires_at` is claimed `deleting` by
       compare-and-set on its state and expiry, its bytes are deleted,
       then the row. A publication claims the same row by the same kind
       of statement, so of the two exactly one lands: a publication after
       the sweep's claim refuses `:expired`, and a sweep meeting a
       publication in flight waits for it and then finds the row
       `published`;
    4. listed bytes no row names are deleted once older than
       `Arca.Storage.reservation_ms/0` by the adapter's own last-modified
       time (`Arca.Storage.last_modified/2`), and left alone inside it.

  A `published` row is never the sweep's, whatever its expiry says. A
  stage writes its row before its bytes, so bytes a live attempt wrote
  always have a row by the time a listing can see them; a key is minted
  per attempt, so two attempts that staged identical content never share
  bytes, and reclaiming one never touches the other's.

  ## The value

  The reservation window is the mechanism and stays fixed: an athanor's
  `fenced_staging_days` changes neither when a reservation expires nor
  how old row-less bytes must be. It is how long a `deleting` row may keep
  failing to delete its bytes before it counts as stuck: a row marked
  `deleting` more than that many days ago whose bytes still cannot be
  deleted is retried like any other, is never dropped, and makes the
  sweep answer `{:error, {:stuck, count}}` so it surfaces in the cleanup's
  errors instead of in a count. Otherwise the count answered is the rows
  reclaimed and the row-less objects deleted (or, on a dry run, that
  would be).

  Every deletion is decided by a row's compare-and-set or by the bytes'
  age, never by this member's standing in the cell, so the sweep runs on
  any member.
  """
  @behaviour Arca.Retention.Kind

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Arca.Retention.Kind
  alias Arca.Schemas.StorageStaging

  # How many rows of each kind one sweep of one athanor reclaims; the next
  # takes up where it stopped.
  @limit 500

  @impl true
  def key, do: "fenced_staging_days"

  @impl true
  def default, do: Kind.configured(:fenced_staging_days, 1)

  @impl true
  def unit, do: :days

  @impl true
  def prune(%Prima.Actor{athanor_id: athanor_id} = actor, days, dry_run)
      when is_binary(athanor_id) and athanor_id != "" and is_integer(days) and days > 0 and
             is_boolean(dry_run) do
    if Arca.Storage.athanor_ready?(actor) do
      Arca.Repo.Errors.with_db_rescue("Arca.Retention.FencedStaging.prune", fn ->
        with {:ok, listing} <- Arca.Storage.list_prefix(actor, [Arca.Storage.staging_root()]) do
          sweep(actor, listing, Kind.days_cutoff(days), dry_run)
        end
      end)
    else
      {:error, :no_athanor}
    end
  end

  def prune(%Prima.Actor{}, _value, _dry_run), do: {:error, :no_athanor}

  defp sweep(actor, listing, _stuck_before, true) do
    now = Arca.ServerMetaStorage.now!()
    rows = length(deleting(actor)) + length(expired(actor, now))
    {:ok, rows + length(aged_orphans(actor, listing))}
  end

  defp sweep(actor, listing, stuck_before, false) do
    now = Arca.ServerMetaStorage.now!()
    {finished, failed} = Enum.split_with(deleting(actor), &finish(actor, &1))
    reclaimed = Enum.count(expired(actor, now), &reclaim(actor, &1, now))
    removed = Enum.count(aged_orphans(actor, listing), &(remove_bytes(actor, &1) == :ok))

    # A row marked `deleting` longer ago than the athanor's value whose
    # bytes still would not go. It stays for the next sweep either way.
    stuck = Enum.count(failed, &(DateTime.compare(&1.updated_at, stuck_before) == :lt))

    if stuck > 0,
      do: {:error, {:stuck, stuck}},
      else: {:ok, length(finished) + reclaimed + removed}
  end

  # ---- rows ------------------------------------------------------------------

  defp deleting(%Prima.Actor{athanor_id: athanor_id}) do
    Arca.Repo.all(
      from(s in StorageStaging,
        where: s.athanor_id == ^athanor_id and s.state == "deleting",
        order_by: [asc: s.id],
        limit: @limit
      )
    )
  end

  defp expired(%Prima.Actor{athanor_id: athanor_id}, now) do
    Arca.Repo.all(
      from(s in StorageStaging,
        where: s.athanor_id == ^athanor_id and s.state == "reserved" and s.expires_at <= ^now,
        order_by: [asc: s.expires_at],
        limit: @limit
      )
    )
  end

  # The claim names the state and the expiry it read: a publication that
  # claimed the row first leaves it `published`, and this matches nothing.
  defp reclaim(%Prima.Actor{athanor_id: athanor_id} = actor, %StorageStaging{id: id} = row, now) do
    claim =
      from(s in StorageStaging,
        where:
          s.athanor_id == ^athanor_id and s.id == ^id and s.state == "reserved" and
            s.expires_at <= ^now
      )

    case Arca.Repo.update_all(claim, set: [state: "deleting", updated_at: now]) do
      {1, _} -> finish(actor, %StorageStaging{row | state: "deleting"})
      {0, _} -> false
    end
  end

  # The bytes go first, then the row: a row left `deleting` by a failure
  # between the two is retried from itself at the next sweep, and the
  # bytes are never left without a row that says they are going.
  defp finish(%Prima.Actor{athanor_id: athanor_id} = actor, %StorageStaging{id: id, key: key}) do
    with {:ok, path} <- staged_path(key),
         :ok <- remove_bytes(actor, path) do
      gone =
        from(s in StorageStaging,
          where: s.athanor_id == ^athanor_id and s.id == ^id and s.state == "deleting"
        )

      # No row left to delete means a concurrent sweep finished it first:
      # the bytes are gone either way, so it is done and never stuck.
      {_count, _} = Arca.Repo.delete_all(gone)
      true
    else
      _kept -> false
    end
  end

  # ---- bytes -----------------------------------------------------------------

  # Listed bytes no row names, older than the reservation window by the
  # store's own clock. The rows are read after the listing, so a row a
  # live attempt wrote before its bytes is always seen here.
  defp aged_orphans(%Prima.Actor{athanor_id: athanor_id} = actor, listing) do
    named =
      Arca.Repo.all(from(s in StorageStaging, where: s.athanor_id == ^athanor_id, select: s.key))
      |> MapSet.new()

    cutoff = DateTime.add(DateTime.utc_now(), -Arca.Storage.reservation_ms(), :millisecond)

    for path <- listing,
        not MapSet.member?(named, Enum.join(path, "/")),
        aged?(actor, path, cutoff),
        do: path
  end

  # Bytes whose age the store cannot tell are kept.
  defp aged?(actor, path, cutoff) do
    case Arca.Storage.last_modified(actor, path) do
      {:ok, at} -> DateTime.compare(at, cutoff) == :lt
      {:error, _} -> false
    end
  end

  # The staging root is reserved, so its bytes are deleted under the same
  # internal-write scope that wrote them. Bytes already gone count as
  # deleted: a retried sweep, or an upload that never landed.
  defp remove_bytes(actor, path) do
    case Arca.Overlay.with_internal_writes(fn -> Arca.delete(actor, path) end) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} = error ->
        Logger.warning(
          "[Arca.Retention.FencedStaging] staged bytes kept for the next sweep: #{inspect(reason)}"
        )

        error
    end
  end

  # A row names bytes under the staging root and nowhere else; a key that
  # does not is left alone rather than followed.
  defp staged_path(key) do
    root = Arca.Storage.staging_root()

    case String.split(key, "/") do
      [^root, id] = path when id != "" -> {:ok, path}
      _other -> {:error, :not_a_staging_key}
    end
  end
end
