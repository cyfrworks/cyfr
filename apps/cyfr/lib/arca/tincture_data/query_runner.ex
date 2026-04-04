defmodule Arca.TinctureData.QueryRunner do
  @moduledoc """
  Execute named queries against tincture sandbox databases.

  Handles cache lookup, readonly SQLite execution, and result caching.
  """

  alias Sanctum.Context
  alias Arca.TinctureData.{DB, Schema, QueryCache}

  @default_cache_ttl_ms 30_000

  @doc """
  Execute a named query against a tincture's data.db.

  Checks cache first, then opens a READONLY connection on miss.
  """
  @spec execute(Context.t(), map(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, String.t()}
  def execute(%Context{} = ctx, tincture_record, query_name, query_def, params) do
    publisher = tincture_record.publisher
    tincture_name = tincture_record.name
    params_hash = QueryCache.params_hash(params)

    case QueryCache.get(ctx, publisher, tincture_name, query_name, params_hash) do
      {:ok, cached} ->
        :telemetry.execute(
          [:cyfr, :tincture, :query, :cache_hit],
          %{},
          %{publisher: publisher, tincture: tincture_name, query: query_name}
        )

        {:ok, Map.put(cached, :cached, true)}

      :miss ->
        start_time = System.monotonic_time()
        result = execute_and_cache(ctx, tincture_record, query_name, query_def, params, params_hash)
        duration = System.monotonic_time() - start_time

        meta = %{publisher: publisher, tincture: tincture_name, query: query_name}

        case result do
          {:ok, _} ->
            :telemetry.execute(
              [:cyfr, :tincture, :query, :stop],
              %{duration: duration},
              meta
            )

          {:error, _} ->
            :telemetry.execute(
              [:cyfr, :tincture, :query, :exception],
              %{duration: duration},
              meta
            )
        end

        result
    end
  end

  @doc """
  Invalidate all cached queries for a tincture.
  """
  @spec invalidate_tincture_cache(Context.t(), String.t(), String.t()) :: :ok
  def invalidate_tincture_cache(%Context{} = ctx, publisher, tincture_name) do
    QueryCache.invalidate_tincture(ctx, publisher, tincture_name)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp execute_and_cache(ctx, tincture_record, query_name, query_def, params, params_hash) do
    db_path = DB.db_path(tincture_record.dir)

    with {:ok, _sql, bound_values} <- Schema.prepare_query(query_def, params) do
      positional_sql = query_def.positional_sql

      case DB.with_connection(db_path, :readonly, fn conn ->
             DB.query(conn, positional_sql, bound_values)
           end) do
        {:ok, {:ok, query_result}} ->
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          result = %{
            data: rows_to_maps(query_result.columns, query_result.rows),
            columns: query_result.columns,
            updated_at: now,
            cached: false
          }

          # cache_ttl in manifest is in seconds; convert to milliseconds for Arca.Cache
          raw_ttl = query_def[:cache_ttl]
          ttl = if is_number(raw_ttl) and raw_ttl > 0, do: trunc(raw_ttl) * 1000, else: @default_cache_ttl_ms

          QueryCache.put(
            ctx,
            tincture_record.publisher,
            tincture_record.name,
            query_name,
            params_hash,
            result,
            ttl
          )

          {:ok, result}

        {:ok, {:error, reason}} ->
          {:error, "query execution failed: #{inspect(reason)}"}

        {:error, reason} ->
          {:error, "database connection failed: #{inspect(reason)}"}
      end
    end
  end

  defp rows_to_maps(columns, rows) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new()
    end)
  end
end
