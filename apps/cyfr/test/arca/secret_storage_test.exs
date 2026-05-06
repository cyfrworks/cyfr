defmodule Arca.SecretStorageTest do
  use ExUnit.Case, async: false

  alias Arca.SecretStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    org_id = ctx.org_id

    {:ok, ctx: ctx, org_id: org_id}
  end

  describe "put_secret/4 and get_secret/3" do
    test "stores and retrieves a secret", %{org_id: org_id} do
      :ok = SecretStorage.put_secret("MY_API_KEY", "encrypted_value_1", "project", org_id)

      assert {:ok, "encrypted_value_1"} =
               SecretStorage.get_secret("MY_API_KEY", "project", org_id)
    end

    test "upserts on conflict", %{org_id: org_id} do
      :ok = SecretStorage.put_secret("UPSERT_KEY", "old_value", "project", org_id)
      :ok = SecretStorage.put_secret("UPSERT_KEY", "new_value", "project", org_id)

      assert {:ok, "new_value"} = SecretStorage.get_secret("UPSERT_KEY", "project", org_id)
    end

    test "returns not_found for missing secret", %{org_id: org_id} do
      assert {:error, :not_found} = SecretStorage.get_secret("MISSING", "project", org_id)
    end
  end

  describe "delete_secret/3" do
    test "deletes a secret", %{org_id: org_id} do
      :ok = SecretStorage.put_secret("DEL_KEY", "value", "project", org_id)
      :ok = SecretStorage.delete_secret("DEL_KEY", "project", org_id)

      assert {:error, :not_found} = SecretStorage.get_secret("DEL_KEY", "project", org_id)
    end

    test "succeeds for nonexistent secret", %{org_id: org_id} do
      assert :ok = SecretStorage.delete_secret("NOPE", "project", org_id)
    end
  end

  describe "list_secrets/2" do
    test "lists secret names for scope and org", %{org_id: org_id} do
      :ok = SecretStorage.put_secret("SEC_A", "val_a", "project", org_id)
      :ok = SecretStorage.put_secret("SEC_B", "val_b", "project", org_id)

      {:ok, names} = SecretStorage.list_secrets("project", org_id)
      assert "SEC_A" in names
      assert "SEC_B" in names
    end

    test "returns empty list when no secrets", %{org_id: org_id} do
      {:ok, names} = SecretStorage.list_secrets("empty_scope", org_id)
      assert names == []
    end
  end

  describe "grants" do
    test "put_grant and list_grants round-trip", %{org_id: org_id} do
      :ok = SecretStorage.put_grant("MY_SECRET", "reagent:local.comp:1.0.0", "project", org_id)

      {:ok, refs} = SecretStorage.list_grants("MY_SECRET", "project", org_id)
      assert refs == ["reagent:local.comp:1.0.0"]
    end

    test "put_grant is idempotent", %{org_id: org_id} do
      :ok = SecretStorage.put_grant("IDEM_SECRET", "reagent:local.comp:1.0.0", "project", org_id)
      :ok = SecretStorage.put_grant("IDEM_SECRET", "reagent:local.comp:1.0.0", "project", org_id)

      {:ok, refs} = SecretStorage.list_grants("IDEM_SECRET", "project", org_id)
      assert length(refs) == 1
    end

    test "delete_grant removes specific grant", %{org_id: org_id} do
      :ok = SecretStorage.put_grant("DEL_GRANT", "reagent:local.a:1.0.0", "project", org_id)
      :ok = SecretStorage.put_grant("DEL_GRANT", "reagent:local.b:1.0.0", "project", org_id)

      :ok = SecretStorage.delete_grant("DEL_GRANT", "reagent:local.a:1.0.0", "project", org_id)

      {:ok, refs} = SecretStorage.list_grants("DEL_GRANT", "project", org_id)
      assert refs == ["reagent:local.b:1.0.0"]
    end

    test "grants_for_component lists secrets granted to a component", %{org_id: org_id} do
      :ok = SecretStorage.put_grant("SECRET_1", "reagent:local.widget:1.0.0", "project", org_id)
      :ok = SecretStorage.put_grant("SECRET_2", "reagent:local.widget:1.0.0", "project", org_id)

      {:ok, secrets} =
        SecretStorage.grants_for_component("reagent:local.widget:1.0.0", "project", org_id)

      assert "SECRET_1" in secrets
      assert "SECRET_2" in secrets
    end

    test "delete_grants_for_component removes all grants for a component", %{
      ctx: ctx,
      org_id: org_id
    } do
      :ok = SecretStorage.put_grant("S1", "reagent:local.cleanup:1.0.0", "project", org_id)
      :ok = SecretStorage.put_grant("S2", "reagent:local.cleanup:1.0.0", "project", org_id)

      :ok = SecretStorage.delete_grants_for_component(ctx, "reagent:local.cleanup:1.0.0")

      {:ok, secrets} =
        SecretStorage.grants_for_component("reagent:local.cleanup:1.0.0", "project", org_id)

      assert secrets == []
    end
  end

  describe "tenant isolation" do
    test "different org_ids cannot see each other's secrets" do
      :ok = SecretStorage.put_secret("SHARED_NAME", "org_a_value", "project", "org_alpha")
      :ok = SecretStorage.put_secret("SHARED_NAME", "org_b_value", "project", "org_beta")

      assert {:ok, "org_a_value"} =
               SecretStorage.get_secret("SHARED_NAME", "project", "org_alpha")

      assert {:ok, "org_b_value"} = SecretStorage.get_secret("SHARED_NAME", "project", "org_beta")

      {:ok, a_names} = SecretStorage.list_secrets("project", "org_alpha")
      {:ok, b_names} = SecretStorage.list_secrets("project", "org_beta")
      assert "SHARED_NAME" in a_names
      assert "SHARED_NAME" in b_names
    end
  end

  describe "project-level scoping" do
    test "same secret name in different projects stays isolated", %{org_id: org_id} do
      :ok = SecretStorage.put_secret("DB_URL", "postgres://proj1", "project", org_id, "proj_1")
      :ok = SecretStorage.put_secret("DB_URL", "postgres://proj2", "project", org_id, "proj_2")

      assert {:ok, "postgres://proj1"} =
               SecretStorage.get_secret("DB_URL", "project", org_id, "proj_1")

      assert {:ok, "postgres://proj2"} =
               SecretStorage.get_secret("DB_URL", "project", org_id, "proj_2")
    end

    test "list_secrets scopes by project_id", %{org_id: org_id} do
      :ok = SecretStorage.put_secret("P1_SECRET", "v1", "project", org_id, "proj_1")
      :ok = SecretStorage.put_secret("P2_SECRET", "v2", "project", org_id, "proj_2")

      {:ok, p1_names} = SecretStorage.list_secrets("project", org_id, "proj_1")
      {:ok, p2_names} = SecretStorage.list_secrets("project", org_id, "proj_2")

      assert "P1_SECRET" in p1_names
      refute "P2_SECRET" in p1_names
      assert "P2_SECRET" in p2_names
      refute "P1_SECRET" in p2_names
    end

    test "delete_secret scopes by project_id", %{org_id: org_id} do
      :ok = SecretStorage.put_secret("DEL_P", "v1", "project", org_id, "proj_1")
      :ok = SecretStorage.put_secret("DEL_P", "v2", "project", org_id, "proj_2")

      :ok = SecretStorage.delete_secret("DEL_P", "project", org_id, "proj_1")

      assert {:error, :not_found} = SecretStorage.get_secret("DEL_P", "project", org_id, "proj_1")
      assert {:ok, "v2"} = SecretStorage.get_secret("DEL_P", "project", org_id, "proj_2")
    end

    test "grants_for_component scopes by project_id", %{org_id: org_id} do
      :ok =
        SecretStorage.put_grant("SEC_A", "reagent:local.comp:1.0.0", "project", org_id, "proj_1")

      :ok =
        SecretStorage.put_grant("SEC_B", "reagent:local.comp:1.0.0", "project", org_id, "proj_2")

      {:ok, p1_secrets} =
        SecretStorage.grants_for_component(
          "reagent:local.comp:1.0.0",
          "project",
          org_id,
          "proj_1"
        )

      {:ok, p2_secrets} =
        SecretStorage.grants_for_component(
          "reagent:local.comp:1.0.0",
          "project",
          org_id,
          "proj_2"
        )

      assert "SEC_A" in p1_secrets
      refute "SEC_B" in p1_secrets
      assert "SEC_B" in p2_secrets
      refute "SEC_A" in p2_secrets
    end
  end
end
