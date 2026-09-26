# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.KeeperProtocolTest do
  @moduledoc """
  The keeper codec reproduces every category of the shared vectors
  (`tests/fixtures/keeper_protocol.json`, which the keeper's Go suite
  reads too), and the file carries no category this test
  does not read and none empty: every frame and control frame encodes to
  its bytes and parses back; the attach frame presents its token; every
  valid request encodes to the line its clients have always written, name
  order and all; every invalid request is refused, naming the member its
  `why` is about; every reserved prefix is refused in a spawn's env; and
  every reply decodes to its typed shape. Beyond the vectors: an
  oversized or unknown frame header, an attach frame of the wrong shape, a
  line past the bound, and a reply of another version, type, member or
  exit shape are refused.
  """

  use ExUnit.Case, async: true

  alias Prima.{KeeperProtocol, RunnerControl}

  # Read as this module compiles, so a checkout without the file fails
  # here, naming it, rather than running without the vectors.
  @vectors Path.expand("../../../../tests/fixtures/keeper_protocol.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @categories ~w(reserved_env_prefixes frames control_frames valid_requests invalid_requests replies)

  @request_types %{"spawn" => :spawn, "signal" => :signal, "release" => :release, "pool" => :pool}

  # The member each invalid vector's refusal names.
  @refused_member %{
    "wrong version" => "v",
    "unknown type" => "type",
    "unknown field" => "extra",
    "field of another type" => "sig",
    "empty argv" => "argv",
    "reserved env name" => "env",
    "reserved env prefix" => "env",
    "the keeper's channel variable" => "env",
    "malformed env name" => "env",
    "NUL in argv" => "argv",
    "rlimit above its ceiling" => "rlimits.nofile",
    "core dumps asked for" => "rlimits.core",
    "no attach" => "attach",
    "relative attach path" => "attach.path",
    "short token" => "attach.token",
    "signal outside the allowed set" => "sig",
    "malformed spawn id" => "spawn_id",
    "release without grace" => "grace_ms",
    "grace above the maximum" => "grace_ms",
    "control that is not a boolean" => "control",
    "control on a request that is not a spawn" => "control",
    "runner spawn naming a reserved variable" => "env",
    "runner spawn without attach" => "attach",
    "memory bound of zero" => "memory_bytes",
    "memory bound below the minimum" => "memory_bytes",
    "memory bound above the maximum" => "memory_bytes",
    "negative memory bound" => "memory_bytes",
    "fractional memory bound" => "memory_bytes",
    "memory bound that is not a number" => "memory_bytes",
    "memory bound inside rlimits" => "rlimits.memory_bytes",
    "memory bound on a request that is not a spawn" => "memory_bytes"
  }

  @token "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  @spawn_id "00112233445566778899aabbccddeeff"

  # A vector's request as `encode/1` takes it: atom keys but for env's
  # names, a known type as its atom, and `v` left out when it is the
  # codec's own, since the codec writes it.
  defp request(vector) do
    version = KeeperProtocol.version()

    vector
    |> Enum.reject(fn {name, value} -> name == "v" and value == version end)
    |> Map.new(fn
      {"type", type} -> {:type, Map.get(@request_types, type, type)}
      {"env", env} -> {:env, env}
      {"attach", %{} = attach} -> {:attach, atom_keys(attach)}
      {"rlimits", %{} = rlimits} -> {:rlimits, atom_keys(rlimits)}
      {name, value} -> {String.to_atom(name), value}
    end)
  end

  defp atom_keys(map), do: Map.new(map, fn {name, value} -> {String.to_atom(name), value} end)

  defp spawn_request(fields) do
    Map.merge(
      %{
        type: :spawn,
        id: "1",
        pool: "build",
        argv: ["true"],
        attach: %{path: "/run/a.sock", token: @token}
      },
      fields
    )
  end

  defp line(request), do: request |> KeeperProtocol.encode() |> IO.iodata_to_binary()

  defp refused(request) do
    error = assert_raise(ArgumentError, fn -> KeeperProtocol.encode(request) end)
    error.message
  end

  defp hex(frame, key), do: Base.decode16!(frame[key], case: :lower)

  defp stream(byte) do
    {name, ^byte} = List.keyfind(KeeperProtocol.streams(), byte, 1)
    name
  end

  defp encoded_line(message), do: Jason.encode!(message)

  describe "the vectors" do
    test "carry exactly the categories this test reads, none empty" do
      assert @vectors |> Map.keys() |> Enum.sort() == Enum.sort(["comment" | @categories])

      for category <- @categories do
        assert @vectors[category] not in [nil, []], "#{category} is empty"
      end
    end

    test "every frame encodes to its bytes and parses back" do
      for frame <- @vectors["frames"] ++ @vectors["control_frames"] do
        stream = stream(frame["stream"])
        payload = hex(frame, "payload_hex")
        encoded = hex(frame, "encoded_hex")

        assert IO.iodata_to_binary(KeeperProtocol.frame(stream, payload)) == encoded
        assert KeeperProtocol.parse_frames(encoded) == {:ok, [{stream, payload}], ""}

        if payload == "",
          do: assert(IO.iodata_to_binary(KeeperProtocol.end_frame(stream)) == encoded),
          else: assert(IO.iodata_to_binary(KeeperProtocol.frames(stream, payload)) == encoded)
      end

      # Every stream the vectors name, back to back, and one cut short.
      all = @vectors["frames"] ++ @vectors["control_frames"]
      bytes = Enum.map_join(all, &hex(&1, "encoded_hex"))
      expected = Enum.map(all, &{stream(&1["stream"]), hex(&1, "payload_hex")})
      assert KeeperProtocol.parse_frames(bytes) == {:ok, expected, ""}

      cut = binary_part(bytes, 0, byte_size(bytes) - 1)
      assert {:ok, parsed, rest} = KeeperProtocol.parse_frames(cut)
      assert parsed == Enum.drop(expected, -1)
      assert rest == binary_part(cut, byte_size(cut) - 4, 4)
    end

    test "the attach frame presents a spawn's token" do
      [frame] = Enum.filter(@vectors["frames"], &(&1["stream"] == 3))
      token = hex(frame, "payload_hex")
      encoded = hex(frame, "encoded_hex")

      assert byte_size(token) == KeeperProtocol.token_hex_bytes()
      assert IO.iodata_to_binary(KeeperProtocol.attach_frame(token)) == encoded
      assert KeeperProtocol.decode_attach(encoded) == {:ok, token}
    end

    test "a control frame carries a runner control line verbatim" do
      [line_frame, end_frame] = @vectors["control_frames"]
      assert {:ok, %{type: :cancel_child}} = RunnerControl.decode(hex(line_frame, "payload_hex"))
      assert hex(end_frame, "payload_hex") == ""
    end

    test "every valid request encodes to its line, name order and all" do
      for vector <- @vectors["valid_requests"] do
        assert vector["v"] == KeeperProtocol.version()
        line = line(request(vector))

        # The line the islands wrote before the codec: Jason's name order.
        assert line == encoded_line(vector) <> "\n"
        assert Jason.decode!(line) == vector
      end
    end

    test "every invalid request is refused, naming the member its why is about" do
      for %{"why" => why, "code" => code, "request" => vector} <- @vectors["invalid_requests"] do
        assert code == "bad_request"
        member = Map.get(@refused_member, why) || flunk("no refused member for #{inspect(why)}")
        message = refused(request(vector))

        assert String.starts_with?(message, member <> " "),
               "#{why}: #{inspect(message)} does not name #{member}"
      end

      assert Enum.sort(Map.keys(@refused_member)) ==
               Enum.sort(Enum.map(@vectors["invalid_requests"], & &1["why"]))
    end

    test "every reserved prefix is refused in a spawn's env, and a name without one is carried" do
      for prefix <- @vectors["reserved_env_prefixes"] do
        assert refused(spawn_request(%{env: %{(prefix <> "ANY") => "t"}})) =~ ~r/\Aenv /
      end

      assert %{"env" => %{"LANG" => "C.UTF-8"}} =
               Jason.decode!(line(spawn_request(%{env: %{"LANG" => "C.UTF-8"}})))
    end

    test "every reply decodes to its typed shape, with or without its newline" do
      for vector <- @vectors["replies"] do
        expected = expected_reply(vector)
        assert KeeperProtocol.decode_reply(Jason.encode!(vector)) == {:ok, expected}
        assert KeeperProtocol.decode_reply(Jason.encode!(vector) <> "\n") == {:ok, expected}
      end

      assert @vectors["replies"] |> Enum.map(& &1["type"]) |> Enum.uniq() |> Enum.sort() ==
               ~w(error exited pool released spawned)
    end
  end

  defp expected_reply(%{"type" => "spawned"} = r),
    do: {:spawned, r["id"], r["spawn_id"], r["uid"], r["pid"]}

  defp expected_reply(%{"type" => "error"} = r), do: {:error, r["id"], r["spawn_id"], r["code"]}

  defp expected_reply(%{"type" => "exited", "signal" => nil} = r),
    do: {:exited, r["spawn_id"], {:status, r["code"]}, r["memory_exceeded"]}

  defp expected_reply(%{"type" => "exited"} = r),
    do: {:exited, r["spawn_id"], {:signal, r["signal"]}, r["memory_exceeded"]}

  defp expected_reply(%{"type" => "released"} = r), do: {:released, r["spawn_id"]}

  defp expected_reply(%{"type" => "pool"} = r),
    do: {:pool, r["id"], r["pool"], r["size"], r["free"], r["quarantined"]}

  describe "frames" do
    test "a header over the bound or on an unknown stream is refused as soon as it is in" do
      max = KeeperProtocol.max_frame_bytes()
      assert KeeperProtocol.parse_frames(<<1, max + 1::32>>) == {:error, :oversized}
      assert KeeperProtocol.parse_frames(<<5, 0::32>>) == {:error, :unknown_stream}

      assert KeeperProtocol.parse_frames(<<1, 1::32, "x", 255, 0::32>>) ==
               {:error, :unknown_stream}

      payload = :binary.copy("x", max)

      assert {:ok, [{:stdout, ^payload}], ""} =
               KeeperProtocol.parse_frames(<<1, max::32>> <> payload)
    end

    test "a header or payload not yet in waits" do
      assert KeeperProtocol.parse_frames(<<1, 0, 0>>) == {:ok, [], <<1, 0, 0>>}
      assert KeeperProtocol.parse_frames(<<1, 5::32, "abc">>) == {:ok, [], <<1, 5::32, "abc">>}
      assert KeeperProtocol.parse_frames("") == {:ok, [], ""}
    end

    test "data is chunked at the frame bound, and a frame past it is refused" do
      max = KeeperProtocol.max_frame_bytes()
      data = :binary.copy("y", 2 * max + 3)
      frames = KeeperProtocol.frames(:stdin, data)

      assert Enum.map(frames, &IO.iodata_length/1) == [max + 5, max + 5, 3 + 5]
      assert {:ok, parsed, ""} = KeeperProtocol.parse_frames(IO.iodata_to_binary(frames))
      assert Enum.map_join(parsed, fn {:stdin, payload} -> payload end) == data
      assert KeeperProtocol.frames(:stdin, "") == []

      assert_raise ArgumentError, fn ->
        KeeperProtocol.frame(:stdout, :binary.copy("z", max + 1))
      end

      assert_raise ArgumentError, fn -> KeeperProtocol.frame(:video, "") end
      assert_raise ArgumentError, fn -> KeeperProtocol.end_frame(:video) end
    end

    test "the streams are the five bytes the relay carries" do
      assert KeeperProtocol.streams() == [stdin: 0, stdout: 1, stderr: 2, attach: 3, control: 4]
    end
  end

  describe "the attach frame" do
    test "presents only a token of 64 lowercase hex digits" do
      for token <- ["0123", String.upcase(@token), String.duplicate("g", 64), @token <> "0"] do
        assert_raise ArgumentError, ~r/\Aattach\.token /, fn ->
          KeeperProtocol.attach_frame(token)
        end
      end
    end

    test "decodes only as a whole frame on the attach stream with a hex token" do
      assert KeeperProtocol.decode_attach(<<3, 64::32>> <> @token) == {:ok, @token}

      for bytes <- [
            <<1, 64::32>> <> @token,
            <<3, 63::32>> <> binary_part(@token, 0, 63),
            <<3, 64::32>> <> binary_part(@token, 0, 63),
            <<3, 64::32>> <> String.upcase(@token),
            <<3, 64::32>> <> @token <> "0",
            <<3, 4::32, "0123">>
          ] do
        assert KeeperProtocol.decode_attach(bytes) == {:error, :malformed}
      end
    end
  end

  describe "lines" do
    test "split at their newlines, the partial one kept" do
      assert KeeperProtocol.split_lines("", "") == {[], ""}
      assert KeeperProtocol.split_lines("ab", "c\nd\n\nef") == {["abc", "d", ""], "ef"}
      assert KeeperProtocol.split_lines("", "x\n") == {["x"], ""}
    end

    test "past the bound, complete or not, end the channel" do
      max = KeeperProtocol.max_line_bytes()
      assert max == 1_048_576
      at_bound = :binary.copy("a", max)

      assert KeeperProtocol.split_lines("", at_bound) == {[], at_bound}
      assert KeeperProtocol.split_lines(at_bound, "\n") == {[at_bound], ""}
      assert KeeperProtocol.split_lines(at_bound, "a") == {:error, :line_too_long}
      assert KeeperProtocol.split_lines("", at_bound <> "a\nb") == {:error, :line_too_long}
    end
  end

  describe "requests" do
    test "are refused past their bounds, and carried at them" do
      assert %{"memory_bytes" => 16_777_216} =
               Jason.decode!(line(spawn_request(%{memory_bytes: 16_777_216})))

      assert %{"grace_ms" => 60_000} =
               Jason.decode!(line(%{type: :release, spawn_id: @spawn_id, grace_ms: 60_000}))

      rlimits = %{nofile: 1024, nproc: 128, core: 0, fsize: 268_435_456}
      assert %{"rlimits" => _} = Jason.decode!(line(spawn_request(%{rlimits: rlimits})))

      assert refused(spawn_request(%{rlimits: %{"nofile" => 16}})) =~ ~r/\Arlimits\.nofile /
      assert refused(spawn_request(%{argv: List.duplicate("x", 257)})) =~ ~r/\Aargv /
      assert refused(spawn_request(%{argv: [""]})) =~ ~r/\Aargv /
      assert refused(spawn_request(%{argv: [<<255>>]})) =~ ~r/\Aargv /
      assert refused(spawn_request(%{env: %{"A" => <<255>>}})) =~ ~r/\Aenv /

      assert refused(spawn_request(%{env: %{"A" => :binary.copy("v", 32 * 1024 + 1)}})) =~
               ~r/\Aenv /

      assert refused(spawn_request(%{attach: %{path: "/run//a.sock", token: @token}})) =~
               ~r/\Aattach\.path /

      assert refused(spawn_request(%{attach: %{path: "/run/../a.sock", token: @token}})) =~
               ~r/\Aattach\.path /

      assert refused(spawn_request(%{attach: %{path: "/run/a/", token: @token}})) =~
               ~r/\Aattach\.path /

      long = "/" <> String.duplicate("a", 107)

      assert refused(spawn_request(%{attach: %{path: long, token: @token}})) =~
               ~r/\Aattach\.path /

      assert refused(spawn_request(%{id: String.duplicate("i", 65)})) =~ ~r/\Aid /
      assert refused(spawn_request(%{pool: "Build"})) =~ ~r/\Apool /
      assert refused(%{type: :signal, spawn_id: @spawn_id}) =~ ~r/\Asig /
      assert refused(%{id: "1", pool: "p"}) =~ ~r/\Atype /
    end

    test "are refused when argv and env together pass the keeper's bound" do
      env = Map.new(1..9, &{"V#{&1}", :binary.copy("v", 30_000)})
      assert refused(spawn_request(%{env: env})) =~ ~r/\Aargv /

      env = Map.new(1..8, &{"V#{&1}", :binary.copy("v", 30_000)})
      assert %{"env" => ^env} = Jason.decode!(line(spawn_request(%{env: env})))
    end

    test "write every member in name order, env's names sorted" do
      env = %{"ZED" => "z", "ALPHA" => "a"}

      assert line(spawn_request(%{env: env, control: true, memory_bytes: 16_777_216})) ==
               ~s({"argv":["true"],"attach":{"path":"/run/a.sock","token":"#{@token}"},) <>
                 ~s("control":true,"env":{"ALPHA":"a","ZED":"z"},"id":"1",) <>
                 ~s("memory_bytes":16777216,"pool":"build","type":"spawn","v":1}\n)

      assert line(%{type: :pool, id: "pool-1", pool: "runner"}) ==
               ~s({"id":"pool-1","pool":"runner","type":"pool","v":1}\n)
    end
  end

  describe "replies" do
    test "of another version, type or member, or not one object, are refused" do
      base = %{"v" => 1, "type" => "released", "spawn_id" => @spawn_id}
      decode = &KeeperProtocol.decode_reply(Jason.encode!(&1))

      assert decode.(%{base | "v" => 2}) == {:error, :bad_version}
      assert decode.(Map.delete(base, "v")) == {:error, :bad_version}
      assert decode.(%{base | "type" => "spawn"}) == {:error, :unknown_type}
      assert decode.(Map.put(base, "extra", 1)) == {:error, {:unknown_field, "extra"}}
      assert decode.(Map.delete(base, "spawn_id")) == {:error, {:missing_field, "spawn_id"}}
      assert decode.(%{base | "spawn_id" => "../x"}) == {:error, {:invalid_field, "spawn_id"}}
      assert decode.(%{base | "spawn_id" => 7}) == {:error, {:wrong_type, "spawn_id"}}
      assert KeeperProtocol.decode_reply("not json") == {:error, :malformed}
      assert KeeperProtocol.decode_reply("[]") == {:error, :malformed}
      assert KeeperProtocol.decode_reply(:line) == {:error, :malformed}

      oversize = :binary.copy(" ", KeeperProtocol.max_line_bytes() + 1)
      assert KeeperProtocol.decode_reply(oversize) == {:error, :oversize_line}
    end

    test "a spawned without its uid or pid is refused" do
      spawned = %{"v" => 1, "type" => "spawned", "id" => "7", "spawn_id" => @spawn_id}
      decode = &KeeperProtocol.decode_reply(Jason.encode!(&1))

      assert decode.(Map.put(spawned, "pid", 1)) == {:error, {:missing_field, "uid"}}
      assert decode.(Map.put(spawned, "uid", 1)) == {:error, {:missing_field, "pid"}}

      assert decode.(Map.merge(spawned, %{"uid" => -1, "pid" => 1})) ==
               {:error, {:invalid_field, "uid"}}
    end

    test "an exited with both a code and a signal, neither, or no boolean report is refused" do
      exited = %{
        "v" => 1,
        "type" => "exited",
        "spawn_id" => @spawn_id,
        "code" => nil,
        "signal" => nil,
        "memory_exceeded" => false
      }

      decode = &KeeperProtocol.decode_reply(Jason.encode!(&1))

      assert decode.(exited) == {:error, :ambiguous_exit}
      assert decode.(%{exited | "code" => 1, "signal" => "SIGKILL"}) == {:error, :ambiguous_exit}
      assert decode.(Map.delete(exited, "code")) == {:error, {:missing_field, "code"}}

      assert decode.(%{exited | "code" => 0, "memory_exceeded" => nil}) ==
               {:error, {:wrong_type, "memory_exceeded"}}

      assert decode.(%{exited | "code" => 0, "memory_exceeded" => "true"}) ==
               {:error, {:wrong_type, "memory_exceeded"}}

      assert decode.(Map.delete(%{exited | "code" => 0}, "memory_exceeded")) ==
               {:error, {:missing_field, "memory_exceeded"}}

      assert decode.(%{exited | "code" => 0}) == {:ok, {:exited, @spawn_id, {:status, 0}, false}}
    end

    test "an error names its request by id, spawn id, both or neither" do
      decode =
        &KeeperProtocol.decode_reply(Jason.encode!(Map.merge(%{"v" => 1, "type" => "error"}, &1)))

      assert decode.(%{"code" => "bad_request"}) == {:ok, {:error, nil, nil, "bad_request"}}

      assert decode.(%{"id" => "1", "spawn_id" => @spawn_id, "code" => "bad_request"}) ==
               {:ok, {:error, "1", @spawn_id, "bad_request"}}

      assert decode.(%{"id" => "1"}) == {:error, {:missing_field, "code"}}

      assert decode.(%{"id" => "1", "code" => "Bad Request"}) ==
               {:error, {:invalid_field, "code"}}
    end
  end
end
