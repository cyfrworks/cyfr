# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ModelCatalog do
  @moduledoc """
  One loader for the model catalogue (`formula:local.list-models`).

  It lived twice — ConversationPaneLive and AquaLive each spelled the ref,
  the spawn, the decode and the timeout — and had drifted: 15s vs 60s
  deadlines, and one copy dropped the `refs` half of the result the other
  read. The caller spawns through `load/2` and handles the one message
  shape `parse/1` produces.
  """

  @list_models_ref "formula:local.list-models"

  # If list-models hangs, the picker settles on the stored model instead
  # of staying empty. One deadline (the longer of the two the pages had —
  # a formula run against several providers legitimately takes a while).
  @timeout_ms 60_000

  @doc "The formula ref, for anything that names it."
  def ref, do: @list_models_ref

  @doc """
  Spawn the catalogue load for the calling LiveView. Sends
  `{:list_models_result, result}` and arms a `{:task_timeout, :models}`
  deadline; when no engine is running there is nothing to load and the
  caller's `:models_loaded` should be set — signalled by `:unavailable`.
  """
  @spec load(Sanctum.Context.t()) :: :ok | :unavailable
  def load(ctx) do
    if Cyfr.Execution.available?() do
      lv = self()
      logger_metadata = Cyfr.LoggerContext.capture()

      Task.Supervisor.start_child(Aqua.TaskSupervisor, fn ->
        Cyfr.LoggerContext.restore(logger_metadata)

        result =
          PrismWeb.MCPHelpers.call_tool(ctx, "execution/run", %{
            "reference" => @list_models_ref,
            "input" => %{}
          })

        send(lv, {:list_models_result, result})
      end)

      Process.send_after(lv, {:task_timeout, :models}, @timeout_ms)
      :ok
    else
      :unavailable
    end
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
end
