# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.OpusService do
  @moduledoc """
  The Opus worker service of the test boot, reached as CYFR reaches it and
  reaching CYFR as it does: over HTTP, through the listeners the boot
  starts on ports of the system's choosing. Its runners are OS processes
  of their own (the `Direct` keeper, `config/test.exs`), pooled and reused
  across tests.

  The umbrella starts CYFR's host API listener (`Crucible.HostListener`,
  port 0 under `config/test.exs`) and the Opus application, whose listener
  (`Opus.WorkerListener`) also binds port 0. Neither knows the other's port
  until both are up, so `wire!/1`, run once by `test_helper.exs` and by the
  step bench, gives the service `wrk_local` its credentials — the key CYFR
  derives for it and where its runners reach CYFR — restarting it when they
  are not the ones it holds, and puts the service's endpoint in
  `config :cyfr, :workers`, where `Crucible.Dispatch` finds it. For
  the suite, the runners reach the host listener through the suite's wire
  (`Cyfr.Test.TwoServices.Wire`), which a test watches, holds a call on or
  loses a call on without restarting the service; the bench run alone
  (`mix cyfr.bench.step`) reaches it directly. A test that replaces `:workers` restores what it found.

  `status/0` and `boot/0` ask the service over the wire, `request!/3` and
  `start!/3` post a `Prima.WorkerAPI` request to the service's listener
  signed as CYFR signs it, and `restart!/0` restarts the service, a new boot
  holding no attempt and a pool refilled from nothing, as an operator's
  restart does.
  """

  alias Crucible.{HostListener, Keys, WorkerClient}
  alias Cyfr.Test.TwoServices
  alias Prima.{WorkerAPI, WorkerAuth, WorkerWire}

  # The service is a sibling application, not a dependency: CYFR names it
  # here as the suite's, never in its own code.
  @compile {:no_warn_undefined, [Opus.Credentials]}

  @service "wrk_local"

  @doc "The configured worker service's id."
  @spec service() :: String.t()
  def service, do: @service

  @doc """
  Point Opus at the running host listener — through the suite's wire
  unless `proxy: false` — and CYFR at Opus's listener. Answers the
  service's endpoint (`t:Prima.WorkerAPI.endpoint/0`).
  """
  @spec wire!(keyword()) :: Prima.WorkerAPI.endpoint()
  def wire!(opts \\ []) do
    unless Process.whereis(Opus.Supervisor),
      do: raise("the Opus worker service is not running: run the suite from the umbrella root")

    {:ok, worker_key} = Keys.worker_key(@service)

    reached =
      if Keyword.get(opts, :proxy, true),
        do: TwoServices.serve_wire!(host_url()).url,
        else: host_url()

    # Everything the service's credentials are read from, spelled here so
    # the suite does not depend on what another suite in this VM (Opus's
    # own, which serves a scripted host) left in the application env.
    env = [
      service_id: @service,
      service_key: Base.encode16(worker_key, case: :lower),
      host_url: reached,
      bind: "127.0.0.1",
      port: 0
    ]

    if Enum.any?(env, fn {key, value} -> Application.get_env(:opus, key) != value end) or
         Opus.Credentials.current() == nil do
      Application.put_all_env(opus: env)
      restart!()
    end

    endpoint = endpoint()
    Application.put_env(:cyfr, :workers, [endpoint])
    endpoint
  end

  @doc "The base URL of CYFR's host API listener, where the suite's wire forwards."
  @spec host_url() :: String.t()
  def host_url do
    {_id, listener, _type, _modules} =
      Cyfr.InfraSupervisor |> Supervisor.which_children() |> List.keyfind(HostListener, 0)

    "http://127.0.0.1:#{HostListener.port(listener)}"
  end

  @doc "The base URL of Opus's listener: where CYFR posts its requests."
  @spec url() :: String.t()
  def url do
    {_id, server, _type, _modules} =
      Opus.Supervisor |> Supervisor.which_children() |> List.keyfind(Opus.WorkerListener, 0)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  @doc "The service's endpoint entry, running any component."
  @spec endpoint() :: Prima.WorkerAPI.endpoint()
  def endpoint, do: %{id: @service, url: url(), components: nil}

  @doc "The service's status, asked over the wire by CYFR's own client."
  @spec status() :: WorkerAPI.status()
  def status do
    {:ok, status} = WorkerClient.status(endpoint())
    status
  end

  @doc "The boot id the running service answers."
  @spec boot() :: String.t()
  def boot, do: status().boot

  @doc """
  Restart the worker service and its runners: a new boot that holds no
  attempt, reloads its credentials and fills its pool from nothing.
  Answers the new boot id. For a sync test only: the service is one.
  """
  @spec restart!() :: String.t()
  def restart! do
    :ok = Supervisor.terminate_child(Opus.Supervisor, Opus.WorkerService.Tree)
    {:ok, _pid} = Supervisor.restart_child(Opus.Supervisor, Opus.WorkerService.Tree)
    boot()
  end

  @doc """
  Post a worker request of `callback` with `args` to the service's
  listener, signed with its dispatch key for `boot` (default the running
  service's) as this boot. Answers the HTTP status and the decoded answer.
  """
  @spec request!(atom(), map(), keyword()) :: {non_neg_integer(), map()}
  def request!(callback, args, opts \\ []) do
    {:ok, worker_key} = Keys.worker_key(@service)
    body = Jason.encode!(WorkerWire.request_body(callback, args))

    request = %{
      service: @service,
      boot: Keyword.get_lazy(opts, :boot, &boot/0),
      ts: System.system_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    }

    {:ok, header} = WorkerAuth.request_header(WorkerAuth.dispatch_key(worker_key), request, body)

    {:ok, %Req.Response{status: status, body: answer}} =
      Req.post(url() <> WorkerWire.worker_route(callback),
        headers: [{WorkerWire.auth_header(), header}],
        body: body,
        retry: false,
        decode_body: false
      )

    {status, Jason.decode!(answer)}
  end

  @doc "Start `assignment` on the service over the wire: the `start` request as CYFR sends it."
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

  @doc """
  The Bandit servers of the wire between CYFR and Opus — CYFR's host API
  listener, Opus's listener and the suite's wire — whose connection
  processes carry the calls in flight.
  """
  @spec listeners() :: [pid()]
  def listeners do
    host =
      with {_id, listener, _type, _modules} <-
             Cyfr.InfraSupervisor |> Supervisor.which_children() |> List.keyfind(HostListener, 0),
           {_id, server, _type, _modules} <-
             listener |> Supervisor.which_children() |> List.keyfind(:server, 0) do
        [server]
      else
        _ -> []
      end

    opus =
      with pid when is_pid(pid) <- Process.whereis(Opus.Supervisor),
           {_id, server, _type, _modules} <-
             pid |> Supervisor.which_children() |> List.keyfind(Opus.WorkerListener, 0) do
        [server]
      else
        _ -> []
      end

    wire =
      case TwoServices.wire() do
        %{server: server} -> [server]
        nil -> []
      end

    host ++ opus ++ wire
  end
end
