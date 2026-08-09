# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TenantScope do
  @moduledoc """
  Single source of truth for deriving the `{scope, org_id, project_id}` tuple
  (and applying the tenant chokepoint) from a `Sanctum.Context`.

  Tenant-scoped stores derive their `{scope, org, project}` tuple here and pass
  their write/read entry points through `Sanctum.Context.require_tenant!/1`;
  one implementation guarantees the chokepoint cannot silently drift between
  callers.
  """

  alias Sanctum.Context

  @doc """
  Returns `{scope_string, org_id, project_id}` for a context, enforcing the
  tenant chokepoint.

  Raises `ArgumentError` for the contradictory `scope: :org, org_id: nil`
  shape, and (via `Context.require_tenant!/1`) `Sanctum.UnauthorizedError` for
  an org-less non-platform context — so an unresolved tenant can never reach a
  tenant-scoped store.
  """
  @spec extract(Context.t()) :: {String.t(), String.t() | nil, String.t()}
  def extract(%Context{scope: :org, org_id: nil}) do
    raise ArgumentError,
          "org_id cannot be nil when scope is :org. " <>
            "Either set an org_id or use scope :project."
  end

  def extract(%Context{scope: scope, org_id: org_id, project_id: project_id} = ctx) do
    Context.require_tenant!(ctx)
    {to_string(scope), org_id, project_id || "default"}
  end
end
