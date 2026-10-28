# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.WorkOSStub do
  @moduledoc """
  WorkOS's two standalone single sign-on endpoints, scripted on loopback
  in plain HTTP, one request per connection, for the company sign-in's
  suites.

    * `GET /sso/authorize` answers as WorkOS does once the person signed
      in at their company: a 302 to the request's `redirect_uri` carrying
      a fresh `code` and the request's own `state`.
    * `POST /sso/token` answers `token.(request)`, which runs in the
      stub's process and answers `{status, body}` (`token/1` is WorkOS's
      200) or `:close` (close without answering).
    * Any other request is a 404.

  Every request is told to the test that started the stub as
  `{:workos_request, %{method:, path:, query:, headers:, body:}}`: the
  query as its raw string, the headers as lower-cased names and their
  values, the body as received.

  `start!/1` points `:sanctum, :workos_api_url` at the stub and adds its
  loopback address to the operator's private egress targets, each
  restored on exit and registered before the change, so a test killed at
  its timeout restores them too, and stops the listener on exit. It
  serves a listener of its own because `Sanctum.Test.RegistryStub.serve!/1`
  answers a status and a JSON body alone, never the `location` header a
  redirect needs.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @host "127.0.0.1"

  @doc "Serve WorkOS with a token endpoint that answers every code 404."
  @spec start!() :: %{url: String.t()}
  def start!, do: start!(fn _request -> {404, ~s({"error":"not_found"})} end)

  @doc "Serve WorkOS with `token` answering its token endpoint (the module doc)."
  @spec start!((map() -> {pos_integer(), binary()} | :close)) :: %{url: String.t()}
  def start!(token) when is_function(token, 1) do
    observer = self()
    put_env!(:sanctum, :private_egress_targets, &Enum.uniq(List.wrap(&1) ++ [@host]))

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :http_bin,
        ip: {127, 0, 0, 1},
        active: false,
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(listen)
    pid = spawn(fn -> accept(listen, token, observer) end)
    :ok = :gen_tcp.controlling_process(listen, pid)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end)

    url = "http://#{@host}:#{port}"
    put_env!(:sanctum, :workos_api_url, fn _previous -> url end)
    %{url: url}
  end

  @doc """
  A WorkOS profile: the fields its token endpoint answers, with
  `overrides` written over them (a key whose value is `:absent` is left
  out).
  """
  @spec profile(map()) :: map()
  def profile(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    %{
      "object" => "profile",
      "id" => "prof_01CYFR#{n}",
      "organization_id" => "org_01CYFR",
      "connection_id" => "conn_01CYFR",
      "connection_type" => "GenericSAML",
      "idp_id" => "idp-#{n}",
      "email" => "person#{n}@company.example",
      "first_name" => "Ada",
      "last_name" => "Lovelace",
      "raw_attributes" => %{}
    }
    |> Map.merge(overrides)
    |> Map.reject(fn {_key, value} -> value == :absent end)
  end

  @doc "The token endpoint's 200: an access token and `profile`, with no ID token."
  @spec token(map()) :: {200, binary()}
  def token(profile) when is_map(profile),
    do: {200, Jason.encode!(%{"access_token" => "wos_access_token", "profile" => profile})}

  defp put_env!(app, key, change) do
    previous = Application.fetch_env(app, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)

    current =
      case previous do
        {:ok, value} -> value
        :error -> nil
      end

    Application.put_env(app, key, change.(current))
  end

  defp accept(listen, token, observer) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        serve(socket, token, observer)
        accept(listen, token, observer)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, token, observer) do
    with {:ok, request} <- read(socket) do
      send(observer, {:workos_request, request})

      case answer(request, token) do
        {status, headers, body} ->
          head = Enum.map_join(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)

          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} Answer\r\n" <>
              head <>
              "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
          )

        :close ->
          :ok
      end
    end

    :gen_tcp.close(socket)
  end

  defp answer(%{method: "GET", path: "/sso/authorize", query: query}, _token) do
    case URI.decode_query(query) do
      %{"redirect_uri" => redirect_uri, "state" => state} ->
        code = "wos_code_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
        callback = URI.encode_query(%{"code" => code, "state" => state})
        {302, [{"location", redirect_uri <> "?" <> callback}], ""}

      _incomplete ->
        {400, [{"content-type", "application/json"}], ~s({"error":"invalid_request"})}
    end
  end

  defp answer(%{method: "POST", path: "/sso/token"} = request, token) do
    case token.(request) do
      {status, body} when is_integer(status) and is_binary(body) ->
        {status, [{"content-type", "application/json"}], body}

      :close ->
        :close
    end
  end

  defp answer(_request, _token),
    do: {404, [{"content-type", "application/json"}], ~s({"error":"not_found"})}

  defp read(socket) do
    with {:ok, {:http_request, method, {:abs_path, target}, _version}} <-
           :gen_tcp.recv(socket, 0, 5_000),
         {:ok, headers} <- headers(socket, []),
         :ok <- :inet.setopts(socket, packet: :raw),
         {:ok, body} <- body(socket, content_length(headers)) do
      %URI{path: path, query: query} = URI.parse(target)

      {:ok,
       %{
         method: to_string(method),
         path: path,
         query: query || "",
         headers: headers,
         body: body
       }}
    end
  end

  defp headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        headers(socket, [{String.downcase(to_string(name)), value} | acc])

      {:ok, :http_eoh} ->
        {:ok, Enum.reverse(acc)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_length(headers) do
    case List.keyfind(headers, "content-length", 0) do
      {_, value} -> String.to_integer(String.trim(value))
      nil -> 0
    end
  end

  defp body(_socket, 0), do: {:ok, ""}
  defp body(socket, length), do: :gen_tcp.recv(socket, length, 5_000)
end
