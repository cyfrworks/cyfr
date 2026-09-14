# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Host do
  @moduledoc """
  The seams a running component's host functions cross into the
  platform's consent plane: an in-chain tool call, whether the host runs
  an action itself, and a policy decision recorded.

  A run's admission, its unsealed credentials, its events and its
  terminal row are `Cyfr.Execution`'s (`Admission`, `Attempt`, `Close`).
  Opus also calls CYFR storage, network and utility modules directly;
  `Opus.HostSurfaceTest` keeps that list from growing quietly.
  """

  alias Sanctum.Context

  @doc "An in-chain tool call under a running component's authority."
  @spec tool_call(String.t(), Context.t(), map(), Cyfr.Authority.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defdelegate tool_call(name, ctx, args, authority, opts \\ []),
    to: Cyfr.Ops.Catalog,
    as: :call_in_chain

  @doc "Whether the host, not the catalog, runs `tool.action` for a chain."
  @spec host_intercepted?(String.t(), String.t() | nil) :: boolean()
  defdelegate host_intercepted?(name, action), to: Cyfr.Ops.Catalog

  @doc "Record a policy decision (allowed or denied) for the audit trail."
  @spec enforce(map()) :: :ok
  defdelegate enforce(attrs), to: Sanctum.Policy.Enforcement, as: :record
end
