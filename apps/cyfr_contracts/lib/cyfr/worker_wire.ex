# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.WorkerWire do
  @moduledoc """
  How the worker protocol crosses HTTP: the header that carries a
  `Cyfr.WorkerAuth` header, the route each callback of `Cyfr.HostAPI` and
  `Cyfr.WorkerAPI` is posted to, and the shape of a request body and an
  answer. CYFR's host listener and worker client and Opus's worker
  listener and host client are built on it; nothing here holds state.

    * Every request is a `POST` whose `x-cyfr-auth` header carries the
      `Cyfr.WorkerAuth` header for its body. A listener verifies that header
      before it reads the body (`Cyfr.WorkerAuth.verify_host_call_header/4`
      and its siblings), reads at most `Cyfr.HostAPI.max_body_bytes/0`, and
      checks the body against the hash the header named.
    * A host call's route is `/host/v1/<callback>` for each callback of
      `Cyfr.HostAPI` (`host_route/1`); a worker service's report goes to
      `/host/v1/runner_exited` like any other. A WorkerAPI request's route
      is `/worker/v1/<callback>` (`worker_route/1`).
    * The base URL a host call is posted to is the one its attempt's
      assignment names (`Cyfr.Assignment`'s `host_url`), and its header
      names that member (`Cyfr.WorkerAuth`'s `member`), so an attempt's
      calls reach the one member holding it. An assignment naming no
      address is posted to the address the worker service is configured
      with, which is the whole deployment in a cell of one; a call that
      lands on another member is refused whatever it asked for. A worker
      service's exit report carries the same member in its `args` and is
      posted the same way, since every attempt one runner holds was
      issued by one member.
    * A request body is the JSON `{"op": <callback>, "args": {...}}`
      (`request_body/2`, `read_request_body/1`), sealed as
      `Cyfr.WorkerAuth.seal_call/5` seals a host call's body. The route and
      the body's `op` name the same callback; a listener refuses a body
      whose `op` is not its route's.
    * An answer is the JSON `{"ok": value}` on success and
      `{"error": <name>, ...}` on a refusal, where `name` is the refusal
      (`lost`, `unavailable`, `replayed`, `malformed`, `bad_mac`,
      `unknown_version`, `claim_expired`, `not_found`), `guest_error` with
      `type`, `message` and an optional `remediation`, `setup_required`
      with `payload`, or `failed` with `message`. A host call's answer is
      sealed as `Cyfr.WorkerAuth.seal_call/5` seals an answer; a worker
      service's answer is plain. `ok/1` and `error/2` build them.
    * Either side is reached at a base URL a route is appended to: an
      `http` or `https` URL with a host and nothing after it
      (`base_url/1`), as CYFR's worker list and a worker service's host
      URL name each other.
  """

  @auth_header "x-cyfr-auth"
  @host_prefix "/host/v1/"
  @worker_prefix "/worker/v1/"

  @host_callbacks Cyfr.HostAPI.callbacks()
  @worker_callbacks Cyfr.WorkerAPI.callbacks()

  @host_routes Map.new(@host_callbacks, &{&1, @host_prefix <> Atom.to_string(&1)})
  @worker_routes Map.new(@worker_callbacks, &{&1, @worker_prefix <> Atom.to_string(&1)})

  @typedoc "A callback of either behaviour, as the route names it."
  @type callback :: atom()

  @doc "The HTTP header a `Cyfr.WorkerAuth` header travels in, lowercase."
  @spec auth_header() :: String.t()
  def auth_header, do: @auth_header

  @doc """
  The base URL `text` spells, with no trailing slash, or `:error`: an
  `http` or `https` URL with a host, and no path, query or fragment, since
  a route is appended to it as it is.
  """
  @spec base_url(term()) :: {:ok, String.t()} | :error
  def base_url(text) when is_binary(text) do
    case URI.parse(text) do
      %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, "", "/"] ->
        {:ok, String.trim_trailing(text, "/")}

      _ ->
        :error
    end
  end

  def base_url(_text), do: :error

  @doc "The route a host call of `callback` is posted to on CYFR."
  @spec host_route(callback()) :: String.t()
  def host_route(callback) when is_map_key(@host_routes, callback),
    do: Map.fetch!(@host_routes, callback)

  @doc "The route a WorkerAPI request of `callback` is posted to on a worker service."
  @spec worker_route(callback()) :: String.t()
  def worker_route(callback) when is_map_key(@worker_routes, callback),
    do: Map.fetch!(@worker_routes, callback)

  @doc "Every host route by callback."
  @spec host_routes() :: %{callback() => String.t()}
  def host_routes, do: @host_routes

  @doc "Every worker route by callback."
  @spec worker_routes() :: %{callback() => String.t()}
  def worker_routes, do: @worker_routes

  @doc "The callback a host route names, or `:error` for a path that is no host route."
  @spec host_callback(String.t()) :: {:ok, callback()} | :error
  def host_callback(path) when is_binary(path), do: callback_of(@host_routes, path)

  @doc "The callback a worker route names, or `:error` for a path that is no worker route."
  @spec worker_callback(String.t()) :: {:ok, callback()} | :error
  def worker_callback(path) when is_binary(path), do: callback_of(@worker_routes, path)

  @doc "The request body for `callback` with `args`, before it is encoded and sealed."
  @spec request_body(callback(), map()) :: %{String.t() => term()}
  def request_body(callback, args) when is_atom(callback) and is_map(args),
    do: %{"op" => Atom.to_string(callback), "args" => args}

  @doc """
  The callback and args a decoded request body carries. A body whose `op`
  is not a callback of `behaviour` (`Cyfr.HostAPI` or `Cyfr.WorkerAPI`),
  or whose `args` is not an object, is `{:error, :malformed}`.
  """
  @spec read_request_body(module(), term()) :: {:ok, callback(), map()} | {:error, :malformed}
  def read_request_body(behaviour, %{"op" => op, "args" => %{} = args})
      when behaviour in [Cyfr.HostAPI, Cyfr.WorkerAPI] and is_binary(op) do
    case Enum.find(behaviour.callbacks(), &(Atom.to_string(&1) == op)) do
      nil -> {:error, :malformed}
      callback -> {:ok, callback, args}
    end
  end

  def read_request_body(behaviour, _body) when behaviour in [Cyfr.HostAPI, Cyfr.WorkerAPI],
    do: {:error, :malformed}

  @doc "The answer carrying `value`."
  @spec ok(term()) :: %{String.t() => term()}
  def ok(value), do: %{"ok" => value}

  @doc "The answer refusing with `name`, and `fields` beside it (a guest error's `type` and `message`, a payload)."
  @spec error(atom() | String.t(), %{String.t() => term()}) :: %{String.t() => term()}
  def error(name, fields \\ %{})

  def error(name, fields) when is_atom(name) and is_map(fields),
    do: error(Atom.to_string(name), fields)

  def error(name, fields) when is_binary(name) and is_map(fields),
    do: Map.put(fields, "error", name)

  defp callback_of(routes, path) do
    case Enum.find(routes, fn {_callback, route} -> route == path end) do
      {callback, _route} -> {:ok, callback}
      nil -> :error
    end
  end
end
