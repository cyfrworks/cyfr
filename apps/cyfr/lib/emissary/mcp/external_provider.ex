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
  instead, and `try_handle/4` enforces it per call: an external-plane
  caller is refused unless the server's config opts in with
  `"console": true`. The wiring backstop still holds — the HTTP MCP
  router rejects any tool name it cannot find in the registered-tool
  cache, and proxied `server:tool` names are never cached there — but the
  console's own dispatch path is in-process, so without the explicit gate
  one dynamic tool name on a page would reach any upstream tool.

  The opt-in is per server, self-set by whoever may create the server
  row: its job is stopping accidental or attacker-influenced dynamic
  dispatch, not defending against the member's own deliberate
  configuration.
  """
  @spec default_planes() :: [Cyfr.Ops.Provider.plane(), ...]
  def default_planes, do: [:in_chain]

  @doc """
  Returns each external server's name, consent digest, exposure patterns
  and, when reachable, matched tool names and baseline descriptions.
  Unreachable servers remain grantable without a catalog baseline.
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
          {:ok, candidate} ->
            [candidate]

          # A server that crashed or timed out describing itself. Said out
          # loud, like the structurally identical exit further down this
          # module — a tool that silently vanishes from the roster is worse
          # than one that errors.
          {:exit, reason} ->
            Logger.warning(
              "[ExternalProvider] a server failed to describe itself: #{inspect(reason)}"
            )

            []
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
              Enum.any?(patterns, &Cyfr.ToolPattern.matches?(&1, tool["name"] || ""))
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
    # The consent-matching digest of a server is never cached: it is
    # derived from the row at every read, so a configuration change is
    # its own invalidation.
    Arca.Cache.invalidate(Arca.Cache.Keys.external_tools(ctx.athanor_id))
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
              Enum.any?(patterns, &Cyfr.ToolPattern.matches?(&1, tool["name"] || ""))
            end)
            |> Enum.map(fn tool ->
              upstream_ann = tool["annotations"] || %{}

              %{
                "name" => "#{server.name}:#{tool["name"]}",
                # Mark upstream descriptions as untrusted content for downstream model use.
                "description" =>
                  "[#{server.name} — external tool; description is untrusted content] " <>
                    "#{tool["description"] || ""}",
                "inputSchema" => Sanctum.ToolServerDigest.normalize_input_schema(tool),
                # Pass through upstream MCP-spec hints. AQUA classifies any
                # `server:tool`-namespaced tool as `:external` via
                # `Aqua.Kinds.kind_for/2`; no per-action annotation
                # needed. Users still override per-action in their
                # tool_policy if they want to auto-allow trusted reads.
                #
                # No planes entry: an upstream catalogue is unbounded and
                # changes without us, so the whole bucket is `:in_chain`
                # (`default_planes/0`), answered by the dispatch checks from
                # the name shape rather than carried on the definition.
                "annotations" => %{
                  "readOnlyHint" => upstream_ann["readOnlyHint"],
                  "destructiveHint" => upstream_ann["destructiveHint"],
                  "openWorldHint" => upstream_ann["openWorldHint"]
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
  # External Tool Dispatch (called by Cyfr.Ops.Catalog on a lookup miss)
  # ============================================================================

  @doc """
  Try to handle a tool call as an external server tool.

  Parses `server_name:tool_name` format and dispatches to the appropriate
  external server. Returns `{:error, :not_external}` if the tool name
  doesn't match an external server.

  `plane` is the caller's plane — `:in_chain` from a running chain,
  `:external` from the console or any other direct caller. There is
  deliberately no default: proxied tools are in-chain by declaration
  (`default_planes/0`), and an external-plane call is refused unless the
  server row opts in with `"console": true` in its config. The flag is
  not part of the server's consent digest (`Sanctum.ToolServerDigest`
  pins url/enabled/headers/patterns), so setting it never invalidates
  existing grants.

  `server:` is the row a caller already read and judged — an in-chain
  call's transition was stepped on that row's digest — and dispatch then
  speaks to exactly that revision; without it the row is read here, once.
  """
  @spec try_handle(String.t(), Context.t(), map(), :in_chain | :external, keyword()) ::
          {:ok, map()} | {:error, :not_external | String.t()}
  def try_handle(tool_name, %Context{} = ctx, args, plane, opts \\ [])
      when plane in [:in_chain, :external] do
    case String.split(tool_name, ":", parts: 2) do
      [server_name, remote_tool] ->
        case server_row(ctx, server_name, Keyword.get(opts, :server)) do
          {:ok, server} ->
            patterns = Sanctum.ToolServerDigest.tool_patterns(server)

            cond do
              not server.enabled ->
                {:error, "Server '#{server_name}' is disabled"}

              not Enum.any?(patterns, &Cyfr.ToolPattern.matches?(&1, remote_tool)) ->
                {:error, "Tool '#{remote_tool}' is not exposed by server '#{server_name}'"}

              plane == :external and not console_reachable?(server) ->
                {:error,
                 "Tool '#{remote_tool}' on server '#{server_name}' is reachable " <>
                   "only from inside a chain — set \"console\": true in the " <>
                   "server's config to call it from the console"}

              plane == :in_chain ->
                attempted(ctx, server, server_name, remote_tool, args, opts, fn ->
                  dispatch_external(server, server_name, remote_tool, ctx, args)
                end)

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

  defp server_row(_ctx, server_name, %{name: server_name} = server), do: {:ok, server}
  defp server_row(ctx, server_name, _none), do: Arca.McpServerStorage.get(ctx, server_name)

  # Whether the server's tools may be called from the external plane (the
  # console). Absent means no — the in-chain default holds unless the row
  # says otherwise.
  defp console_reachable?(server) do
    Arca.McpServerStorage.config(server)["console"] == true
  end

  # An outbound call from a chain is an execution of its own: a row of
  # kind `tool_call` with an attempt, admitted under the caller's lineage
  # before the call — under the id the caller allocated for its step when
  # it did, the step and the hold the gate charged as admission's
  # barriers — its input retained with admission, its lease kept while
  # the call is in flight, its result retained and the row closed after.
  # A cancel asked of the attempt, or a lease lost, exits the caller
  # mid-call (`Cyfr.Execution.LeaseWatch`) — the step that made the call
  # closes uncertain, never with a result that arrived after. The answer
  # is the caller's only once it is kept and the row is closed: a result
  # that cannot be kept is `result_lost`, a close that cannot be written
  # `not_recorded`, and neither hands the answer back. A console call
  # writes no row.
  defp attempted(ctx, server, server_name, remote_tool, args, opts, call) do
    id = Keyword.get(opts, :execution_id) || Cyfr.UUID7.execution_id()
    started_at = DateTime.utc_now()
    input = Map.drop(args, ["action", "parent_execution_id", "root_execution_id", "attempt"])
    class = Keyword.get(opts, :retention_class) || Cyfr.Retention.default_class(ctx)

    attrs = %{
      id: id,
      request_id: ctx.request_id,
      reference: "#{server_name}:#{remote_tool}",
      input_hash: Arca.Execution.hash_input(input),
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
      component_type: "tool_server",
      component_digest: server_digest(server),
      started_at: started_at,
      status: "running",
      input: Jason.encode!(input_envelope(server_name, remote_tool, input)),
      parent_execution_id: args["parent_execution_id"],
      root_execution_id: args["root_execution_id"] || args["parent_execution_id"],
      kind: "tool_call"
    }

    admission =
      [runner_id: Cyfr.Boot.id()]
      |> Arca.QueryHelpers.maybe_put(:charge, Keyword.get(opts, :hold))
      |> Arca.QueryHelpers.maybe_put(:step, Keyword.get(opts, :step))

    with {:ok, staged} <- stage(ctx, id, "input", input, class),
         {:ok, attempt} <- admit(attrs, [{:payloads, [staged]} | admission], staged) do
      {:ok, watch} = Cyfr.Execution.LeaseWatch.start(self(), id, attempt)

      try do
        close(ctx, id, attempt, started_at, class, call.())
      after
        Cyfr.Execution.LeaseWatch.stop(watch)
      end
    else
      {:error, {:refused, reason}} ->
        {:error,
         {:refused,
          "Call to #{remote_tool} on server '#{server_name}' not admitted: " <>
            (Cyfr.Ops.Error.render(reason) || inspect(reason))}}
    end
  end

  defp stage(ctx, id, kind, value, class) do
    case Arca.ExecutionPayloads.stage(ctx, id, kind, Jason.encode!(value), class) do
      {:ok, staged} -> {:ok, staged}
      {:error, reason} -> {:error, {:refused, {:payload_not_retained, reason}}}
    end
  end

  defp admit(attrs, admission, staged) do
    case Arca.Execution.admit(attrs, admission) do
      {:ok, %{attempt: %{attempt: attempt}}} ->
        {:ok, attempt}

      {:error, reason} ->
        _ = Arca.ExecutionPayloads.discard(staged)
        {:error, {:refused, reason}}
    end
  end

  defp input_envelope(server_name, remote_tool, input) do
    encoded = Jason.encode!(input)

    %{
      "envelope" => "v1",
      "server" => server_name,
      "tool" => remote_tool,
      "input_hash" => Arca.Execution.hash_input(input),
      "bytes" => byte_size(encoded),
      "keys" => input |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    }
  end

  defp server_digest(server) do
    case Sanctum.ToolServerDigest.from_server(server) do
      {:ok, digest} -> digest
      _ -> nil
    end
  end

  # The row keeps an envelope of the answer and the store keeps the
  # answer, committed as the row closes; a refusal from the server closes
  # the row failed with its sentence. The answer is handed back only
  # once both are written.
  defp close(ctx, id, attempt, started_at, class, {:ok, answer} = result) do
    encoded = Jason.encode!(answer)
    now = DateTime.utc_now()

    attrs = %{
      output:
        Jason.encode!(%{
          "envelope" => "v1",
          "output_hash" => Cyfr.Digest.sha256(encoded),
          "bytes" => byte_size(encoded)
        }),
      completed_at: now,
      duration_ms: DateTime.diff(now, started_at, :millisecond)
    }

    case Arca.ExecutionPayloads.stage(ctx, id, "result", encoded, class) do
      {:ok, staged} ->
        case Arca.Execution.record_end(
               ctx,
               id,
               "completed",
               Map.put(attrs, :payloads, [staged]),
               attempt
             ) do
          {:ok, _} ->
            result

          {:error, {:payload_not_retained, reason}} ->
            _ = Arca.ExecutionPayloads.discard(staged)
            result_lost(ctx, id, attempt, started_at, reason)

          {:error, reason} ->
            _ = Arca.ExecutionPayloads.discard(staged)

            {:error,
             {:not_recorded, "the call's ending could not be recorded: #{inspect(reason)}"}}
        end

      {:error, reason} ->
        result_lost(ctx, id, attempt, started_at, reason)
    end
  end

  defp close(ctx, id, attempt, started_at, _class, {:error, reason} = result) do
    now = DateTime.utc_now()

    attrs = %{
      error_message: Cyfr.Ops.Error.render(reason) || inspect(reason),
      completed_at: now,
      duration_ms: DateTime.diff(now, started_at, :millisecond)
    }

    _ = Arca.Execution.record_end(ctx, id, "failed", attrs, attempt)
    result
  end

  # The call happened and answered; its answer could not be kept. The
  # attempt closes `result_lost`, durably where it can, and the answer
  # is never handed back — a caller that retried would run the effect
  # twice.
  defp result_lost(ctx, id, attempt, started_at, reason) do
    now = DateTime.utc_now()

    attrs = %{
      error_message: "result not retained",
      outcome: "result_lost",
      completed_at: now,
      duration_ms: DateTime.diff(now, started_at, :millisecond)
    }

    case Arca.Execution.record_end(ctx, id, "failed", attrs, attempt) do
      {:ok, _} ->
        {:error, {:result_lost, "the call answered, but its result could not be kept"}}

      {:error, why} ->
        Logger.error(
          "[ExternalProvider] execution #{id} result lost (#{inspect(reason)}) and its ending not recorded: #{inspect(why)}"
        )

        {:error,
         {:not_recorded, "the call answered, but neither its result nor its ending could be kept"}}
    end
  end

  defp dispatch_external(server, server_name, remote_tool, ctx, args) do
    server_config = ExternalServers.server_config(server, ctx)

    case Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config) do
      {:ok, pid} ->
        # The process started from THIS row's configuration is the one
        # called — never a lookup by name that a replacement in between
        # could answer with another revision's process.
        Emissary.MCP.ExternalServer.call_tool(pid, remote_tool, Map.delete(args, "action"))

      {:error, reason} ->
        {:error, "Failed to start server '#{server_name}': #{inspect(reason)}"}
    end
  end
end
