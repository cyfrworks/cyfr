# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Provider do
  @moduledoc """
  MCP tool and resource provider for Sanctum identity & authorization service.

  ## Tools

  Each tool's actions are declared once, in its definition (`Prima.Operation`);
  the catalog (`Sanctum.Catalog`) is their one roster.

  - `session` - The caller's own session, its sign-ins and its athanor
  - `key` - API keys
  - `tincture_visibility` - Whether a tincture is public
  - `athanor` - The athanors a person belongs to
  - `member` - Who is in an athanor
  - `invitation` - Invitations to become a person here
  - `door` - The server allowlist, platform admins only
  - `vault` - The athanor's credential entries
  - `profile` - Consent profiles and their grants
  - `oauth` - OAuth grant flow for vault entries
  - `webhook` - Inbound webhooks
  - `person` - A person's identity at their own home: enrollment, the kit, the
    live key, doors, device certificates, the sign-in carry and its assertion
  - `pairing` - Paired devices
  - `passkey` - Passkeys at this home
  - `confirmation` - Pending confirmations of sensitive changes
  - `instance_entry` - The instance's own credentials, offered to the people on it

  ## Resources

  - `sanctum://identity` - Current user identity
  - `sanctum://permissions` - Current user permissions

  Both are read through `session.read_resource`, which answers from the
  caller's established context alone and reads no stored tenant data.

  Tool definitions live next to their implementation under
  `lib/sanctum/providers`.
  """

  @behaviour Prima.Provider

  @impl true
  def service, do: "sanctum"

  # ============================================================================
  # Resources
  # ============================================================================

  @doc """
  Returns available Sanctum resources (concrete URIs only). A read of
  either is the `session.read_resource` operation, which answers any
  caller its own self-description.
  """
  @impl true
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
  @impl true
  def resource_templates do
    []
  end

  # ============================================================================
  # Prima.Provider callbacks
  # ============================================================================

  @impl true
  def tools do
    [
      Sanctum.Providers.Session.definition(),
      Sanctum.Providers.Athanor.definition(),
      Sanctum.Providers.Member.definition(),
      Sanctum.Providers.Invitation.definition(),
      Sanctum.Providers.Door.definition(),
      Sanctum.Providers.OAuth.definition(),
      Sanctum.Providers.Key.definition(),
      Sanctum.Providers.TinctureVisibility.definition(),
      Sanctum.Providers.Webhook.definition(),
      Sanctum.Providers.Vault.definition(),
      Sanctum.Providers.Profile.definition(),
      Sanctum.Providers.Person.definition(),
      Sanctum.Providers.Pairing.definition(),
      Sanctum.Providers.Passkey.definition(),
      Sanctum.Providers.Confirmation.definition(),
      Sanctum.Providers.InstanceEntry.definition()
    ]
  end

  @doc """
  The streams Sanctum's tools offer, each declared beside its operations:
  a person's pending confirmations (`confirmation.changes`).
  """
  @impl true
  def streams, do: Sanctum.Providers.Confirmation.streams()

  # ============================================================================
  # Tool Handlers — delegated to per-tool modules
  # ============================================================================

  @impl true
  def handle("session", ctx, args), do: Sanctum.Providers.Session.handle(ctx, args)
  def handle("athanor", ctx, args), do: Sanctum.Providers.Athanor.handle(ctx, args)
  def handle("member", ctx, args), do: Sanctum.Providers.Member.handle(ctx, args)
  def handle("invitation", ctx, args), do: Sanctum.Providers.Invitation.handle(ctx, args)
  def handle("door", ctx, args), do: Sanctum.Providers.Door.handle(ctx, args)
  def handle("oauth", ctx, args), do: Sanctum.Providers.OAuth.handle(ctx, args)
  def handle("key", ctx, args), do: Sanctum.Providers.Key.handle(ctx, args)

  def handle("tincture_visibility", ctx, args),
    do: Sanctum.Providers.TinctureVisibility.handle(ctx, args)

  def handle("webhook", ctx, args), do: Sanctum.Providers.Webhook.handle(ctx, args)
  def handle("vault", ctx, args), do: Sanctum.Providers.Vault.handle(ctx, args)
  def handle("profile", ctx, args), do: Sanctum.Providers.Profile.handle(ctx, args)
  def handle("person", ctx, args), do: Sanctum.Providers.Person.handle(ctx, args)
  def handle("pairing", ctx, args), do: Sanctum.Providers.Pairing.handle(ctx, args)
  def handle("passkey", ctx, args), do: Sanctum.Providers.Passkey.handle(ctx, args)
  def handle("confirmation", ctx, args), do: Sanctum.Providers.Confirmation.handle(ctx, args)
  def handle("instance_entry", ctx, args), do: Sanctum.Providers.InstanceEntry.handle(ctx, args)

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end
end
