# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ModelCatalog do
  @moduledoc """
  One loader for the model catalogue the pickers show.

  Callers use `load/1` to request models and `parse/1` to decode the
  resulting message.

  The catalogue is `Aqua.models/1`: every installed catalyst
  that speaks `model/chat@1`, asked for its models with the key the
  athanor bound on it. A pane asks for it on every mount — every thread
  switch — so a run's answer is kept per athanor in `Arca.Cache` for a
  short while (`ttl_ms/0`): a hit is delivered to the caller's mailbox at
  once, with no run and no deadline armed, and a key bound or dropped in
  the meantime is seen when the entry lapses or `forget/1` is called. A
  run that began before a `forget/1` does not keep what it lists.
  """

  # If a provider hangs, the picker settles on the stored model instead
  # of staying empty. One deadline for the whole listing.
  @timeout_ms 60_000

  # Short: long enough that switching threads does not run the listing
  # again, short enough that a key bound on the Aqua page shows in the
  # picker within the minute even where nothing calls `forget/1`.
  @ttl_ms :timer.minutes(1)

  # How long a forget is remembered: longer than any run of the listing
  # that began before it can still be out.
  @forgotten_ms :timer.minutes(30)

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
  `CyfrWeb.ContextGuard.deliver/3`, so a catalogue read for one athanor is
  never shown under another.

  A caller that may have two loads out at once passes `ask`, its own
  number for this one, and is sent `{:list_models_result, tag, ask,
  result}`: the answers arrive in any order, and the number says which
  was asked last.
  """
  @spec load(Sanctum.Context.t(), term()) :: :ok | :unavailable
  def load(ctx, ask \\ nil)

  def load(%Sanctum.Context{athanor_id: athanor_id} = ctx, ask) when is_binary(athanor_id) do
    tag = CyfrWeb.ContextGuard.capture(ctx)

    case Arca.Cache.get(key(athanor_id)) do
      {:ok, result} ->
        send(self(), answer(tag, ask, {:ok, result}))
        :ok

      :miss ->
        if Opus.available?(), do: run(ctx, athanor_id, tag, ask), else: :unavailable
    end
  end

  # No athanor, no catalogue: nothing to run it against and nowhere to keep
  # it — answered here rather than raised inside the task, which would
  # leave the caller waiting out the deadline.
  def load(%Sanctum.Context{}, _ask), do: :unavailable

  defp answer(tag, nil, result), do: {:list_models_result, tag, result}
  defp answer(tag, ask, result), do: {:list_models_result, tag, ask, result}

  defp run(ctx, athanor_id, tag, ask) do
    lv = self()
    logger_metadata = Prima.LoggerContext.capture()
    began = began(athanor_id)

    Task.Supervisor.start_child(Prism.TaskSupervisor, fn ->
      Prima.LoggerContext.restore(logger_metadata)
      result = Aqua.models(ctx)
      with {:ok, catalogue} <- result, do: remember(athanor_id, catalogue, began)
      send(lv, answer(tag, ask, result))
    end)

    Process.send_after(lv, {:task_timeout, :models}, @timeout_ms)
    :ok
  end

  @doc """
  What a run takes as it begins, for `remember/3`: the mark of the last
  `forget/1` of `athanor_id`.
  """
  @spec began(String.t()) :: term()
  def began(athanor_id) when is_binary(athanor_id), do: Arca.Cache.get(forgotten(athanor_id))

  @doc """
  Keep what a run answered for `athanor_id`, as the next `load/1` will
  read it. With `began` (`began/1`, taken as the run began), it is kept
  only when no `forget/1` came since: a key bound or replaced while the
  run was out makes its listing the old key's.
  """
  @spec remember(String.t(), term()) :: :ok
  def remember(athanor_id, catalogue) when is_binary(athanor_id) do
    Arca.Cache.put(key(athanor_id), catalogue, @ttl_ms)
    :ok
  end

  @spec remember(String.t(), term(), term()) :: :ok
  def remember(athanor_id, catalogue, began) when is_binary(athanor_id) do
    if began(athanor_id) == began, do: remember(athanor_id, catalogue), else: :ok
  end

  @doc """
  Drop the kept catalogue — a key was bound, replaced or removed; the next
  `load/1` runs, and a run already out does not keep what it lists
  (`remember/3`).
  """
  @spec forget(String.t()) :: :ok
  def forget(athanor_id) when is_binary(athanor_id) do
    Arca.Cache.put(forgotten(athanor_id), System.unique_integer([:monotonic]), @forgotten_ms)
    Arca.Cache.invalidate(key(athanor_id))
    :ok
  end

  @doc """
  Decode a `{:list_models_result, tag, {:ok, result}}` payload into
  `%{models: %{provider => [model_id]}, refs: %{provider => ref}, errors:
  %{provider => sentence}, refused: %{provider => sentence}}` — every
  part, so a page cannot silently drop one again. `refused` is what a
  provider that refused the key said, and `errors` what any other that
  listed no models said instead.
  """
  @spec parse(term()) :: %{models: map(), refs: map(), errors: map(), refused: map()}
  def parse(result) when is_map(result) do
    models =
      (result["models"] || %{})
      |> Enum.filter(fn {_provider, ids} -> is_list(ids) end)
      |> Map.new(fn {provider, ids} -> {provider, Enum.filter(ids, &is_binary/1)} end)

    %{
      models: models,
      refs: result["refs"] || %{},
      errors: sentences(result["errors"]),
      refused: sentences(result["refused"])
    }
  end

  def parse(_), do: %{models: %{}, refs: %{}, errors: %{}, refused: %{}}

  defp sentences(by_provider) do
    (by_provider || %{})
    |> Enum.filter(fn {_provider, sentence} -> is_binary(sentence) end)
    |> Map.new()
  end

  # Spelled here rather than in `Arca.Cache.Keys`: the entry is the
  # console's own read-through, nothing else reads or sweeps it by shape.
  defp key(athanor_id), do: {:model_catalog, athanor_id}
  defp forgotten(athanor_id), do: {:model_catalog_forgotten, athanor_id}
end
