# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RouterTenancyTest do
  @moduledoc """
  What a caller with no credential may reach, and that the answer is the
  same one discovery gives.

  These tests used to assert that component browsing was open on an install
  with no auth provider. It never was: the Router waved the call through and
  the dispatcher refused it a moment later for want of `requires_auth: false`,
  so the assertion — "the Router did not say auth_required" — held while the
  call still failed. The promise is gone now, and the surface is one list.
  """
  use ExUnit.Case, async: false

  alias Emissary.MCP.Router

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    :ok
  end

  # public_tool_action? is private, so it is exercised through dispatch.

  defp make_context(authenticated) do
    Sanctum.Context.build(
      user_id: if(authenticated, do: "test_user", else: nil),
      athanor_id: if(authenticated, do: "ath_test", else: nil),
      permissions: if(authenticated, do: [:*], else: []),
      scope: :athanor,
      auth_method: if(authenticated, do: :oidc, else: nil),
      authenticated: authenticated
    )
  end

  defp tool_call_msg(tool_name, action) do
    %Emissary.MCP.Message{
      type: :request,
      method: "tools/call",
      id: "test-#{System.unique_integer([:positive])}",
      params: %{
        "name" => tool_name,
        "arguments" => %{"action" => action}
      }
    }
  end

  # An anonymous call is refused whether the Router turns it away or the
  # dispatcher does. Both are "you may not", and a test that accepts only one
  # of them mistakes a dead promise for a working door.
  defp refused?(result) do
    case result do
      {:error, :auth_required, _} -> true
      {:error, message} when is_binary(message) -> message =~ "Unauthorized"
      {:ok, %{"isError" => true, "content" => [%{"text" => text} | _]}} -> text =~ "Unauthorized"
      _ -> false
    end
  end

  defp with_auth_provider(provider, fun) do
    original = Application.get_env(:cyfr, :auth_provider)

    if provider,
      do: Application.put_env(:cyfr, :auth_provider, provider),
      else: Application.delete_env(:cyfr, :auth_provider)

    try do
      fun.()
    after
      if original,
        do: Application.put_env(:cyfr, :auth_provider, original),
        else: Application.delete_env(:cyfr, :auth_provider)
    end
  end

  # The operator authenticates with an API key on every install, so the
  # anonymous surface does not widen when no auth provider is configured.
  for {label, provider} <- [
        {"no auth provider", nil},
        {"auth provider configured", Emissary.TestAuthProvider}
      ] do
    describe "the anonymous surface — #{label}" do
      @provider provider

      test "session and system.status stay reachable" do
        with_auth_provider(@provider, fn ->
          ctx = make_context(false)

          refute refused?(Router.dispatch(ctx, tool_call_msg("session", "whoami")))
          refute refused?(Router.dispatch(ctx, tool_call_msg("system", "status")))
        end)
      end

      test "component browsing is not reachable" do
        with_auth_provider(@provider, fn ->
          ctx = make_context(false)

          for action <- ~w(list search inspect categories setup_plan) do
            assert refused?(Router.dispatch(ctx, tool_call_msg("component", action))),
                   "component.#{action} answered an anonymous caller"
          end
        end)
      end

      test "aqua and registry are not reachable" do
        with_auth_provider(@provider, fn ->
          ctx = make_context(false)

          for {tool, action} <- [
                {"aqua", "list"},
                {"aqua", "get"},
                {"aqua", "create"},
                {"registry", "probe"},
                {"registry", "claim_personal"}
              ] do
            assert refused?(Router.dispatch(ctx, tool_call_msg(tool, action))),
                   "#{tool}.#{action} answered an anonymous caller"
          end
        end)
      end
    end
  end

  describe "an authenticated caller" do
    test "reaches component browsing" do
      with_auth_provider(Emissary.TestAuthProvider, fn ->
        ctx = make_context(true)

        refute refused?(Router.dispatch(ctx, tool_call_msg("component", "list")))
      end)
    end
  end
end
