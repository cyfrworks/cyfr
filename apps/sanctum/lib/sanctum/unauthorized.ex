# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Unauthorized do
  @moduledoc """
  The authorization-refusal vocabulary: each reason's refusal class and
  its public sentence.

  Authorization gates return typed `{:error, reason}` values. `class/1`
  places each reason in `Prima.Refusal`'s classes, which decide status and
  code at every surface; `message/2` is the sentence a person reads. This
  vocabulary classifies its own reasons — `Grimoire.Error.classify/1`
  tries it before `Prima.Refusal`'s table, which does not know it.
  """

  @type reason ::
          :unauthenticated
          | :missing_tenant
          | :tenant_mismatch
          | :malformed_record
          | :untagged_tenant_resource
          | :platform_admin_required
          | {:missing_tenant, :no_membership}
          | {:missing_permission, atom()}
          | {:guest_plane, atom()}
          | {:guest_plane_call, String.t()}
          | {:tool_auth_required, String.t()}
          | {:malformed_resource, :execution | :tenant}
          | {:consent_class_required, term()}
          | {:authorization_required, String.t()}

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

  def reason?({:missing_tenant, :no_membership}), do: true
  def reason?({:missing_permission, p}) when is_atom(p), do: true
  def reason?({:guest_plane, p}) when is_atom(p), do: true
  def reason?({:guest_plane_call, n}) when is_binary(n), do: true
  def reason?({:tool_auth_required, n}) when is_binary(n), do: true
  def reason?({:malformed_resource, tag}) when tag in [:execution, :tenant], do: true
  def reason?({:consent_class_required, _refusal}), do: true
  def reason?({:authorization_required, detail}) when is_binary(detail), do: true
  def reason?(_), do: false

  @doc "The refusal class a reason belongs to (`Prima.Refusal.classes/0`)."
  @spec class(reason()) :: Prima.Refusal.class()
  def class(:unauthenticated), do: :unauthenticated
  def class({:tool_auth_required, _name}), do: :unauthenticated
  def class({:consent_class_required, :not_authenticated}), do: :unauthenticated
  def class({:authorization_required, _detail}), do: :setup_required

  # A record or resource that cannot be attributed is a fault of the
  # caller's code, not something the person can change.
  def class(reason)
      when reason in [:malformed_record, :untagged_tenant_resource],
      do: :internal

  def class({:malformed_resource, _tag}), do: :internal

  def class(reason)
      when reason in [:missing_tenant, :tenant_mismatch, :platform_admin_required],
      do: :forbidden

  def class({:missing_tenant, :no_membership}), do: :forbidden
  def class({:missing_permission, _permission}), do: :forbidden
  def class({:guest_plane, _permission}), do: :forbidden
  def class({:guest_plane_call, _name}), do: :forbidden
  def class({:consent_class_required, _refusal}), do: :forbidden

  @doc """
  The JSON-RPC code name a reason answers with in place of its class's
  code, or `nil` — the codes these reasons have always carried on the
  wire: a connection to re-authorize is an identity answer, and a
  malformed resource or a consent class refused for want of a sign-in
  keep the permission code.
  """
  @spec code_override(reason()) :: atom() | nil
  def code_override({:authorization_required, _detail}), do: :auth_required

  def code_override(reason)
      when reason in [:malformed_record, :untagged_tenant_resource],
      do: :insufficient_permissions

  def code_override({:malformed_resource, _tag}), do: :insufficient_permissions

  def code_override({:consent_class_required, :not_authenticated}),
    do: :insufficient_permissions

  def code_override(_reason), do: nil

  @doc """
  Render a refusal as the sentence a person reads. No internal field
  name, no term syntax.

  `auth_method` is the caller's — an API key's missing permission carries
  the recreate-with-scope hint, since the key's scopes are the one thing
  its holder can change.
  """
  @spec message(reason(), atom() | nil) :: String.t()
  def message(reason, auth_method \\ nil)

  def message(:unauthenticated, _), do: "Unauthorized: authentication required"

  def message(:missing_tenant, _),
    do: "Unauthorized: this request needs an athanor, and none is resolved"

  # An authenticated person with no athanor membership needs operator assistance.
  def message({:missing_tenant, :no_membership}, _),
    do: "Unauthorized: your account has no athanor — contact your administrator"

  def message(:tenant_mismatch, _), do: "Unauthorized: this belongs to another athanor"

  def message(:malformed_record, _),
    do: "Unauthorized: the record could not be attributed to an athanor"

  def message(:untagged_tenant_resource, _),
    do: "Unauthorized: the resource could not be attributed to an athanor"

  def message(:platform_admin_required, _), do: "Unauthorized: platform admin required"

  def message({:missing_permission, permission}, :api_key) do
    "Unauthorized: missing required permission '#{permission}' " <>
      "(API key does not include this scope — recreate with --scope #{permission})"
  end

  def message({:missing_permission, permission}, _) do
    "Unauthorized: missing required permission '#{permission}'"
  end

  def message({:guest_plane, permission}, _) do
    "Unauthorized: a call from inside a running component cannot use '#{permission}'"
  end

  def message({:guest_plane_call, name}, _) do
    "Unauthorized: a call from inside a running component cannot call '#{name}'"
  end

  def message({:tool_auth_required, name}, _) do
    "Unauthorized: tool '#{name}' requires authentication"
  end

  def message({:malformed_resource, _tag}, _),
    do: "Unauthorized: the resource could not be attributed to its owner"

  # The consent-class refusal renders through the vocabulary's owner —
  # one spelling whichever layer refused (the dispatch gate here, the
  # profile tool's domain arms there).
  def message({:consent_class_required, refusal}, _) do
    Sanctum.Consent.Authz.message(refusal)
  end

  # A stored OAuth credential that requires reauthorization, with the
  # producer's own description of why.
  def message({:authorization_required, detail}, _) do
    "Unauthorized: this connection must be re-authorized (#{detail})"
  end
end
