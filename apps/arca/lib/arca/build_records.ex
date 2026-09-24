# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.BuildRecords do
  @moduledoc """
  One `build_records` row per build (`Arca.Schemas.BuildRecord`), from
  `started` through `compiled` or `failed`. `Compendium.Builds` writes
  them and `Arca.Retention.Builds` prunes them — two writers, one owner of the
  shape both rely on.

  Build status is stored in rows. WASM and tincture artifacts remain
  blobs under the athanor's `components/` tree.

  Every function takes the actor first and works on that actor's
  athanor; an actor carrying none is `{:error, :no_athanor}` before any
  query, and a `%Sanctum.Context{}` or a bare athanor id matches no head
  at all. A row belonging to another athanor reads exactly like a row
  that is not there — `{:error, :not_found}` — so a build id learned
  elsewhere confirms nothing.

  A read answers `{:ok, map}` with the row's fields under string keys and
  the `result` column decoded; `{:error, :not_found}` when the athanor has
  no such row; and `{:error, :database_error}` when the store could not
  answer. The three stay apart: an absent row is not an outage.
  """

  import Ecto.Query

  require Logger

  alias Arca.Schemas.BuildRecord

  # How long a row may read "started" before retention treats it as
  # orphaned rather than in flight. Far beyond any live build: a build's
  # budget is 270 s (`Compendium.Builds`) under the MCP layer's 5-minute
  # brutal kill, so an hour can only mean the writer went away (node
  # restart, dropped task) and no `record_finished/4` is coming.
  @started_grace_ms :timer.hours(1)

  # How long a registration outcome waits for the build's own finish to
  # land, and how often it looks.
  @registration_attempts 5
  @registration_wait_ms 400

  @type refusal :: {:error, :no_athanor | :database_error}

  @doc """
  Record a build as started. Overwrites the actor's own stale row with the
  same id; a row belonging to another athanor is `{:error, :not_found}`.

  `build_id` is caller-supplied (`Compendium.Builds` takes it from the
  request's `build_id`), so this is a tenant-scoped update-then-insert
  rather than an upsert on the id: keying the conflict on the id alone let
  anyone who knew a build id reset another athanor's row to "started" and
  blank its result.
  """
  @spec record_started(Prima.Actor.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :invalid | {:invalid, map()}} | refusal()
  def record_started(%Prima.Actor{athanor_id: athanor_id} = actor, build_id, reference)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(build_id) and
             is_binary(reference) do
    Arca.Repo.Errors.with_db_rescue("Arca.BuildRecords.record_started", fn ->
      start_row(athanor_id, actor.user_id, build_id, reference, DateTime.utc_now())
    end)
    |> Arca.Data.project()
  end

  def record_started(%Prima.Actor{}, _build_id, _reference), do: {:error, :no_athanor}

  # arca:db-raise-ok the public entry that wraps it rescues.
  defp start_row(athanor_id, user_id, build_id, reference, now) do
    refreshed = [
      reference: reference,
      user_id: user_id,
      status: "started",
      started_at: now,
      finished_at: nil,
      error: nil,
      result: nil
    ]

    {count, _} =
      BuildRecord
      |> where([b], b.id == ^build_id and b.athanor_id == ^athanor_id)
      |> Arca.Repo.update_all(set: refreshed)

    if count == 1,
      do: :ok,
      else: insert_started(athanor_id, user_id, build_id, reference, now)
  end

  # arca:db-raise-ok the public entry that wraps it rescues.
  defp insert_started(athanor_id, user_id, build_id, reference, now) do
    attrs = %{
      id: build_id,
      athanor_id: athanor_id,
      user_id: user_id,
      reference: reference,
      status: "started",
      started_at: now
    }

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
  @spec record_finished(Prima.Actor.t(), String.t(), String.t(), map() | String.t()) ::
          :ok | {:error, :not_found} | refusal()
  def record_finished(%Prima.Actor{athanor_id: athanor_id}, build_id, status, outcome)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(build_id) and
             status in ["compiled", "failed"] do
    Arca.Repo.Errors.with_db_rescue("Arca.BuildRecords.record_finished", fn ->
      updates =
        case status do
          "compiled" -> [result: Jason.encode!(outcome)]
          "failed" -> [error: outcome]
        end ++ [status: status, finished_at: DateTime.utc_now()]

      {count, _} =
        BuildRecord
        |> where([b], b.id == ^build_id and b.athanor_id == ^athanor_id)
        |> Arca.Repo.update_all(set: updates)

      if count == 1, do: :ok, else: {:error, :not_found}
    end)
    |> Arca.Data.project()
  end

  def record_finished(%Prima.Actor{}, _build_id, status, _outcome)
      when status in ["compiled", "failed"],
      do: {:error, :no_athanor}

  @doc """
  One build's record as a plain map: the row's fields under string keys,
  with the stored `result` column decoded and the columns it has nothing
  in left out.
  """
  @spec get(Prima.Actor.t(), String.t()) :: {:ok, map()} | {:error, :not_found} | refusal()
  def get(%Prima.Actor{athanor_id: athanor_id}, build_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(build_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.BuildRecords.get", fn ->
      case row(athanor_id, build_id) do
        nil -> {:error, :not_found}
        record -> {:ok, to_map(record)}
      end
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _build_id), do: {:error, :no_athanor}

  @doc """
  Record the post-compile registration outcome onto a finished build's
  result, so `build.status` answers with what actually happened instead
  of the `"pending"` the compile result was born with.

  Two tasks of one build write this row: the registration task is spawned
  before the async wrapper finalizes the row, so a not-yet-"compiled" row
  is retried briefly rather than dropped. A build with no row (sync mode)
  is a no-op — its caller got the outcome inline.
  """
  @spec record_registration(Prima.Actor.t(), String.t(), String.t(), non_neg_integer()) ::
          :ok | refusal()
  def record_registration(actor, build_id, outcome, attempts \\ @registration_attempts)

  def record_registration(%Prima.Actor{athanor_id: athanor_id}, build_id, outcome, attempts)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(build_id) and
             is_binary(outcome) and attempts > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.BuildRecords.record_registration", fn ->
      patch_registration(athanor_id, build_id, outcome, attempts)
    end)
    |> Arca.Data.project()
  end

  def record_registration(%Prima.Actor{athanor_id: athanor_id}, _build_id, _outcome, _attempts)
      when is_binary(athanor_id) and athanor_id != "",
      do: :ok

  def record_registration(%Prima.Actor{}, _build_id, _outcome, _attempts),
    do: {:error, :no_athanor}

  # arca:db-raise-ok the public entry that wraps it rescues.
  defp patch_registration(athanor_id, build_id, outcome, attempts) do
    case row(athanor_id, build_id) do
      nil ->
        :ok

      %{status: "compiled", result: result} when is_binary(result) ->
        # A stored column, so a bang decode here turns one corrupt row into a
        # crash in whatever process is recording a registration.
        case Prima.Json.decode(result) do
          {:ok, decoded} when is_map(decoded) ->
            patched =
              decoded
              |> Map.put("registration", outcome)
              |> Prima.Json.safe_encode()

            BuildRecord
            |> where([b], b.id == ^build_id and b.athanor_id == ^athanor_id)
            |> Arca.Repo.update_all(set: [result: patched])

            :ok

          _ ->
            Logger.warning(
              "[Arca.BuildRecords] build #{build_id} has an unreadable result column; " <>
                "the registration outcome was not recorded"
            )

            :ok
        end

      _still_running ->
        if attempts > 1 do
          Process.sleep(@registration_wait_ms)
          patch_registration(athanor_id, build_id, outcome, attempts - 1)
        else
          :ok
        end
    end
  end

  @doc """
  Delete every build record past the newest `keep`, ordered by
  `started_at`. `dry_run: true` counts instead of deleting. The
  row-plane retention convention: `{:ok, affected_count}` — or
  `{:error, :database_error}` when the store cannot answer.
  """
  @spec prune(Prima.Actor.t(), non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | refusal()
  def prune(actor, keep, opts \\ [])

  def prune(%Prima.Actor{athanor_id: athanor_id}, keep, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_integer(keep) and keep >= 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.BuildRecords.prune", fn ->
      # Keep the newest rows and recently started builds. Started rows also
      # need an age limit because builds have no lease sweeper. Use a survivor
      # subquery to avoid SQLite's unsupported bare OFFSET.
      stale_cutoff = DateTime.add(DateTime.utc_now(), -@started_grace_ms, :millisecond)

      keepers =
        BuildRecord
        |> where([b], b.athanor_id == ^athanor_id)
        |> order_by([b], desc: b.started_at)
        |> limit(^keep)
        |> select([b], b.id)

      doomed_query =
        BuildRecord
        |> where([b], b.athanor_id == ^athanor_id)
        |> where([b], b.id not in subquery(keepers))
        |> where([b], b.status != "started" or b.started_at < ^stale_cutoff)

      if Keyword.get(opts, :dry_run, false) do
        {:ok, Arca.Repo.aggregate(doomed_query, :count)}
      else
        {count, _} = Arca.Repo.delete_all(doomed_query)
        {:ok, count}
      end
    end)
    |> Arca.Data.project()
  end

  def prune(%Prima.Actor{}, keep, _opts) when is_integer(keep) and keep >= 0,
    do: {:error, :no_athanor}

  # arca:db-raise-ok the public entry that wraps it rescues.
  defp row(athanor_id, build_id) do
    BuildRecord
    |> where([b], b.id == ^build_id and b.athanor_id == ^athanor_id)
    |> Arca.Repo.one()
  end

  defp to_map(%BuildRecord{} = r) do
    %{
      "build_id" => r.id,
      "reference" => r.reference,
      "status" => r.status,
      "started_at" => DateTime.to_iso8601(r.started_at)
    }
    |> Prima.MapUtil.put_present(
      "finished_at",
      r.finished_at && DateTime.to_iso8601(r.finished_at)
    )
    |> Prima.MapUtil.put_present("error", r.error)
    |> Prima.MapUtil.put_present("result", decoded_result(r.result))
  end

  # Serializing a row must not crash on a corrupt column: the listing that
  # would have shown the operator every other build is more useful than a
  # raise about one of them.
  defp decoded_result(nil), do: nil

  defp decoded_result(result) when is_binary(result) do
    case Prima.Json.decode(result) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"_unreadable" => true}
    end
  end
end
