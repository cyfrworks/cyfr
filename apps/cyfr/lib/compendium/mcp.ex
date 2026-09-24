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
    - `read_resource` - Read a `compendium://` resource
  - `aqua` - AQUA agent system and documentation guides (list, get, create, update, delete)

  ## Architecture Note

  This module lives in the `compendium` app, keeping tool definitions
  close to their implementation.

  Implements the ToolProvider protocol (tools/0 and handle/3)
  which is validated at runtime by Grimoire.Catalog.
  """

  @behaviour Prima.Provider

  def service, do: "compendium"

  require Logger

  alias Sanctum.Context
  alias Compendium.MCP.Shared

  # ============================================================================
  # Resources
  # ============================================================================

  @doc """
  Returns available Compendium resources (concrete URIs only).
  """
  def resources do
    []
  end

  @doc """
  Returns Compendium resource templates (RFC 6570 URI templates). A read
  of either is the `component.read_resource` operation, admitted by the
  gate under `:component_read`.
  """
  def resource_templates do
    [
      %{
        uriTemplate: "compendium://components/{reference}",
        name: "Component Metadata",
        description: "Component metadata by OCI reference",
        mimeType: Prima.MediaType.json()
      },
      %{
        uriTemplate: "compendium://assets/{reference}/{path}",
        name: "Component Assets",
        description: "Static assets from components",
        mimeType: Prima.MediaType.binary()
      }
    ]
  end

  # The gate admitted the read (authenticated, `:component_read`, the
  # external plane); what is left is the domain's own tenant and asset
  # semantics, answered under the caller's context.
  defp read_resource(%Context{} = ctx, "compendium://components/" <> reference),
    do: read_component_metadata(ctx, reference)

  defp read_resource(%Context{} = ctx, "compendium://assets/" <> rest),
    do: read_component_asset(ctx, rest)

  defp read_resource(_ctx, uri) when is_binary(uri),
    do: {:error, {:invalid_argument, "Unknown resource URI: #{uri}"}}

  defp read_resource(_ctx, _uri),
    do: {:error, {:invalid_argument, "Missing required argument: uri"}}

  defp read_component_metadata(ctx, reference) do
    case Shared.resolve_component(ctx, reference) do
      {:ok, component, _ref} ->
        case Jason.encode(component) do
          {:ok, json} -> {:ok, %{content: json, mimeType: Prima.MediaType.json()}}
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

          case Arca.get(Sanctum.Context.actor(ctx), asset_path) do
            {:ok, content} ->
              {:ok, %{content: Base.encode64(content), mimeType: Prima.MediaType.binary()}}

            {:error, reason} ->
              Logger.warning("[Compendium.MCP] Asset not found: #{rest} (#{inspect(reason)})")
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
         :ok <- Prima.PathSafety.validate_segments(segments) do
      {:ok, segments}
    else
      [] -> {:error, "Invalid asset path: empty"}
      {:error, {_reason, message}} -> {:error, "Invalid asset path: #{message}"}
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

  def handle("component", ctx, %{"action" => "read_resource"} = args),
    do: ctx |> read_resource(args["uri"]) |> index("Component index")

  def handle("component", ctx, args),
    do: ctx |> Compendium.MCP.ComponentTool.handle(args) |> index("Component index")

  def handle("aqua", ctx, args),
    do: ctx |> Compendium.MCP.AquaTool.handle(args) |> index("Agent index")

  def handle("registry", ctx, args),
    do: ctx |> Compendium.MCP.RegistryTool.handle(args) |> index("Component index")

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # A projection the tree has moved past, answered by a facade the tool
  # reached without saying so itself: unavailable, in the surface's words.
  defp index({:error, :projection_unavailable}, noun), do: {:error, {:unavailable, noun}}
  defp index(answer, _noun), do: answer
end
