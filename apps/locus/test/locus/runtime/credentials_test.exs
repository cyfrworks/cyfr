# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.CredentialsTest do
  @moduledoc """
  A worker service is what `config :locus, :runtime` says it is, and
  nothing else: its id, the worker key CYFR derived for it, where CYFR is
  and where it listens. Each value missing or malformed refuses; the keys
  it derives are the ones CYFR derives; and the control plane's own
  configuration in a runtime node's environment refuses the node, through
  the one list every role's boot reads (`Locus.Config`).
  """

  # The boot refusal edits the application environment the running service
  # was started from, so this module runs alone.
  use ExUnit.Case, async: false

  alias Prima.WorkerAuth
  alias Locus.Runtime.Credentials

  @worker_key :crypto.hash(:sha256, "credentials-test")
  @env [
    service_id: "wrk_test",
    service_key: Base.encode16(@worker_key, case: :lower),
    host_url: "http://cyfr.internal:4300/",
    bind: "0.0.0.0",
    port: 4200
  ]

  test "well-formed values load, and the dispatch keys are the ones CYFR derives" do
    assert {:ok, %Credentials{} = credentials} = Credentials.load(@env)
    assert credentials.service_id == "wrk_test"
    assert credentials.worker_key == @worker_key
    assert credentials.dispatch_key == WorkerAuth.dispatch_key(@worker_key)
    assert credentials.dispatch_seal_key == WorkerAuth.dispatch_seal_key(@worker_key)
    assert credentials.host_url == "http://cyfr.internal:4300"
    assert credentials.bind == {0, 0, 0, 0}
    assert credentials.port == 4200
  end

  test "the key is read in either case, and an IPv6 bind address parses" do
    env = Keyword.merge(@env, service_key: Base.encode16(@worker_key, case: :upper), bind: "::1")

    assert {:ok, %{worker_key: @worker_key, bind: {0, 0, 0, 0, 0, 0, 0, 1}}} =
             Credentials.load(env)
  end

  test "each value missing refuses by name" do
    for key <- [:service_id, :service_key, :host_url, :bind, :port] do
      assert {:error, {:missing, ^key}} = Credentials.load(Keyword.delete(@env, key))
    end
  end

  test "each value malformed refuses by name" do
    malformed = [
      service_id: ["local", "wrk_", "wrk_" <> String.duplicate("a", 65), "wrk_a b", 42],
      service_key: ["abc", String.duplicate("0", 63), String.duplicate("zz", 32), @worker_key],
      host_url: [
        "cyfr:4300",
        "ftp://cyfr",
        "http://",
        "http://cyfr/host/v1",
        "http://cyfr?x=1",
        1
      ],
      bind: ["localhost", "999.0.0.1", "", 1],
      port: ["4200", -1, 65_536, 1.5]
    ]

    for {key, values} <- malformed, value <- values do
      assert {:error, {:malformed, ^key}} = Credentials.load(Keyword.put(@env, key, value)),
             "#{inspect(value)} was accepted as #{key}"
    end
  end

  test "a refusal raises the boot with the value named, never with the value shown" do
    previous = Locus.Runtime.Settings.env()
    Application.put_env(:locus, :runtime, Keyword.delete(@env, :host_url))

    try do
      assert_raise ArgumentError, ~r/:host_url is not set/, &Credentials.load!/0

      Locus.Runtime.Test.Env.merge(
        host_url: "http://cyfr.internal:4300",
        service_key: "not-a-key"
      )

      error = assert_raise(ArgumentError, ~r/:service_key is malformed/, &Credentials.load!/0)
      refute error.message =~ "not-a-key"
    after
      Locus.Runtime.Test.Env.restore(previous)
    end
  end

  test "the control plane's configuration in a runtime node's environment is refused by name" do
    env = fn map -> &Map.get(map, &1) end

    key = %{
      "LOCUS_RUNTIME_KEY" => String.duplicate("ab", 32),
      "LOCUS_RUNTIME_HOST_API_URL" => "http://cyfr:4300"
    }

    assert Locus.Config.refused_environment(env.(Map.merge(key, %{"PATH" => "/bin"}))) == []

    refused =
      Locus.Config.refused_environment(
        env.(
          Map.merge(key, %{
            "CYFR_LOCUS_RUNTIME_ROOT" => "x",
            "CYFR_DATABASE_URL" => "postgres://",
            "CYFR_CRYPTO_KEYRING" => "y",
            "LOCUS_RUNTIME_PORT" => "4200"
          })
        )
      )

    assert Enum.sort(refused) ==
             Enum.sort(["CYFR_LOCUS_RUNTIME_ROOT", "CYFR_CRYPTO_KEYRING", "CYFR_DATABASE_URL"])
  end

  test "a credential's inspection shows its identity and never its keys" do
    {:ok, credentials} = Credentials.load(@env)
    shown = inspect(credentials, limit: :infinity)

    assert shown =~ "wrk_test"
    assert shown =~ "cyfr.internal"

    for key <- [credentials.worker_key, credentials.dispatch_key, credentials.dispatch_seal_key] do
      refute shown =~ inspect(key, limit: :infinity)
      refute shown =~ Base.encode16(key, case: :lower)
    end
  end

  test "the running worker service installed the credentials the suite configured" do
    assert %Credentials{service_id: "wrk_local", port: 0} = Credentials.current()
  end
end
