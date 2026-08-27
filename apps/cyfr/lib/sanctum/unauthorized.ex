# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Unauthorized do
  @moduledoc """
  The authorization-refusal vocabulary and its one prose renderer.

  `Sanctum.Context.authorize/3`, the permission gates, the tool dispatch
  gates and `Sanctum.TenantPolicy.verify/2` refuse with `{:error, reason}`
  where `reason` is a term from this vocabulary — data a caller can branch
  on (`Sanctum.TinctureAccess` turns it into 403-vs-404, the MCP router
  into a JSON-RPC auth code). Prose is a rendering concern: the boundary
  that answers a human or a wire calls `message/2`. English used to be the
  contract itself — one consumer matched on the `"Unauthorized"` prefix —
  so rewording a refusal could silently turn a 403 into a 404.
  """

  @type reason ::
          :unauthenticated
          | :missing_tenant
          | :tenant_mismatch
          | :malformed_record
          | :untagged_tenant_resource
          | :platform_admin_required
          | {:missing_permission, atom()}
          | {:guest_plane, atom()}
          | {:guest_plane_call, String.t()}
          | {:tool_auth_required, String.t()}
          | {:malformed_resource, :execution | :tenant}

  @doc """
  Whether a term is a refusal from this vocabulary. Dispatchers use it to
  tell an authorization refusal apart from a tool's own error value.
  """
  @spec reason?(term()) :: boolean()
  def reason?(reason)

  def reason?(atom)
      when atom in [
             :unauthenticated,
             :missing_tenant,
             :tenant_mismatch,
             :malformed_record,
             :untagged_tenant_resource,
             :platform_admin_required
           ],
      do: true

  def reason?({:missing_permission, p}) when is_atom(p), do: true
  def reason?({:guest_plane, p}) when is_atom(p), do: true
  def reason?({:guest_plane_call, n}) when is_binary(n), do: true
  def reason?({:tool_auth_required, n}) when is_binary(n), do: true
  def reason?({:malformed_resource, tag}) when tag in [:execution, :tenant], do: true
  def reason?(_), do: false

  @doc """
  The JSON-RPC error-code atom a refusal maps to (`Emissary.MCP.Message`'s
  tables): absent or refused identity is `:auth_required`, everything else
  `:insufficient_permissions`.
  """
  @spec code(reason()) :: :auth_required | :insufficient_permissions
  def code(:unauthenticated), do: :auth_required
  def code({:tool_auth_required, _}), do: :auth_required
  def code(_reason), do: :insufficient_permissions

  @doc """
  Render a refusal as the sentence a person (or a log line) reads.

  `auth_method` is the caller's — an API key's missing permission carries
  the recreate-with-scope hint, since the key's scopes are the one thing
  its holder can change.
  """
  @spec message(reason(), atom() | nil) :: String.t()
  def message(reason, auth_method \\ nil)

  def message(:unauthenticated, _), do: "Unauthorized: authentication required"

  def message(:missing_tenant, _), do: "Unauthorized: a resolved athanor_id is required"

  def message(:tenant_mismatch, _), do: "Unauthorized: tenant mismatch"

  def message(:malformed_record, _), do: "Unauthorized: malformed record (no athanor)"

  def message(:untagged_tenant_resource, _) do
    "Unauthorized: a tenant-bearing resource must be passed tagged " <>
      "({:execution, record} or {:tenant, record})"
  end

  def message(:platform_admin_required, _), do: "Unauthorized: platform admin required"

  def message({:missing_permission, permission}, :api_key) do
    "Unauthorized: missing required permission '#{permission}' " <>
      "(API key does not include this scope — recreate with --scope #{permission})"
  end

  def message({:missing_permission, permission}, _) do
    "Unauthorized: missing required permission '#{permission}'"
  end

  def message({:guest_plane, permission}, _) do
    "Unauthorized: guest-plane context cannot authorize '#{permission}' " <>
      "(external plane required)"
  end

  def message({:guest_plane_call, name}, _) do
    "Unauthorized: guest-plane context cannot make external-plane call to '#{name}'"
  end

  def message({:tool_auth_required, name}, _) do
    "Unauthorized: tool '#{name}' requires authentication"
  end

  def message({:malformed_resource, tag}, _) do
    "Unauthorized: malformed #{tag} resource (missing tenant/owner identity)"
  end
end
