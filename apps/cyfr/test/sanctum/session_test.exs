# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SessionTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Session

  setup do
    # Use Arca.Repo sandbox for test isolation
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx =
      Context.build(
        user_id: "user_123",
        email: "test@example.com",
        provider: "github",
        permissions: [:execute, :read]
      )

    {:ok, ctx: ctx}
  end

  describe "create/1" do
    test "creates session with valid token", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)

      assert session.token != nil
      assert byte_size(session.token) > 30
      assert session.user_id == "user_123"
      assert session.email == "test@example.com"
      assert session.provider == "github"
    end

    test "sets expiration in the future", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)

      {:ok, expires_at, _} = DateTime.from_iso8601(session.expires_at)
      now = DateTime.utc_now()

      assert DateTime.compare(expires_at, now) == :gt

      # Default idle timeout is 30 days (720h)
      diff = DateTime.diff(expires_at, now, :hour)
      assert diff >= 719 and diff <= 720
    end

    test "respects CYFR_SESSION_TTL_HOURS override", %{ctx: ctx} do
      Application.put_env(:cyfr, :session_ttl_hours, 1)
      on_exit(fn -> Application.delete_env(:cyfr, :session_ttl_hours) end)

      {:ok, session} = Session.create(ctx)
      {:ok, expires_at, _} = DateTime.from_iso8601(session.expires_at)
      diff = DateTime.diff(expires_at, DateTime.utc_now(), :hour)
      assert diff in [0, 1]
    end

    test "each session has unique token", %{ctx: ctx} do
      {:ok, session1} = Session.create(ctx)
      {:ok, session2} = Session.create(ctx)

      assert session1.token != session2.token
    end

    test "preserves permissions", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)

      assert "execute" in session.permissions or :execute in session.permissions
      assert "read" in session.permissions or :read in session.permissions
    end
  end

  describe "load/1" do
    test "returns context for valid session (unclaimed namespace stays unauthenticated)",
         %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)
      {:ok, retrieved_ctx} = Session.load(session.token, surface: :console)

      assert retrieved_ctx.user_id == "user_123"
      assert retrieved_ctx.email == "test@example.com"
      assert retrieved_ctx.provider == "github"
      # Test fixture user has no claimed personal namespace, so the session
      # row reconstructs to authenticated: false. RequirePersonalNamespace
      # plug then forwards them to /claim-namespace.
      assert retrieved_ctx.authenticated == false
      assert retrieved_ctx.namespace == nil
    end

    test "a session loads authenticated from the users row's namespace, and survives losing every push token" do
      n = System.unique_integer([:positive])
      user_id = "github|https://github.com|sess-#{n}"

      {:ok, row} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: user_id,
          provider: "github",
          email: "sess#{n}@example.com",
          verified: true
        })

      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(row, "sess#{n}")

      ctx =
        Sanctum.Context.build(
          user_id: user_id,
          email: "sess#{n}@example.com",
          provider: "github",
          namespace: "sess#{n}",
          permissions: [:read]
        )

      {:ok, session} = Session.create(ctx)

      assert {:ok, %{authenticated: true, namespace: ns}} =
               Session.load(session.token, surface: :console)

      assert ns == "sess#{n}"

      # Push tokens are for pushing: none were ever stored, and storing then
      # deleting one changes nothing about who the person is.
      registry = Compendium.Registry.canonical_host()

      :ok =
        Compendium.Registry.CredentialStore.put_push_token(
          user_id,
          registry,
          "sess#{n}",
          "t",
          "personal"
        )

      :ok = Compendium.Registry.CredentialStore.delete(user_id, registry, "sess#{n}")
      Sanctum.Namespace.invalidate(user_id)
      assert {:ok, %{authenticated: true}} = Session.load(session.token, surface: :console)
    end

    test "returns error for invalid token", %{ctx: _ctx} do
      assert {:error, :invalid_session} = Session.load("invalid_token", surface: :console)
    end

    test "the surface decides the auth class and cannot be omitted", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)

      # The interactive class (:oidc) is only ever stamped for an explicit
      # :console surface; :tincture gets :session, which the consent
      # authorization class rejects. Omission is a caller bug, not a default.
      assert_raise KeyError, fn -> Session.load(session.token, []) end

      assert_raise ArgumentError, fn ->
        Session.load(session.token, surface: :public)
      end
    end

    test "returns error for expired session", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)

      # Manually expire the session by updating the DB directly
      token_hash = :crypto.hash(:sha256, session.token)
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      import Ecto.Query

      from(s in Arca.Schemas.Session, where: s.token_hash == ^token_hash)
      |> Arca.Repo.update_all(set: [expires_at: past])

      assert {:error, :invalid_session} = Session.load(session.token, surface: :console)
    end
  end

  describe "get/1" do
    test "returns full session for valid token", %{ctx: ctx} do
      {:ok, created} = Session.create(ctx)
      {:ok, retrieved} = Session.get(created.token)

      assert retrieved.token == created.token
      assert retrieved.user_id == created.user_id
      assert retrieved.created_at == created.created_at
    end
  end

  describe "refresh/1" do
    test "extends session expiration", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)
      {:ok, original_expires, _} = DateTime.from_iso8601(session.expires_at)

      # Wait a tiny bit to ensure different timestamp
      :timer.sleep(10)

      {:ok, refreshed} = Session.refresh(session.token)
      {:ok, new_expires, _} = DateTime.from_iso8601(refreshed.expires_at)

      # New expiration should be later than original
      assert DateTime.compare(new_expires, original_expires) in [:gt, :eq]
    end

    test "returns error for invalid token", %{ctx: _ctx} do
      assert {:error, :invalid_session} = Session.refresh("invalid_token")
    end
  end

  describe "refresh_if_stale/1" do
    test "no-ops for a freshly created session", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)
      {:ok, before, _} = DateTime.from_iso8601(session.expires_at)

      assert :ok = Session.refresh_if_stale(session.token)

      {:ok, after_, _} = DateTime.from_iso8601(elem(Session.get(session.token), 1).expires_at)
      assert DateTime.compare(after_, before) == :eq
    end

    test "extends a session that is due for refresh", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)

      # Move expires_at close to now so the session looks stale (last refreshed ~30d ago).
      import Ecto.Query
      token_hash = :crypto.hash(:sha256, session.token)
      soon = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)

      from(s in Arca.Schemas.Session, where: s.token_hash == ^token_hash)
      |> Arca.Repo.update_all(set: [expires_at: soon])

      assert :ok = Session.refresh_if_stale(session.token)

      {:ok, refreshed, _} = DateTime.from_iso8601(elem(Session.get(session.token), 1).expires_at)
      assert DateTime.diff(refreshed, DateTime.utc_now(), :hour) >= 719
    end

    test "is a no-op for invalid tokens", %{ctx: _ctx} do
      assert :ok = Session.refresh_if_stale("nope")
    end

    test "no-ops when TTL is infinite", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)
      Application.put_env(:cyfr, :session_ttl_hours, 0)
      on_exit(fn -> Application.delete_env(:cyfr, :session_ttl_hours) end)

      assert :ok = Session.refresh_if_stale(session.token)
    end
  end

  describe "destroy/1" do
    test "removes session", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)

      # Session should exist
      {:ok, _} = Session.load(session.token, surface: :console)

      # Destroy it
      assert :ok = Session.destroy(session.token)

      # Session should no longer exist
      assert {:error, :invalid_session} = Session.load(session.token, surface: :console)
    end

    test "destroying non-existent session succeeds", %{ctx: _ctx} do
      assert :ok = Session.destroy("nonexistent_token")
    end
  end

  describe "cleanup/0" do
    test "removes expired sessions", %{ctx: ctx} do
      # Create a valid session
      {:ok, valid_session} = Session.create(ctx)

      # Create and manually expire another session
      {:ok, expired_session} = Session.create(ctx)

      token_hash = :crypto.hash(:sha256, expired_session.token)
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      import Ecto.Query

      from(s in Arca.Schemas.Session, where: s.token_hash == ^token_hash)
      |> Arca.Repo.update_all(set: [expires_at: past])

      # Run cleanup
      {:ok, removed_count} = Session.cleanup()
      assert removed_count == 1

      # Valid session should still work
      {:ok, _} = Session.load(valid_session.token, surface: :console)

      # Expired session should be gone
      assert {:error, :invalid_session} = Session.load(expired_session.token, surface: :console)
    end
  end
end
