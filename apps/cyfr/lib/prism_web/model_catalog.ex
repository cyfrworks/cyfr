# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ModelCatalog do
  @moduledoc """
  One loader for the model catalogue the pickers show.

  Callers use `load/1` to request models and `parse/1` to decode the
  resulting message.

  The catalogue is `Aqua.models/1`: every installed catalyst
  that speaks `model/chat@1`, asked for its models with the key the
  estate bound on it. A pane asks for it on every mount — every thread
  switch — so a run's answer is kept per athanor in `Arca.Cache` for a
  short while (`ttl_ms/0`): a hit is delivered to the caller's mailbox at
  once, with no run and no deadline armed, and a key bound or dropped in
  the meantime is seen when the entry lapses or `forget/1` is called.
  """

  # If a provider hangs, the picker settles on the stored model instead
  # of staying empty. One deadline for the whole listing.
  @timeout_ms 60_000

  # Short: long enough that switching threads does not run the listing
  # again, short enough that a key bound on the AQUA page shows in the
  # picker within the minute even where nothing calls `forget/1`.
  @ttl_ms :timer.minutes(1)

  @doc "How long one athanor's catalogue is kept, in milliseconds."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc """
  Load the catalogue for the calling LiveView. Sends
  `{:list_models_result, tag, result}` — at once from the cache, else from
  a supervised run that also arms a `{:task_timeout, :models}` deadline;
  when no engine is running and nothing is cached there is nothing to load
  and the caller's `:models_loaded` should be set — signalled by
  `:unavailable`. `tag` is the focus the catalogue was read for
  (`CyfrWeb.ContextGuard.capture/1`); the caller takes the result through
  `CyfrWeb.ContextGuard.deliver/3`, so a catalogue read for one estate is
  never shown under another.
  """
  @spec load(Sanctum.Context.t()) :: :ok | :unavailable
  def load(%Sanctum.Context{athanor_id: athanor_id} = ctx) when is_binary(athanor_id) do
    tag = CyfrWeb.ContextGuard.capture(ctx)

    case Arca.Cache.get(key(athanor_id)) do
      {:ok, result} ->
        send(self(), {:list_models_result, tag, {:ok, result}})
        :ok

      :miss ->
        if Crucible.available?(), do: run(ctx, athanor_id, tag), else: :unavailable
    end
  end

  # No athanor, no catalogue: nothing to run it against and nowhere to keep
  # it — answered here rather than raised inside the task, which would
  # leave the caller waiting out the deadline.
  def load(%Sanctum.Context{}), do: :unavailable

  defp run(ctx, athanor_id, tag) do
    lv = self()
    logger_metadata = Prima.LoggerContext.capture()

    Task.Supervisor.start_child(Aqua.TaskSupervisor, fn ->
      Prima.LoggerContext.restore(logger_metadata)
      result = Aqua.models(ctx)
      with {:ok, catalogue} <- result, do: remember(athanor_id, catalogue)
      send(lv, {:list_models_result, tag, result})
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
  Decode a `{:list_models_result, tag, {:ok, result}}` payload into
  `%{models: %{provider => [model_id]}, refs: %{provider => ref}}` — both
  halves, so a page cannot silently drop one again.
  """
  @spec parse(term()) :: %{models: map(), refs: map()}
  def parse(result) when is_map(result) do
    models =
      (result["models"] || %{})
      |> Enum.filter(fn {_provider, ids} -> is_list(ids) end)
      |> Map.new(fn {provider, ids} -> {provider, Enum.filter(ids, &is_binary/1)} end)

    %{models: models, refs: result["refs"] || %{}}
  end

  def parse(_), do: %{models: %{}, refs: %{}}

  # Spelled here rather than in `Arca.Cache.Keys`: the entry is the
  # console's own read-through, nothing else reads or sweeps it by shape.
  defp key(athanor_id), do: {:model_catalog, athanor_id}
end
