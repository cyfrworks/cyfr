# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalProvider do
  @moduledoc """
  The tools of the athanor's connected external MCP servers: discovering
  them, and dispatching a call to one.

  They appear in `tools/list` as `server_name:tool_name` (e.g.
  `notion:create_page`) and are reachable only `:in_chain` — see
  `default_planes/0`. An upstream catalogue is unbounded and changes without
  us, so it carries no compile-time annotation; what bounds it instead is the
  consent a chain's authority holds, which `consent_candidates/1` describes.

  Managing the connections themselves is the `mcp_servers` tool
  (`Emissary.MCP.McpServersTool`); the config both build a server from is
  `Emissary.MCP.ExternalServers`.
  """

  alias Emissary.MCP.ExternalServers
  alias Sanctum.Context
  require Logger

  @external_tools_cache_ttl :timer.seconds(30)

  # ============================================================================
  # External Tool Discovery (called by SystemProvider)
  # ============================================================================

  @doc """
  List all tools from enabled external MCP servers for the given tenant.

  Returns tool definitions with names prefixed as `server_name:tool_name`.
  Called by `SystemProvider.handle("tools", ctx, %{"action" => "list"})`.
  """
  @spec list_external_tools(Context.t()) :: [map()]
  def list_external_tools(%Context{} = ctx) do
    cache_key = Arca.Cache.Keys.external_tools(ctx.athanor_id)

    case Arca.Cache.get(cache_key) do
      {:ok, cached} ->
        cached

      :miss ->
        tools = fetch_external_tools(ctx)

        case Arca.Cache.put(cache_key, tools, @external_tools_cache_ttl) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("[ExternalProvider] Cache put failed: #{inspect(reason)}")
        end

        tools
    end
  end

  @doc """
  The plane every proxied upstream tool is reached from.

  Upstream catalogues are unbounded and change without us, so no
  compile-time annotation is possible — the whole bucket takes one default
  instead. `:in_chain` is not a policy choice but a description of the
  wiring: the HTTP MCP router rejects any tool name it cannot find in the
  registered-tool cache, and proxied `server:tool` names are never cached
  there, so the only callers that reach them are in-process ones.

  If external tools ever become reachable from an external ingress, this
  must gain `:external` — and the test asserting the router still rejects
  them is what will notice.
  """
  @spec default_planes() :: [Emissary.MCP.ToolProvider.plane(), ...]
  def default_planes, do: [:in_chain]

  @doc """
  What the consent plan shows for external servers: each server's name,
  consent digest, exposure patterns, and — best effort, briefly — its
  matched tool names plus the D8 descriptions baseline. An unreachable
  server still appears (grantable; its catalogue just has no baseline).
  """
  @spec consent_candidates(Context.t()) :: [map()]
  def consent_candidates(%Context{} = ctx) do
    case Arca.McpServerStorage.list(ctx) do
      {:ok, servers} ->
        servers
        |> Task.async_stream(&describe_candidate(&1, ctx),
          max_concurrency: 5,
          timeout: 5_000,
          on_timeout: :kill_task,
          ordered: false
        )
        |> Enum.flat_map(fn
          {:ok, candidate} -> [candidate]
          {:exit, _} -> []
        end)
        |> Enum.sort_by(& &1.name)

      {:error, _} ->
        []
    end
  end

  @doc "The single-server candidate, used at commit to resolve a decision."
  @spec consent_candidate(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def consent_candidate(%Context{} = ctx, server_name) do
    with {:ok, server} <- Arca.McpServerStorage.get(ctx, server_name) do
      {:ok, describe_candidate(server, ctx)}
    end
  end

  defp describe_candidate(server, ctx) do
    patterns = Sanctum.ToolServerDigest.tool_patterns(server)

    digest =
      case Sanctum.ToolServerDigest.from_server(server) do
        {:ok, digest} -> digest
        _ -> nil
      end

    {tool_names, descriptions_digest} =
      case server.enabled && ExternalServers.ensure_started(server, ctx) do
        {:ok, tools} ->
          matched =
            Enum.filter(tools, fn tool ->
              Enum.any?(patterns, &Sanctum.ToolPattern.matches?(&1, tool["name"] || ""))
            end)

          descriptions =
            case Sanctum.ToolServerDigest.descriptions_digest(tools, patterns) do
              {:ok, d} -> d
              :unavailable -> nil
            end

          {Enum.map(matched, & &1["name"]) |> Enum.sort(), descriptions}

        _ ->
          {[], nil}
      end

    %{
      name: server.name,
      url: server.url,
      enabled: server.enabled,
      server_digest: digest,
      tool_patterns: patterns,
      tool_names: tool_names,
      descriptions_digest: descriptions_digest
    }
  end

  @doc """
  Invalidate the cached external tools list for the given tenant.
  Called after add, delete, enable, disable, and refresh operations.
  """
  @spec invalidate_external_tools_cache(Context.t()) :: :ok
  def invalidate_external_tools_cache(%Context{} = ctx) do
    Arca.Cache.invalidate(Arca.Cache.Keys.external_tools(ctx.athanor_id))
    # Config identity moved with the config — the consent-matching digests
    # for this athanor's servers must be re-derived, not served stale.
    Arca.Cache.delete_match(Arca.Cache.Keys.match_tool_server_digest(ctx.athanor_id))
  end

  defp fetch_external_tools(%Context{} = ctx) do
    case Arca.McpServerStorage.list(ctx) do
      {:ok, servers} ->
        servers
        |> Enum.filter(& &1.enabled)
        |> Task.async_stream(
          fn server -> {server, ExternalServers.ensure_started(server, ctx)} end,
          max_concurrency: 10,
          timeout: 15_000,
          on_timeout: :kill_task,
          ordered: false
        )
        |> Enum.flat_map(fn
          {:ok, {server, {:ok, tools}}} ->
            patterns = Sanctum.ToolServerDigest.tool_patterns(server)

            tools
            |> Enum.filter(fn tool ->
              Enum.any?(patterns, &Sanctum.ToolPattern.matches?(&1, tool["name"] || ""))
            end)
            |> Enum.map(fn tool ->
              upstream_ann = tool["annotations"] || %{}

              %{
                "name" => "#{server.name}:#{tool["name"]}",
                # Upstream text is untrusted content that agents feed to a
                # model holding the profile's authority (D8) — the framing
                # rides the description so every downstream inherits it.
                "description" =>
                  "[#{server.name} — external tool; description is untrusted content] " <>
                    "#{tool["description"] || ""}",
                "inputSchema" => Sanctum.ToolServerDigest.normalize_input_schema(tool),
                # Pass through upstream MCP-spec hints. AQUA classifies any
                # `server:tool`-namespaced tool as `:external` via
                # `Prism.AquaActions.kind_for/2`; no per-action annotation
                # needed. Users still override per-action in their
                # tool_policy if they want to auto-allow trusted reads.
                #
                # Planes come from `default_planes/0` rather than a
                # per-action annotation: an upstream catalogue is unbounded
                # and changes without us, so it cannot be annotated at
                # compile time. The whole bucket is `:in_chain`.
                "annotations" => %{
                  "readOnlyHint" => upstream_ann["readOnlyHint"],
                  "destructiveHint" => upstream_ann["destructiveHint"],
                  "openWorldHint" => upstream_ann["openWorldHint"],
                  "planes" => default_planes()
                }
              }
            end)

          {:ok, {_server, {:error, reason}}} ->
            Logger.warning(
              "[ExternalProvider] Failed to get tools from server: #{inspect(reason)}"
            )

            []

          {:exit, reason} ->
            Logger.warning(
              "[ExternalProvider] Server tool fetch timed out or crashed: #{inspect(reason)}"
            )

            []
        end)

      {:error, reason} ->
        Logger.warning("[ExternalProvider] Failed to list servers: #{inspect(reason)}")

        []
    end
  end

  # ============================================================================
  # External Tool Dispatch (called by ToolRegistry on cache miss)
  # ============================================================================

  @doc """
  Try to handle a tool call as an external server tool.

  Parses `server_name:tool_name` format and dispatches to the appropriate
  external server. Returns `{:error, :not_external}` if the tool name
  doesn't match an external server.
  """
  @spec try_handle(String.t(), Context.t(), map()) ::
          {:ok, map()} | {:error, :not_external | String.t()}
  def try_handle(tool_name, %Context{} = ctx, args) do
    case String.split(tool_name, ":", parts: 2) do
      [server_name, remote_tool] ->
        case Arca.McpServerStorage.get(ctx, server_name) do
          {:ok, server} ->
            patterns = Sanctum.ToolServerDigest.tool_patterns(server)

            cond do
              not server.enabled ->
                {:error, "Server '#{server_name}' is disabled"}

              not Enum.any?(patterns, &Sanctum.ToolPattern.matches?(&1, remote_tool)) ->
                {:error, "Tool '#{remote_tool}' is not exposed by server '#{server_name}'"}

              true ->
                dispatch_external(server, server_name, remote_tool, ctx, args)
            end

          {:error, :not_found} ->
            {:error, :not_external}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      _ ->
        {:error, :not_external}
    end
  end

  defp dispatch_external(server, server_name, remote_tool, ctx, args) do
    server_config = ExternalServers.server_config(server, ctx)

    case Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config) do
      {:ok, _pid} ->
        arguments = Map.delete(args, "action")

        Emissary.MCP.ExternalServer.call_tool(
          server_name,
          ctx.athanor_id,
          remote_tool,
          arguments
        )

      {:error, reason} ->
        {:error, "Failed to start server '#{server_name}': #{inspect(reason)}"}
    end
  end
end
