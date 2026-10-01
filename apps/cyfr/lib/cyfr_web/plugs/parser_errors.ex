# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.Plugs.ParserErrors do
  @moduledoc """
  `Plug.Parsers`, with media types refused before any byte of their body is
  read, and one path prefix's failures answered in JSON-RPC.

  ## Options

  - `:refuse` — `{media_types, reason}`: media types, each
    `"type/subtype"` or `"type/*"`, refused 415 before the parsers run, on
    every request whose body `Plug.Parsers` would read (a POST, PUT, PATCH
    or DELETE whose body is unfetched), by the first `content-type` header
    as `Plug.Parsers` reads it. Nothing of a refused body is read. Under
    the JSON-RPC prefix the refusal is answered through `renderer.halt/4`
    (`:parse_error`, -32700); elsewhere through the `:errors` renderer
    with `reason`, a `Prima.Refusal` reason. Either answer carries
    `connection: close` on HTTP/1, so the server ends the connection
    instead of reading the rest of the body to keep it alive.
  - `:errors` — the module that renders a refusal outside the JSON-RPC
    prefix, defaulting to `CyfrWeb.ApiError`.
  - `:jsonrpc` — `{path_prefix, renderer}`. A request whose routed path
    (`conn.path_info`, which drops empty segments, as the router matches
    it) begins with `path_prefix`'s segments has its content type gated
    before parsing (a POST must be `application/json`), and an unparseable
    body (-32700) or an oversized one is answered through
    `renderer.halt/4`. The id is null because it cannot be read from an
    unparseable body.

  Every other option is `Plug.Parsers`'. Without `:refuse` and `:jsonrpc`
  the plug is `Plug.Parsers`: no refusal, no gate, and every failure
  re-raises. A parser failure outside the prefix keeps Phoenix's behaviour
  the same way.
  """

  @behaviour Plug

  # The methods whose body `Plug.Parsers` reads; a refusal answers exactly
  # the requests the parsers would otherwise read the body of.
  @body_methods ~w(POST PUT PATCH DELETE)

  @default_errors CyfrWeb.ApiError

  @media_type ~r{\A[a-z0-9][a-z0-9!#$&^_.+-]*/(\*|[a-z0-9][a-z0-9!#$&^_.+-]*)\z}

  @impl true
  def init(opts) do
    {jsonrpc, opts} = Keyword.pop(opts, :jsonrpc)
    {refuse, opts} = Keyword.pop(opts, :refuse)
    {errors, parsers_opts} = Keyword.pop(opts, :errors, @default_errors)
    {prefix, renderer} = jsonrpc(jsonrpc)
    {prefix, renderer, refuse(refuse, errors(errors)), Plug.Parsers.init(parsers_opts)}
  end

  defp jsonrpc(nil), do: {nil, nil}

  defp jsonrpc({prefix, renderer} = value)
       when is_binary(prefix) and prefix != "" and is_atom(renderer) and
              renderer not in [nil, true, false] do
    if String.starts_with?(prefix, "/") do
      {String.split(prefix, "/", trim: true), renderer}
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

  defp refuse(nil, _errors), do: nil

  defp refuse({[_ | _] = types, reason} = value, errors) when is_atom(reason) do
    if reason not in [nil, true, false] and
         Enum.all?(types, &(is_binary(&1) and Regex.match?(@media_type, &1))),
       do: {types, reason, errors},
       else: invalid_refuse!(value)
  end

  defp refuse(value, _errors), do: invalid_refuse!(value)

  @spec invalid_refuse!(term()) :: no_return()
  defp invalid_refuse!(value) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} expects `refuse: {media_types, reason}` with a " <>
            "non-empty list of lowercase media types, each \"type/subtype\" or " <>
            "\"type/*\", and a refusal reason, got a " <> Prima.LoggerContext.shape(value)
  end

  defp errors(errors) when is_atom(errors) and errors not in [nil, true, false], do: errors

  defp errors(value) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} expects `errors:` to be a renderer module, got a " <>
            Prima.LoggerContext.shape(value)
  end

  @impl true
  def call(conn, {prefix, renderer, refuse, parsers_opts}) do
    jsonrpc? = jsonrpc?(conn, prefix)

    with :ok <- check_refused(conn, refuse),
         :ok <- check_content_type(conn, jsonrpc?) do
      Plug.Parsers.call(conn, parsers_opts)
    else
      :refused ->
        refuse_media_type(conn, jsonrpc?, renderer, refuse)

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

  # Decided on the request `Plug.Parsers` would parse and the header it
  # would read, so the refusal and the parser never disagree about a body:
  # one whose `body_params` are already set is not read here or there.
  defp check_refused(_conn, nil), do: :ok

  defp check_refused(
         %Plug.Conn{method: method, body_params: %Plug.Conn.Unfetched{}} = conn,
         {types, _reason, _errors}
       )
       when method in @body_methods do
    with {"content-type", header} <- List.keyfind(conn.req_headers, "content-type", 0),
         {:ok, type, subtype, _params} <- Plug.Conn.Utils.content_type(header),
         true <- "#{type}/#{subtype}" in types or "#{type}/*" in types do
      :refused
    else
      _ -> :ok
    end
  end

  defp check_refused(_conn, _refuse), do: :ok

  defp refuse_media_type(conn, true, renderer, _refuse) do
    conn
    |> close_after_response()
    |> renderer.halt(415, :parse_error, "The request body's media type is not accepted")
  end

  defp refuse_media_type(conn, false, _renderer, {_types, reason, errors}) do
    conn
    |> close_after_response()
    |> errors.halt(415, reason, nil)
  end

  # On HTTP/1 the server keeps a connection alive by reading the rest of an
  # unread body after the response; `connection: close` ends it instead.
  # HTTP/2 forbids the header (RFC 9113 §8.2.2) and resets the unread
  # stream itself.
  defp close_after_response(conn) do
    if conn |> Plug.Conn.get_http_protocol() |> Atom.to_string() |> String.starts_with?("HTTP/1"),
      do: Plug.Conn.put_resp_header(conn, "connection", "close"),
      else: conn
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

  defp jsonrpc?(%Plug.Conn{path_info: path_info}, segments),
    do: :lists.prefix(segments, path_info)
end
