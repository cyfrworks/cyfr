# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Cyfr.Authority.TransitionToolTest do
  use ExUnit.Case, async: true

  alias Cyfr.Authority
  alias Cyfr.Authority.Transition
  alias Cyfr.Test.AuthorityFixtures, as: Fixtures

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

      assert {:deny, :tool_not_granted} =
               Transition.step(auth, :call, tool("component", "search"))

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

      assert {:deny, :unbound_control_plane} =
               Transition.step(zero, :call, tool("storage", "read"))

      assert {:deny, :unbound_control_plane} =
               Transition.step(zero, :call, external(Fixtures.server_digest(), "repo_get"))
    end
  end

  # External tool servers

  describe "external tool servers" do
    test "a granted server authorizes tools matching its patterns" do
      auth = Fixtures.root!()
      digest = Fixtures.server_digest()

      assert {:allow_tool, {:tool_server, ^digest}} =
               Transition.step(auth, :call, external(digest, "issues.list"))

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
               Transition.step(auth, :call, external("sha256:other-server", "issues.list"))
    end
  end

  # ============================================================================
  # Grant predicates — the membership halves, shared with discovery
  # ============================================================================

  describe "tool_granted?/3 and external_tool_granted?/3" do
    test "agree with the step verdicts on the same edge" do
      auth = Fixtures.root!()

      assert Transition.tool_granted?(auth, "storage", "read")
      refute Transition.tool_granted?(auth, "storage", "write")
      refute Transition.tool_granted?(auth, "component", "search")
      # Exact membership — no prefix semantics.
      refute Transition.tool_granted?(auth, "storage", "rea")

      assert Transition.external_tool_granted?(auth, Fixtures.server_digest(), "repo_get") ==
               match?(
                 {:allow_tool, _},
                 Transition.step(auth, :call, external(Fixtures.server_digest(), "repo_get"))
               )

      refute Transition.external_tool_granted?(auth, "sha256:unknown", "repo_get")
    end

    test ":none resources grant nothing" do
      auth = %{Fixtures.root!() | resources: :none}

      refute Transition.tool_granted?(auth, "storage", "read")
      refute Transition.external_tool_granted?(auth, Fixtures.server_digest(), "repo_get")
    end
  end
end
