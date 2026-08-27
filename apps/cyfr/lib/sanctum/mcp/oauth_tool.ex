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

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.MCP assembles its roster from these.
  def definition do
    %{
      name: "oauth",
      title: "OAuth Provider Configuration",
      description:
        "Store, list and remove OAuth app client credentials per provider. Grants are " <>
          "connection-keyed: start them with vault.authorize.",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: true,
        actions: %{
          # External only, like every other credential write (key.create,
          # vault.create, webhook.create). This one writes the operator's
          # OAuth *client* secret, so a component reaching it from inside
          # the sandbox would be the widest of the set, not the narrowest.
          "set_client" => %{kind: :write, planes: [:external], permission: :vault_write},
          "list" => %{kind: :read, planes: [:external], permission: :vault_read},
          "delete_client" => %{
            kind: :destructive,
            planes: [:external],
            permission: :vault_write
          }
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["set_client", "list", "delete_client"],
            "description" => "Action to perform"
          },
          "provider" => %{
            "type" => "string",
            "description" => "OAuth provider name (e.g. 'google')"
          },
          "client_id" => %{
            "type" => "string",
            "description" => "The OAuth app's client id"
          },
          "client_secret" => %{
            "type" => "string",
            "description" => "The OAuth app's client secret (omit for public clients)"
          }
        },
        "required" => ["action"]
      }
    }
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    case Sanctum.ProviderCredentials.list(ctx) do
      {:ok, rows} -> {:ok, %{providers: rows, count: length(rows)}}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "delete_client", "provider" => provider})
      when is_binary(provider) do
    case Sanctum.ProviderCredentials.delete(ctx, provider) do
      :ok -> {:ok, %{status: "ok", provider: provider, deleted: true}}
      {:error, :not_found} -> {:error, "No client credentials stored for provider '#{provider}'"}
      {:error, reason} -> {:error, format_reason(reason)}
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
        {:error, format_reason(reason)}
    end
  end

  def handle(_ctx, %{"action" => "set_client"}) do
    {:error, "set_client requires: provider, client_id (client_secret optional)"}
  end

  def handle(_ctx, _args) do
    {:error, Emissary.MCP.ToolProvider.invalid_action("oauth", action_enum())}
  end

  defp action_enum, do: get_in(definition(), [:input_schema, "properties", "action", "enum"])

  # An authorization refusal stays a vocabulary term — the dispatcher
  # renders it with the auth code. `to_string/1` here used to crash on a
  # refusal tuple whenever the annotation chokepoint was bypassed.
  defp format_reason(reason) when is_binary(reason), do: reason

  defp format_reason(reason) do
    if Sanctum.Unauthorized.reason?(reason), do: reason, else: to_string(reason)
  end
end
