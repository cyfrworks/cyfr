# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.ManifestPolicyTest do
  use ExUnit.Case, async: false

  alias Sanctum.Policy.ManifestPolicy
  import Sanctum.Test.ComponentHelpers

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()

    arca_ok = arca_available?()

    name = "manifest-policy-#{:rand.uniform(1_000_000)}"

    if arca_ok do
      register_test_component(name, "1.0.0", "catalyst", %{
        "setup" => %{"policy" => %{"allowed_domains" => ["v1.example"]}}
      })

      register_test_component(name, "2.0.0", "catalyst", %{
        "setup" => %{"policy" => %{"allowed_domains" => ["v2.example"]}}
      })
    end

    {:ok, name: name, arca_available: arca_ok}
  end

  defp arca_available? do
    Code.ensure_loaded?(Arca.ComponentStorage) and
      Code.ensure_loaded?(Arca.Repo) and
      match?({:ok, _}, Arca.Repo.query("SELECT 1"))
  rescue
    _ -> false
  end

  describe "fetch/3 resolve mode (load-bearing behaviour nuance)" do
    test ":exact_or_latest resolves a versioned ref against THAT version's manifest",
         %{name: name, arca_available: arca} do
      if arca do
        ctx = Sanctum.TestContext.local()

        assert {:ok, sp} =
                 ManifestPolicy.fetch(ctx, "catalyst:local.#{name}:1.0.0",
                   resolve: :exact_or_latest
                 )

        assert sp["allowed_domains"] == ["v1.example"]
      end
    end

    test ":exact_or_latest resolves a name-level ref against the latest manifest",
         %{name: name, arca_available: arca} do
      if arca do
        ctx = Sanctum.TestContext.local()

        assert {:ok, sp} =
                 ManifestPolicy.fetch(ctx, "catalyst:local.#{name}", resolve: :exact_or_latest)

        assert sp["allowed_domains"] == ["v2.example"]
      end
    end

    test ":latest ignores a pinned version and always reads the latest manifest",
         %{name: name, arca_available: arca} do
      if arca do
        ctx = Sanctum.TestContext.local()

        # Versioned ref but :latest mode → v2 (latest), NOT v1. This is the
        # exact divergence a naive single helper would have silently broken.
        assert {:ok, sp} =
                 ManifestPolicy.fetch(ctx, "catalyst:local.#{name}:1.0.0", resolve: :latest)

        assert sp["allowed_domains"] == ["v2.example"]
      end
    end

    test "default mode is :latest", %{name: name, arca_available: arca} do
      if arca do
        ctx = Sanctum.TestContext.local()

        assert {:ok, sp} = ManifestPolicy.fetch(ctx, "catalyst:local.#{name}:1.0.0")
        assert sp["allowed_domains"] == ["v2.example"]
      end
    end

    test "unregistered component yields {:error, :not_found}",
         %{arca_available: arca} do
      if arca do
        ctx = Sanctum.TestContext.local()
        ref = "catalyst:local.does-not-exist-#{:rand.uniform(99_999)}"

        assert {:error, :not_found} = ManifestPolicy.fetch(ctx, ref, resolve: :latest)
      end
    end

    test "manifest with no setup.policy yields {:ok, %{}}",
         %{arca_available: arca} do
      if arca do
        ctx = Sanctum.TestContext.local()
        bare = "bare-#{:rand.uniform(1_000_000)}"
        register_test_component(bare, "1.0.0", "catalyst", %{"setup" => %{}})

        assert {:ok, %{}} =
                 ManifestPolicy.fetch(ctx, "catalyst:local.#{bare}:1.0.0",
                   resolve: :exact_or_latest
                 )
      end
    end
  end
end
