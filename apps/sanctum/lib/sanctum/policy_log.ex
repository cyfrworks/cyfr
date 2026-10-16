# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PolicyLog do
  @moduledoc """
  The policy consultation log's rows, read for a surface.

  Each row is one consultation of a policy (`Sanctum.Policy.Enforcement`
  records them): what was asked, the decision and why. The rows are
  security rows, so Sanctum is their one reader (`Arca.PolicyLog`); a
  reader above it takes them from here, and the `policy_log` tool
  (`Sanctum.Providers.PolicyLog`) is the operation table's door to the
  same rows.

  `list/2` reads the caller's athanor's rows and no other. The caller's
  context must hold `:storage_read`, on the external plane, before any row
  is read; the athanor is the context's, whatever the options name, and a
  context with no athanor, a platform administrator's included, is refused
  before any row is read.
  """

  alias Sanctum.Context

  @doc """
  The caller's athanor's policy logs, newest first (`Arca.PolicyLog.list/2`,
  whose filters `opts` carries: `:limit`, `:user_id`, `:request_id`,
  `:execution_id`, `:event_type` and `:with_consent`; an `:athanor_id`
  among them names nothing).

  A context without `:storage_read`, or one on the guest plane, is the
  permission refusal `Sanctum.Context.require_permission/2` answers; a
  context with no athanor is `{:error, :no_athanor}`, whatever its scope.
  Both refuse before any row is read.
  """
  @spec list(Context.t(), keyword()) ::
          {:ok, [map()]}
          | {:error, :no_athanor | :database_error | Sanctum.Unauthorized.reason()}
  def list(%Context{} = ctx, opts) when is_list(opts) do
    with :ok <- Context.require_permission(ctx, :storage_read) do
      Arca.PolicyLog.list(Context.actor(ctx), opts)
    end
  end
end
