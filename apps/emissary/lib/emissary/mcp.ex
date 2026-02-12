defmodule Emissary.MCP do
  @moduledoc """
  MCP (Model Context Protocol) implementation for CYFR.

  This module is the main entry point for MCP protocol handling.
  It coordinates message parsing, session management, and request routing.

  ## Protocol Support

  Implements MCP 2025-11-25 specification with:
  - JSON-RPC 2.0 message format
  - Streamable HTTP transport
  - Session management via Mcp-Session-Id header
  - Tool discovery and execution

  ## Usage

      # Handle an incoming MCP message
      {:ok, response} = Emissary.MCP.handle_message(session, json_message)

      # Initialize a new session
      {:ok, result, session} = Emissary.MCP.initialize(context, params)

  """

  alias Emissary.MCP.{Message, Session, Router}
  alias Sanctum.Context

  @doc """
  Handle an incoming MCP JSON-RPC message.

  Takes a session and the raw JSON params (already decoded from JSON).
  Returns `{:ok, response}` or `{:error, code, message}`.
  """
  def handle_message(%Session{} = session, params) when is_map(params) do
    with {:ok, message} <- Message.decode(params) do
      handle_decoded(session, message)
    else
      {:error, code, msg} ->
        {:error, code, msg}
    end
  end

  def handle_message(%Session{} = session, params) when is_list(params) do
    # Batch request
    with {:ok, messages} <- Message.decode(params) do
      responses =
        messages
        |> Enum.map(&handle_decoded(session, &1))
        |> Enum.filter(fn
          :ok -> false
          _ -> true
        end)
        |> Enum.map(fn
          {:ok, result, id} -> Message.encode_result(id, result)
          {:error, code, msg, id} -> Message.encode_error(id, code, msg)
        end)

      {:ok, responses}
    end
  end

  defp handle_decoded(session, %Message{type: :request, id: id} = message) do
    case Router.dispatch(session, message) do
      {:ok, result} -> {:ok, result, id}
      {:error, code, msg} -> {:error, code, msg, id}
    end
  end

  defp handle_decoded(session, %Message{type: :notification} = message) do
    Router.dispatch(session, message)
  end

  @doc """
  Initialize a new MCP session.

  Called when a client sends an initialize request without an existing session.
  Creates a new session and returns the initialization result.

  Returns `{:ok, result, session}` or `{:error, code, message}`.
  """
  def initialize(%Context{} = context, params) do
    Router.handle_initialize(context, params)
  end

  @doc """
  Format a successful response for the given request ID.
  """
  def encode_result(id, result) do
    Message.encode_result(id, result)
  end

  @doc """
  Format an error response for the given request ID.
  """
  def encode_error(id, code, message) do
    Message.encode_error(id, code, message)
  end

  @doc """
  Get the protocol version this server supports.
  """
  def protocol_version do
    Router.protocol_version()
  end
end
