# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Registry.ClientTest do
  # The registry does not answer here: `config/test.exs` points both registry
  # endpoints at 127.0.0.1:19, a loopback port with no listener, so every
  # call is refused on this machine and none reaches a registry. Tests that
  # point the client elsewhere change the global `:registry_url`, or
  # capture its log, and live in
  # `Compendium.Registry.ClientSyncTest`.
  use ExUnit.Case, async: true

  alias Compendium.Registry.Client
  alias Compendium.Provider
  alias Compendium.OCI.Errors

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # ============================================================================
  # Registry.Client — Error Handling
  # ============================================================================

  describe "search/2 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.search(ctx, %{query: "test"})
      assert err.registry == "cyfr.run"
      assert err.reason == :registry_unavailable
    end

    test "accepts empty params", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.search(ctx, %{})
      assert err.registry == "cyfr.run"
    end
  end

  describe "discover/2 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.discover(ctx, %{namespace: "cyfr"})
      assert err.registry == "cyfr.run"
      assert err.reason == :registry_unavailable
    end

    test "accepts empty params", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.discover(ctx, %{})
      assert err.registry == "cyfr.run"
    end
  end

  describe "get_component/5 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable", %{ctx: ctx} do
      {:error, %Errors{} = err} =
        Client.get_component(ctx, "reagent", "cyfr", "data-processor", "1.0.0")

      assert err.registry == "cyfr.run"
      assert err.reason == :registry_unavailable
    end
  end

  # Registry endpoint error paths against an unreachable host.

  describe "signed/3 - error handling" do
    test "a person with no identifier is refused before anything is sent" do
      user = Sanctum.Test.RegistryStub.person!()

      assert {:error, :not_enrolled} =
               Client.signed(user.id, "handle.claim", %{"handle" => "alice"})
    end

    test "an unreachable registry is unavailable for every operation, and nothing is written" do
      user = Sanctum.Test.RegistryStub.person!()
      Sanctum.Test.RegistryStub.enroll!(user.id)

      for {operation, body} <- [
            {"handle.claim", %{"handle" => "alice"}},
            {"tokens.mint", %{"label" => "laptop"}},
            {"address.set", %{}},
            {"policy.accept", %{"policy_version" => "2026-09"}},
            {"appeal.file",
             %{"action_type" => "ban", "action_ref" => "x", "argument" => "it was not me"}},
            {"publisher.claim", %{"slug" => "acme.com"}},
            {"publisher.verify", %{"slug" => "acme.com", "label" => "laptop"}}
          ] do
        assert {:error, :registry_unavailable} = Client.signed(user.id, operation, body),
               operation
      end

      assert {:ok, %{namespace: nil}} = Sanctum.Tenancy.Users.get(user.id)
    end
  end

  describe "get_namespace/1 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable" do
      {:error, %Errors{} = err} = Client.get_namespace("alice")
      assert err.reason == :registry_unavailable
    end
  end

  describe "list_tokens/2 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable" do
      {:error, %Errors{} = err} = Client.list_tokens("alice", "fake-bearer")
      assert err.reason == :registry_unavailable
    end
  end

  describe "issue_additional_token/3 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable" do
      {:error, %Errors{} = err} =
        Client.issue_additional_token("alice", "fake-bearer", "ci-laptop")

      assert err.reason == :registry_unavailable
    end
  end

  describe "revoke_token/3 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable" do
      {:error, %Errors{} = err} =
        Client.revoke_token("alice", "01H8K9XZABC", "fake-bearer")

      assert err.reason == :registry_unavailable
    end
  end

  describe "members CRUD - error handling" do
    test "add_member returns %Errors{} on connection refused" do
      {:error, %Errors{} = err} =
        Client.add_member("acme.com", "alice", "member", "fake-bearer")

      assert err.reason == :registry_unavailable
    end

    test "update_member returns %Errors{} on connection refused" do
      {:error, %Errors{} = err} =
        Client.update_member("acme.com", "alice", "admin", "fake-bearer")

      assert err.reason == :registry_unavailable
    end

    test "remove_member returns %Errors{} on connection refused" do
      {:error, %Errors{} = err} =
        Client.remove_member("acme.com", "alice", "fake-bearer")

      assert err.reason == :registry_unavailable
    end

    test "list_members returns %Errors{} on connection refused" do
      {:error, %Errors{} = err} = Client.list_members("acme.com", "fake-bearer")
      assert err.reason == :registry_unavailable
    end
  end

  describe "MCP component.deprecate" do
    test "rejects missing reason", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "deprecate",
          "reference" => "c:alice.widget:1.0.0"
        })

      assert err_msg(msg) =~ "reason"
    end

    test "rejects empty reason", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "deprecate",
          "reference" => "c:alice.widget:1.0.0",
          "reason" => ""
        })

      assert err_msg(msg) =~ "reason"
    end

    test "rejects unpinned ref (no version)", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "deprecate",
          "reference" => "c:alice.widget",
          "reason" => "use v2"
        })

      assert err_msg(msg) =~ "pinned version"
    end
  end

  describe "MCP registry.report" do
    test "rejects missing category", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("registry", ctx, %{
          "action" => "report",
          "target_namespace" => "alice",
          "details" => "d"
        })

      assert err_msg(msg) =~ "category"
    end

    test "rejects missing target", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("registry", ctx, %{
          "action" => "report",
          "category" => "malware",
          "details" => "d"
        })

      assert err_msg(msg) =~ "target"
    end

    test "rejects missing details", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("registry", ctx, %{
          "action" => "report",
          "category" => "malware",
          "target_namespace" => "alice"
        })

      assert err_msg(msg) =~ "details"
    end
  end

  describe "MCP component.yank" do
    # The gate casts the call against the action's declaration
    # (`Prima.Operation.cast/2`) before the handler runs.
    test "rejects missing reference" do
      assert {:error, {:invalid_argument, "Missing required field: reference"}} =
               Prima.Operation.cast(Compendium.Providers.Component.definition(), %{
                 "action" => "yank"
               })
    end

    test "rejects unpinned ref", %{ctx: ctx} do
      {:error, msg} =
        Provider.handle("component", ctx, %{
          "action" => "yank",
          "reference" => "c:alice.widget"
        })

      assert err_msg(msg) =~ "pinned version"
    end
  end

  # Providers answer typed reasons where the class is clear; the shared
  # renderer is the one spelling of every sentence, so assert through it.
  # Plain strings pass through unchanged.
  defp err_msg(reason) do
    Sanctum.Refusals.render(reason) ||
      flunk("unrenderable refusal: #{inspect(reason)}")
  end
end
