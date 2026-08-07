# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.TransitionToolTest do
  use ExUnit.Case, async: true

  alias Sanctum.Authority
  alias Sanctum.Authority.Transition
  alias Sanctum.Test.AuthorityFixtures, as: Fixtures

  @catalyst "catalyst:supabase.com.database"

  defp tool(name, action), do: {:tool, %{tool: name, action: action}}
  defp external(digest, tool), do: {:external_tool, %{server_digest: digest, tool: tool}}

  defp bound_child! do
    {:child, child} =
      Transition.step(
        Fixtures.root!(),
        :call,
        Fixtures.invoke(@catalyst, need: "source", declared_needs: Fixtures.formula_needs())
      )

    child
  end

  # ============================================================================
  # Registered tools — the current node's own edge resources only
  # ============================================================================

  describe "tool plane" do
    test "an expanded tool.action in the current edge is allowed, with the authorizing resource" do
      auth = Fixtures.root!()

      assert {:allow_tool, {:tools, "storage.read"}} =
               Transition.step(auth, :call, tool("storage", "read"))
    end

    test "anything not in the current edge is denied" do
      auth = Fixtures.root!()

      assert {:deny, :tool_not_granted} = Transition.step(auth, :call, tool("storage", "write"))
      assert {:deny, :tool_not_granted} = Transition.step(auth, :call, tool("component", "search"))
      # Exact membership — no prefix or glob semantics on tool actions.
      assert {:deny, :tool_not_granted} = Transition.step(auth, :call, tool("storage", "rea"))
    end

    test "a child consumes its own edge's tools, not the root's" do
      child = bound_child!()

      # The source edge grants storage.write; the root ingress does not.
      assert {:allow_tool, {:tools, "storage.write"}} =
               Transition.step(child, :call, tool("storage", "write"))

      # And the child does not inherit the root's tool servers.
      assert {:deny, :tool_server_not_granted} =
               Transition.step(child, :call, external(Fixtures.server_digest(), "repo_get"))
    end

    test "unbound executions have no control plane" do
      zero = Authority.zero()

      assert {:deny, :unbound_control_plane} = Transition.step(zero, :call, tool("storage", "read"))

      assert {:deny, :unbound_control_plane} =
               Transition.step(zero, :call, external(Fixtures.server_digest(), "repo_get"))
    end
  end

  # ============================================================================
  # External tool servers (§3.8)
  # ============================================================================

  describe "external tool servers" do
    test "a granted server authorizes tools matching its patterns" do
      auth = Fixtures.root!()
      digest = Fixtures.server_digest()

      assert {:allow_tool, {:tool_server, ^digest}} =
               Transition.step(auth, :call, external(digest, "issues_list"))

      assert {:allow_tool, {:tool_server, ^digest}} =
               Transition.step(auth, :call, external(digest, "repo_get"))
    end

    test "a tool outside the granted patterns is simply not callable" do
      auth = Fixtures.root!()

      assert {:deny, :tool_server_not_granted} =
               Transition.step(auth, :call, external(Fixtures.server_digest(), "repo_delete"))
    end

    test "one server's grant does not authorize another" do
      auth = Fixtures.root!()

      assert {:deny, :tool_server_not_granted} =
               Transition.step(auth, :call, external("sha256:other-server", "issues_list"))
    end
  end

  # ============================================================================
  # Spawned tool dispatch charges the root budget
  # ============================================================================

  describe "spawn budget on tools" do
    test "a spawned tool dispatch takes a slot; a denied one does not" do
      auth = Fixtures.root!(%{}, ceiling: %{max_concurrent_tasks: 1})

      assert {:deny, :tool_not_granted} = Transition.step(auth, :spawn, tool("storage", "write"))
      assert Authority.budget(auth).in_flight == 0

      assert {:allow_tool, _} = Transition.step(auth, :spawn, tool("storage", "read"))
      assert Authority.budget(auth).in_flight == 1

      assert {:deny, :invoke_budget_exhausted} =
               Transition.step(auth, :spawn, tool("storage", "read"))

      Authority.release_invoke(auth)

      assert {:allow_tool, _} =
               Transition.step(auth, :spawn, external(Fixtures.server_digest(), "repo_get"))
    end

    test "a synchronous tool call never consumes budget" do
      auth = Fixtures.root!(%{}, ceiling: %{max_concurrent_tasks: 1})

      for _ <- 1..5 do
        assert {:allow_tool, _} = Transition.step(auth, :call, tool("storage", "read"))
      end

      assert Authority.budget(auth).in_flight == 0
    end
  end
end
