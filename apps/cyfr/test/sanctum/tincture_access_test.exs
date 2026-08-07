# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TinctureAccessTest do
  use ExUnit.Case, async: false

  alias Sanctum.{Context, TinctureAccess}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Public-ness reads the profiles table now; point the source at it.
    original_source = Application.get_env(:cyfr, :consent_source)
    Application.put_env(:cyfr, :consent_source, Sanctum.Consent.Source.DB)

    on_exit(fn ->
      if original_source,
        do: Application.put_env(:cyfr, :consent_source, original_source),
        else: Application.delete_env(:cyfr, :consent_source)
    end)

    # Create temp tincture structure with one public and one private tincture
    base = Path.join(System.tmp_dir!(), "tincture_access_test_#{:rand.uniform(1_000_000)}")
    components_dir = Path.join(base, "components")

    # Public tincture
    pub_dir = Path.join([components_dir, "tinctures", "local", "public-dash", "1.0.0"])
    File.mkdir_p!(pub_dir)

    pub_manifest = %{
      "name" => "public-dash",
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "description" => "Public Dashboard",
      "tincture" => %{
        "entry" => "index.html",
        "public" => true,
        "window" => %{"width" => 800, "height" => 600}
      },
      "schema" => %{
        "tables" => %{},
        "queries" => %{
          "latest" => %{
            "sql" => "SELECT 1",
            "params" => %{},
            "cache_ttl" => 60
          }
        }
      }
    }

    File.write!(Path.join(pub_dir, "cyfr-manifest.json"), Jason.encode!(pub_manifest))
    File.write!(Path.join(pub_dir, "index.html"), "<html></html>")

    # Private tincture
    priv_dir = Path.join([components_dir, "tinctures", "local", "private-dash", "1.0.0"])
    File.mkdir_p!(priv_dir)

    priv_manifest = %{
      "name" => "private-dash",
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "description" => "Private Dashboard",
      "tincture" => %{
        "entry" => "index.html",
        "public" => false,
        "window" => %{"width" => 800, "height" => 600}
      },
      "schema" => %{
        "tables" => %{},
        "queries" => %{}
      }
    }

    File.write!(Path.join(priv_dir, "cyfr-manifest.json"), Jason.encode!(priv_manifest))
    File.write!(Path.join(priv_dir, "index.html"), "<html></html>")

    # Point components_path to temp dir so Arca.Adapters.Local.components_path() resolves there
    original_path = Application.get_env(:cyfr, :components_path)
    Application.put_env(:cyfr, :components_path, components_dir)

    ctx = Sanctum.TestContext.local()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # Register components in SQLite so Compendium.Registry.get_latest finds them
    {:ok, _} =
      Arca.ComponentStorage.put_component(ctx, %{
        id: "test_pub_dash_#{:rand.uniform(1_000_000)}",
        name: "public-dash",
        version: "1.0.0",
        component_type: "tincture",
        description: "Public Dashboard",
        tags: "[]",
        digest: "sha256:test_pub",
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(pub_manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: "local",
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    {:ok, _} =
      Arca.ComponentStorage.put_component(ctx, %{
        id: "test_priv_dash_#{:rand.uniform(1_000_000)}",
        name: "private-dash",
        version: "1.0.0",
        component_type: "tincture",
        description: "Private Dashboard",
        tags: "[]",
        digest: "sha256:test_priv",
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(priv_manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: "local",
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    # Store tincture policies (visibility is now a policy field)
    pub_ref = "tincture:local.public-dash"
    priv_ref = "tincture:local.private-dash"

    # Public-ness is a published profile now, not a policy bit.
    _ = priv_ref

    {:ok, _} =
      Arca.ProfileStorage.put(%{
        id: "prof_pub_#{:rand.uniform(1_000_000)}",
        org_id: ctx.org_id,
        project_id: ctx.project_id,
        source_ref: pub_ref,
        kind: "public",
        label: "public",
        status: "active"
      })

    on_exit(fn ->
      if original_path do
        Application.put_env(:cyfr, :components_path, original_path)
      else
        Application.delete_env(:cyfr, :components_path)
      end

      # Clean up policy cache entries
      Arca.Cache.invalidate({:policy, pub_ref, "", "default"})
      Arca.Cache.invalidate({:policy, priv_ref, "", "default"})

      File.rm_rf!(base)
    end)

    %{components_dir: components_dir}
  end

  describe "get_private/3" do
    test "returns tincture for authenticated context" do
      ctx = Sanctum.TestContext.local()
      assert {:ok, tincture} = TinctureAccess.get_private(ctx, "local", "public-dash")
      assert tincture.name == "public-dash"
    end

    test "returns private tincture for authenticated context" do
      ctx = Sanctum.TestContext.local()
      assert {:ok, tincture} = TinctureAccess.get_private(ctx, "local", "private-dash")
      assert tincture.name == "private-dash"
    end

    test "returns :not_found for nonexistent tincture" do
      ctx = Sanctum.TestContext.local()
      assert {:error, :not_found} = TinctureAccess.get_private(ctx, "local", "nonexistent")
    end

    test "returns :not_found for invalid publisher" do
      ctx = Sanctum.TestContext.local()
      assert {:error, :not_found} = TinctureAccess.get_private(ctx, "../evil", "public-dash")
    end

    test "returns :not_found for invalid name" do
      ctx = Sanctum.TestContext.local()
      assert {:error, :not_found} = TinctureAccess.get_private(ctx, "local", "../etc/passwd")
    end
  end

  describe "get_public/3" do
    test "returns public tincture" do
      ctx = Context.build(org_id: "local", project_id: "default", authenticated: false)
      assert {:ok, tincture} = TinctureAccess.get_public(ctx, "local", "public-dash")
      assert tincture.name == "public-dash"
    end

    test "returns :not_found for private tincture (indistinguishable)" do
      ctx = Context.build(org_id: "local", project_id: "default", authenticated: false)
      assert {:error, :not_found} = TinctureAccess.get_public(ctx, "local", "private-dash")
    end

    test "returns :not_found for nonexistent tincture" do
      ctx = Context.build(org_id: "local", project_id: "default", authenticated: false)
      assert {:error, :not_found} = TinctureAccess.get_public(ctx, "local", "nonexistent")
    end

    test "fails closed for an unresolved org when a stricter tenant policy is configured" do
      # build/1 canonicalizes nil → the "local" sentinel; under a stricter
      # tenant policy an unresolved org must fail closed even for a public tincture.
      ctx = Context.build(org_id: nil, project_id: "default", authenticated: false)
      assert {:error, :not_found} = TinctureAccess.get_public(ctx, "local", "public-dash")
    end

    test "returns :not_found for invalid publisher" do
      ctx = Context.build(org_id: "local", project_id: "default", authenticated: false)

      assert {:error, :not_found} =
               TinctureAccess.get_public(ctx, "bad publisher!", "public-dash")
    end

    test "returns :not_found for invalid name" do
      ctx = Context.build(org_id: "local", project_id: "default", authenticated: false)
      assert {:error, :not_found} = TinctureAccess.get_public(ctx, "local", "bad name!")
    end
  end
end
