# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.ParserErrors do
  @moduledoc """
  `Plug.Parsers`, with one path prefix's failures answered in JSON-RPC.

  ## Options

  - `:jsonrpc` — `{path_prefix, renderer}`. A request whose path starts with
    `path_prefix` has its content type gated before parsing (a POST must be
    `application/json`), and an unparseable body (-32700) or an oversized one
    is answered through `renderer.halt/4`. The id is null because it cannot be
    read from an unparseable body.

  Every other option is `Plug.Parsers`'. Without `:jsonrpc` the plug is
  `Plug.Parsers`: no gate, and every failure re-raises. A path outside the
  prefix keeps Phoenix's behaviour the same way.
  """

  @behaviour Plug

  @impl true
  def init(opts) do
    {jsonrpc, parsers_opts} = Keyword.pop(opts, :jsonrpc)
    {prefix, renderer} = jsonrpc(jsonrpc)
    {prefix, renderer, Plug.Parsers.init(parsers_opts)}
  end

  defp jsonrpc(nil), do: {nil, nil}

  defp jsonrpc({prefix, renderer} = value)
       when is_binary(prefix) and prefix != "" and is_atom(renderer) and
              renderer not in [nil, true, false] do
    if String.starts_with?(prefix, "/") do
      value
    else
      invalid_jsonrpc!(value)
    end
  end

  defp jsonrpc(value), do: invalid_jsonrpc!(value)

  @spec invalid_jsonrpc!(term()) :: no_return()
  defp invalid_jsonrpc!(value) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} expects `jsonrpc: {path_prefix, renderer}` with a " <>
            "path prefix starting with \"/\" and a renderer module, got a " <>
            Prima.LoggerContext.shape(value)
  end

  @impl true
  def call(conn, {prefix, renderer, parsers_opts}) do
    jsonrpc? = jsonrpc?(conn, prefix)

    with :ok <- check_content_type(conn, jsonrpc?) do
      Plug.Parsers.call(conn, parsers_opts)
    else
      {:error, message} ->
        renderer.halt(conn, 400, :parse_error, message)
    end
  rescue
    e in Plug.Parsers.ParseError ->
      if jsonrpc?(conn, prefix) do
        # Generic on purpose: the parser's own message can echo attacker
        # bytes from the body.
        renderer.halt(conn, 400, :parse_error, "The request body is not parseable JSON")
      else
        reraise e, __STACKTRACE__
      end

    e in Plug.Parsers.RequestTooLargeError ->
      if jsonrpc?(conn, prefix) do
        renderer.halt(conn, 413, :invalid_request, "The request body exceeds the size limit")
      else
        reraise e, __STACKTRACE__
      end
  end

  defp check_content_type(%Plug.Conn{method: "POST"} = conn, true) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [type | _] ->
        case Plug.Conn.Utils.content_type(type) do
          {:ok, "application", "json", _params} -> :ok
          _ -> {:error, "Content-Type must be application/json"}
        end

      [] ->
        {:error, "Content-Type must be application/json"}
    end
  end

  defp check_content_type(_conn, _jsonrpc?), do: :ok

  defp jsonrpc?(_conn, nil), do: false
  defp jsonrpc?(conn, prefix), do: String.starts_with?(conn.request_path, prefix)
end
