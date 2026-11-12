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
