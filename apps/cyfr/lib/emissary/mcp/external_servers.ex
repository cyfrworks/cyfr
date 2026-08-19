# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalServers do
  @moduledoc """
  What a stored `mcp_servers` row means as a live connection.

  One athanor's row is a name, a URL and a config document; a running
  `Emissary.MCP.ExternalServer` needs resolved headers, a timeout and the
  athanor it belongs to. Turning one into the other is the only thing both
  halves of the external-server subsystem share — the `mcp_servers` tool
  (`Emissary.MCP.McpServersTool`) builds a config to create, test or refresh
  a server, and `Emissary.MCP.ExternalProvider` builds one to discover and
  dispatch its tools. They must build the same config from the same row, so
  they build it here.

  Note what this does *not* do: `server_config/2` leaves `vault:<name>`
  header templates as written. Resolving them against the vault happens
  inside `Emissary.MCP.ExternalServer.resolve_headers/2`, at the moment of
  the call, so a credential never sits in a config map being passed around.
  """

  alias Sanctum.Context

  @default_timeout_ms 30_000

  @doc """
  The keyword config `Emissary.MCP.ExternalServerSupervisor.ensure_started/1`
  takes, from a stored row or a freshly-built `%{name:, url:, config:}`.
  """
  @spec server_config(map(), Context.t()) :: keyword()
  def server_config(%{name: name, url: url} = server, %Context{} = ctx) do
    config = config_map(server)

    [
      name: name,
      url: url,
      headers: config["headers"] || %{},
      timeout_ms: config["timeout_ms"] || @default_timeout_ms,
      athanor_id: ctx.athanor_id
    ]
  end

  @doc """
  Start the server if it is not running, and return its tool catalogue.
  """
  @spec ensure_started(map(), Context.t()) :: {:ok, [map()]} | {:error, term()}
  def ensure_started(server, %Context{} = ctx) do
    case Emissary.MCP.ExternalServerSupervisor.ensure_started(server_config(server, ctx)) do
      {:ok, _pid} -> Emissary.MCP.ExternalServer.get_tools(server.name, ctx.athanor_id)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The config map of either a stored `%Arca.Schemas.McpServer{}` (decode its
  raw `config_json`) or a freshly-built `%{config: map}` — the create path,
  which already holds the parsed config and has no column to read.
  """
  @spec config_map(map()) :: map()
  def config_map(server) do
    case Map.get(server, :config) do
      config when is_map(config) -> config
      _ -> Arca.McpServerStorage.config(server)
    end
  end
end
