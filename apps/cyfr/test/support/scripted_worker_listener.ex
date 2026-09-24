# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ScriptedWorkerListener do
  @moduledoc """
  A worker service's listener for the test suite: the `Prima.WorkerWire`
  worker routes, served by Bandit on a loopback port of the system's
  choosing, in front of any `Prima.WorkerAPI` module. It is what
  `Cyfr.Test.ScriptedWorker` is reached through, and what a test's own
  worker module is served by, so `Crucible.Dispatch` reaches either
  exactly as it reaches Opus.

  `start_link/1` takes `worker:` (the `Prima.WorkerAPI` module it serves)
  and `service:` (that worker service's configured id, whose dispatch key
  CYFR derives for it: `Crucible.Keys.worker_key/1`); `url/1` is the
  base URL a `t:Prima.WorkerAPI.endpoint/0` names.

  A request is answered as Opus's listener answers it: the `x-cyfr-auth`
  header is verified with the service's dispatch key before the body is
  read (`Prima.WorkerAuth.verify_request_header/3`, `401` with the
  refusal), the body is read up to `Prima.HostAPI.max_body_bytes/0` (`413`
  past it) and checked against the hash the header named (`400`
  `bad_mac`), and a body whose `op` is not the route's callback, or whose
  `args` are not the callback's, is `400` `malformed`. What the module
  answers crosses as `Prima.WorkerWire.ok/1` or `error/2` with status
  `200`; a route that is no worker route is `404`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Prima.{HostAPI, WorkerAPI, WorkerAuth, WorkerWire}
  alias Crucible.Keys

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

    Bandit.start_link(
      plug: {__MODULE__, worker: worker, service: service},
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
  def init(opts), do: Map.new(Keyword.take(opts, [:worker, :service]))

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, opts) do
    case WorkerWire.worker_callback(conn.request_path) do
      {:ok, callback} -> serve(conn, callback, opts)
      :error -> answer(conn, 404, WorkerWire.error(:not_found))
    end
  end

  def call(conn, _opts), do: answer(conn, 404, WorkerWire.error(:not_found))

  # The header is verified before the body is read, so an unauthenticated
  # caller is refused without the listener reading what it sent.
  defp serve(conn, callback, opts) do
    now = System.system_time(:millisecond)

    case WorkerAuth.verify_request_header(dispatch_key(opts.service), header(conn), now) do
      {:ok, _request, body_hash} -> serve_body(conn, callback, body_hash, opts)
      {:error, refusal} -> answer(conn, 401, WorkerWire.error(refusal))
    end
  end

  defp serve_body(conn, callback, body_hash, opts) do
    max = HostAPI.max_body_bytes()

    case read_body(conn, length: max, read_length: max) do
      {:ok, body, conn} ->
        with :ok <- WorkerAuth.verify_body(body_hash, body),
             {:ok, ^callback, args} <- decode(body),
             %{} = answer <- run(opts.worker, callback, args) do
          answer(conn, 200, answer)
        else
          {:error, refusal} -> answer(conn, 400, WorkerWire.error(refusal))
          {:ok, _other_callback, _args} -> answer(conn, 400, WorkerWire.error(:malformed))
          :malformed -> answer(conn, 400, WorkerWire.error(:malformed))
        end

      {:more, _partial, conn} ->
        answer(conn, 413, WorkerWire.error(:malformed))

      {:error, _reason} ->
        answer(conn, 400, WorkerWire.error(:malformed))
    end
  end

  defp header(conn) do
    case get_req_header(conn, WorkerWire.auth_header()) do
      [header] -> header
      _none_or_many -> nil
    end
  end

  defp decode(body) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, callback, args} <- WorkerWire.read_request_body(WorkerAPI, decoded) do
      {:ok, callback, args}
    else
      _ -> {:error, :malformed}
    end
  end

  defp answer(conn, status, %{} = body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp run(worker, :start, %{"assignment" => token, "input" => input, "sealed_keys" => sealed})
       when is_binary(token) and is_binary(input) and is_binary(sealed) do
    case worker.start(token, input, sealed) do
      :ok -> WorkerWire.ok(true)
      {:error, refusal} -> WorkerWire.error(refusal)
    end
  end

  defp run(worker, :kill, %{"execution_id" => execution_id}) when is_binary(execution_id) do
    case worker.kill(execution_id) do
      :ok -> WorkerWire.ok(true)
      {:error, refusal} -> WorkerWire.error(refusal)
    end
  end

  defp run(worker, :status, args) when map_size(args) == 0 do
    {:ok, status} = worker.status()
    WorkerWire.ok(status)
  end

  # Args that are not the callback's are no request of it.
  defp run(_worker, _callback, _args), do: :malformed

  defp dispatch_key(service) do
    {:ok, worker_key} = Keys.worker_key(service)
    WorkerAuth.dispatch_key(worker_key)
  end
end
