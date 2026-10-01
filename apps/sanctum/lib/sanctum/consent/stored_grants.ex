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
  under the canonical spelling; this check says so once at boot, so the
  people who hold it hear before a run is refused. Nothing is rewritten.

  It reads every athanor's active heads a page at a time
  (`Arca.ConsentStorage.active_head_policies/2`), logs each grant it finds,
  and announces each athanor's list to that athanor alone, as one tray
  entry (`Sanctum.Notify`, kind `:regrant_required`). A head whose policy
  does not parse is the loader's to refuse, and is not listed here.

  Sanctum starts before the host, so the announcement waits, within a
  bound, for the host's bridge to attach to the tray's event: one made
  before anything hears it would be lost. A store that cannot answer ends
  the check with a warning; it is a notice, and the loader's refusal
  stands whether or not it was heard.
  """

  use Task, restart: :temporary

  require Logger

  alias Prima.Authority.Blob

  @page 200
  @notify_event [:cyfr, :sanctum, :notify]
  @listener_wait_ms 60_000
  @listener_poll_ms 250

  @typedoc "A stored grant the storage grammar no longer admits."
  @type grant :: %{profile_id: String.t(), source_ref: String.t(), revision: non_neg_integer()}

  @doc false
  def start_link(opts \\ []), do: Task.start_link(__MODULE__, :run, [opts])

  @doc """
  Find, list and announce the stored grants the storage grammar no longer
  admits. `opts`: `:page` (rows a read takes, #{@page}) and `:listener_wait_ms`
  (how long the announcement waits for a listener, #{@listener_wait_ms}).
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    case scan(Keyword.get(opts, :page, @page)) do
      {:ok, found} when map_size(found) == 0 ->
        :ok

      {:ok, found} ->
        listen_or_log(Keyword.get(opts, :listener_wait_ms, @listener_wait_ms))
        Enum.each(found, fn {athanor_id, grants} -> announce(athanor_id, grants) end)

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

  defp announce(athanor_id, grants) do
    Logger.warning(
      "[Sanctum.Consent.StoredGrants] athanor #{athanor_id} holds grants naming a storage " <>
        "path the server no longer admits; each is refused until granted again: " <>
        Enum.map_join(
          grants,
          ", ",
          &"#{&1.source_ref} (#{&1.profile_id}, revision #{&1.revision})"
        )
    )

    Sanctum.Notify.broadcast(athanor_id, :regrant_required, %{
      references: grants |> Enum.map(& &1.source_ref) |> Enum.uniq()
    })
  end

  # The tray's event reaches the bus only through the host's bridge, which
  # attaches after Sanctum starts. A bounded wait; past it the list stands
  # in the log, and the loader's refusal stands either way.
  defp listen_or_log(wait_ms) do
    deadline = System.monotonic_time(:millisecond) + wait_ms

    if not listening?(deadline) do
      Logger.warning(
        "[Sanctum.Consent.StoredGrants] nothing listens to the tray yet; the grants below " <>
          "are listed in this log only"
      )
    end
  end

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
