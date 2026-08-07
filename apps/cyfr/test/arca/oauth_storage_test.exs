# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.OAuthStorageTest do
  # Characterization of the Arca layer beneath Sanctum.OAuth: upsert semantics,
  # the raw/decrypted cache-key pair, the provider-cred vs token cache-key
  # split, and tenant isolation. Sanctum.OAuth depends on each of these.
  use ExUnit.Case, async: false

  alias Arca.OAuthStorage

  @ref "catalyst:local.gmail"
  @provider "google"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()

    sweep = fn ->
      Arca.Cache.delete_match({:oauth_token, :_})
      Arca.Cache.delete_match({:oauth_token_dec, :_})
      Arca.Cache.delete_match({:oauth_cred, :_})
    end

    on_exit(sweep)
    sweep.()

    {:ok, org_id: ctx.org_id, project_id: ctx.project_id}
  end

  defp token_key(ref, provider, org_id, project_id) do
    {:oauth_token,
     {ref, provider, Arca.QueryHelpers.normalize_org_id(org_id),
      Arca.QueryHelpers.normalize_project_id(project_id)}}
  end

  defp dec_key(ref, provider, org_id, project_id) do
    {:oauth_token_dec,
     {ref, provider, Arca.QueryHelpers.normalize_org_id(org_id),
      Arca.QueryHelpers.normalize_project_id(project_id)}}
  end

  describe "put_token/5 and get_token/4" do
    test "round-trips an encrypted blob", %{org_id: org, project_id: proj} do
      :ok = OAuthStorage.put_token(@ref, @provider, <<1, 2, 3>>, org, proj)

      assert {:ok, <<1, 2, 3>>} = OAuthStorage.get_token(@ref, @provider, org, proj)
    end

    test "upserts in place on (provider, component_ref, org, project)",
         %{org_id: org, project_id: proj} do
      :ok = OAuthStorage.put_token(@ref, @provider, "old", org, proj)
      :ok = OAuthStorage.put_token(@ref, @provider, "new", org, proj)

      assert {:ok, "new"} = OAuthStorage.get_token(@ref, @provider, org, proj)
      assert {:ok, [@provider]} = OAuthStorage.list_tokens(@ref, org, proj)
    end

    test "returns not_found for a missing bundle", %{org_id: org, project_id: proj} do
      assert {:error, :not_found} = OAuthStorage.get_token(@ref, "missing", org, proj)
    end
  end

  describe "cache interaction" do
    test "get_token fills the raw cache and reads cache-first",
         %{org_id: org, project_id: proj} do
      :ok = OAuthStorage.put_token(@ref, @provider, "from_db", org, proj)
      key = token_key(@ref, @provider, org, proj)

      assert Arca.Cache.get(key) == :miss
      assert {:ok, "from_db"} = OAuthStorage.get_token(@ref, @provider, org, proj)
      assert {:ok, "from_db"} = Arca.Cache.get(key)

      # Cache-first: a stale cached value wins over the DB row until invalidated.
      Arca.Cache.put(key, "stale_cached")
      assert {:ok, "stale_cached"} = OAuthStorage.get_token(@ref, @provider, org, proj)
    end

    test "put_token invalidates BOTH the raw and decrypted cache keys",
         %{org_id: org, project_id: proj} do
      raw = token_key(@ref, @provider, org, proj)
      dec = dec_key(@ref, @provider, org, proj)
      Arca.Cache.put(raw, "stale_raw")
      Arca.Cache.put(dec, {"stale_dec", 0})

      :ok = OAuthStorage.put_token(@ref, @provider, "fresh", org, proj)

      assert Arca.Cache.get(raw) == :miss
      assert Arca.Cache.get(dec) == :miss
    end

    test "delete_token invalidates BOTH cache keys and removes the row",
         %{org_id: org, project_id: proj} do
      :ok = OAuthStorage.put_token(@ref, @provider, "doomed", org, proj)
      assert {:ok, _} = OAuthStorage.get_token(@ref, @provider, org, proj)
      Arca.Cache.put(dec_key(@ref, @provider, org, proj), {"dec", 0})

      :ok = OAuthStorage.delete_token(@ref, @provider, org, proj)

      assert Arca.Cache.get(token_key(@ref, @provider, org, proj)) == :miss
      assert Arca.Cache.get(dec_key(@ref, @provider, org, proj)) == :miss
      assert {:error, :not_found} = OAuthStorage.get_token(@ref, @provider, org, proj)
    end

    test "delete_token is idempotent for a missing row", %{org_id: org, project_id: proj} do
      assert :ok = OAuthStorage.delete_token(@ref, "never_stored", org, proj)
    end

    test "provider-cred rows (empty component_ref) use the oauth_cred cache key on write",
         %{org_id: org, project_id: proj} do
      oid = Arca.QueryHelpers.normalize_org_id(org)
      pid = Arca.QueryHelpers.normalize_project_id(proj)
      cred_key = {:oauth_cred, {@provider, oid, pid}}
      Arca.Cache.put(cred_key, "stale_cred")

      :ok = OAuthStorage.put_token("", @provider, "client_blob", org, proj)

      assert Arca.Cache.get(cred_key) == :miss
    end
  end

  describe "list_tokens/3" do
    test "lists providers for a component, sorted", %{org_id: org, project_id: proj} do
      :ok = OAuthStorage.put_token(@ref, "google", "g", org, proj)
      :ok = OAuthStorage.put_token(@ref, "github", "h", org, proj)

      assert {:ok, ["github", "google"]} = OAuthStorage.list_tokens(@ref, org, proj)
    end

    test "excludes provider-cred rows (empty component_ref) structurally",
         %{org_id: org, project_id: proj} do
      :ok = OAuthStorage.put_token("", @provider, "client_blob", org, proj)

      assert {:ok, []} = OAuthStorage.list_tokens("", org, proj)
    end
  end

  describe "tenant isolation" do
    test "same (ref, provider) in two orgs holds independent bundles",
         %{project_id: proj} do
      :ok = OAuthStorage.put_token(@ref, @provider, "org_a_blob", "org_a", proj)
      :ok = OAuthStorage.put_token(@ref, @provider, "org_b_blob", "org_b", proj)

      assert {:ok, "org_a_blob"} = OAuthStorage.get_token(@ref, @provider, "org_a", proj)
      assert {:ok, "org_b_blob"} = OAuthStorage.get_token(@ref, @provider, "org_b", proj)

      :ok = OAuthStorage.delete_token(@ref, @provider, "org_a", proj)
      assert {:error, :not_found} = OAuthStorage.get_token(@ref, @provider, "org_a", proj)
      assert {:ok, "org_b_blob"} = OAuthStorage.get_token(@ref, @provider, "org_b", proj)
    end

    test "same (ref, provider) in two projects holds independent bundles",
         %{org_id: org} do
      :ok = OAuthStorage.put_token(@ref, @provider, "proj_a_blob", org, "proj_a")
      :ok = OAuthStorage.put_token(@ref, @provider, "proj_b_blob", org, "proj_b")

      assert {:ok, "proj_a_blob"} = OAuthStorage.get_token(@ref, @provider, org, "proj_a")
      assert {:ok, "proj_b_blob"} = OAuthStorage.get_token(@ref, @provider, org, "proj_b")
    end
  end
end
