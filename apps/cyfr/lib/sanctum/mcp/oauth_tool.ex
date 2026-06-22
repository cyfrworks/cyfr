# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.OAuthTool do
  @moduledoc """
  OAuth tool handlers for the Sanctum MCP provider — authorize, status,
  and revoke OAuth providers for catalysts.

  Extracted from `Sanctum.MCP`; behaviour preserved exactly.
  """

  alias Sanctum.Context
  alias Sanctum.MCP.Shared

  def handle(
        %Context{} = ctx,
        %{
          "action" => "authorize",
          "component_ref" => component_ref,
          "provider" => provider
        } = args
      ) do
    pin_version = Map.get(args, "pin_version", false)

    with {:ok, component_ref} <- Shared.normalize_ref(component_ref),
         :ok <- Shared.require_permission(ctx, :secrets_write),
         {:ok, store_ref, promoted_from} <-
           Shared.maybe_promote_to_name_level(component_ref, pin_version) do
      case Sanctum.OAuth.authorize_url(ctx, store_ref, provider) do
        {:ok, result} ->
          response = %{
            status: "ok",
            authorize_url: result.url,
            redirect_uri: result.redirect_uri,
            component_ref: store_ref,
            message:
              "Visit the authorize_url to grant access. " <>
                "The redirect_uri (#{result.redirect_uri}) must be registered with your OAuth provider."
          }

          response =
            if promoted_from,
              do: Map.put(response, :promoted_from, promoted_from),
              else: response

          {:ok, response}

        {:error, reason} ->
          {:error, to_string(reason)}
      end
    end
  end

  def handle(_ctx, %{"action" => "authorize"}) do
    {:error, "authorize requires: component_ref, provider"}
  end

  def handle(%Context{} = ctx, %{"action" => "status", "component_ref" => component_ref}) do
    with {:ok, component_ref} <- Shared.normalize_ref(component_ref),
         :ok <- Shared.require_permission(ctx, :secrets_read) do
      case Sanctum.OAuth.status(ctx, component_ref) do
        {:ok, providers} -> {:ok, %{status: "ok", providers: providers}}
        {:error, reason} -> {:error, to_string(reason)}
      end
    end
  end

  def handle(_ctx, %{"action" => "status"}) do
    {:error, "status requires: component_ref"}
  end

  def handle(
        %Context{} = ctx,
        %{
          "action" => "revoke",
          "component_ref" => component_ref,
          "provider" => provider
        } = args
      ) do
    pin_version = Map.get(args, "pin_version", false)

    with {:ok, component_ref} <- Shared.normalize_ref(component_ref),
         :ok <- Shared.require_permission(ctx, :secrets_write),
         {:ok, store_ref, promoted_from} <-
           Shared.maybe_promote_to_name_level(component_ref, pin_version) do
      case Sanctum.OAuth.revoke(ctx, store_ref, provider) do
        :ok ->
          result = %{status: "ok", message: "Token revoked for #{store_ref}/#{provider}"}

          result =
            if promoted_from, do: Map.put(result, :promoted_from, promoted_from), else: result

          {:ok, result}

        {:error, reason} ->
          {:error, to_string(reason)}
      end
    end
  end

  def handle(_ctx, %{"action" => "revoke"}) do
    {:error, "revoke requires: component_ref, provider"}
  end

  def handle(_ctx, _args) do
    {:error, "Invalid oauth action. Use: authorize, status, or revoke"}
  end
end
