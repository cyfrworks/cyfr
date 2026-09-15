# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Host do
  @moduledoc """
  The seams a running component's host functions cross into the
  platform's consent plane: an in-chain tool call, and whether the host
  runs an action itself.

  A run's admission is `Cyfr.Execution.Admission`'s; its unsealed
  credentials, its events, its OAuth tokens, its egress rate and denials,
  its storage, its component's artifact, its lease and its terminal row are
  host calls of its attempt (`Opus.HostClient`). Opus also calls CYFR
  network and utility modules directly; `Opus.HostSurfaceTest` keeps that
  list from growing quietly.
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
end
