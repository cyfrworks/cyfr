# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        token_prefix: "cyfr_",
        scope: "athanor"
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

  describe "scope persistence" do
    test "persists and returns the resolved scope and athanor" do
      hash = make_token_hash("scope")
      attrs = session_attrs(%{scope: "platform", athanor_id: "ath_home"})

      assert :ok = SessionStorage.create_session(hash, attrs)
      assert {:ok, session} = SessionStorage.get_session(hash)
      assert session.scope == "platform"
      assert session.athanor_id == "ath_home"
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

  describe "cleanup_expired_sessions/0" do
    test "deletes expired sessions globally and returns count" do
      hash = make_token_hash("cleanup")
      attrs = session_attrs(%{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)})
      :ok = SessionStorage.create_session(hash, attrs)

      {:ok, count} = SessionStorage.cleanup_expired_sessions()
      assert count >= 1
    end
  end

  describe "tenant column" do
    test "stores and retrieves athanor_id" do
      hash = make_token_hash("tenant")
      attrs = session_attrs(%{athanor_id: "ath_alpha"})

      assert :ok = SessionStorage.create_session(hash, attrs)

      assert {:ok, session} = SessionStorage.get_session(hash)
      assert session.athanor_id == "ath_alpha"
    end

    test "a session may exist before its athanor is resolved (nil, never a default)" do
      hash = make_token_hash("tenant_default")
      attrs = session_attrs()

      assert :ok = SessionStorage.create_session(hash, attrs)

      assert {:ok, session} = SessionStorage.get_session(hash)
      assert session.athanor_id == nil
    end
  end
end
