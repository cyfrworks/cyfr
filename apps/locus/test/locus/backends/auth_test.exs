# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.AuthTest do
  @moduledoc """
  The two Locus services on one node, each under its own key, refuse each
  other's signatures both ways, from the shared vectors: every header the
  backends vectors reject (among them the builds key and the builds label,
  either way round) is refused `unauthorized` by the backends service at
  its instant, and every header the builds vectors reject under the
  backends key or label is refused by the builds service with its reason.
  A header one service accepts is no header of the other's.
  """

  # Installs the builds key as the node's and serves both services.
  use ExUnit.Case, async: false

  alias Locus.Backends.{Owners, Service}
  alias Locus.Test.Wire
  alias Prima.BuilderProtocol
  alias Prima.LocusBackends, as: LB

  @fixtures Path.expand("../../../../../tests/fixtures", __DIR__)
  @backends @fixtures |> Path.join("locus_backends.json") |> File.read!() |> Jason.decode!()
  @builds @fixtures |> Path.join("locus_builds.json") |> File.read!() |> Jason.decode!()

  setup do
    # One node's two keys, each the other fixture's cross-service key.
    assert @backends["builds_key_hex"] == @builds["key_hex"]
    assert @builds["backends_key_hex"] == @backends["key_hex"]

    backends_key = Base.decode16!(@backends["key_hex"], case: :lower)
    builds_key = Base.decode16!(@builds["key_hex"], case: :lower)

    Application.put_env(:locus, :request_key, BuilderProtocol.request_key(builds_key))
    on_exit(fn -> Application.delete_env(:locus, :request_key) end)
    :ets.delete_all_objects(Locus.BuilderService.Nonces)
    :ets.delete_all_objects(Service.Nonces)

    {:ok, now} = Agent.start_link(fn -> 0 end)
    clock = fn -> Agent.get(now, & &1) end
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    owners =
      start_supervised!(
        {Owners,
         boot: @backends["sync"]["fields"]["boot"],
         launcher: Locus.DirectLauncher,
         launcher_server: [],
         supervisor: supervisor}
      )

    backends =
      start_supervised!(
        Locus.Backends.listener(
          plug: {Service, owners: owners, key: backends_key, now: clock},
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        ),
        id: :backends
      )

    builds =
      start_supervised!(
        Locus.Application.listener(
          plug: {Locus.BuilderService, now: clock},
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        ),
        id: :builds
      )

    {:ok, {_ip, backends_port}} = ThousandIsland.listener_info(backends)
    {:ok, {_ip, builds_port}} = ThousandIsland.listener_info(builds)
    {:ok, now: now, backends: backends_port, builds: builds_port}
  end

  defp at(%{now: now}, ts), do: Agent.update(now, fn _ -> ts end)

  # The status and body of a backends answer.
  defp post(port, path, body, headers) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

    head = [
      "POST #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: #{byte_size(body)}\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]

    :ok = :gen_tcp.send(socket, [head, body])
    answer = read(socket, "")
    :gen_tcp.close(socket)
    answer
  end

  defp read(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        [status_line | lines] = String.split(head, "\r\n")
        [_version, code | _reason] = String.split(status_line, " ")

        length =
          Enum.find_value(lines, "0", fn line ->
            case String.split(line, ":", parts: 2) do
              [name, value] -> String.downcase(name) == "content-length" && String.trim(value)
              _ -> false
            end
          end)

        {String.to_integer(code), body(socket, rest, String.to_integer(length))}

      [_partial] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 10_000)
        read(socket, buffer <> more)
    end
  end

  defp body(_socket, buffer, length) when byte_size(buffer) >= length,
    do: binary_part(buffer, 0, length)

  defp body(socket, buffer, length) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 10_000)
    body(socket, buffer <> more, length)
  end

  defp assert_backends_unauthorized({status, body}, kind, name) do
    assert status == 401, name

    case kind do
      "control" ->
        assert body == LB.encode_refusal(:unauthorized), name

      "invoke" ->
        assert %{"error" => %{"code" => -33_001, "message" => "unauthorized"}} =
                 Jason.decode!(body),
               name
    end
  end

  test "the backends service refuses every header its vectors reject, the builds ones among them",
       ctx do
    names = Enum.map(@backends["auth_rejected"], & &1["name"])

    for name <- ~w(builds_label builds_key builds_key_backends_label builds_header
                   invoke_builds_owner_key),
        do: assert(name in names, name)

    for %{"name" => name, "kind" => kind, "header" => header, "body" => body} = vector <-
          @backends["auth_rejected"] do
      at(ctx, vector["now"])
      route = if kind == "control", do: "control", else: "mcp"

      ctx.backends
      |> post(@backends["routes"][route], body, [{@backends["auth_header"], header}])
      |> assert_backends_unauthorized(kind, name)
    end
  end

  test "the builds service refuses every header its vectors sign under the backends key or label",
       ctx do
    crossed = Enum.filter(@builds["auth_rejected"], &String.starts_with?(&1["name"], "backends"))

    assert Enum.map(crossed, & &1["name"]) |> Enum.sort() ==
             ~w(backends_key backends_key_builds_label backends_label)

    for %{"name" => name, "header" => header, "body" => body, "refusal" => reason} = vector <-
          crossed do
      at(ctx, vector["now"])

      assert {401, [{:refusal, {:unauthorized, refused}, []}]} =
               Wire.post(ctx.builds, @builds["routes"]["build"], body, [
                 {@builds["auth_header"], header}
               ]),
             name

      assert Atom.to_string(refused) == reason, name
    end
  end

  test "a header one service accepts is no header of the other's", ctx do
    # A backends control message, presented to the builds service.
    status = @backends["status"]
    at(ctx, status["ts"])

    assert {401, [{:refusal, {:unauthorized, :malformed}, []}]} =
             Wire.post(ctx.builds, @builds["routes"]["build"], status["body"], [
               {"x-cyfr-auth", status["header"]}
             ])

    # A backends invoke, presented to the builds service.
    invoke = @backends["invoke"]
    at(ctx, invoke["fields"]["ts"])

    assert {401, [{:refusal, {:unauthorized, :malformed}, []}]} =
             Wire.post(ctx.builds, @builds["routes"]["build"], invoke["body"], [
               {"x-cyfr-auth", invoke["header"]}
             ])

    # A build request, presented to the backends service on either route.
    request = @builds["request"]
    at(ctx, request["ts"])

    for {route, kind} <- [{"control", "control"}, {"mcp", "invoke"}] do
      ctx.backends
      |> post(@backends["routes"][route], request["body"], [{"x-cyfr-auth", request["header"]}])
      |> assert_backends_unauthorized(kind, route)
    end
  end
end
