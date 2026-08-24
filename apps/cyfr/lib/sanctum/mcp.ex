# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP do
  @moduledoc """
  MCP tool and resource provider for Sanctum identity & authorization service.

  ## Tools

  - `session` - Session management (login, logout, whoami, use)
  - `key` - API key management (create, get, list, revoke, rotate)
  - `tincture_visibility` - Tincture public/private visibility (set, get)
  - `athanor` - The athanors a person belongs to (list, create a group, rename, archive)
  - `member` - Who is in an athanor (list, add, remove, leave)
  - `door` - The server allowlist, platform admins only (allow, deny, list, requests)

  ## Resources

  - `sanctum://identity` - Current user identity
  - `sanctum://permissions` - Current user permissions

  ## Architecture Note

  Tool definitions live next to their implementation under `lib/sanctum`.
  Authentication tools (login/logout) are handled differently as they
  require browser redirects.
  """

  @behaviour Emissary.MCP.ToolProvider

  alias Sanctum.Context
  alias Sanctum.MCP.Shared

  # ============================================================================
  # ResourceProvider Protocol
  # ============================================================================

  @doc """
  Returns available Sanctum resources (concrete URIs only).
  """
  def resources do
    [
      %{
        uri: "sanctum://identity",
        name: "Current Identity",
        description: "Current authenticated user identity",
        mimeType: "application/json"
      },
      %{
        uri: "sanctum://permissions",
        name: "User Permissions",
        description: "Current user's granted permissions",
        mimeType: "application/json"
      }
    ]
  end

  @doc """
  Returns Sanctum resource templates (RFC 6570 URI templates).
  """
  def resource_templates do
    []
  end

  @doc """
  Read a resource by URI.
  """
  def read(%Context{} = ctx, "sanctum://identity") do
    content =
      case Jason.encode(%{user_id: ctx.user_id, athanor_id: ctx.athanor_id, scope: ctx.scope}) do
        {:ok, json} -> json
        {:error, _} -> ~s({"error":"encoding_error"})
      end

    {:ok, %{content: content, mimeType: "application/json"}}
  end

  def read(%Context{} = ctx, "sanctum://permissions") do
    content =
      case Jason.encode(%{permissions: Shared.format_permissions(ctx.permissions)}) do
        {:ok, json} -> json
        {:error, _} -> ~s({"error":"encoding_error"})
      end

    {:ok, %{content: content, mimeType: "application/json"}}
  end

  def read(_ctx, uri) do
    {:error, "Unknown resource URI: #{uri}"}
  end

  # ============================================================================
  # ToolProvider Protocol
  # ============================================================================

  def tools do
    [
      Sanctum.MCP.SessionTool.definition(),
      Sanctum.MCP.AthanorTool.definition(),
      Sanctum.MCP.MemberTool.definition(),
      Sanctum.MCP.DoorTool.definition(),
      Sanctum.MCP.OAuthTool.definition(),
      Sanctum.MCP.KeyTool.definition(),
      Sanctum.MCP.TinctureVisibilityTool.definition(),
      Sanctum.MCP.WebhookTool.definition(),
      Sanctum.MCP.VaultTool.definition(),
      Sanctum.MCP.ProfileTool.definition()
    ]
  end

  # ============================================================================
  # Tool Handlers — delegated to per-tool modules
  # ============================================================================

  def handle("session", ctx, args), do: Sanctum.MCP.SessionTool.handle(ctx, args)
  def handle("athanor", ctx, args), do: Sanctum.MCP.AthanorTool.handle(ctx, args)
  def handle("member", ctx, args), do: Sanctum.MCP.MemberTool.handle(ctx, args)
  def handle("door", ctx, args), do: Sanctum.MCP.DoorTool.handle(ctx, args)
  def handle("oauth", ctx, args), do: Sanctum.MCP.OAuthTool.handle(ctx, args)
  def handle("key", ctx, args), do: Sanctum.MCP.KeyTool.handle(ctx, args)

  def handle("tincture_visibility", ctx, args),
    do: Sanctum.MCP.TinctureVisibilityTool.handle(ctx, args)

  def handle("webhook", ctx, args), do: Sanctum.MCP.WebhookTool.handle(ctx, args)
  def handle("vault", ctx, args), do: Sanctum.MCP.VaultTool.handle(ctx, args)
  def handle("profile", ctx, args), do: Sanctum.MCP.ProfileTool.handle(ctx, args)

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end
end
