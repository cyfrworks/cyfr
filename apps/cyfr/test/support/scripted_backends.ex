# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ScriptedBackends do
  @moduledoc """
  A Locus backends service whose owners answer from a script instead of
  running backends, as `Cyfr.Test.ScriptedBuilder` stands in for a builds
  service. Test-only; its users are `async: false`, since the controller it
  answers is one named process.

  Everything but the backends is the wire's (`Prima.LocusBackends`). It is
  served by Bypass on a loopback port (`url`), at the wire's `control` and
  `mcp` routes. A control message's `x-cyfr-auth` header is verified under
  the control key, its lifetime and its `(generation, seq)` against the
  high-water mark, and its body read strictly (`read_control/1`); an
  invoke's header is verified under the key of the owner it names, and its
  lifetime and owner version against what runs. Every answer carries
  `x-cyfr-boot`, every control answer the protocol version, and every
  refusal is `encode_refusal/1` at its code's status. Each accepted message
  is reported to the test as `{:control, type, message, fields}`, the
  message as its JSON, and each invoke as `{:invoke, method, fields}`.

  Each owner runs and lists the tools the test sets for its server
  (running, rev 1 and `github__search` unless set), and reports
  `stderr_bytes` of stderr tail per backend in a status (none unless set):
  the script does not bound its answers, so a test can see what the
  controller makes of an unbounded one. `answer_version` is the protocol
  version its control answers name (the wire's unless set).
  """

  import Plug.Conn

  alias Prima.LocusBackends

  @doc "Start the service for the calling test, reporting to `test` and keyed by `root`."
  def start(test, root) do
    bypass = Bypass.open()

    # Supervised by the test before the controller is, so it answers until
    # the controller has stopped.
    agent =
      ExUnit.Callbacks.start_supervised!(
        {Agent,
         fn ->
           %{
             test: test,
             root: root,
             boot: "bb_first",
             hwm: {0, 0},
             owners: %{},
             readiness: %{},
             tools: %{},
             hold: MapSet.new(),
             pool: 32,
             stderr_bytes: 0,
             answer_version: LocusBackends.version(),
             refuse: %{}
           }
         end},
        id: :scripted_backends
      )

    Bypass.stub(
      bypass,
      "POST",
      LocusBackends.route(:control),
      &serve(&1, fn conn -> control(conn, agent) end)
    )

    Bypass.stub(
      bypass,
      "POST",
      LocusBackends.route(:mcp),
      &serve(&1, fn conn -> invoke(conn, agent) end)
    )

    %{bypass: bypass, agent: agent, url: "http://127.0.0.1:#{bypass.port}"}
  end

  # Once the script runs a request it traps exits, so a request whose client
  # goes away mid-way (a controller that crashes while the script holds its
  # sync) still runs to its answer, 503 if the script's state is gone. A
  # request cut off before that, or while its body is read, ends with its
  # connection and Bypass fails the test for it, so no test ends with a
  # message of the controller's in flight.
  defp serve(conn, handler) do
    Process.flag(:trap_exit, true)
    handler.(conn)
  catch
    :exit, _reason -> resp(conn, 503, "")
  end

  @doc "A new lifetime: every owner forgotten and the high-water mark reset, as a restarted service."
  def restart(%{agent: agent}, boot),
    do: Agent.update(agent, &%{&1 | boot: boot, hwm: {0, 0}, owners: %{}})

  @doc """
  Refuse the next message of `what` (a control type, or an invoke's method)
  with `code`, at its status unless `status` names another.
  """
  def refuse_once(%{agent: agent}, what, code, status \\ nil) do
    status = status || LocusBackends.status(String.to_existing_atom(code))
    Agent.update(agent, &put_in(&1, [:refuse, what], {code, status}))
  end

  def set(%{agent: agent}, key, value), do: Agent.update(agent, &Map.put(&1, key, value))
  def get(%{agent: agent}, key), do: Agent.get(agent, &Map.fetch!(&1, key))

  @doc "What the owner of `server` reports: its state and rev."
  def readiness(%{agent: agent}, server, state, rev),
    do: Agent.update(agent, &put_in(&1, [:readiness, server], %{state: state, rev: rev}))

  @doc "The tool names the owner of `server` lists."
  def tools(%{agent: agent}, server, names),
    do: Agent.update(agent, &put_in(&1, [:tools, server], names))

  @doc "Hold the next message of `type` until the test sends `:go` to the pid it reports."
  def hold(%{agent: agent}, type),
    do: Agent.update(agent, &%{&1 | hold: MapSet.put(&1.hold, type)})

  defp control(conn, agent) do
    {:ok, body, conn} = read_body(conn)
    st = Agent.get(agent, & &1)
    header = get_req_header(conn, LocusBackends.auth_header())

    with [header] <- header,
         {:ok, fields} <-
           LocusBackends.verify(:control, st.root, header, body, System.os_time(:millisecond)) do
      case LocusBackends.read_control(body) do
        {:ok, %{type: type}} -> accepted(conn, agent, st, type, Jason.decode!(body), fields)
        {:error, error} -> refuse(conn, st, LocusBackends.refusal_for(error))
      end
    else
      _unauthenticated -> refuse(conn, st, :unauthorized)
    end
  end

  defp accepted(conn, agent, st, type, message, fields) do
    cond do
      fields.boot != if(type == :hello, do: "-", else: st.boot) ->
        refuse(conn, st, :stale_boot)

      {fields.generation, fields.seq} <= st.hwm ->
        refuse(conn, st, :stale_control)

      true ->
        Agent.update(agent, &%{&1 | hwm: {fields.generation, fields.seq}})
        send(st.test, {:control, message["type"], message, fields})
        held(agent, message["type"])

        case pop_refusal(agent, message["type"]) do
          nil -> handle(conn, agent, message, fields)
          {code, status} -> answer(conn, st, status, %{"version" => 1, "error" => code})
        end
    end
  end

  defp held(agent, type) do
    st = Agent.get(agent, & &1)

    if MapSet.member?(st.hold, type) do
      Agent.update(agent, &%{&1 | hold: MapSet.delete(&1.hold, type)})
      send(st.test, {:held, type, self()})

      receive do
        :go -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  defp readiness_of(st, server), do: Map.get(st.readiness, server, %{state: "running", rev: 1})

  defp handle(conn, agent, %{"type" => "hello"}, _fields) do
    st = Agent.get(agent, & &1)

    control_answer(conn, st, %{
      "boot" => st.boot,
      "pool" => %{"size" => st.pool, "free" => st.pool}
    })
  end

  defp handle(conn, agent, %{"type" => "reconcile", "keep" => keep}, fields) do
    kept =
      for %{"athanor" => a, "server" => s, "e" => e} <- keep,
          do: {{a, s}, {fields.generation, e}}

    Agent.update(agent, fn st ->
      %{st | owners: Map.filter(st.owners, fn owner -> owner in kept end)}
    end)

    control_answer(conn, Agent.get(agent, & &1), %{"released" => []})
  end

  defp handle(conn, agent, %{"type" => "sync"} = message, fields) do
    st = Agent.get(agent, & &1)
    %{"owner" => %{"athanor" => athanor, "server" => server}, "e" => e} = message

    owner = %{athanor: athanor, server: server, generation: fields.generation, epoch: e}

    {:ok, plaintext} =
      LocusBackends.open(LocusBackends.seal_key(st.root), owner, st.boot, message["sealed"])

    send(st.test, {:sealed_env, server, Jason.decode!(plaintext)})

    Agent.update(agent, &put_in(&1, [:owners, {athanor, server}], {fields.generation, e}))
    %{state: state, rev: rev} = readiness_of(st, server)

    backends =
      for backend <- message["backends"],
          do: %{"name" => backend["name"], "status" => "ready", "tools" => 1}

    control_answer(conn, st, %{"status" => state, "rev" => rev, "backends" => backends})
  end

  defp handle(conn, agent, %{"type" => "renew", "owners" => owners}, fields) do
    st = Agent.get(agent, & &1)

    {renewed, unknown} =
      Enum.split_with(owners, fn %{"athanor" => a, "server" => s, "e" => e} ->
        Map.get(st.owners, {a, s}) == {fields.generation, e}
      end)

    renewed =
      for %{"server" => server} = owner <- renewed do
        %{state: state, rev: rev} = readiness_of(st, server)
        Map.merge(owner, %{"state" => state, "rev" => rev})
      end

    control_answer(conn, st, %{"renewed" => renewed, "unknown" => unknown})
  end

  defp handle(conn, agent, %{"type" => "release", "owners" => owners}, fields) do
    released =
      for %{"athanor" => a, "server" => s, "e" => e} <- owners,
          version = Agent.get(agent, &Map.get(&1.owners, {a, s})),
          version != nil and version <= {fields.generation, e},
          do: %{"athanor" => a, "server" => s, "g" => elem(version, 0), "e" => elem(version, 1)}

    Agent.update(agent, fn st ->
      %{st | owners: Map.drop(st.owners, Enum.map(released, &{&1["athanor"], &1["server"]}))}
    end)

    control_answer(conn, Agent.get(agent, & &1), %{"released" => released})
  end

  defp handle(conn, agent, %{"type" => "status", "owners" => named}, _fields) do
    st = Agent.get(agent, & &1)

    owners =
      for owner <- named,
          {g, e} <- List.wrap(Map.get(st.owners, {owner["athanor"], owner["server"]})) do
        %{state: state, rev: rev} = readiness_of(st, owner["server"])

        Map.merge(owner, %{
          "g" => g,
          "e" => e,
          "state" => state,
          "rev" => rev,
          "lease_ms_left" => 30_000,
          "backends" => [
            %{
              "name" => "github",
              "status" => "ready",
              "restarts" => 0,
              "tools" => 1,
              "error" => nil,
              "stderr_tail" => String.duplicate("x", st.stderr_bytes)
            }
          ]
        })
      end

    control_answer(conn, st, %{"owners" => owners})
  end

  defp invoke(conn, agent) do
    {:ok, body, conn} = read_body(conn)
    st = Agent.get(agent, & &1)
    [header] = get_req_header(conn, LocusBackends.auth_header())
    message = Jason.decode!(body)

    case LocusBackends.verify(:invoke, st.root, header, body, System.os_time(:millisecond)) do
      {:ok, fields} ->
        invoked(conn, agent, st, fields, message)

      {:error, _refused} ->
        error = %{"code" => -33_001, "message" => "unauthorized"}
        answer(conn, st, 401, %{"jsonrpc" => "2.0", "id" => nil, "error" => error})
    end
  end

  defp invoked(conn, agent, st, fields, message) do
    running = Map.get(st.owners, {fields.athanor, fields.server})
    version = {fields.generation, fields.epoch}

    cond do
      fields.boot != st.boot ->
        refuse(conn, st, :stale_boot)

      running == nil ->
        refuse(conn, st, :unknown_owner)

      version < running ->
        refuse(conn, st, :stale_epoch)

      version > running ->
        refuse(conn, st, :epoch_ahead)

      refusal = pop_refusal(agent, message["method"]) ->
        {code, status} = refusal
        send(st.test, {:invoke, message["method"], fields})
        answer(conn, st, status, %{"version" => 1, "error" => code})

      true ->
        send(st.test, {:invoke, message["method"], fields})

        answer(conn, st, 200, %{
          "jsonrpc" => "2.0",
          "id" => message["id"],
          "result" => result(st, fields.server, message)
        })
    end
  end

  defp result(st, server, %{"method" => "tools/list"}) do
    names = Map.get(st.tools, server, ["github__search"])

    %{
      "tools" => for(name <- names, do: %{"name" => name, "inputSchema" => %{"type" => "object"}})
    }
  end

  defp result(_st, _server, %{"method" => "tools/call"}),
    do: %{"content" => [%{"type" => "text", "text" => "found"}]}

  defp pop_refusal(agent, what) do
    Agent.get_and_update(agent, fn st ->
      {Map.get(st.refuse, what), %{st | refuse: Map.delete(st.refuse, what)}}
    end)
  end

  defp refuse(conn, st, code),
    do: answer(conn, st, LocusBackends.status(code), LocusBackends.encode_refusal(code))

  # Encoded here and not through `encode_answer/2`: the script answers
  # whatever it is set to, bounded or not, at the version it is set to.
  defp control_answer(conn, st, body),
    do: answer(conn, st, 200, Map.put(body, "version", st.answer_version))

  defp answer(conn, st, status, body) when is_map(body),
    do: answer(conn, st, status, Jason.encode!(body))

  defp answer(conn, st, status, body) when is_binary(body) do
    conn
    |> put_resp_header(LocusBackends.boot_header(), st.boot)
    |> put_resp_content_type("application/json")
    |> resp(status, body)
  end
end
