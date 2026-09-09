# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.OAuthHandlerTest do
  @moduledoc """
  The `cyfr:oauth/token` host boundary.

  Checks that typed vault refusals become bounded string errors at the
  WIT result<string, string> boundary without raising into the guest.
  """
  use ExUnit.Case, async: true

  alias Opus.OAuthHandler

  defp token_fn(resolver) do
    imports =
      OAuthHandler.build_oauth_imports(
        Sanctum.TestContext.local(),
        "catalyst:local.probe:0.1.0",
        "exec_oauth_#{System.unique_integer([:positive])}",
        resolver: resolver
      )

    {:fn, fun} = imports["cyfr:oauth/token@0.1.0"]["get-access-token"]
    fun
  end

  test "every refusal crosses as a string" do
    reasons = [
      :binding_mismatch,
      :anonymous_denied,
      :unseal_failed,
      :no_oauth_material,
      {:provider_mismatch, "github"},
      {:scope_projection_unsatisfiable, ["a", "b"]},
      {:invalid_payload, %{"secret" => "leak"}}
    ]

    for reason <- reasons do
      fun = token_fn(fn _p -> {:error, reason} end)

      assert {:error, message} = fun.("google")
      assert is_binary(message), "#{inspect(reason)} crossed as #{inspect(message)}"
    end
  end

  test "a refusal does not carry the payload it refused" do
    # The reason may quote the material it could not use; the guest gets the
    # shape of the failure, not its contents.
    fun = token_fn(fn _p -> {:error, {:invalid_payload, %{"secret" => "cyfr_live_leak"}}} end)

    assert {:error, message} = fun.("google")
    refute message =~ "cyfr_live_leak"
  end

  test "a resolver that raises is a refusal, not a fault in the guest" do
    fun = token_fn(fn _p -> raise "resolver blew up" end)

    assert {:error, message} = fun.("google")
    assert is_binary(message)
  end

  test "a resolver that exits is a refusal too" do
    fun = token_fn(fn _p -> exit(:boom) end)

    assert {:error, message} = fun.("google")
    assert is_binary(message)
  end

  test "the guest-supplied provider name is bounded" do
    # It is guest input and it reaches telemetry and a log line; nothing
    # bounded it.
    fun = token_fn(fn p -> {:error, "no such provider: #{p}"} end)

    assert {:error, message} = fun.(String.duplicate("x", 10_000))
    assert byte_size(message) < 1_000
  end

  test "a successful dispense still returns the token" do
    fun = token_fn(fn _p -> {:ok, "tok-live"} end)
    assert {:ok, "tok-live"} = fun.("google")
  end
end
