# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire do
  @moduledoc """
  The gate's root facade: the one way into the operation table from
  outside Grimoire.

  Two entries dispatch, one per plane — `call_external/4` for a person,
  a key or the console, `call_in_chain/5` for a running chain under its
  authority — and every refusal either makes before a handler runs is a
  `%Prima.Refusal{stage: :admission}`. The rest reads the table this
  member wrote at boot (`Grimoire.Catalog.load!/0`) or cancels a call the
  gate is running. `Grimoire.Catalog` is the implementation: outside
  Grimoire only the composition root names it, to load its table and
  install it as consent's port.
  """

  alias Grimoire.{Catalog, RunningTasks}

  @doc "Call a tool from the external plane (`Grimoire.Catalog.call_external/4`)."
  @spec call_external(String.t(), Sanctum.Context.t(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defdelegate call_external(name, ctx, args, opts \\ []), to: Catalog

  @doc "Call a tool from inside a running chain (`Grimoire.Catalog.call_in_chain/5`)."
  @spec call_in_chain(String.t(), Sanctum.Context.t(), term(), Prima.Authority.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defdelegate call_in_chain(name, ctx, args, authority, opts \\ []), to: Catalog

  @doc "A tool's provider and its declarations: `{:ok, {module, tool}}` or `:miss`."
  @spec lookup(String.t()) :: {:ok, {module(), map()}} | :miss
  defdelegate lookup(name), to: Catalog

  @doc "A tool's wire definition, as `tools/list` serves it."
  @spec get_tool(String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_tool(name), to: Catalog

  @doc "A wire tool definition narrowed to `actions`."
  @spec restrict_tool(map(), [String.t()]) :: map()
  defdelegate restrict_tool(tool_def, actions), to: Catalog

  @doc "Every tool the table holds, as `tools/list` serves it, sorted by name."
  @spec list_tools() :: [map()]
  defdelegate list_tools(), to: Catalog

  @doc "Whether a running chain can run `tool.action`, through the table or the host."
  @spec chain_reachable?(String.t(), String.t() | nil) :: boolean()
  defdelegate chain_reachable?(name, action), to: Catalog

  @doc "Whether the table knows `tool.action` and refuses it to every chain."
  @spec in_chain_refused?(String.t(), String.t() | nil) :: boolean()
  defdelegate in_chain_refused?(name, action), to: Catalog

  @doc "Whether the host, not the table, runs `tool.action` for a chain."
  @spec host_intercepted?(String.t(), String.t() | nil) :: boolean()
  defdelegate host_intercepted?(name, action), to: Catalog

  @doc "Every `tool.action` annotated `host: :intercepted`, sorted."
  @spec host_intercepted_actions() :: [String.t()]
  defdelegate host_intercepted_actions(), to: Catalog

  @doc "Every provider named in `config :cyfr, :tool_providers`, loaded or not."
  @spec configured_providers() :: [module()]
  defdelegate configured_providers(), to: Catalog

  @doc "The operation table: tool name → `{provider, tool}`."
  @spec operations() :: %{String.t() => {module(), map()}}
  defdelegate operations(), to: Catalog

  @doc "The resource index (`Grimoire.Resources`)."
  @spec resources() :: Grimoire.Resources.table()
  defdelegate resources(), to: Grimoire.Resources, as: :table

  @doc "Stop the supervised handler of the call named by `handle`, started or not."
  @spec cancel_call(term()) :: :ok
  defdelegate cancel_call(handle), to: RunningTasks, as: :cancel_handle

  @doc "Forget a call's cancellation handle once its caller is done with it."
  @spec release_call(term()) :: :ok
  defdelegate release_call(handle), to: RunningTasks, as: :release_handle

  @doc "Stop the supervised call running under an ingress request id."
  @spec cancel_request(String.t()) :: :ok | {:error, :not_found}
  defdelegate cancel_request(request_id), to: RunningTasks, as: :cancel
end
