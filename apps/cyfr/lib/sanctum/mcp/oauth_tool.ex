# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.OAuthTool do
  @moduledoc """
  OAuth provider configuration for the Sanctum MCP provider.

  One verb: `set_client` stores an OAuth app's client credentials for a
  provider in the tenant provider-credential store. Grants themselves are
  connection-keyed — `vault.authorize` starts them, and the callback
  route completes them into a vault entry. The old component-keyed
  `authorize`/`status`/`revoke` actions are gone with the plane that
  stored their tokens.
  """

  alias Sanctum.Context
  alias Sanctum.MCP.Shared

  def handle(
        %Context{} = ctx,
        %{"action" => "set_client", "provider" => provider, "client_id" => client_id} = args
      )
      when is_binary(provider) and is_binary(client_id) do
    with :ok <- Shared.require_permission(ctx, :secrets_write) do
      case Sanctum.ProviderCredentials.put(ctx, provider, client_id, args["client_secret"]) do
        :ok ->
          {:ok,
           %{
             status: "ok",
             provider: provider,
             message: "Client credentials stored for provider '#{provider}'"
           }}

        {:error, reason} ->
          {:error, to_string(reason)}
      end
    end
  end

  def handle(_ctx, %{"action" => "set_client"}) do
    {:error, "set_client requires: provider, client_id (client_secret optional)"}
  end

  def handle(_ctx, _args) do
    {:error, "Invalid oauth action. Use: set_client"}
  end
end
