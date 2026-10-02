# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.StoredGrants do
  @moduledoc """
  The boot check of stored grants against the storage grammar.

  A grant is a consent revision, and it never changes. One committed
  before the manifest grammar refused a storage path spelled other than
  the storage door reaches it (`data//secrets/`, a `.` or `..` segment, a
  doubled trailing `/`) still names that spelling. The loader refuses such
  a head at admission with `consent_required`
  (`Sanctum.Consent.Loader`), so it runs nothing until it is granted again
  under the canonical spelling; this check says so at boot, so the people
  who hold it hear before a run is refused. Nothing is rewritten.

  It reads every athanor's active heads a page at a time
  (`Arca.ConsentStorage.active_head_policies/2`) and logs each grant it
  finds, on every member's boot. A head whose policy does not parse is the
  loader's to refuse, and is not listed here.

  The announcement is the cell's, not each member's: each athanor's list
  goes to that athanor alone, as one tray entry (`Sanctum.Notify`, kind
  `:regrant_required`), once per list. It is made under the
  `regrant_notice` claim (`Arca.JobClaims`, key `"cell"`), and a member
  that finds a live peer holding it leaves the announcement to that peer.
  The holder compares a digest of the list it found (`digest/1`) with the
  claim's `detail`, the digest of the last list the cell announced, and
  announces only a different one: a later member's boot, or a restart of
  the cell, with the same list says nothing, and a changed list is
  announced once.

  Sanctum starts before the host, so the announcement waits, within a
  bound, for the host's bridge to attach to the tray's event: one made
  before anything hears it would be lost, so until something listens
  nothing is announced and no digest is recorded, and the next boot tries
  again. The tray keeps no history: a person not connected when the list
  is announced sees no badge later, and the log and the loader's
  `consent_required` refusal still name the grant. A store that cannot
  answer ends the check with a warning; it is a notice, and the loader's
  refusal stands whether or not it was heard.
  """

  use Task, restart: :temporary

  require Logger

  alias Arca.JobClaims
  alias Prima.Authority.Blob

  @page 200
  @notify_event [:cyfr, :sanctum, :notify]
  @listener_wait_ms 60_000
  @listener_poll_ms 250
  @kind "regrant_notice"
  # Above the listener wait, so the holder keeps the claim while it waits.
  @lease_ms :timer.minutes(5)

  @typedoc "A stored grant the storage grammar no longer admits."
  @type grant :: %{profile_id: String.t(), source_ref: String.t(), revision: non_neg_integer()}

  @doc false
  def start_link(opts \\ []), do: Task.start_link(__MODULE__, :run, [opts])

  @doc """
  Find and log the stored grants the storage grammar no longer admits, and
  announce them once for the cell. `opts`: `:page` (rows a read takes,
  #{@page}), `:listener_wait_ms` (how long the announcement waits for a
  listener, #{@listener_wait_ms}), and the claim's `:key` (`"cell"` by
  default), `:owner` (this boot by default) and `:lease_ms`.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    case scan(Keyword.get(opts, :page, @page)) do
      {:ok, found} when map_size(found) == 0 ->
        :ok

      {:ok, found} ->
        Enum.each(found, fn {athanor_id, grants} -> log(athanor_id, grants) end)
        announce_once(found, opts)

      {:error, reason} ->
        Logger.warning(
          "[Sanctum.Consent.StoredGrants] stored grants not checked: #{inspect(reason)}"
        )
    end

    :ok
  end

  @doc """
  Every active head whose policy grants a storage path the grammar no
  longer admits (`Prima.Manifest.Caps.canonical_storage_path?/1`), grouped
  by athanor, read `page` rows at a time.
  """
  @spec scan(pos_integer()) :: {:ok, %{String.t() => [grant(), ...]}} | {:error, term()}
  def scan(page \\ @page) when is_integer(page) and page > 0, do: scan(nil, page, %{})

  @doc """
  The digest of a list `scan/1` found, as the `regrant_notice` claim
  records it: the same grants give the same digest whichever member read
  them, in whatever order.
  """
  @spec digest(%{String.t() => [grant()]}) :: String.t()
  def digest(found) when is_map(found) do
    found
    |> Enum.map(fn {athanor_id, grants} ->
      [
        athanor_id,
        grants |> Enum.map(&[&1.profile_id, &1.source_ref, &1.revision]) |> Enum.sort()
      ]
    end)
    |> Enum.sort()
    |> Jason.encode!()
    |> Prima.Digest.sha256()
  end

  # A short page is the last one.
  defp scan(after_id, page, found) do
    case Arca.ConsentStorage.active_head_policies(after_id, page) do
      {:ok, rows} when length(rows) < page ->
        {:ok, rows |> Enum.reduce(found, &collect/2) |> in_read_order()}

      {:ok, rows} ->
        scan(List.last(rows).profile_id, page, Enum.reduce(rows, found, &collect/2))

      {:error, _} = error ->
        error
    end
  end

  defp in_read_order(found),
    do: Map.new(found, fn {athanor_id, grants} -> {athanor_id, Enum.reverse(grants)} end)

  defp collect(row, found) do
    if canonical?(row.resolved_policy) do
      found
    else
      grant = %{profile_id: row.profile_id, source_ref: row.source_ref, revision: row.revision}
      Map.update(found, row.athanor_id, [grant], &[grant | &1])
    end
  end

  # A policy that does not parse is the loader's refusal, not this list's.
  defp canonical?(policy) do
    case Blob.parse(policy) do
      {:ok, %Blob{nodes: nodes}} ->
        Enum.all?(nodes, fn {_ref, node} ->
          Enum.all?(node.edges, fn {_key, edge} ->
            Enum.all?(Blob.Edge.paths(edge), &Prima.Manifest.Caps.canonical_storage_path?/1)
          end)
        end)

      {:error, _} ->
        true
    end
  end

  defp log(athanor_id, grants) do
    Logger.warning(
      "[Sanctum.Consent.StoredGrants] athanor #{athanor_id} holds grants naming a storage " <>
        "path the server no longer admits; each is refused until granted again: " <>
        Enum.map_join(
          grants,
          ", ",
          &"#{&1.source_ref} (#{&1.profile_id}, revision #{&1.revision})"
        )
    )
  end

  # The cell's one announcement of this list. The claim is given up whatever
  # happened under it, a raise included, so the next boot never waits out a
  # lease nobody is using; its `detail` survives the release.
  defp announce_once(found, opts) do
    key = Keyword.get(opts, :key, JobClaims.cell_key())
    owner = Keyword.get(opts, :owner, Prima.Boot.id())
    lease_ms = Keyword.get(opts, :lease_ms, @lease_ms)
    wait_ms = Keyword.get(opts, :listener_wait_ms, @listener_wait_ms)

    case JobClaims.claim(@kind, key, owner, lease_ms) do
      {:ok, claim} ->
        claim |> under_claim(found, wait_ms) |> JobClaims.release()

      {:busy, %{owner: peer}} ->
        Logger.info("[Sanctum.Consent.StoredGrants] the cell's announcement is #{peer}'s")

      {:error, :database_error} ->
        Logger.warning(
          "[Sanctum.Consent.StoredGrants] the regrant_notice claim could not be read; the " <>
            "grants above are listed in this log only"
        )
    end
  end

  # Answers the claim as it stands after any write made under it: the one
  # to give up.
  defp under_claim(claim, found, wait_ms) do
    digest = digest(found)

    cond do
      claim.detail == digest ->
        claim

      not listening?(System.monotonic_time(:millisecond) + wait_ms) ->
        Logger.warning(
          "[Sanctum.Consent.StoredGrants] nothing listens to the tray yet; the grants above " <>
            "are listed in this log only, and a later boot announces them"
        )

        claim

      true ->
        Enum.each(found, fn {athanor_id, grants} -> notify(athanor_id, grants) end)

        case JobClaims.record(claim, digest) do
          {:ok, recorded} -> recorded
          _taken_or_unreachable -> claim
        end
    end
  rescue
    e ->
      _ = JobClaims.release(claim)
      reraise e, __STACKTRACE__
  catch
    kind, reason ->
      _ = JobClaims.release(claim)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp notify(athanor_id, grants) do
    Sanctum.Notify.broadcast(athanor_id, :regrant_required, %{
      references: grants |> Enum.map(& &1.source_ref) |> Enum.uniq()
    })
  end

  # The tray's event reaches the bus only through the host's bridge, which
  # attaches after Sanctum starts. A bounded wait; past it the list stands
  # in the log, and the loader's refusal stands either way.
  defp listening?(deadline) do
    cond do
      :telemetry.list_handlers(@notify_event) |> Enum.any?(&(&1.event_name == @notify_event)) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@listener_poll_ms)
        listening?(deadline)
    end
  end
end
