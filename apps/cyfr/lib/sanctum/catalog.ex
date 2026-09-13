# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Catalog do
  @moduledoc """
  The operation catalog as consent sees it.

  A consent shape may only name `tool.action` pairs this server can serve,
  so shape derivation asks the catalog which those are. A grant on an
  external tool server may only name a server the catalog proxies, so a
  plan and a commit ask it which servers those are and what each exposes.
  Both ask through this port rather than the catalog module directly: the
  contract is written here, in the domain that depends on it, and the one
  implementation (`Cyfr.Ops.Catalog`) answers for every provider it has
  loaded. A provider that cannot load is a boot failure there, never a
  narrower answer here — a digest derived from a partial catalog would
  read as the whole.
  """

  alias Sanctum.Context

  @typedoc """
  An external tool server as a grant may name it: its `name`, the
  `server_digest` a grant binds to (`nil` when its configuration cannot be
  digested), the `tool_patterns` the operator exposes and, when the server
  answered, the `tool_names` matched and a `descriptions_digest` over
  their descriptions.
  """
  @type tool_server_candidate :: %{
          required(:name) => String.t(),
          required(:server_digest) => String.t() | nil,
          required(:tool_patterns) => [String.t()],
          optional(atom()) => term()
        }

  @doc "Every `tool.action` the catalog serves, from its loaded providers."
  @callback tool_actions() :: [String.t()]

  @doc "Whether every configured provider loaded, or which did not."
  @callback providers_loaded() :: :ok | {:error, [module()]}

  @doc """
  The external tool servers of the caller's athanor, each as a candidate.
  A server that cannot be reached is still one, with no matched tool
  names: a grant is on its configured patterns, not on what it happens to
  expose at the moment.
  """
  @callback tool_server_candidates(Context.t()) :: [tool_server_candidate()]

  @doc "One external tool server by name, as a candidate, or why not."
  @callback tool_server_candidate(Context.t(), String.t()) ::
              {:ok, tool_server_candidate()} | {:error, term()}

  @doc "The implementation: `Cyfr.Ops.Catalog`, swappable for a test."
  @spec impl() :: module()
  def impl, do: Application.get_env(:cyfr, :catalog, Cyfr.Ops.Catalog)

  @spec tool_actions() :: [String.t()]
  def tool_actions, do: impl().tool_actions()

  @spec tool_server_candidates(Context.t()) :: [tool_server_candidate()]
  def tool_server_candidates(%Context{} = ctx), do: impl().tool_server_candidates(ctx)

  @spec tool_server_candidate(Context.t(), String.t()) ::
          {:ok, tool_server_candidate()} | {:error, term()}
  def tool_server_candidate(%Context{} = ctx, name) when is_binary(name),
    do: impl().tool_server_candidate(ctx, name)
end
