# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# Loaded by each integration test under `apps/cyfr/test/integration/opus`
# through `Code.require_file/2`, once.
unless Code.ensure_loaded?(Cyfr.Test.Integration.Opus) do
  defmodule Cyfr.Test.Integration.Opus.HostBridge do
    @moduledoc """
    CYFR's host API served over HTTP for the integration suite: the routes
    `Cyfr.WorkerWire` names, answered by the in-process
    `Cyfr.Execution.Host`. A host call's header is verified and its sealed
    body opened as CYFR's listener does, the call is answered by
    `Cyfr.Execution.Host.call/2`, and the answer is sealed back to the
    same call; a worker service's report is plain and goes to
    `Cyfr.Execution.Host.runner_exited/2` as it is.
    """

    @behaviour Plug

    import Plug.Conn

    alias Cyfr.Execution.{Host, Keys}
    alias Cyfr.{WorkerAuth, WorkerWire}

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn, length: Cyfr.HostAPI.max_body_bytes() * 4)
      header = conn |> get_req_header(WorkerWire.auth_header()) |> List.first()

      case WorkerWire.host_callback(conn.request_path) do
        {:ok, :runner_exited} ->
          json(conn, 200, Host.runner_exited(header || "", body))

        {:ok, _callback} ->
          case open(header, body) do
            {:ok, fields, keys, plain} ->
              {:ok, resigned} = WorkerAuth.host_call_header(keys.call, fields, plain)
              answer = Host.call(resigned, plain)
              {:ok, sealed} = WorkerAuth.seal_call(keys.seal, :answer, fields, answer)
              json(conn, 200, sealed)

            {:error, _reason} ->
              json(conn, 401, Jason.encode!(WorkerWire.error(:lost)))
          end

        :error ->
          json(conn, 404, Jason.encode!(WorkerWire.error(:not_found)))
      end
    end

    defp open(header, sealed) when is_binary(header) do
      now = System.system_time(:millisecond)

      with {:ok, generation} <- Keys.generation(),
           {:ok, fields, body_hash} <-
             WorkerAuth.verify_host_call_header(Keys.root(), header, now, generation),
           :ok <- WorkerAuth.verify_body(body_hash, sealed),
           {:ok, keys} <- Keys.attempt_keys(fields),
           {:ok, plain} <- WorkerAuth.open_call(keys.seal, :body, fields, sealed) do
        {:ok, fields, keys, plain}
      end
    end

    defp open(_header, _sealed), do: {:error, :malformed}

    defp json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body)
    end
  end

  defmodule Cyfr.Test.Integration.Opus do
    @moduledoc """
    The running Opus worker service for the integration suite, reached as
    CYFR reaches it: over HTTP.

    `ensure_started!/0` serves the host bridge
    (`Cyfr.Test.Integration.Opus.HostBridge`) on a loopback port, gives
    Opus the credentials CYFR derives for the configured worker service
    and that bridge's URL, starts the `:opus` application and serves its
    worker listener (`Opus.WorkerListener`) on another loopback port. Both
    servers live for the suite. `start!/3` posts a `start` request to the
    listener signed as CYFR signs it.
    """

    alias Cyfr.Execution.Keys
    alias Cyfr.{WorkerAuth, WorkerWire}

    @service "wrk_local"

    @doc "Start the bridge, Opus and its listener once; answers `:ok`."
    @spec ensure_started!() :: :ok
    def ensure_started! do
      :global.trans({__MODULE__, :start}, fn ->
        if :persistent_term.get({__MODULE__, :urls}, nil) == nil do
          bridge = serve!(Cyfr.Test.Integration.Opus.HostBridge)
          {:ok, worker_key} = Keys.worker_key(@service)

          Application.put_env(:opus, :service_id, @service)
          Application.put_env(:opus, :service_key, Base.encode16(worker_key, case: :lower))
          Application.put_env(:opus, :host_url, bridge)
          Application.put_env(:opus, :bind, "127.0.0.1")
          Application.put_env(:opus, :port, 0)

          # The umbrella started Opus with its test defaults; the service
          # reloads its credentials when it restarts.
          case Application.ensure_all_started(:opus) do
            {:ok, []} ->
              :ok = Supervisor.terminate_child(Opus.Supervisor, Opus.WorkerService.Tree)
              {:ok, _pid} = Supervisor.restart_child(Opus.Supervisor, Opus.WorkerService.Tree)

            {:ok, _started} ->
              :ok
          end

          worker = serve!(Opus.WorkerListener)
          :persistent_term.put({__MODULE__, :urls}, %{host: bridge, worker: worker})
        end

        :ok
      end)
    end

    @doc "The bridge's URL: where Opus reaches CYFR's host API."
    @spec host_url() :: String.t()
    def host_url, do: urls().host

    @doc "The worker listener's URL: where CYFR reaches Opus."
    @spec worker_url() :: String.t()
    def worker_url, do: urls().worker

    @doc "The configured worker service's id."
    @spec service() :: String.t()
    def service, do: @service

    @doc """
    Post a worker request of `callback` with `args` to Opus's listener,
    signed with the service's dispatch key for `boot` (default the running
    service's). Answers the HTTP status and the decoded answer.
    """
    @spec request!(atom(), map(), keyword()) :: {non_neg_integer(), map()}
    def request!(callback, args, opts \\ []) do
      {:ok, worker_key} = Keys.worker_key(@service)

      boot =
        Keyword.get_lazy(opts, :boot, fn ->
          {:ok, %{boot: boot}} = Opus.WorkerService.status()
          boot
        end)

      body = Jason.encode!(WorkerWire.request_body(callback, args))

      request = %{
        service: @service,
        boot: boot,
        ts: System.system_time(:millisecond),
        nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      }

      {:ok, header} = WorkerAuth.request_header(WorkerAuth.dispatch_key(worker_key), request, body)

      {:ok, %Req.Response{status: status, body: answer}} =
        Req.post(worker_url() <> WorkerWire.worker_route(callback),
          headers: [{WorkerWire.auth_header(), header}],
          body: body,
          retry: false,
          decode_body: false
        )

      {status, Jason.decode!(answer)}
    end

    @doc "Start `assignment` on Opus over the wire: the `start` request as CYFR sends it."
    @spec start!(String.t(), String.t(), String.t()) :: :ok | {:error, :malformed}
    def start!(assignment, input, sealed_keys) do
      case request!(:start, %{
             "assignment" => assignment,
             "input" => input,
             "sealed_keys" => sealed_keys
           }) do
        {200, %{"ok" => true}} -> :ok
        {200, %{"error" => "malformed"}} -> {:error, :malformed}
      end
    end

    defp urls do
      ensure_started!()
      :persistent_term.get({__MODULE__, :urls})
    end

    # A server that lives for the suite: started under a process of its
    # own, which nothing stops.
    defp serve!(plug) do
      parent = self()

      spawn(fn ->
        {:ok, server} = Bandit.start_link(plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
        {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
        send(parent, {:served, plug, port})

        receive do
          :stop -> :ok
        end
      end)

      receive do
        {:served, ^plug, port} -> "http://127.0.0.1:#{port}"
      after
        10_000 -> raise "#{inspect(plug)} did not start"
      end
    end
  end
end
