# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Compendium.OCILocalNamespaceTest do
  # The filesystem-registration exemption depends on ingress, never the publisher string.
  use ExUnit.Case, async: false

  alias Compendium.OCI

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # Both spellings resolve to the `local` namespace. The first skips
  # component_tool's friendly check because it contains a "/"; the second
  # additionally names the canonical registry host.
  defp refused do
    host = Compendium.RegistryHost.canonical_host()

    [
      "local/reagents/sneaky:1.0.0",
      "#{host}/local/formulas/sneaky:1.0.0",
      "#{host}/local/catalysts/sneaky:0.1.0"
    ]
  end

  describe "pull refusal" do
    test "every local-namespace ref is refused", %{ctx: ctx} do
      for ref <- refused() do
        assert {:error, message} = OCI.Client.pull(ctx, ref)

        assert message =~ "local namespace",
               "#{ref} was not refused for its namespace: #{inspect(message)}"
      end
    end

    test "the refusal precedes any network I/O", %{ctx: ctx} do
      # A registry host that cannot resolve: if the pull reached the network
      # it would fail with a transport error instead. Refusing first is the
      # point — a rejected namespace must cost nothing and must not depend
      # on what a remote registry says.
      assert {:error, message} =
               OCI.Client.pull(
                 ctx,
                 "#{Compendium.RegistryHost.canonical_host()}/local/reagents/sneaky:1.0.0"
               )

      assert message =~ "local namespace"
      refute message =~ "Failed"
      refute message =~ "connect"
    end

    test "a non-local namespace is not caught by the gate" do
      # Pure check on the same predicate the gate applies — no network.
      {:ok, ref} =
        OCI.Reference.parse(
          "#{Compendium.RegistryHost.canonical_host()}/moonmoon69/reagents/thing:1.0.0"
        )

      {:ok, component_ref} = OCI.Reference.to_component_ref(ref)

      assert component_ref.namespace == "moonmoon69"
      refute Compendium.ComponentPath.local_publisher?(component_ref.namespace)
    end

    test "both refused spellings really do resolve to the local namespace" do
      for spelling <- refused() do
        {:ok, ref} = OCI.Reference.parse(spelling)
        {:ok, component_ref} = OCI.Reference.to_component_ref(ref)

        assert component_ref.namespace == "local",
               "#{spelling} did not resolve to the local namespace — the gate would be moot"
      end
    end
  end

  describe "the component tool's early check" do
    test "refuses a bare local ref with an actionable message", %{ctx: ctx} do
      assert {:error, message} =
               Compendium.Providers.Component.handle(ctx, %{
                 "action" => "pull",
                 "reference" => "reagent:local.thing:1.0.0"
               })

      assert message =~ "not a version the server ships"
      assert message =~ "cyfr register"
    end
  end

  describe "local_publisher?/1" do
    test "is the single source of truth for the namespace distinction" do
      assert Compendium.ComponentPath.local_publisher?("local")
      # An absent publisher normalizes to local — so it is local, and a pull
      # naming no publisher must not slip through as "not local".
      assert Compendium.ComponentPath.local_publisher?(nil)
      assert Compendium.ComponentPath.local_publisher?("")
      refute Compendium.ComponentPath.local_publisher?("moonmoon69")
      refute Compendium.ComponentPath.local_publisher?("Local")
    end
  end
end
