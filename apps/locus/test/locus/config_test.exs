# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.ConfigTest do
  @moduledoc """
  The builder's settings come from `LOCUS_BUILDS_*` and nothing else: a
  full valid environment produces the documented settings, only the key
  is required, every malformed value refuses with a message naming its
  variable, and any of the control plane's variables in the environment
  refuses before anything else is read. Where the environment was never
  read, every accessor answers its default and no key is held.
  """
  use ExUnit.Case, async: true

  alias Locus.Config

  @key_hex "101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f"
  @key Base.decode16!(@key_hex, case: :lower)

  defp env(map), do: fn key -> Map.get(map, key) end

  defp full do
    %{
      "LOCUS_BUILDS_KEY" => @key_hex,
      "LOCUS_BUILDS_BIND" => "127.0.0.1",
      "LOCUS_BUILDS_PORT" => "4101",
      "LOCUS_BUILDS_TIMEOUT_MS" => "60000",
      "LOCUS_BUILDS_MAX_CONCURRENT" => "4",
      "LOCUS_BUILDS_MAX_CONCURRENT_PER_TENANT" => "2",
      "LOCUS_BUILDS_MEMORY_BYTES" => "2147483648",
      "LOCUS_BUILDS_CARGO_SEED" => "/opt/cyfr/cargo-seed",
      "LOCUS_BUILDS_LOG_LEVEL" => "debug",
      "LOCUS_BUILDS_LOG_FORMAT" => "json"
    }
  end

  test "a full valid environment produces the documented settings, holding the derived key only" do
    assert {:ok, settings} = Config.from_env(env(full()))

    assert settings == [
             request_key: Cyfr.BuilderProtocol.request_key(@key),
             bind: {127, 0, 0, 1},
             port: 4101,
             timeout_ms: 60_000,
             max_concurrent: 4,
             max_concurrent_per_tenant: 2,
             memory_bytes: 2_147_483_648,
             cargo_seed: "/opt/cyfr/cargo-seed",
             log_level: :debug,
             log_format: :json
           ]

    refute settings[:request_key] == @key
    refute inspect(settings) =~ @key_hex
  end

  test "only the key is required; everything else takes its default" do
    assert {:ok, settings} = Config.from_env(env(%{"LOCUS_BUILDS_KEY" => @key_hex}))

    assert settings == [
             request_key: Cyfr.BuilderProtocol.request_key(@key),
             bind: {0, 0, 0, 0},
             port: 4100,
             timeout_ms: 270_000,
             max_concurrent: 2,
             max_concurrent_per_tenant: 1,
             memory_bytes: 1_073_741_824,
             cargo_seed: nil,
             log_level: :info,
             log_format: :text
           ]
  end

  test "a missing key refuses, naming the variable and its counterpart on the server" do
    assert {:error, message} = Config.from_env(env(%{}))
    assert message =~ "LOCUS_BUILDS_KEY"
    assert message =~ "CYFR_LOCUS_BUILDS_KEY"

    assert {:error, ^message} = Config.from_env(env(%{"LOCUS_BUILDS_KEY" => "  "}))
  end

  test "a malformed value refuses, naming its variable and the accepted form" do
    for {variable, bad, form} <- [
          {"LOCUS_BUILDS_KEY", "not-a-key", "64 hexadecimal digits"},
          {"LOCUS_BUILDS_KEY", String.slice(@key_hex, 0..62), "64 hexadecimal digits"},
          {"LOCUS_BUILDS_BIND", "builder", "IPv4 or IPv6 address"},
          {"LOCUS_BUILDS_PORT", "0", "port from 1 to 65535"},
          {"LOCUS_BUILDS_PORT", "http", "port from 1 to 65535"},
          {"LOCUS_BUILDS_TIMEOUT_MS", "999", "milliseconds from 1000 to 600000"},
          {"LOCUS_BUILDS_TIMEOUT_MS", "5m", "milliseconds from 1000 to 600000"},
          {"LOCUS_BUILDS_MAX_CONCURRENT", "0", "builds from 1 to 1024"},
          {"LOCUS_BUILDS_MAX_CONCURRENT_PER_TENANT", "1025", "builds from 1 to 1024"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "0", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "16777215", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "1099511627777", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "1G", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "1073741824.5", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "-1073741824", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BUILDS_MEMORY_BYTES", "unlimited", "bytes from 16777216 to 1099511627776"},
          {"LOCUS_BUILDS_LOG_LEVEL", "verbose", "Logger level"},
          {"LOCUS_BUILDS_LOG_FORMAT", "xml", "text or json"}
        ] do
      assert {:error, message} = Config.from_env(env(Map.put(full(), variable, bad))), variable
      assert message =~ variable, message
      assert message =~ form, message
    end

    assert {:error, message} =
             Config.from_env(env(Map.put(full(), "LOCUS_BUILDS_KEY", "not-a-key")))

    refute message =~ "not-a-key"
  end

  test "the memory bound takes the whole of the keeper's range, both ends, and nothing outside it" do
    vectors =
      Path.expand("../../../../tests/fixtures/spawn_protocol.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    # A spawn's own bound: a whole number refused for what it is, not for
    # the request it rides on.
    bounds = fn requests ->
      for %{"request" => %{"type" => "spawn", "memory_bytes" => bytes}} <- requests,
          is_integer(bytes),
          do: bytes
    end

    accepted =
      for %{"memory_bytes" => bytes} <- vectors["valid_requests"], do: bytes

    assert 16_777_216 in accepted and 1_099_511_627_776 in accepted

    # What the keeper accepts as a spawn's bound, this setting accepts.
    for bytes <- accepted do
      env = env(Map.put(full(), "LOCUS_BUILDS_MEMORY_BYTES", Integer.to_string(bytes)))
      assert {:ok, settings} = Config.from_env(env)
      assert settings[:memory_bytes] == bytes
    end

    # And what the keeper refuses, this setting refuses at the boot.
    refused = bounds.(vectors["invalid_requests"])
    assert refused != []

    for bytes <- refused do
      env = env(Map.put(full(), "LOCUS_BUILDS_MEMORY_BYTES", Integer.to_string(bytes)))
      assert {:error, message} = Config.from_env(env)
      assert message =~ "LOCUS_BUILDS_MEMORY_BYTES"
    end
  end

  test "a control-plane variable in the environment refuses the boot before anything else is read" do
    for variable <- ~w(CYFR_DATABASE_URL CYFR_CRYPTO_KEYRING CYFR_WORKER_KEY CYFR_MCP_BRIDGE_KEY) do
      assert Config.refused_environment(env(%{variable => "x"})) == [variable]

      assert {:error, message} = Config.from_env(env(Map.put(full(), variable, "x")))
      assert message =~ variable
      assert message =~ "must not see"

      # Refused first: with no key set the message is still about the control plane.
      assert {:error, ^message} = Config.from_env(env(%{variable => "x"}))
    end

    assert Config.refused_environment(env(full())) == []

    assert {:error, message} =
             Config.from_env(env(%{"CYFR_DATABASE_URL" => "x", "CYFR_WORKER_KEY" => "y"}))

    assert message =~ "CYFR_DATABASE_URL, CYFR_WORKER_KEY"
  end

  test "an unread environment leaves every accessor at its default and no key held" do
    assert Config.request_key() == nil
    assert Config.bind() == {0, 0, 0, 0}
    assert Config.port() == 4100
    assert Config.timeout_ms() == 270_000
    assert Config.max_concurrent() == 2
    assert Config.max_concurrent_per_tenant() == 1
    assert Config.memory_bytes() == 1_073_741_824
    assert Config.cargo_seed() == nil
    assert Config.log_level() == :info
    assert Config.log_format() == :text
    assert Config.log_formatter() == nil
  end
end

defmodule Locus.RuntimeConfigFileTest do
  @moduledoc """
  `config/locus_runtime.exs` evaluates the way the `locus` release boots:
  it writes exactly what `Locus.Config.from_env/1` answers, under `:locus`
  and no other application, and refuses the boot with the message.
  """
  # Sets the operating system's environment for the duration of a test.
  use ExUnit.Case, async: false

  @root Path.expand("../../../..", __DIR__)
  @config_file Path.join(@root, "config/locus_runtime.exs")
  @key_hex "101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f"

  @cleared ~w(CYFR_DATABASE_URL CYFR_CRYPTO_KEYRING CYFR_WORKER_KEY CYFR_MCP_BRIDGE_KEY
              LOCUS_BUILDS_KEY LOCUS_BUILDS_BIND LOCUS_BUILDS_PORT LOCUS_BUILDS_TIMEOUT_MS
              LOCUS_BUILDS_MAX_CONCURRENT LOCUS_BUILDS_MAX_CONCURRENT_PER_TENANT
              LOCUS_BUILDS_MEMORY_BYTES LOCUS_BUILDS_CARGO_SEED LOCUS_BUILDS_LOG_LEVEL LOCUS_BUILDS_LOG_FORMAT)

  defp with_env(set, fun) do
    previous = Map.new(@cleared, &{&1, System.get_env(&1)})

    try do
      Enum.each(@cleared, &System.delete_env/1)
      Enum.each(set, fn {key, value} -> System.put_env(key, value) end)
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  test "writes the settings under :locus and nothing else" do
    set = %{
      "LOCUS_BUILDS_KEY" => @key_hex,
      "LOCUS_BUILDS_PORT" => "4102",
      "LOCUS_BUILDS_MEMORY_BYTES" => "536870912"
    }

    with_env(set, fn ->
      config = Config.Reader.read!(@config_file, env: :prod, imports: :disabled)
      {:ok, expected} = Locus.Config.from_env(&Map.get(set, &1))

      assert Keyword.keys(config) == [:locus]
      assert Enum.sort(config[:locus]) == Enum.sort(expected)
      assert config[:locus][:port] == 4102
      # The bound reaches `:locus` through the file as it stands: it writes
      # whatever `from_env/1` answers.
      assert config[:locus][:memory_bytes] == 536_870_912
    end)
  end

  test "refuses the boot with the message naming the variable" do
    with_env(%{}, fn ->
      assert_raise RuntimeError, ~r/\[Locus\] FATAL: LOCUS_BUILDS_KEY/, fn ->
        Config.Reader.read!(@config_file, env: :prod, imports: :disabled)
      end
    end)

    with_env(%{"LOCUS_BUILDS_KEY" => @key_hex, "CYFR_DATABASE_URL" => "postgres://x"}, fn ->
      assert_raise RuntimeError,
                   ~r/FATAL: the locus release must not see CYFR_DATABASE_URL/,
                   fn ->
                     Config.Reader.read!(@config_file, env: :prod, imports: :disabled)
                   end
    end)
  end

  test "log_formatter names Cyfr.JsonFormatter once the format is json" do
    Application.put_env(:locus, :log_format, :json)
    on_exit(fn -> Application.delete_env(:locus, :log_format) end)

    assert Locus.Config.log_formatter() == {Cyfr.JsonFormatter, :format}

    assert Code.ensure_loaded?(Cyfr.JsonFormatter) and
             function_exported?(Cyfr.JsonFormatter, :format, 4)
  end
end
