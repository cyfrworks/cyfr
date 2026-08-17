# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.OAuthTool do
  @moduledoc """
  OAuth provider configuration for the Sanctum MCP provider.

  `set_client` stores an OAuth app's client credentials for a provider in
  the athanor's provider-credential store, `list` names the providers that
  have them (never the secret), `delete_client` removes one. Grants
  themselves are connection-keyed — `vault.authorize` starts them, and the
  callback route completes them into a vault entry.
  """

  alias Sanctum.Context

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    case Sanctum.ProviderCredentials.list(ctx) do
      {:ok, rows} -> {:ok, %{providers: rows, count: length(rows)}}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "delete_client", "provider" => provider})
      when is_binary(provider) do
    case Sanctum.ProviderCredentials.delete(ctx, provider) do
      :ok -> {:ok, %{status: "ok", provider: provider, deleted: true}}
      {:error, :not_found} -> {:error, "No client credentials stored for provider '#{provider}'"}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  def handle(_ctx, %{"action" => "delete_client"}) do
    {:error, "delete_client requires: provider"}
  end

  def handle(
        %Context{} = ctx,
        %{"action" => "set_client", "provider" => provider, "client_id" => client_id} = args
      )
      when is_binary(provider) and is_binary(client_id) do
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

  def handle(_ctx, %{"action" => "set_client"}) do
    {:error, "set_client requires: provider, client_id (client_secret optional)"}
  end

  def handle(_ctx, _args) do
    {:error, "Invalid oauth action. Use: set_client, list, or delete_client"}
  end
end
