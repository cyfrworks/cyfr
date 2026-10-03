# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.WorkerWire do
  @moduledoc """
  How the worker protocol crosses HTTP: the header that carries a
  `Prima.WorkerAuth` header, the route each callback of `Prima.HostAPI` and
  `Prima.WorkerAPI` is posted to, and the shape of a request body and an
  answer. CYFR's host listener and worker client and Opus's worker
  listener and host client are built on it; nothing here holds state.

    * Every request is a `POST` whose `x-cyfr-auth` header carries the
      `Prima.WorkerAuth` header for its body. A listener verifies that header
      before it reads the body (`Prima.WorkerAuth.verify_host_call_header/4`
      and its siblings), reads at most `Prima.HostAPI.max_body_bytes/0`, and
      checks the body against the hash the header named.
    * A host call's route is `/host/v1/<callback>` for each callback of
      `Prima.HostAPI` (`host_route/1`); a worker service's report goes to
      `/host/v1/runner_exited` like any other. A WorkerAPI request's route
      is `/worker/v1/<callback>` (`worker_route/1`).
    * The base URL a host call is posted to is the one its attempt's
      assignment names (`Prima.Assignment`'s `host_url`), and its header
      names that member (`Prima.WorkerAuth`'s `member`), so an attempt's
      calls reach the one member holding it. An assignment naming no
      address is posted to the address the worker service is configured
      with, which is the whole deployment in a cell of one; a call that
      lands on another member is refused whatever it asked for. A worker
      service's exit report carries the same member in its `args` and is
      posted the same way, since every attempt one runner holds was
      issued by one member. A report names at most
      `max_report_attempts/0` attempts, so it fits the body bound
      whatever its identifiers; the bound counts every child one
      assignment started over its lifetime, not concurrently.
    * Every request body and every answer carries the wire's version as
      its first member, `v` (`version/0`). A request body is the JSON
      `{"v": 1, "op": <callback>, "args": {...}}` (`request_body/2`,
      `read_request_body/2`), sealed as `Prima.WorkerAuth.seal_call/5`
      seals a host call's body. A sealed body cannot be versioned before
      it is opened: the header's `v1` token is what a listener reads before
      the body (`Prima.WorkerAuth`'s pre-body order), and the body's `v`
      binds the plaintext to it, read after the body is opened and before
      its `op`. The route and the body's `op` name the same callback; a
      listener refuses a body whose `op` is not its route's.
    * An answer is the JSON `{"v": 1, "ok": value}` on success and
      `{"v": 1, "error": <name>, ...}` on a refusal, where `name` is the
      refusal (`lost`, `unavailable`, `replayed`, `malformed`, `bad_mac`,
      `unknown_version`, `claim_expired`, `not_found`, and for
      `c:Prima.HostAPI.egress_pin/3` the refusals
      `Prima.PinnedTarget.refusals/0` names), `guest_error` with `type`,
      `message` and an optional `remediation`, `setup_required` with
      `payload`, or `failed` with `message`. A host call's answer is sealed
      as `Prima.WorkerAuth.seal_call/5` seals an answer; a worker service's
      exit report is answered plain, and so is every WorkerAPI request.
      `ok/1` and `error/2` build answers and `read_answer/1` reads one; an
      answer without `v`, or at another version, is no answer at all.
    * `c:Prima.HostAPI.attached_fetch/3`, posted to
      `/host/v1/attached_fetch`, is answered one of two ways. Refused
      before its request is admitted, it is an ordinary sealed answer, a
      `guest_error` whose members name the request's `call_id` beside its
      `type` and `message`. Admitted, the answer's body is
      `attached_frames_content_type/0` and holds the request's answer as
      `Prima.WorkerAuth` frames, each sealed for that `call_id`, written
      as they arrive.
    * `tests/fixtures/host_api.json` and `tests/fixtures/worker_api.json`
      hold every message of both behaviours as it crosses, sealed and
      signed with the keys of `tests/fixtures/worker_auth.json`.
    * Either side is reached at a base URL a route is appended to: an
      `http` or `https` URL with a host and nothing after it
      (`base_url/1`), as CYFR's worker list and a worker service's host
      URL name each other.
  """

  @version 1
  @auth_header Prima.MacEnvelope.auth_header()
  @host_prefix "/host/v1/"
  @worker_prefix "/worker/v1/"

  @host_callbacks Prima.HostAPI.callbacks()
  @worker_callbacks Prima.WorkerAPI.callbacks()

  @host_routes Map.new(@host_callbacks, &{&1, @host_prefix <> Atom.to_string(&1)})
  @worker_routes Map.new(@worker_callbacks, &{&1, @worker_prefix <> Atom.to_string(&1)})

  # The longest identifier the worker protocol carries (`Prima.Assignment`,
  # `Prima.RunnerControl`): 256 printable ASCII bytes, every one of which
  # may be `"` or `\`, which JSON escapes to two.
  @worst_id String.duplicate(~S("), 256)

  # One attempt in a report's list: the worst identifier, quoted and
  # escaped, and the comma that separates it from the next.
  @report_entry_bytes byte_size(Jason.encode!(@worst_id)) + 1

  # A report naming no attempt, its member and runner at the worst
  # identifier: everything a report carries besides its list's entries,
  # encoded as `request_body/2` encodes it.
  @empty_report_bytes Jason.OrderedObject.new([
                        {"v", @version},
                        {"op", "runner_exited"},
                        {"args",
                         %{"attempts" => [], "member" => @worst_id, "runner" => @worst_id}}
                      ])
                      |> Jason.encode!()
                      |> byte_size()

  # A list of n entries is n entries less the comma its last one lacks.
  @max_report_attempts div(
                         Prima.HostAPI.max_body_bytes() - @empty_report_bytes + 1,
                         @report_entry_bytes
                       )

  @typedoc "A callback of either behaviour, as the route names it."
  @type callback :: atom()

  @doc "The wire's version, which every request body and answer carries as `v`."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  The most attempts one `runner_exited` report names, its subtree's root
  included: as many as fit `Prima.HostAPI.max_body_bytes/0` when every
  identifier the report carries, its member and runner too, is the longest
  the worker protocol allows and every byte of it is escaped. A worker
  service holds no more for one runner, and names no more in the report
  of that runner's end.

  It counts every child one runner assignment started over the
  assignment's lifetime, not the children running at once: no frame tells
  the service a child ended, so the report names each child the runner
  started, ended or not. It is a bound of the report's own meaning, beside
  a run's limits, ceilings and budgets.
  """
  @spec max_report_attempts() :: pos_integer()
  def max_report_attempts, do: @max_report_attempts

  @doc "The HTTP header a `Prima.WorkerAuth` header travels in, lowercase."
  @spec auth_header() :: String.t()
  def auth_header, do: @auth_header

  @doc "The content type of an admitted `attached_fetch` answer: its sealed frames."
  @spec attached_frames_content_type() :: String.t()
  def attached_frames_content_type, do: "application/vnd.cyfr.frames"

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

  @doc """
  The request body for `callback` with `args`, before it is encoded and
  sealed: `v`, then `op`, then `args`, in that order as it is encoded.
  """
  @spec request_body(callback(), map()) :: Jason.OrderedObject.t()
  def request_body(callback, args) when is_atom(callback) and is_map(args),
    do: versioned([{"op", Atom.to_string(callback)}, {"args", args}])

  @doc """
  The callback and args a decoded request body carries, read as a callback
  of `behaviour` (`Prima.HostAPI` or `Prima.WorkerAPI`). The version is
  read before the callback: an object whose `v` is absent or not
  `version/0` is `{:error, :unknown_version}`. A body that is not an
  object, has a member besides `v`, `op` and `args`, names no callback of
  `behaviour`, or whose `args` is not an object is `{:error, :malformed}`.
  """
  @spec read_request_body(module(), term()) ::
          {:ok, callback(), map()} | {:error, :unknown_version | :malformed}
  def read_request_body(behaviour, %{} = body)
      when behaviour in [Prima.HostAPI, Prima.WorkerAPI] and not is_struct(body) do
    case body do
      %{"v" => @version, "op" => op, "args" => %{} = args}
      when map_size(body) == 3 and is_binary(op) and not is_struct(args) ->
        case Enum.find(behaviour.callbacks(), &(Atom.to_string(&1) == op)) do
          nil -> {:error, :malformed}
          callback -> {:ok, callback, args}
        end

      %{"v" => @version} ->
        {:error, :malformed}

      _other_version ->
        {:error, :unknown_version}
    end
  end

  def read_request_body(behaviour, _body) when behaviour in [Prima.HostAPI, Prima.WorkerAPI],
    do: {:error, :malformed}

  @doc "The answer carrying `value`: `v`, then `ok`."
  @spec ok(term()) :: Jason.OrderedObject.t()
  def ok(value), do: versioned([{"ok", value}])

  @doc """
  The answer refusing with `name`, and `fields` beside it (a guest error's
  `type` and `message`, a payload): `v`, then `error`, then the fields by
  name. A field named `v` or `error` is the answer's own, never the
  caller's.
  """
  @spec error(atom() | String.t(), %{String.t() => term()}) :: Jason.OrderedObject.t()
  def error(name, fields \\ %{})

  def error(name, fields) when is_atom(name) and is_map(fields),
    do: error(Atom.to_string(name), fields)

  def error(name, fields) when is_binary(name) and is_map(fields) do
    rest = fields |> Map.drop(["v", "error"]) |> Enum.sort()
    versioned([{"error", name} | rest])
  end

  @doc """
  What a decoded answer says, or `:lost` when it is no answer at this
  version: `{:ok, value}` for `{"v": 1, "ok": value}` and nothing else,
  `{:error, name, fields}` for `{"v": 1, "error": name, ...}` with a
  string `name` and no `ok`, `fields` being its other members. An answer
  without `v`, at another version, or of any other shape is `:lost`, as a
  client counts an answer that never arrived: whether the call acted is
  unknown, and `Prima.HostAPI.retry/1` says what may follow.
  """
  @spec read_answer(term()) ::
          {:ok, term()} | {:error, String.t(), %{String.t() => term()}} | :lost
  def read_answer(%{"v" => @version, "ok" => value} = answer)
      when map_size(answer) == 2 and not is_struct(answer),
      do: {:ok, value}

  def read_answer(%{"v" => @version, "error" => name} = answer)
      when is_binary(name) and not is_map_key(answer, "ok") and not is_struct(answer),
      do: {:error, name, Map.drop(answer, ["v", "error"])}

  def read_answer(_answer), do: :lost

  defp versioned(members), do: Jason.OrderedObject.new([{"v", @version} | members])

  defp callback_of(routes, path) do
    case Enum.find(routes, fn {_callback, route} -> route == path end) do
      {callback, _route} -> {:ok, callback}
      nil -> :error
    end
  end
end
