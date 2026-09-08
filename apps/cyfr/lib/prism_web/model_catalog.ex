# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ModelCatalog do
  @moduledoc """
  One loader for the model catalogue (`formula:local.list-models`).

  It lived twice — ConversationPaneLive and AquaLive each spelled the ref,
  the spawn, the decode and the timeout — and had drifted: 15s vs 60s
  deadlines, and one copy dropped the `refs` half of the result the other
  read. The caller asks through `load/1` and handles the one message
  shape `parse/1` produces.

  The catalogue is a formula run against every provider the athanor holds
  a key for, and a pane asked for it on every mount — every thread switch.
  So a run's answer is kept per athanor in `Arca.Cache` for a short while
  (`ttl_ms/0`): a hit is delivered to the caller's mailbox at once, with no
  run and no deadline armed, and a key bound or dropped in the meantime is
  seen when the entry lapses or `forget/1` is called.
  """

  @list_models_ref "formula:local.list-models"

  # If list-models hangs, the picker settles on the stored model instead
  # of staying empty. One deadline (the longer of the two the pages had —
  # a formula run against several providers legitimately takes a while).
  @timeout_ms 60_000

  # Short: long enough that switching threads does not run the formula
  # again, short enough that a key bound on the AQUA page shows in the
  # picker within the minute even where nothing calls `forget/1`.
  @ttl_ms :timer.minutes(1)

  @doc "The formula ref, for anything that names it."
  def ref, do: @list_models_ref

  @doc "How long one athanor's catalogue is kept, in milliseconds."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc """
  Load the catalogue for the calling LiveView. Sends
  `{:list_models_result, result}` — at once from the cache, else from a
  supervised run that also arms a `{:task_timeout, :models}` deadline; when
  no engine is running and nothing is cached there is nothing to load and
  the caller's `:models_loaded` should be set — signalled by `:unavailable`.
  """
  @spec load(Sanctum.Context.t()) :: :ok | :unavailable
  def load(%Sanctum.Context{athanor_id: athanor_id} = ctx) when is_binary(athanor_id) do
    case Arca.Cache.get(key(athanor_id)) do
      {:ok, result} ->
        send(self(), {:list_models_result, {:ok, result}})
        :ok

      :miss ->
        if Cyfr.Execution.available?(), do: run(ctx, athanor_id), else: :unavailable
    end
  end

  # No athanor, no catalogue: nothing to run it against and nowhere to keep
  # it — answered here rather than raised inside the task, which would
  # leave the caller waiting out the deadline.
  def load(%Sanctum.Context{}), do: :unavailable

  defp run(ctx, athanor_id) do
    lv = self()
    logger_metadata = Cyfr.LoggerContext.capture()

    Task.Supervisor.start_child(Aqua.TaskSupervisor, fn ->
      Cyfr.LoggerContext.restore(logger_metadata)

      result =
        PrismWeb.Ops.call_tool(ctx, "execution/run", %{
          "reference" => @list_models_ref,
          "input" => %{}
        })

      with {:ok, catalogue} <- result, do: remember(athanor_id, catalogue)
      send(lv, {:list_models_result, result})
    end)

    Process.send_after(lv, {:task_timeout, :models}, @timeout_ms)
    :ok
  end

  @doc "Keep what a run answered for `athanor_id`, as the next `load/1` will read it."
  @spec remember(String.t(), term()) :: :ok
  def remember(athanor_id, catalogue) when is_binary(athanor_id) do
    Arca.Cache.put(key(athanor_id), catalogue, @ttl_ms)
    :ok
  end

  @doc "Drop the kept catalogue — a key was bound or removed; the next `load/1` runs."
  @spec forget(String.t()) :: :ok
  def forget(athanor_id) when is_binary(athanor_id) do
    Arca.Cache.invalidate(key(athanor_id))
    :ok
  end

  @doc """
  Decode a `{:list_models_result, {:ok, result}}` payload into
  `%{models: %{provider => [model]}, refs: %{}}` — both halves, so a page
  cannot silently drop one again.
  """
  @spec parse(term()) :: %{models: map(), refs: map()}
  def parse(result) do
    raw = result[:result] || result

    decoded =
      cond do
        is_binary(raw) ->
          case Jason.decode(raw) do
            {:ok, m} -> m
            _ -> %{}
          end

        is_map(raw) ->
          raw

        true ->
          %{}
      end

    models =
      (decoded["models"] || %{})
      |> Map.new(fn {provider, value} ->
        {provider, PrismWeb.AquaLive.Catalog.normalize_provider_models(value)}
      end)

    %{models: models, refs: decoded["refs"] || %{}}
  end

  # Spelled here rather than in `Arca.Cache.Keys`: the entry is the
  # console's own read-through, nothing else reads or sweeps it by shape.
  defp key(athanor_id), do: {:model_catalog, athanor_id}
end
