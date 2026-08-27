# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP do
  @moduledoc """
  MCP tool provider for Compendium component registry.

  Provides tools with action-based dispatch:
  - `component` - Component discovery and registry operations
    - `search` - Search components by type, category, tags
    - `inspect` - Get component metadata, schema, and dependency tree (when deps declared)
    - `pull` - Pull component from OCI registry
    - `push` - Push a local component to the OCI registry
    - `categories` - List available categories
    - `list` - List all installed components (local-only)
    - `delete` - Delete a component from the registry
  - `aqua` - AQUA agent system and documentation guides (list, get, create, update, delete)

  ## Architecture Note

  This module lives in the `compendium` app, keeping tool definitions
  close to their implementation.

  Implements the ToolProvider protocol (tools/0 and handle/3)
  which is validated at runtime by Emissary.MCP.ToolRegistry.
  """

  @behaviour Emissary.MCP.ToolProvider

  require Logger

  alias Sanctum.Context
  alias Compendium.MCP.Shared

  # ============================================================================
  # ResourceProvider Protocol
  # ============================================================================

  @doc """
  Returns available Compendium resources (concrete URIs only).
  """
  def resources do
    []
  end

  @doc """
  Returns Compendium resource templates (RFC 6570 URI templates).
  """
  def resource_templates do
    [
      %{
        uriTemplate: "compendium://components/{reference}",
        name: "Component Metadata",
        description: "Component metadata by OCI reference",
        mimeType: "application/json"
      },
      %{
        uriTemplate: "compendium://assets/{reference}/{path}",
        name: "Component Assets",
        description: "Static assets from components",
        mimeType: "application/octet-stream"
      }
    ]
  end

  @doc """
  Read a resource by URI.

  Anonymous reads are refused before any tenant resolution: an
  unauthenticated context carries no athanor of its own, so letting it
  through would serve component metadata and asset bytes to anyone who can
  reach `POST /mcp` with an exact reference.
  """
  def read(%Context{authenticated: false}, "compendium://" <> _rest) do
    {:error, "Authentication required to read components"}
  end

  def read(%Context{} = ctx, "compendium://components/" <> reference) do
    with :ok <- Context.require_permission(ctx, :component_read) do
      read_component_metadata(ctx, reference)
    end
  end

  def read(%Context{} = ctx, "compendium://assets/" <> rest) do
    with :ok <- Context.require_permission(ctx, :component_read) do
      read_component_asset(ctx, rest)
    end
  end

  def read(_ctx, uri) do
    {:error, "Unknown resource URI: #{uri}"}
  end

  # Resources bypass the tool-annotation chokepoint (the router delegates
  # authorization to each handler), so the `:component_read` the sibling
  # component tool actions declare is enforced above, per clause.
  defp read_component_metadata(ctx, reference) do
    case Shared.resolve_component(ctx, reference) do
      {:ok, component, _ref} ->
        case Jason.encode(component) do
          {:ok, json} -> {:ok, %{content: json, mimeType: "application/json"}}
          {:error, _} -> {:error, "Failed to encode component as JSON"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_component_asset(ctx, rest) do
    case String.split(rest, "/", parts: 2) do
      [reference, path] when path != "" ->
        # The trailing path is caller-controlled: validate it at this
        # boundary (the rule at `Arca`'s door — every untrusted-path
        # ingress refuses with a type, never a raise) before the resolved
        # ref builds the real segments.
        with {:ok, asset_segments} <- validate_asset_path(path),
             {:ok, _component, ref} <- Shared.resolve_component(ctx, reference) do
          asset_path =
            Compendium.ComponentPath.version_dir(
              ref.type,
              ref.namespace,
              ref.name,
              ref.version
            ) ++ asset_segments

          case Arca.get(ctx, asset_path) do
            {:ok, content} ->
              {:ok, %{content: Base.encode64(content), mimeType: "application/octet-stream"}}

            {:error, reason} ->
              Logger.error("[Compendium.MCP] Asset not found: #{rest} (#{inspect(reason)})")
              {:error, "Asset not found: #{rest}"}
          end
        end

      _ ->
        {:error, "Invalid asset URI: missing path after reference"}
    end
  end

  defp validate_asset_path(path) do
    segments = path |> String.split("/") |> Enum.reject(&(&1 == ""))

    with [_ | _] <- segments,
         :ok <- Cyfr.PathSafety.validate_segments(segments) do
      {:ok, segments}
    else
      [] -> {:error, "Invalid asset path: empty"}
      {:error, message} -> {:error, "Invalid asset path: #{message}"}
    end
  end

  # ============================================================================
  # ToolProvider Protocol (validated at runtime)
  # ============================================================================

  def tools do
    [
      Compendium.MCP.ComponentTool.definition(),
      Compendium.MCP.AquaTool.definition(),
      Compendium.MCP.RegistryTool.definition()
    ]
  end

  # ============================================================================
  # Tool Handlers — delegated to per-tool modules
  # ============================================================================

  def handle("component", ctx, args), do: Compendium.MCP.ComponentTool.handle(ctx, args)
  def handle("aqua", ctx, args), do: Compendium.MCP.AquaTool.handle(ctx, args)
  def handle("registry", ctx, args), do: Compendium.MCP.RegistryTool.handle(ctx, args)

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end
end
