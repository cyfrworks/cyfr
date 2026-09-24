# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Provider do
  @moduledoc """
  MCP tool and resource provider for Sanctum identity & authorization service.

  ## Tools

  - `session` - Session management (login, logout, whoami, use)
  - `key` - API key management (create, get, list, revoke, rotate)
  - `tincture_visibility` - Tincture public/private visibility (get)
  - `athanor` - The athanors a person belongs to (list, create a group, rename, archive)
  - `member` - Who is in an athanor (list, add, remove, leave)
  - `door` - The server allowlist, platform admins only (allow, deny, list, requests)
  - `vault` - The athanor's credential entries (Connections)
  - `profile` - Consent profiles: plan, preview, commit, grant, revoke
  - `oauth` - OAuth grant flow for vault entries
  - `webhook` - Inbound webhook management

  ## Resources

  - `sanctum://identity` - Current user identity
  - `sanctum://permissions` - Current user permissions

  Both are read through `session.read_resource`, which answers from the
  caller's established context alone and reads no stored tenant data.

  ## Architecture Note

  Tool definitions live next to their implementation under `lib/sanctum`.
  Authentication tools (login/logout) are handled differently as they
  require browser redirects.
  """

  @behaviour Prima.Provider

  def service, do: "sanctum"

  # ============================================================================
  # Resources
  # ============================================================================

  @doc """
  Returns available Sanctum resources (concrete URIs only). A read of
  either is the `session.read_resource` operation, which answers any
  caller its own self-description.
  """
  def resources do
    [
      %{
        uri: "sanctum://identity",
        name: "Current Identity",
        description: "Current authenticated user identity",
        mimeType: Prima.MediaType.json()
      },
      %{
        uri: "sanctum://permissions",
        name: "User Permissions",
        description: "Current user's granted permissions",
        mimeType: Prima.MediaType.json()
      }
    ]
  end

  @doc """
  Returns Sanctum resource templates (RFC 6570 URI templates).
  """
  def resource_templates do
    []
  end

  # ============================================================================
  # ToolProvider Protocol
  # ============================================================================

  def tools do
    [
      Sanctum.Providers.Session.definition(),
      Sanctum.Providers.Athanor.definition(),
      Sanctum.Providers.Member.definition(),
      Sanctum.Providers.Door.definition(),
      Sanctum.Providers.OAuth.definition(),
      Sanctum.Providers.Key.definition(),
      Sanctum.Providers.TinctureVisibility.definition(),
      Sanctum.Providers.Webhook.definition(),
      Sanctum.Providers.Vault.definition(),
      Sanctum.Providers.Profile.definition()
    ]
  end

  # ============================================================================
  # Tool Handlers — delegated to per-tool modules
  # ============================================================================

  def handle("session", ctx, args), do: Sanctum.Providers.Session.handle(ctx, args)
  def handle("athanor", ctx, args), do: Sanctum.Providers.Athanor.handle(ctx, args)
  def handle("member", ctx, args), do: Sanctum.Providers.Member.handle(ctx, args)
  def handle("door", ctx, args), do: Sanctum.Providers.Door.handle(ctx, args)
  def handle("oauth", ctx, args), do: Sanctum.Providers.OAuth.handle(ctx, args)
  def handle("key", ctx, args), do: Sanctum.Providers.Key.handle(ctx, args)

  def handle("tincture_visibility", ctx, args),
    do: Sanctum.Providers.TinctureVisibility.handle(ctx, args)

  def handle("webhook", ctx, args), do: Sanctum.Providers.Webhook.handle(ctx, args)
  def handle("vault", ctx, args), do: Sanctum.Providers.Vault.handle(ctx, args)
  def handle("profile", ctx, args), do: Sanctum.Providers.Profile.handle(ctx, args)

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end
end
