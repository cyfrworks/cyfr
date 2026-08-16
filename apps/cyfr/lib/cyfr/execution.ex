# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution do
  @moduledoc """
  The execution port: how cyfr asks for a component to run, follows its
  events, and stops it — without a compile-time path into the engine.

  The engine (`Opus`) registers itself as the implementation when it starts
  (`config :cyfr, :execution_impl`); a build without it — a headless control
  plane, a test that stubs the engine — answers `available?/0` false and
  every call `{:error, :execution_unavailable}`. The functions mirror the
  engine's public surface one to one so the seam is a name, not a
  translation; a worker split changes the implementation, not the callers.
  """

  alias Sanctum.Context

  @type impl :: module()

  @callback run_root(Context.t(), term(), String.t(), map(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback run_root_edge(Context.t(), String.t(), String.t(), map(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback authority_for(Context.t(), term(), String.t(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback subscribe_events(String.t(), Context.t()) :: :ok | {:error, term()}
  @callback unsubscribe_events(String.t(), Context.t()) :: :ok | {:error, term()}
  @callback events_since(String.t(), non_neg_integer(), String.t()) :: [map()]
  @callback cancel(Context.t(), String.t()) :: :ok | {:error, term()}
  @callback cancel_for_restart(Context.t(), String.t(), map()) :: :ok | {:error, term()}
  @callback get(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback list(Context.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback ready?() :: boolean()

  @doc "The registered engine module, or nil when none has started."
  @spec impl() :: impl() | nil
  def impl, do: Application.get_env(:cyfr, :execution_impl)

  @doc "Whether an engine is registered and ready to admit work."
  @spec available?() :: boolean()
  def available? do
    case impl() do
      nil -> false
      mod -> mod.ready?()
    end
  end

  @spec run_root(Context.t(), term(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_root(ctx, profile_selector, reference, input, opts \\ []),
    do: call(:run_root, [ctx, profile_selector, reference, input, opts])

  @spec run_root_edge(Context.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_root_edge(ctx, source_ref, reference, input, opts \\ []),
    do: call(:run_root_edge, [ctx, source_ref, reference, input, opts])

  @spec authority_for(Context.t(), term(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def authority_for(ctx, profile_selector, reference, opts \\ []),
    do: call(:authority_for, [ctx, profile_selector, reference, opts])

  @spec subscribe_events(String.t(), Context.t()) :: :ok | {:error, term()}
  def subscribe_events(execution_id, ctx), do: call(:subscribe_events, [execution_id, ctx])

  @spec unsubscribe_events(String.t(), Context.t()) :: :ok | {:error, term()}
  def unsubscribe_events(execution_id, ctx), do: call(:unsubscribe_events, [execution_id, ctx])

  @spec events_since(String.t(), non_neg_integer(), String.t()) :: [map()]
  def events_since(execution_id, last_sequence, athanor_id) do
    case call(:events_since, [execution_id, last_sequence, athanor_id]) do
      {:error, :execution_unavailable} -> []
      events -> events
    end
  end

  @spec cancel(Context.t(), String.t()) :: :ok | {:error, term()}
  def cancel(ctx, execution_id), do: call(:cancel, [ctx, execution_id])

  @spec cancel_for_restart(Context.t(), String.t(), map()) :: :ok | {:error, term()}
  def cancel_for_restart(ctx, execution_id, payload),
    do: call(:cancel_for_restart, [ctx, execution_id, payload])

  @spec get(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(ctx, execution_id), do: call(:get, [ctx, execution_id])

  @spec list(Context.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(ctx, opts \\ []), do: call(:list, [ctx, opts])

  defp call(fun, args) do
    case impl() do
      nil -> {:error, :execution_unavailable}
      mod -> apply(mod, fun, args)
    end
  end
end
