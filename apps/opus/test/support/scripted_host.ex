# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Test.ScriptedHost do
  @moduledoc """
  CYFR's host API as a test scripts it, served on a loopback port: the
  routes `Cyfr.WorkerWire` names, each request verified as CYFR verifies
  it (`Cyfr.WorkerAuth.verify_host_call/5` for a runner's call, whose
  sealed body is then opened and whose answer is sealed back;
  `Cyfr.WorkerAuth.verify_report/4` for a worker service's plain report)
  under a root of the test's choosing, and answered from the test's script.

  `start!/1` serves one host for the calling test and answers where it is.
  `attempt!/2` mints an attempt on it as CYFR would — its keys, a signed
  assignment, the keys sealed for the worker service — and the
  `Opus.HostClient` a runner of that attempt holds. `script/3` sets what
  an operation answers: one answer for every call, a list consumed in
  order, or a function of the call's args and verified header. An
  operation with no script answers a harmless default. `requests/1` is
  every request the host saw, verified or refused, oldest first.

  An answer is `{:ok, value}`, `{:error, name}`, a guest error, a
  `setup_required` or `failed` refusal as `Opus.HostClient` reads them, or
  `:drop`, which answers nothing readable — a lost answer.

  The default root is the one `test_helper.exs` derives the running worker
  service's key from, so a host started with it verifies that service's
  reports; a host started with another root is a stranger to it.
  """

  alias Cyfr.{Assignment, WorkerAuth, WorkerWire}

  @root :crypto.hash(:sha256, "opus-test-root")
  @service "wrk_local"
  @generation 1

  @type t :: %{
          url: String.t(),
          root: binary(),
          generation: pos_integer(),
          service: String.t(),
          agent: pid()
        }

  @doc "The root the running worker service's key derives from."
  @spec root() :: binary()
  def root, do: @root

  @doc "The service id the running worker service is configured with."
  @spec service() :: String.t()
  def service, do: @service

  @doc """
  Serve a scripted host for the calling test, stopped when the test ends.
  Options: `:root` (default `root/0`), `:generation` (default 1),
  `:service` (default `service/0`), `:script` (a map of operation name to
  answers, as `script/3` takes them).
  """
  @spec start!(keyword()) :: t()
  def start!(opts \\ []) do
    root = Keyword.get(opts, :root, @root)
    generation = Keyword.get(opts, :generation, @generation)
    service = Keyword.get(opts, :service, @service)
    unique = System.unique_integer([:positive])

    agent =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Agent,
           fn ->
             %{
               root: root,
               generation: generation,
               script: Keyword.get(opts, :script, %{}),
               requests: []
             }
           end},
          id: {__MODULE__.Agent, unique}
        )
      )

    server =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: {__MODULE__.Plug, agent}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: {__MODULE__.Server, unique}
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    %{
      url: "http://127.0.0.1:#{port}",
      root: root,
      generation: generation,
      service: service,
      agent: agent
    }
  end

  @doc """
  Point the running worker service at this host, restarting it (a new
  boot), and point it back when the test ends. Answers the service's new
  boot id. For a sync test only: the service is one.
  """
  @spec serve!(t()) :: String.t()
  def serve!(%{url: url}) do
    previous = Application.get_env(:opus, :host_url)
    Application.put_env(:opus, :host_url, url)
    restart_service!()

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:opus, :host_url, previous)
      restart_service!()
    end)

    {:ok, %{boot: boot}} = Opus.WorkerService.status()
    boot
  end

  @doc "Restart the running worker service and its runners: a new boot that holds no attempt."
  @spec restart_service!() :: :ok
  def restart_service! do
    :ok = Supervisor.terminate_child(Opus.Supervisor, Opus.WorkerService.Tree)
    {:ok, _pid} = Supervisor.restart_child(Opus.Supervisor, Opus.WorkerService.Tree)
    :ok
  end

  @doc "Set what `op` answers (`answers`: one answer, a list in order, or a function of args and caller)."
  @spec script(t(), String.t(), term()) :: :ok
  def script(%{agent: agent}, op, answers) when is_binary(op) do
    Agent.update(agent, &put_in(&1, [:script, op], answers))
  end

  @doc "Every request the host saw, oldest first: `%{op, args, caller, header, body}` (the body opened) or `{:refused, op, reason}`."
  @spec requests(t()) :: [map() | {:refused, String.t(), atom()}]
  def requests(%{agent: agent}), do: agent |> Agent.get(& &1.requests) |> Enum.reverse()

  @doc "The verified requests of `op`, oldest first."
  @spec requests(t(), String.t()) :: [map()]
  def requests(host, op), do: for(%{op: ^op} = request <- requests(host), do: request)

  @doc """
  An attempt on this host, as CYFR mints one: its fields, its keys
  (`Cyfr.WorkerAuth.attempt_keys/2`), a signed assignment (`:assignment`),
  the keys sealed for the worker service (`:sealed_keys`), the input JSON
  the assignment's digest binds (`:input`) and the `:client` a runner of
  it holds. Options: `:boot` (default `"boot_test"`), `:runner` (default a
  fresh id), `:service` (default the host's), `:component_type` (default
  `:catalyst`), `:component_ref`, `:digest`, `:input` (default
  `%{"fixture" => true}`), `:authority` (default `Cyfr.Authority.zero/0`),
  `:timeout_ms` (default 60 s), `:intercepted` (default `[]`).
  """
  @spec attempt!(t(), keyword()) :: map()
  def attempt!(host, opts \\ []) do
    now = System.system_time(:millisecond)
    service = Keyword.get(opts, :service, host.service)
    boot = Keyword.get(opts, :boot, "boot_test")
    runner = Keyword.get(opts, :runner, Cyfr.UUID7.generate_id("runner"))
    component_type = Keyword.get(opts, :component_type, :catalyst)

    component_ref =
      Keyword.get_lazy(opts, :component_ref, fn ->
        "#{component_type}:local.fixture-#{System.unique_integer([:positive])}:0.1.0"
      end)

    digest = Keyword.get_lazy(opts, :digest, fn -> Cyfr.Digest.sha256(component_ref) end)
    input = Keyword.get(opts, :input, %{"fixture" => true})
    input_json = Jason.encode!(input)
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    execution_id = Cyfr.UUID7.execution_id()

    attempt = %{
      athanor_id: "ath_test",
      execution_id: execution_id,
      attempt: Cyfr.UUID7.generate_id("att"),
      fence: 1,
      generation: host.generation,
      service: service
    }

    assignment = %Assignment{
      generation: host.generation,
      service: service,
      boot: boot,
      issued_at: now,
      claim_by: now + Assignment.claim_window_ms(),
      execution_id: execution_id,
      attempt: attempt.attempt,
      fence: 1,
      root_execution_id: execution_id,
      athanor_id: attempt.athanor_id,
      actor: %Cyfr.Actor{},
      authority: Cyfr.Authority.to_wire(Keyword.get(opts, :authority, Cyfr.Authority.zero())),
      component: %{
        ref: component_ref,
        type: Atom.to_string(component_type),
        digest: digest,
        declared_needs: [],
        activation_digest: nil
      },
      input_digest: Cyfr.Digest.sha256(input_json),
      timeout_ms: timeout_ms,
      deadline: now + timeout_ms,
      lease_until: now + 60_000,
      intercepted: Keyword.get(opts, :intercepted, [])
    }

    {:ok, keys} = WorkerAuth.attempt_keys(host.root, attempt)
    {:ok, token} = Assignment.sign(assignment, WorkerAuth.assign_key(host.root))
    {:ok, worker_key} = WorkerAuth.worker_key(host.root, service)
    {:ok, sealed} = WorkerAuth.seal_attempt_keys(WorkerAuth.dispatch_seal_key(worker_key), keys)

    Map.merge(attempt, %{
      boot: boot,
      runner: runner,
      keys: keys,
      assignment: token,
      sealed_keys: sealed,
      input: input_json,
      component_ref: component_ref,
      digest: digest,
      client: Opus.HostClient.new(keys, runner, boot, host.url)
    })
  end

  @doc "The dispatch key of `service` under this host's root, which signs requests to that service."
  @spec dispatch_key(t(), String.t()) :: binary()
  def dispatch_key(host, service \\ nil) do
    {:ok, worker_key} = WorkerAuth.worker_key(host.root, service || host.service)
    WorkerAuth.dispatch_key(worker_key)
  end

  @doc false
  # What the host answers for a verified request with no script: enough
  # for a runner to attach, renew, emit and close.
  def default(op, args, _caller)

  def default("attach", _args, _caller), do: {:ok, %{}}

  def default("renew", %{"attempts" => attempts}, _caller) do
    until = System.system_time(:millisecond) + 60_000
    {:ok, Map.new(attempts, &{&1, %{"lease_until" => until}})}
  end

  def default("push_deltas", %{"deltas" => deltas}, _caller),
    do: {:ok, Enum.map(deltas, fn _ -> Jason.encode!(%{"ok" => true}) end)}

  def default("complete", %{"outcome" => %{"output" => output}}, _caller), do: {:ok, output}
  def default("fail", %{"outcome" => %{"error" => error}}, _caller), do: {:ok, error}
  def default("take_rate", _args, _caller), do: {:ok, true}
  def default("record_denial", _args, _caller), do: {:ok, true}
  def default("release_child", _args, _caller), do: {:ok, true}
  def default("runner_exited", _args, _caller), do: {:ok, true}
  def default("fetch_artifact", _args, _caller), do: {:error, :not_found}

  def default(_op, _args, _caller),
    do: {:error, {:guest_error, "dispatch_error", "The scripted host has no answer for this call."}}

  @doc false
  # The wire answer for a scripted answer.
  def encode({:ok, value}), do: WorkerWire.ok(value)

  def encode({:error, {:guest_error, type, message}}),
    do: WorkerWire.error(:guest_error, %{"type" => type, "message" => message})

  def encode({:error, {:guest_error, type, message, remediation}}),
    do:
      WorkerWire.error(:guest_error, %{
        "type" => type,
        "message" => message,
        "remediation" => remediation
      })

  def encode({:error, {:setup_required, payload}}),
    do: WorkerWire.error(:setup_required, %{"payload" => payload})

  def encode({:error, {:failed, message}}), do: WorkerWire.error(:failed, %{"message" => message})
  def encode({:error, name}) when is_atom(name), do: WorkerWire.error(name)

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    import Elixir.Plug.Conn

    alias Opus.Test.ScriptedHost

    @impl true
    def init(agent), do: agent

    @impl true
    def call(conn, agent) do
      {:ok, body, conn} = read_body(conn, length: 50_000_000)
      header = conn |> get_req_header(WorkerWire.auth_header()) |> List.first()
      now = System.system_time(:millisecond)
      %{root: root, generation: generation} = Agent.get(agent, & &1)

      case WorkerWire.host_callback(conn.request_path) do
        {:ok, callback} ->
          op = Atom.to_string(callback)

          case verify(callback, root, generation, header, body, now) do
            {:ok, caller, plain, seal} ->
              args = args(plain, callback)
              request = %{op: op, args: args, caller: caller, header: header, body: plain}
              Agent.update(agent, &%{&1 | requests: [request | &1.requests]})
              answer(conn, agent, op, args, caller, seal)

            {:error, reason} ->
              Agent.update(agent, &%{&1 | requests: [{:refused, op, reason} | &1.requests]})
              json(conn, 401, ScriptedHost.encode({:error, :lost}), nil)
          end

        :error ->
          json(conn, 404, ScriptedHost.encode({:error, :not_found}), nil)
      end
    end

    # A report is plain; a host call's body opens under the attempt's seal
    # key as the call the header names, and its answer seals the same way.
    defp verify(:runner_exited, root, _generation, header, body, now) do
      with {:ok, report} <- WorkerAuth.verify_report(root, header, body, now),
           do: {:ok, report, body, nil}
    end

    defp verify(_callback, root, generation, header, sealed, now) do
      with {:ok, caller} <- WorkerAuth.verify_host_call(root, header, sealed, now, generation),
           {:ok, seal} <- WorkerAuth.attempt_seal_key(root, caller),
           {:ok, plain} <- WorkerAuth.open_call(seal, :body, caller, sealed) do
        {:ok, caller, plain, {seal, caller}}
      end
    end

    defp args(body, callback) do
      op = Atom.to_string(callback)

      case Jason.decode(body) do
        {:ok, %{"op" => ^op, "args" => %{} = args}} -> args
        _ -> :malformed
      end
    end

    defp answer(conn, agent, op, args, caller, seal) do
      scripted =
        Agent.get_and_update(agent, fn state ->
          case Map.get(state.script, op) do
            nil -> {:default, state}
            [] -> {{:error, :lost}, state}
            [next | rest] -> {next, put_in(state, [:script, op], rest)}
            fun when is_function(fun, 2) -> {fun.(args, caller), state}
            answer -> {answer, state}
          end
        end)

      case scripted do
        :default ->
          json(conn, 200, ScriptedHost.encode(ScriptedHost.default(op, args, caller)), seal)

        :drop ->
          send_resp(conn, 500, "")

        {:raw, status, body} ->
          send_resp(conn, status, body)

        answer ->
          json(conn, 200, ScriptedHost.encode(answer), seal)
      end
    end

    defp json(conn, status, answer, seal) do
      encoded = Jason.encode!(answer)

      body =
        case seal do
          {key, caller} ->
            {:ok, sealed} = WorkerAuth.seal_call(key, :answer, caller, encoded)
            sealed

          nil ->
            encoded
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body)
    end
  end
end
