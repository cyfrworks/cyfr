# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP do
  @moduledoc """
  MCP (Model Context Protocol) implementation for CYFR.

  This module is the main entry point for MCP protocol handling.
  It coordinates message decoding and request routing.

  ## Protocol Support

  Implements MCP #{Emissary.MCP.Protocol.version()} with:
  - JSON-RPC 2.0 message format, one message per request — never a batch
  - Streamable HTTP transport, POST only
  - Per-request protocol version and client capabilities in `params._meta`;
    there is no handshake and no session
  - Tool discovery and execution

  ## Usage

      # Handle an incoming MCP message
      {:ok, result, id} = Emissary.MCP.handle_message(ctx, json_message)

  """

  alias Emissary.MCP.{Message, Router}
  alias Sanctum.Context

  @doc """
  Handle an incoming MCP JSON-RPC message.

  Takes the caller's `%Sanctum.Context{}` and the decoded JSON body. Returns
  `{:ok, result, id}`, `:ok` for a notification, or `{:error, code, message}`.

  There is no list-of-messages clause. The specification requires the POST body
  to be a single request or notification, and `EmissaryWeb.MCPController`
  rejects a batch before it reaches here.
  """
  def handle_message(%Context{} = ctx, params) when is_map(params) do
    with {:ok, message} <- Message.decode(params) do
      handle_decoded(ctx, message)
    else
      {:error, code, msg} ->
        {:error, code, msg}
    end
  end

  defp handle_decoded(ctx, %Message{type: :request, id: id} = message) do
    case Router.dispatch(ctx, message) do
      {:ok, result} -> {:ok, result, id}
      {:error, code, msg} -> {:error, code, msg, id}
    end
  end

  defp handle_decoded(ctx, %Message{type: :notification} = message) do
    Router.dispatch(ctx, message)
  end

  defp handle_decoded(ctx, %Message{type: :response} = message) do
    Router.dispatch(ctx, message)
  end

  defp handle_decoded(ctx, %Message{type: :error} = message) do
    Router.dispatch(ctx, message)
  end
end
