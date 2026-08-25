# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BuildRecords do
  @moduledoc """
  The build-record surface: one `build_records` row per build. `Locus.MCP`
  writes them and `Cyfr.Retention` prunes them — two apps, one owner of
  the shape both rely on.

  Build status was the last structured record living as blob files
  (`builds/{id}.json`); as rows, "the newest N" is a query instead of a
  list-read-parse walk. The WASM/tincture artifacts a build produces stay
  blobs under the athanor's `components/` tree.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.BuildRecord
  alias Sanctum.Context

  @doc "Record a build as started. Overwrites a stale row with the same id."
  @spec record_started(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def record_started(%Context{} = ctx, build_id, reference) do
    attrs = %{
      id: build_id,
      athanor_id: ctx.athanor_id,
      user_id: ctx.user_id,
      reference: reference,
      status: "started",
      started_at: DateTime.utc_now()
    }

    %BuildRecord{}
    |> BuildRecord.changeset(attrs)
    |> Arca.Repo.insert(
      on_conflict: {:replace, [:status, :started_at, :finished_at, :error, :result]},
      conflict_target: :id
    )
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Record a build's outcome: `"compiled"` with a result map, or `"failed"`
  with an error string. Tenant-scoped — a foreign or unknown id is
  `{:error, :not_found}`.
  """
  @spec record_finished(Context.t(), String.t(), String.t(), map() | String.t()) ::
          :ok | {:error, term()}
  def record_finished(%Context{} = ctx, build_id, status, outcome)
      when status in ["compiled", "failed"] do
    updates =
      case status do
        "compiled" -> [result: Jason.encode!(outcome)]
        "failed" -> [error: outcome]
      end ++ [status: status, finished_at: DateTime.utc_now()]

    {count, _} =
      BuildRecord
      |> where([b], b.id == ^build_id)
      |> QueryHelpers.where_tenant(ctx)
      |> Arca.Repo.update_all(set: updates)

    if count == 1, do: :ok, else: {:error, :not_found}
  end

  @doc "One build's record as the JSON-shaped map the `build.status` tool returns."
  @spec get(Context.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(%Context{} = ctx, build_id) do
    BuildRecord
    |> where([b], b.id == ^build_id)
    |> QueryHelpers.where_tenant(ctx)
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :not_found}
      record -> {:ok, to_map(record)}
    end
  end

  @doc """
  Delete every build record past the newest `keep`, ordered by
  `started_at`. `dry_run: true` names the ids instead of deleting.
  Returns `{:ok, deleted_count}` or `{:ok, %{would_delete: ids}}`.
  """
  @spec prune(Context.t(), non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer() | %{would_delete: [String.t()]}}
  def prune(%Context{} = ctx, keep, opts \\ []) when is_integer(keep) and keep >= 0 do
    # SQLite has no bare OFFSET, so the survivors are the subquery: the
    # newest `keep` rows stay, everything else in the tenant goes.
    keepers =
      BuildRecord
      |> QueryHelpers.where_tenant(ctx)
      |> order_by([b], desc: b.started_at)
      |> limit(^keep)
      |> select([b], b.id)

    doomed_query =
      BuildRecord
      |> QueryHelpers.where_tenant(ctx)
      |> where([b], b.id not in subquery(keepers))

    if Keyword.get(opts, :dry_run, false) do
      {:ok, %{would_delete: doomed_query |> select([b], b.id) |> Arca.Repo.all()}}
    else
      {count, _} = Arca.Repo.delete_all(doomed_query)
      {:ok, count}
    end
  end

  defp to_map(%BuildRecord{} = r) do
    %{
      "build_id" => r.id,
      "reference" => r.reference,
      "status" => r.status,
      "started_at" => DateTime.to_iso8601(r.started_at)
    }
    |> put_present("finished_at", r.finished_at && DateTime.to_iso8601(r.finished_at))
    |> put_present("error", r.error)
    |> put_present("result", r.result && Jason.decode!(r.result))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
