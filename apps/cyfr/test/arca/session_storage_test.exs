defmodule Arca.SessionStorageTest do
  use ExUnit.Case, async: false

  alias Arca.SessionStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp make_token_hash(suffix) do
    :crypto.hash(:sha256, "test_token_#{suffix}_#{:rand.uniform(100_000)}")
  end

  defp session_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        user_id: "user_1",
        email: "user@example.com",
        provider: "github",
        permissions: "[\"execute\",\"component:read\"]",
        session_id: Ecto.UUID.generate(),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        token_prefix: "cyfr_"
      },
      overrides
    )
  end

  describe "create_session/2 and get_session/1" do
    test "stores and retrieves a session" do
      hash = make_token_hash("create")
      attrs = session_attrs()

      assert :ok = SessionStorage.create_session(hash, attrs)

      assert {:ok, session} = SessionStorage.get_session(hash)
      assert session.user_id == "user_1"
      assert session.email == "user@example.com"
      assert session.provider == "github"
    end

    test "returns not_found for missing session" do
      hash = make_token_hash("missing")
      assert {:error, :not_found} = SessionStorage.get_session(hash)
    end

    test "returns not_found for expired session" do
      hash = make_token_hash("expired")
      attrs = session_attrs(%{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})

      :ok = SessionStorage.create_session(hash, attrs)

      assert {:error, :not_found} = SessionStorage.get_session(hash)
    end
  end

  describe "refresh_session/2" do
    test "updates session expiration" do
      hash = make_token_hash("refresh")
      attrs = session_attrs()
      :ok = SessionStorage.create_session(hash, attrs)

      new_expires = DateTime.add(DateTime.utc_now(), 7200, :second)
      assert :ok = SessionStorage.refresh_session(hash, new_expires)

      # Verify the session still exists after refresh
      assert {:ok, _session} = SessionStorage.get_session(hash)
    end

    test "returns not_found for missing session" do
      hash = make_token_hash("refresh_missing")
      assert {:error, :not_found} = SessionStorage.refresh_session(hash, DateTime.utc_now())
    end
  end

  describe "delete_session/1" do
    test "deletes a session" do
      hash = make_token_hash("delete")
      :ok = SessionStorage.create_session(hash, session_attrs())

      assert :ok = SessionStorage.delete_session(hash)
      assert {:error, :not_found} = SessionStorage.get_session(hash)
    end

    test "succeeds for nonexistent session" do
      hash = make_token_hash("delete_missing")
      assert :ok = SessionStorage.delete_session(hash)
    end
  end

  describe "list_active_sessions/1" do
    test "lists non-expired sessions scoped to tenant" do
      hash = make_token_hash("active")
      :ok = SessionStorage.create_session(hash, session_attrs(%{
        user_id: "active_user",
        org_id: "org_list",
        project_id: "proj_list"
      }))

      {:ok, sessions} = SessionStorage.list_active_sessions(org_id: "org_list", project_id: "proj_list")
      assert Enum.any?(sessions, &(&1.user_id == "active_user"))
    end

    test "excludes expired sessions" do
      hash = make_token_hash("expired_list")
      attrs = session_attrs(%{
        user_id: "expired_user",
        org_id: "org_list2",
        project_id: "proj_list2",
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })
      :ok = SessionStorage.create_session(hash, attrs)

      {:ok, sessions} = SessionStorage.list_active_sessions(org_id: "org_list2", project_id: "proj_list2")
      refute Enum.any?(sessions, &(&1.user_id == "expired_user"))
    end

    test "scopes to tenant — other tenant's sessions not visible" do
      hash_a = make_token_hash("tenant_a")
      hash_b = make_token_hash("tenant_b")

      :ok = SessionStorage.create_session(hash_a, session_attrs(%{
        user_id: "user_a",
        org_id: "org_a",
        project_id: "proj_a"
      }))
      :ok = SessionStorage.create_session(hash_b, session_attrs(%{
        user_id: "user_b",
        org_id: "org_b",
        project_id: "proj_b"
      }))

      {:ok, sessions_a} = SessionStorage.list_active_sessions(org_id: "org_a", project_id: "proj_a")
      assert length(sessions_a) == 1
      assert hd(sessions_a).user_id == "user_a"

      {:ok, sessions_b} = SessionStorage.list_active_sessions(org_id: "org_b", project_id: "proj_b")
      assert length(sessions_b) == 1
      assert hd(sessions_b).user_id == "user_b"
    end
  end

  describe "cleanup_expired_sessions/0" do
    test "deletes expired sessions globally and returns count" do
      hash = make_token_hash("cleanup")
      attrs = session_attrs(%{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)})
      :ok = SessionStorage.create_session(hash, attrs)

      {:ok, count} = SessionStorage.cleanup_expired_sessions()
      assert count >= 1
    end
  end

  describe "cleanup_expired_sessions/1 (scoped)" do
    test "deletes expired sessions scoped to tenant" do
      hash_a = make_token_hash("cleanup_a")
      hash_b = make_token_hash("cleanup_b")

      :ok = SessionStorage.create_session(hash_a, session_attrs(%{
        user_id: "cleanup_user_a",
        org_id: "org_cleanup_a",
        project_id: "proj_cleanup_a",
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }))
      :ok = SessionStorage.create_session(hash_b, session_attrs(%{
        user_id: "cleanup_user_b",
        org_id: "org_cleanup_b",
        project_id: "proj_cleanup_b",
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }))

      # Cleanup only tenant A
      {:ok, count} = SessionStorage.cleanup_expired_sessions(
        org_id: "org_cleanup_a",
        project_id: "proj_cleanup_a"
      )
      assert count == 1

      # Tenant B's expired session still exists (cleanup was scoped)
      {:ok, remaining} = SessionStorage.cleanup_expired_sessions(
        org_id: "org_cleanup_b",
        project_id: "proj_cleanup_b"
      )
      assert remaining == 1
    end
  end

  describe "tenant columns" do
    test "stores and retrieves org_id and project_id" do
      hash = make_token_hash("tenant")
      attrs = session_attrs(%{org_id: "org_alpha", project_id: "proj_1"})

      assert :ok = SessionStorage.create_session(hash, attrs)

      assert {:ok, session} = SessionStorage.get_session(hash)
      assert session.org_id == "org_alpha"
      assert session.project_id == "proj_1"
    end

    test "defaults org_id to empty string and project_id to default" do
      hash = make_token_hash("tenant_default")
      attrs = session_attrs()

      assert :ok = SessionStorage.create_session(hash, attrs)

      assert {:ok, session} = SessionStorage.get_session(hash)
      assert session.org_id == ""
      assert session.project_id == "default"
    end
  end

  describe "revocations" do
    test "put_revocation and revoked? round-trip" do
      session_id = Ecto.UUID.generate()
      now = DateTime.utc_now()
      expires = DateTime.add(now, 3600, :second)

      :ok = SessionStorage.put_revocation(session_id, now, expires)

      assert {:ok, true} = SessionStorage.revoked?(session_id)
    end

    test "revoked? returns false for non-revoked session" do
      assert {:ok, false} = SessionStorage.revoked?(Ecto.UUID.generate())
    end

    test "put_revocation is idempotent" do
      session_id = Ecto.UUID.generate()
      now = DateTime.utc_now()
      expires = DateTime.add(now, 3600, :second)

      :ok = SessionStorage.put_revocation(session_id, now, expires)
      :ok = SessionStorage.put_revocation(session_id, now, expires)

      assert {:ok, true} = SessionStorage.revoked?(session_id)
    end

    test "expired revocation returns false" do
      session_id = Ecto.UUID.generate()
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      expired = DateTime.add(DateTime.utc_now(), -1, :second)

      :ok = SessionStorage.put_revocation(session_id, past, expired)

      assert {:ok, false} = SessionStorage.revoked?(session_id)
    end

    test "cleanup_revocations removes expired entries" do
      session_id = Ecto.UUID.generate()
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      expired = DateTime.add(DateTime.utc_now(), -1, :second)

      :ok = SessionStorage.put_revocation(session_id, past, expired)

      {:ok, count} = SessionStorage.cleanup_revocations()
      assert count >= 1
    end

    test "put_revocation stores tenant columns from opts" do
      session_id = Ecto.UUID.generate()
      now = DateTime.utc_now()
      expires = DateTime.add(now, 3600, :second)

      :ok = SessionStorage.put_revocation(session_id, now, expires,
        org_id: "org_rev",
        project_id: "proj_rev"
      )

      assert {:ok, true} = SessionStorage.revoked?(session_id)
    end

    test "put_revocation defaults tenant to sentinel values" do
      session_id = Ecto.UUID.generate()
      now = DateTime.utc_now()
      expires = DateTime.add(now, 3600, :second)

      :ok = SessionStorage.put_revocation(session_id, now, expires)

      assert {:ok, true} = SessionStorage.revoked?(session_id)
    end

    test "scoped cleanup_revocations only removes entries for specified tenant" do
      session_a = Ecto.UUID.generate()
      session_b = Ecto.UUID.generate()
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      expired = DateTime.add(DateTime.utc_now(), -1, :second)

      :ok = SessionStorage.put_revocation(session_a, past, expired,
        org_id: "org_rev_a",
        project_id: "proj_rev_a"
      )
      :ok = SessionStorage.put_revocation(session_b, past, expired,
        org_id: "org_rev_b",
        project_id: "proj_rev_b"
      )

      # Cleanup only tenant A
      {:ok, count} = SessionStorage.cleanup_revocations(
        org_id: "org_rev_a",
        project_id: "proj_rev_a"
      )
      assert count == 1

      # Tenant B's expired revocation still exists
      {:ok, remaining} = SessionStorage.cleanup_revocations(
        org_id: "org_rev_b",
        project_id: "proj_rev_b"
      )
      assert remaining == 1
    end
  end
end
