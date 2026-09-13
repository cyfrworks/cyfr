# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BuildRecords do
  @moduledoc """
  The build-record surface: one `build_records` row per build. `Locus.MCP`
  writes them and `Cyfr.Retention` prunes them — two apps, one owner of
  the shape both rely on.

  Build status is stored in database rows. WASM and tincture artifacts
  remain blobs under the athanor’s `components/` tree.
  """

  import Ecto.Query

  require Logger

  alias Arca.QueryHelpers
  alias Arca.Schemas.BuildRecord
  alias Sanctum.Context

  # How long a row may read "started" before retention treats it as
  # orphaned rather than in flight. Far beyond any live build: the
  # compile deadline is 270 s under the MCP layer's 5-minute brutal kill,
  # so an hour can only mean the writer went away (node restart, dropped
  # task) and no `record_finished/4` is coming. Spelled here rather than
  # taken from `Locus.Builder` because locus depends on cyfr, not the
  # other way around.
  @started_grace_ms :timer.hours(1)

  @doc """
  Record a build as started. Overwrites the caller's own stale row with the
  same id; a row belonging to another athanor is `{:error, :not_found}`.

  `build_id` is caller-supplied (`Locus.MCP` reads `args["build_id"]` off the
  request), so this is a tenant-scoped update-then-insert rather than an
  upsert on the id: keying the conflict on the id alone let anyone who knew a
  build id reset another athanor's row to "started" and blank its result.
  """
  @spec record_started(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def record_started(%Context{} = ctx, build_id, reference) do
    now = DateTime.utc_now()

    refreshed = [
      reference: reference,
      user_id: ctx.user_id,
      status: "started",
      started_at: now,
      finished_at: nil,
      error: nil,
      result: nil
    ]

    {count, _} =
      BuildRecord
      |> where([b], b.id == ^build_id)
      |> QueryHelpers.where_tenant(ctx)
      |> Arca.Repo.update_all(set: refreshed)

    if count == 1, do: :ok, else: insert_started(ctx, build_id, reference, now)
  end

  defp insert_started(ctx, build_id, reference, now) do
    attrs =
      QueryHelpers.stamp_tenant!(ctx, %{
        id: build_id,
        user_id: ctx.user_id,
        reference: reference,
        status: "started",
        started_at: now
      })

    %BuildRecord{}
    |> BuildRecord.changeset(attrs)
    |> Arca.Repo.insert()
    |> case do
      {:ok, _} ->
        :ok

      # The id is taken and the scoped update above did not find it, so it
      # belongs to another athanor. Same answer every other verb here gives
      # for a foreign id — never "you may not", which would confirm it exists.
      {:error, %Ecto.Changeset{errors: errors}} when errors != [] ->
        if Keyword.has_key?(errors, :id), do: {:error, :not_found}, else: {:error, :invalid}

      {:error, changeset} ->
        {:error, changeset}
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
  Record the post-compile registration outcome onto a finished build's
  result, so `build.status` answers with what actually happened instead
  of the `"pending"` the compile result was born with.

  The registration task is spawned before the async wrapper finalizes
  the row, so a not-yet-"compiled" row is retried briefly rather than
  dropped; a build with no row (sync mode) is a no-op — its caller got
  the outcome inline.
  """
  @spec record_registration(Context.t(), String.t(), String.t()) :: :ok
  def record_registration(ctx, build_id, outcome, attempts \\ 5)

  def record_registration(%Context{} = ctx, build_id, outcome, attempts)
      when is_binary(outcome) and attempts > 0 do
    row =
      BuildRecord
      |> where([b], b.id == ^build_id)
      |> QueryHelpers.where_tenant(ctx)
      |> Arca.Repo.one()

    case row do
      nil ->
        :ok

      %{status: "compiled", result: result} when is_binary(result) ->
        # A stored column, so a bang decode here turns one corrupt row into a
        # crash in whatever process is recording a registration.
        case Cyfr.Json.decode(result) do
          {:ok, decoded} when is_map(decoded) ->
            patched =
              decoded
              |> Map.put("registration", outcome)
              |> Cyfr.Json.safe_encode()

            BuildRecord
            |> where([b], b.id == ^build_id)
            |> QueryHelpers.where_tenant(ctx)
            |> Arca.Repo.update_all(set: [result: patched])

            :ok

          _ ->
            Logger.warning(
              "[Cyfr.BuildRecords] build #{build_id} has an unreadable result column; " <>
                "the registration outcome was not recorded"
            )

            :ok
        end

      _still_running ->
        Process.sleep(400)
        record_registration(ctx, build_id, outcome, attempts - 1)
    end
  end

  def record_registration(_ctx, _build_id, _outcome, _attempts), do: :ok

  @doc """
  Delete every build record past the newest `keep`, ordered by
  `started_at`. `dry_run: true` counts instead of deleting. The
  row-plane retention convention: `{:ok, affected_count}` — or
  `{:error, :database_error}` when the store cannot answer.
  """
  @spec prune(Context.t(), non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def prune(%Context{} = ctx, keep, opts \\ []) when is_integer(keep) and keep >= 0 do
    Arca.Repo.Errors.with_db_rescue("Cyfr.BuildRecords.prune", fn ->
      # Keep the newest rows and recently started builds. Started rows also
      # need an age limit because builds have no lease sweeper. Use a survivor
      # subquery to avoid SQLite’s unsupported bare OFFSET.
      stale_cutoff = DateTime.add(DateTime.utc_now(), -@started_grace_ms, :millisecond)

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
        |> where([b], b.status != "started" or b.started_at < ^stale_cutoff)

      if Keyword.get(opts, :dry_run, false) do
        {:ok, Arca.Repo.aggregate(doomed_query, :count)}
      else
        {count, _} = Arca.Repo.delete_all(doomed_query)
        {:ok, count}
      end
    end)
  end

  defp to_map(%BuildRecord{} = r) do
    %{
      "build_id" => r.id,
      "reference" => r.reference,
      "status" => r.status,
      "started_at" => DateTime.to_iso8601(r.started_at)
    }
    |> Cyfr.MapUtil.put_present(
      "finished_at",
      r.finished_at && DateTime.to_iso8601(r.finished_at)
    )
    |> Cyfr.MapUtil.put_present("error", r.error)
    |> Cyfr.MapUtil.put_present("result", decoded_result(r.result))
  end

  # Serializing a row must not crash on a corrupt column: the listing that
  # would have shown the operator every other build is more useful than a
  # raise about one of them.
  defp decoded_result(nil), do: nil

  defp decoded_result(result) when is_binary(result) do
    case Cyfr.Json.decode(result) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"_unreadable" => true}
    end
  end
end
