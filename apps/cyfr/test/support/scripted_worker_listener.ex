# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ScriptedWorkerListener do
  @moduledoc """
  A worker service's listener for the test suite: the `Prima.WorkerWire`
  worker routes, served by Bandit on a loopback port of the system's
  choosing, in front of any `Prima.WorkerAPI` module. It is what
  `Cyfr.Test.ScriptedWorker` is reached through, and what a test's own
  worker module is served by, so `Opus.Dispatch` reaches either
  exactly as it reaches the runtime.

  `start_link/1` takes `worker:` (the `Prima.WorkerAPI` module it serves)
  and `service:` (that worker service's configured id, whose dispatch key
  CYFR derives for it: `Opus.Keys.locus_runtime_key/1`); `url/1` is the
  base URL a `t:Prima.WorkerAPI.endpoint/0` names.

  A request is answered as the runtime's listener answers it
  (`Locus.Runtime.WorkerListener`), checked before its body is read in
  the order `Prima.WorkerAuth` documents: the route (`404`); the
  service's dispatch key, without which it is addressed by nobody
  (`503` `unavailable`); exactly one `x-cyfr-auth` header, then the
  header itself under that key (`Prima.WorkerAuth.verify_request_header/3`),
  a header naming another service (`malformed`) and a nonce presented
  before within the header window (`replayed`), each `401`. A refusal made
  before the body is read is answered on a closed connection. The body is
  then read up to `Prima.HostAPI.max_body_bytes/0` (`413` `malformed` past
  it, on a closed connection, after one more bounded read drops what the
  client still sends), checked against the hash the header named (`401`
  `bad_mac`), and read as the route's callback: a body without the wire's
  version, or at another, is `400` `unknown_version` before its `op` is
  read, and a body whose `op` is not the route's callback, or whose `args`
  are not the callback's, is `400` `malformed`. What the module answers
  crosses as the runtime's does: `200` with `Prima.WorkerWire.ok/1` for a
  start or a kill done, or the status as `Prima.WorkerAPI.status_to_wire/1`
  writes it; `200` with the error for a start refused `malformed` and a
  kill that finds nothing; `503` `unavailable` (with its `message`, when
  the refusal names one) for a start no runner can take, or a module that
  exits; `400` `malformed` for any other refusal. A route that is no
  worker route is `404`.

  The nonces a listener has seen are kept in a table owned by the process
  that started it, which a listener's whole life is (`start_link/1`).
  """

  @behaviour Plug

  import Plug.Conn

  alias Prima.{HostAPI, WorkerAPI, WorkerAuth, WorkerWire}
  alias Opus.Keys

  @doc "A child spec for `start_link/1`, one listener per `worker:`."
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :worker)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  @doc "Serve `opts[:worker]` as the worker service `opts[:service]` on a loopback port."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    worker = Keyword.fetch!(opts, :worker)
    service = Keyword.fetch!(opts, :service)
    nonces = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])

    Bandit.start_link(
      plug: {__MODULE__, worker: worker, service: service, nonces: nonces},
      scheme: :http,
      ip: {127, 0, 0, 1},
      port: 0,
      startup_log: false
    )
  end

  @doc "The base URL the listener `pid` answers on."
  @spec url(pid()) :: String.t()
  def url(pid) when is_pid(pid) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  @doc "The endpoint entry (`t:Prima.WorkerAPI.endpoint/0`) for the listener `pid` serving `service`."
  @spec endpoint(pid(), String.t(), [String.t()] | nil) :: WorkerAPI.endpoint()
  def endpoint(pid, service, components \\ nil) when is_pid(pid) and is_binary(service),
    do: %{id: service, url: url(pid), components: components}

  @impl Plug
  def init(opts), do: Map.new(Keyword.take(opts, [:worker, :service, :nonces]))

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, opts),
    do: serve(conn, opts, System.system_time(:millisecond))

  def call(conn, _opts), do: refuse(closing(conn), 404, :not_found)

  defp serve(conn, opts, now) do
    with {:ok, callback} <- route(conn),
         {:ok, key} <- dispatch_key(opts.service),
         {:ok, header} <- header(conn),
         {:ok, request, body_hash} <- verify_header(key, header, now),
         :ok <- addressed(request, opts.service),
         :ok <- fresh(opts.nonces, request, now),
         {:ok, body, read} <- read(conn),
         {:ok, args} <- read_request(read, body_hash, body, callback) do
      answer(read, run(opts.worker, callback, args), callback)
    else
      # A refusal after the body was read answers on the conn that read it.
      {:refused, read, status, reason} -> refuse(read, status, reason)
      # One made before it ends the connection: the body is still on it.
      {:refused, status, reason} -> refuse(closing(conn), status, reason)
      {:over_bound, read} -> read |> refuse(413, :malformed) |> drop()
    end
  end

  defp closing(conn), do: put_resp_header(conn, "connection", "close")

  defp route(conn) do
    case WorkerWire.worker_callback(conn.request_path) do
      {:ok, callback} -> {:ok, callback}
      :error -> {:refused, 404, :not_found}
    end
  end

  defp header(conn) do
    case get_req_header(conn, WorkerWire.auth_header()) do
      [header] -> {:ok, header}
      _none_or_many -> {:refused, 401, :malformed}
    end
  end

  defp verify_header(key, header, now) do
    case WorkerAuth.verify_request_header(key, header, now) do
      {:ok, request, body_hash} -> {:ok, request, body_hash}
      {:error, reason} -> {:refused, 401, reason}
    end
  end

  # The MAC verified under this service's key, so the header is CYFR's;
  # one naming another service was not made for this one.
  defp addressed(%{service: service}, service), do: :ok
  defp addressed(_request, _service), do: {:refused, 401, :malformed}

  # A nonce is refused for two header windows from when it is first seen,
  # which is as long as the header can verify; a row past that is swept.
  defp fresh(nonces, %{nonce: nonce}, now) do
    :ets.select_delete(nonces, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])

    if :ets.insert_new(nonces, {nonce, now + 2 * WorkerAuth.window_ms()}),
      do: :ok,
      else: {:refused, 401, :replayed}
  end

  defp read(conn) do
    max = HostAPI.max_body_bytes()

    case read_body(conn, length: max, read_length: max) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:over_bound, closing(conn)}
      {:error, _reason} -> {:refused, 400, :malformed}
    end
  end

  # What the client still sends of a body past the bound is read once more
  # and dropped, so a client still writing it reads the refusal.
  defp drop(conn) do
    max = HostAPI.max_body_bytes()

    case read_body(conn, length: max, read_length: max) do
      {_read, _bytes, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp read_request(read, body_hash, body, callback) do
    with :ok <- verify_body(body_hash, body),
         {:ok, args} <- decode(body, callback) do
      {:ok, args}
    else
      {:refused, status, reason} -> {:refused, read, status, reason}
    end
  end

  defp verify_body(body_hash, body) do
    case WorkerAuth.verify_body(body_hash, body) do
      :ok -> :ok
      {:error, reason} -> {:refused, 401, reason}
    end
  end

  # The body's version is read before its callback.
  defp decode(body, callback) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, ^callback, args} <- WorkerWire.read_request_body(WorkerAPI, decoded) do
      {:ok, args}
    else
      {:error, :unknown_version} -> {:refused, 400, :unknown_version}
      _ -> {:refused, 400, :malformed}
    end
  end

  defp answer(conn, {:ok, value}, _callback), do: send_answer(conn, 200, WorkerWire.ok(value))

  defp answer(conn, {:error, :malformed}, :start),
    do: send_answer(conn, 200, WorkerWire.error(:malformed))

  defp answer(conn, {:error, :not_found}, :kill),
    do: send_answer(conn, 200, WorkerWire.error(:not_found))

  defp answer(conn, {:error, :unavailable}, _callback), do: refuse(conn, 503, :unavailable)

  defp answer(conn, {:error, {:unavailable, message}}, _callback),
    do: send_answer(conn, 503, WorkerWire.error(:unavailable, %{"message" => message}))

  defp answer(conn, {:error, _malformed}, _callback), do: refuse(conn, 400, :malformed)

  # A module that exits is a worker service that could not answer.
  defp run(worker, :start, %{"assignment" => token, "input" => input, "sealed_keys" => sealed})
       when is_binary(token) and is_binary(input) and is_binary(sealed) do
    case worker.start(token, input, sealed) do
      :ok -> {:ok, true}
      {:error, refusal} -> {:error, refusal}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp run(worker, :kill, %{"execution_id" => execution_id})
       when is_binary(execution_id) and execution_id != "" do
    case worker.kill(execution_id) do
      :ok -> {:ok, true}
      {:error, refusal} -> {:error, refusal}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp run(worker, :status, args) when map_size(args) == 0 do
    {:ok, status} = worker.status()
    {:ok, WorkerAPI.status_to_wire(status)}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  # Args that are not the callback's are no request of it.
  defp run(_worker, _callback, _args), do: {:error, :malformed}

  defp refuse(conn, status, reason), do: send_answer(conn, status, WorkerWire.error(reason))

  defp send_answer(conn, status, %{} = body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp dispatch_key(service) do
    case Keys.locus_runtime_key(service) do
      {:ok, worker_key} -> {:ok, WorkerAuth.dispatch_key(worker_key)}
      _no_key -> {:refused, 503, :unavailable}
    end
  end
end
