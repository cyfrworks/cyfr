# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.NoRealCyfrRunTest do
  @moduledoc """
  No person is ever made at the real cyfr.run from a test: the test node's
  registry is the discard address `config/test.exs` names and it pins no
  directory. A development build and a release share one default, cyfr.run
  for the registry and the account service, so a CYFR takes one path
  whatever it was built as.
  """

  # The runtime configuration is read under a changed process environment.
  use ExUnit.Case, async: false

  alias Prima.Test.Env

  @root Path.expand("../../../..", __DIR__)
  @discard "127.0.0.1:19"

  test "the test node's registry is config/test.exs's discard address, and it pins no directory" do
    assert File.read!(Path.join(@root, "config/test.exs")) =~
             ~s(config :sanctum, :registry_url, "#{@discard}")

    assert Application.get_env(:sanctum, :registry_url) == @discard
    assert Application.get_env(:cyfr, :registry_url) == @discard
    assert Application.get_env(:cyfr, :oci_registry_url) == @discard
    assert Sanctum.registry_base_url(@discard) == "http://#{@discard}"
    assert Sanctum.directory_url() == nil
  end

  for env <- [:dev, :prod] do
    test "a #{env} configuration with neither URL set names cyfr.run" do
      config = runtime(unquote(env))
      assert get_in(config, [:sanctum, :registry_url]) == "cyfr.run"
      assert get_in(config, [:cyfr, :registry_url]) == "cyfr.run"
      assert get_in(config, [:cyfr, :oci_registry_url]) == "registry.cyfr.run"
      assert get_in(config, [:sanctum, :directory_url]) == "https://cyfr.run"
    end
  end

  test "a directory over http is accepted on this machine's loopback alone" do
    config = runtime(:dev, %{"CYFR_DIRECTORY_URL" => "http://127.79.0.1:4702"})
    assert get_in(config, [:sanctum, :directory_url]) == "http://127.79.0.1:4702"

    for refused <- ["http://10.0.0.5", "http://dir.example", "http://127.0.0.1.example"] do
      assert_raise RuntimeError, ~r/CYFR_DIRECTORY_URL must be a directory URL/, fn ->
        runtime(:dev, %{"CYFR_DIRECTORY_URL" => refused})
      end
    end
  end

  # What each registry setting boots with, stored as written, and what
  # refuses the boot. The registry is named in signed requests by a host
  # name's grammar, so it takes no IPv6 literal; the OCI registry is reached
  # by URL alone and takes a bracketed one. `none` refuses in any case.
  @names ~w(registry.example registry.example:8443 REGISTRY.EXAMPLE 127.0.0.1:9 localhost
            localhost:65535)
  @refused [
    "none",
    "NONE",
    "None",
    "::1",
    "registry.example.",
    "https://registry.example",
    "registry.example/path",
    "registry.example:",
    "registry.example:0",
    "registry.example:65536",
    "registry example"
  ]

  test "the registry boots with a host name or an IPv4 address and an optional port, and nothing else" do
    for value <- @names do
      assert get_in(runtime(:prod, %{"CYFR_REGISTRY_URL" => value}), [:sanctum, :registry_url]) ==
               value
    end

    assert get_in(runtime(:prod, %{"CYFR_REGISTRY_URL" => ""}), [:sanctum, :registry_url]) ==
             "cyfr.run"

    for value <- @refused ++ ["[::1]:9", "[::1]"] do
      assert_raise RuntimeError,
                   ~r/CYFR_REGISTRY_URL must name this CYFR's registry, cyfr.run or one of its own/,
                   fn -> runtime(:prod, %{"CYFR_REGISTRY_URL" => value}) end
    end
  end

  test "the OCI registry also boots with a bracketed IPv6 address, and with nothing else" do
    for value <- @names ++ ["[::1]:9", "[::1]", "[2001:db8::1]:5000"] do
      assert get_in(runtime(:prod, %{"CYFR_OCI_REGISTRY_URL" => value}), [
               :cyfr,
               :oci_registry_url
             ]) ==
               value
    end

    for value <- @refused ++ ["[::1]:", "[::1]:0", "[zz::1]:9", "[::1]x"] do
      assert_raise RuntimeError, ~r/CYFR_OCI_REGISTRY_URL must name the OCI registry/, fn ->
        runtime(:prod, %{"CYFR_OCI_REGISTRY_URL" => value})
      end
    end
  end

  defmodule IPv6Registry do
    @moduledoc false
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "local-registry")
  end

  test "an OCI registry on an IPv6 address the transport reaches is one the boot takes" do
    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: IPv6Registry,
         scheme: :http,
         ip: {0, 0, 0, 0, 0, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    registry = "[::1]:#{port}"
    Env.put_app_env(:sanctum, :private_egress_targets, ["::1"])
    Env.put_app_env(:cyfr, :oci_registry_url, registry)
    ref = %Compendium.OCI.Reference{registry: registry, repository: "demo/catalysts/example"}

    assert {:ok, 200, _headers, "local-registry"} =
             Compendium.OCI.Transport.request(nil, :get, "/v2/", ref)

    assert get_in(runtime(:prod, %{"CYFR_OCI_REGISTRY_URL" => registry}), [
             :cyfr,
             :oci_registry_url
           ]) ==
             registry
  end

  # `config/runtime.exs` read for `env` with neither URL set but those in
  # `vars`, and the variables a production boot cannot do without.
  defp runtime(env, vars \\ %{}) do
    base = %{
      "CYFR_REGISTRY_URL" => nil,
      "CYFR_DIRECTORY_URL" => nil,
      "CYFR_OCI_REGISTRY_URL" => nil,
      "CYFR_DATABASE" => nil,
      "RELEASE_ROOT" => nil,
      "CYFR_SECRET_KEY_BASE" => Base.encode64(:crypto.strong_rand_bytes(48)),
      "RELEASE_NAME" => "cyfr"
    }

    base
    |> Map.merge(vars)
    |> Enum.reduce(
      fn ->
        Config.Reader.read!(Path.join(@root, "config/runtime.exs"), env: env, imports: :disabled)
      end,
      fn
        {key, nil}, read -> fn -> Env.without_system_env(key, read) end
        {key, value}, read -> fn -> Env.with_system_env(key, value, read) end
      end
    )
    |> then(& &1.())
  end
end
