# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuildsVectorsTest do
  @moduledoc """
  The shared vectors of the build wire (`tests/fixtures/locus_builds.json`)
  on the builder's side: the listener's. The service is configured from
  the vectors' key as the `locus` release is, served on a loopback port,
  and met at the vectors' own instant (the service's `:now`), so the bytes
  it verifies and the bytes it answers are the file's. The vectors'
  request is admitted past its header and read; every rejected header is
  refused `unauthorized` with its reason; every invalid body is refused
  with the class its error names, at the vectors' status; the health body
  is answered with a line of the vectors' shape; a refusal the service
  makes is, byte for byte, the vectors' line for it; and the largest answer
  the service can write — its log spent through `Locus.Diagnostics`, its
  terminal line carrying those lines as they were charged beside outputs
  at every bound — is within the vectors' `max_answer_bytes`, while one
  byte of output more is no result at all.
  """

  # Installs the vectors' key as the service's and replaces PATH.
  use ExUnit.Case, async: false

  alias Prima.BuilderProtocol
  alias Locus.Test.Wire

  @vectors Path.expand("../../../../tests/fixtures/locus_builds.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @now @vectors["request"]["ts"]

  setup do
    # The key arrives as the release's environment spells it.
    environment = %{"LOCUS_BUILDS_KEY" => @vectors["key_hex"]}
    {:ok, settings} = Locus.Config.from_env(&Map.get(environment, &1))

    assert Base.encode16(settings[:request_key], case: :lower) == @vectors["request_key_hex"]

    Application.put_env(:locus, :request_key, settings[:request_key])
    on_exit(fn -> Application.delete_env(:locus, :request_key) end)

    # The vectors present one nonce throughout; each test starts with none seen.
    forget_nonces()

    {:ok, clock} = Agent.start_link(fn -> @now end)

    server =
      start_supervised!(
        {Bandit,
         plug: {Locus.BuilderService, now: fn -> Agent.get(clock, & &1) end},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         http_2_options: [enabled: false]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    # No toolchain on PATH: a request that reads is answered `unavailable`
    # on every machine, with nothing run.
    path = System.get_env("PATH")
    System.put_env("PATH", "/nonexistent")
    on_exit(fn -> System.put_env("PATH", path) end)

    {:ok, port: port, clock: clock}
  end

  defp post(port, route, body, header \\ nil) do
    headers = if header, do: [{@vectors["auth_header"], header}], else: []
    Wire.post(port, @vectors["routes"][route], body, headers)
  end

  defp key, do: Base.decode16!(@vectors["key_hex"], case: :lower)

  defp forget_nonces, do: :ets.delete_all_objects(Locus.BuilderService.Nonces)

  # The vectors' request with its header, signed afresh over another body.
  defp signed(body) do
    {:ok, header} =
      BuilderProtocol.request_header(
        BuilderProtocol.request_key(key()),
        %{ts: @now, nonce: Wire.nonce()},
        body
      )

    header
  end

  defp synthesized(%{"files" => count, "bytes" => bytes}) do
    b64 = Base.encode64(:binary.copy(<<0>>, bytes))
    sources = for index <- 1..count, do: %{"path" => "f/#{index}.bin", "base64" => b64}

    @vectors["request"]["body"]
    |> Jason.decode!()
    |> Map.put("sources", sources)
    |> Jason.encode!()
  end

  test "the routes and the header are the vectors'" do
    assert BuilderProtocol.routes() ==
             %{build: @vectors["routes"]["build"], health: @vectors["routes"]["health"]}

    assert BuilderProtocol.auth_header() == @vectors["auth_header"]
  end

  test "the vectors' request verifies and reads, and the answer is the vectors' own line", %{
    port: port
  } do
    request = @vectors["request"]
    refusal = Enum.find(@vectors["lines"]["refusals"], &(&1["class"] == "unavailable"))

    assert {status, body} = raw(port, request["body"], request["header"])
    assert status == @vectors["statuses"]["unavailable"]
    assert body == refusal["body"] <> "\n"

    # Presented again it is a replay, in the vectors' line for that.
    replayed = Enum.find(@vectors["lines"]["refusals"], &(&1["reason"] == "replayed"))
    assert {status, body} = raw(port, request["body"], request["header"])
    assert status == @vectors["statuses"]["unauthorized"]
    assert body == replayed["body"] <> "\n"
  end

  test "every rejected header is refused unauthorized with its reason, at its instant", %{
    port: port,
    clock: clock
  } do
    assert @vectors["auth_rejected"] != []

    for vector <- @vectors["auth_rejected"] do
      Agent.update(clock, fn _ -> vector["now"] end)
      forget_nonces()

      assert {status, [{:refusal, {:unauthorized, reason}, []}]} =
               post(port, "build", vector["body"], vector["header"]),
             vector["name"]

      assert status == @vectors["statuses"]["unauthorized"], vector["name"]
      assert Atom.to_string(reason) == vector["refusal"], vector["name"]
    end
  end

  test "every invalid body is refused with the class its error names", %{port: port} do
    assert @vectors["invalid_requests"] != []

    for vector <- @vectors["invalid_requests"] do
      {status, [{:refusal, refusal, []}]} = refuse_invalid(port, vector)
      class = if vector["error"] == "version", do: :protocol_mismatch, else: :malformed

      assert elem(refusal, 0) == class, vector["name"]
      assert status == @vectors["statuses"][Atom.to_string(class)], vector["name"]
    end
  end

  test "the health body is answered, without a key, with a line of the vectors' shape", %{
    port: port
  } do
    assert {200, [{:health, health}]} = post(port, "health", @vectors["health_request"]["body"])

    vector = @vectors["lines"]["health"]
    assert health.release == BuilderProtocol.release()

    assert Map.keys(health.toolchains) |> Enum.map(&Atom.to_string/1) |> Enum.sort() ==
             Map.keys(vector["toolchains"]) |> Enum.sort()

    for {language, toolchain} <- vector["toolchains"] do
      ours = health.toolchains[String.to_existing_atom(language)]
      assert ours.command == toolchain["command"]
      assert ours.description == toolchain["description"]
    end
  end

  describe "the largest answer" do
    test "the service's largest answer is within the vectors' answer bound" do
      bounds = @vectors["bounds"]
      {progress, diagnostics} = spent_log()

      # The log is the vectors' to the last line that fits: what is left of
      # it holds no line of the builder's own.
      assert charged(progress) <= bounds["max_log_bytes"]
      assert bounds["max_log_bytes"] - charged(progress) < byte_size(List.last(progress)) + 1

      {:ok, terminal} =
        BuilderProtocol.encode_result(%{
          language: :javascript,
          target_type: :tincture,
          outputs: largest_outputs(bounds["max_output_bytes"]),
          diagnostics: {:encoded, diagnostics}
        })

      answer = charged(progress) + byte_size(terminal) + 1
      assert answer <= bounds["max_answer_bytes"]
      assert answer > bounds["max_answer_bytes"] - bounds["max_output_files"] * 1_100
    end

    test "one byte of output past the bound is no result the service can write" do
      bounds = @vectors["bounds"]
      max = bounds["max_output_bytes"]

      assert {:error, {:too_large, :outputs, over, ^max}} =
               BuilderProtocol.encode_result(%{
                 language: :javascript,
                 target_type: :tincture,
                 outputs: largest_outputs(max + 1),
                 diagnostics: []
               })

      assert over == max + 1
    end
  end

  # The build's log spent as the service spends it: the build's own lines,
  # quoted so every byte of them escapes, until the log is cut, then the
  # builder's until nothing more fits.
  defp spent_log do
    budget = Locus.Diagnostics.budget()
    loud = String.duplicate(~s("), 60_000)

    build =
      Stream.repeatedly(fn -> Locus.Diagnostics.admit(budget, :output, loud) end)
      |> Enum.take_while(&(&1 != []))
      |> Enum.concat()

    builder =
      Stream.repeatedly(fn ->
        Locus.Diagnostics.admit(budget, :validating, "the builder's own")
      end)
      |> Enum.take_while(&(&1 != []))
      |> Enum.concat()

    admitted = build ++ builder
    {Enum.map(admitted, &elem(&1, 0)), Enum.map(admitted, &elem(&1, 1))}
  end

  defp charged(lines), do: Enum.reduce(lines, 0, &(byte_size(&1) + 1 + &2))

  # `total` bytes over the vectors' most files, each named at the longest
  # path the wire takes, of quotes, which escape to two bytes each.
  defp largest_outputs(total) do
    files = @vectors["bounds"]["max_output_files"]
    path_bytes = @vectors["bounds"]["max_output_path_bytes"]
    quotes = String.duplicate(~s("), 240)

    for index <- 0..(files - 1), into: %{} do
      stem = Enum.join([quotes, quotes, quotes, quotes, Integer.to_string(index)], "/")
      path = stem <> String.duplicate(~s("), path_bytes - byte_size(stem))
      size = div(total, files) + if(index < rem(total, files), do: 1, else: 0)
      {path, :binary.copy(<<rem(index, 256)>>, size)}
    end
  end

  # A declared size is refused from the header; every other body is sent.
  defp refuse_invalid(port, %{"declared_bytes" => bytes}) do
    conn =
      Wire.open_raw(port, [
        "POST #{@vectors["routes"]["build"]} HTTP/1.1\r\nhost: locus\r\n",
        "content-length: #{bytes}\r\n#{@vectors["auth_header"]}: #{signed("")}\r\n\r\n"
      ])

    {status, conn} = Wire.status(conn)
    {line, conn} = Wire.line(conn)
    Wire.close(conn)
    {status, [line]}
  end

  defp refuse_invalid(port, %{"synthesize" => synthesize}) do
    body = synthesized(synthesize)
    post(port, "build", body, signed(body))
  end

  defp refuse_invalid(port, %{"body" => body}), do: post(port, "build", body, signed(body))

  # The answer's status and its body's bytes, unread.
  defp raw(port, body, header) do
    conn =
      Wire.open(port, @vectors["routes"]["build"], body, [{@vectors["auth_header"], header}])

    {status, conn} = Wire.status(conn)
    {:length, length} = conn.framing
    {status, read_exactly(conn, length)}
  end

  defp read_exactly(conn, length) when byte_size(conn.buffer) >= length do
    Wire.close(conn)
    binary_part(conn.buffer, 0, length)
  end

  defp read_exactly(conn, length) do
    {:ok, bytes} = :gen_tcp.recv(conn.socket, 0, 5_000)
    read_exactly(%{conn | buffer: conn.buffer <> bytes}, length)
  end
end
