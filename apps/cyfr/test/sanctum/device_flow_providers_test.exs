# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceFlowProvidersTest do
  @moduledoc """
  `provider` on `session.device_init` comes straight from the caller, and
  nothing validated it. `normalize_provider/1` passes an unrecognised name
  through unchanged, so it reached a `get_client_id/1` with clauses only for
  `:github` and `:google` — a FunctionClauseError out of an MCP tool.

  Provider availability requires credentials sufficient for token exchange,
  including both a client id and secret for Google.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Auth.DeviceFlow

  setup do
    original = {
      Application.get_env(:cyfr, :github_client_id),
      Application.get_env(:cyfr, :google_client_id),
      Application.get_env(:cyfr, :google_client_secret)
    }

    on_exit(fn ->
      {gh, g_id, g_secret} = original
      put(:github_client_id, gh)
      put(:google_client_id, g_id)
      put(:google_client_secret, g_secret)
    end)

    put(:github_client_id, nil)
    put(:google_client_id, nil)
    put(:google_client_secret, nil)
    :ok
  end

  defp put(key, nil), do: Application.delete_env(:cyfr, key)
  defp put(key, value), do: Application.put_env(:cyfr, key, value)

  describe "an unknown provider" do
    test "is refused by name rather than crashing" do
      for verb <- [
            fn p -> DeviceFlow.init_device_flow(p, nil) end,
            fn p -> DeviceFlow.poll_for_session(p, "dc", nil) end,
            fn p -> DeviceFlow.poll_for_access_token(p, "dc", nil) end
          ] do
        assert {:error, {:unknown_provider, "okta"}} = verb.("okta")
      end
    end

    test "is told apart from a provider the operator simply has not configured" do
      put(:github_client_id, "gh_id")

      assert {:error, {:client_id_not_configured, :google}} =
               DeviceFlow.init_device_flow("google", nil)

      assert {:error, {:unknown_provider, "azure"}} = DeviceFlow.init_device_flow("azure", nil)
    end
  end

  describe "provider?/1" do
    test "accepts both spellings of a known name and nothing else" do
      assert DeviceFlow.provider?("github")
      assert DeviceFlow.provider?(:github)
      refute DeviceFlow.provider?("okta")
      refute DeviceFlow.provider?(:okta)
      refute DeviceFlow.provider?(%{"provider" => "github"})
      refute DeviceFlow.provider?(nil)
    end
  end

  describe "configured_providers/0" do
    test "none configured => nothing to offer" do
      assert DeviceFlow.configured_providers() == []
    end

    test "GitHub needs only a client id; Google needs the secret too" do
      put(:github_client_id, "gh_id")
      assert DeviceFlow.configured_providers() == [:github]

      put(:google_client_id, "g_id")

      assert DeviceFlow.configured_providers() == [:github],
             "a Google client id without the secret cannot complete a token exchange"

      put(:google_client_secret, "g_secret")
      assert DeviceFlow.configured_providers() == [:github, :google]
    end

    test "a blank value is not a configured provider" do
      put(:github_client_id, "   ")
      assert DeviceFlow.configured_providers() == []
    end

    test "every configured provider is a known one" do
      put(:github_client_id, "gh_id")
      put(:google_client_id, "g_id")
      put(:google_client_secret, "g_secret")

      for provider <- DeviceFlow.configured_providers() do
        assert DeviceFlow.provider?(provider)
      end
    end
  end
end
