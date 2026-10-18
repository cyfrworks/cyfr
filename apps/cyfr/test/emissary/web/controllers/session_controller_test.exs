# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.SessionControllerTest do
  @moduledoc """
  Tests for the HTTP API's sign-out and session read.

  Tests cover:
  - logout/2: Session destruction
  - whoami/2: Current user info
  """
  use CyfrWeb.ConnCase

  import Ecto.Query, only: [from: 2]

  describe "logout/2" do
    test "returns error when no token provided via Bearer header", %{conn: conn} do
      # Use Bearer auth header (no session cookie)
      conn =
        conn
        |> put_req_header("authorization", "Bearer ")
        |> delete(~p"/auth/logout")

      # Empty bearer token should fall through to missing_token, which is
      # a credential not presented: 401 with its challenge.
      assert json_response(conn, 401)["code"] == "unauthenticated"
    end

    test "a token in the request body is ignored", %{conn: conn} do
      # A credential in a body or query string lands in access logs and
      # Referer headers. The header is the only way into the API logout;
      # POST routes to the browser sign-out (CSRF-guarded), which reads
      # only the cookie session and never the body.
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/auth/logout", Jason.encode!(%{"token" => "nonexistent_token"}))

      assert redirected_to(conn) == "/login?error=signed_out"
    end

    test "ignores a body token on the routed verb", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> delete(~p"/auth/logout", Jason.encode!(%{"token" => "nonexistent_token"}))

      assert json_response(conn, 401)["code"] == "unauthenticated"
    end

    test "a session's sign-out is the gate's session logout, and leaves its decision row", %{
      conn: conn
    } do
      {user, session} = person_session!()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> delete(~p"/auth/logout")

      assert %{"ok" => true} = json_response(conn, 200)
      assert {:error, _gone} = Sanctum.Session.get(session.token)
      assert_logout_decided(user)
    end

    test "a person denied at the door since signs out through the gate too", %{conn: conn} do
      {user, session} = person_session!()

      Arca.Schemas.User
      |> Arca.Repo.get!(user.id)
      |> Ecto.Changeset.change(status: "denied")
      |> Arca.Repo.update!()

      assert {:error, {:denied, _ctx}} =
               Sanctum.Caller.establish({:session, session.token}, refresh: false)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> delete(~p"/auth/logout")

      assert %{"ok" => true} = json_response(conn, 200)
      assert {:error, _gone} = Sanctum.Session.get(session.token)
      assert_logout_decided(user)
    end

    test "a store that cannot establish the caller answers 503 and signs nothing out", %{
      conn: conn
    } do
      {_user, session} = person_session!()
      Arca.Repo.query!("ALTER TABLE users RENAME TO users_unavailable")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> delete(~p"/auth/logout")

      assert json_response(conn, 503)
      Arca.Repo.query!("ALTER TABLE users_unavailable RENAME TO users")
      assert {:ok, _still} = Sanctum.Session.get(session.token)
    end

    test "accepts token via Bearer header", %{conn: conn} do
      # Session.destroy is idempotent - destroying nonexistent token returns :ok
      conn =
        conn
        |> put_req_header("authorization", "Bearer nonexistent_token")
        |> delete(~p"/auth/logout")

      response = json_response(conn, 200)
      assert response["ok"] == true
    end
  end

  # A person seated in a group of their own, and a session of theirs.
  defp person_session! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|logout-#{n}",
        provider: "github",
        email: "logout#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(user.id, "Sign-out #{n}")

    {:ok, session} =
      Sanctum.Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )
      |> Sanctum.TestContext.create_session()

    {user, session}
  end

  # The gate's session logout, admitted and completed, under the person.
  defp assert_logout_decided(user) do
    rows = fn ->
      Arca.Repo.all(
        from(d in Arca.Schemas.DecisionLog,
          where: d.tool == "session" and d.action == "logout" and d.user_id == ^user.id
        )
      )
    end

    assert [%{admission: "admitted"}] = rows.()
    Prima.Test.Wait.wait_until(fn -> match?([%{completion: "succeeded"}], rows.()) end)
  end

  describe "whoami/2" do
    test "returns unauthorized when no token provided", %{conn: conn} do
      conn = get(conn, ~p"/auth/whoami")

      assert json_response(conn, 401)["code"] == "unauthenticated"
      assert json_response(conn, 401)["message"] == "No session token provided"
    end

    test "returns invalid_session for nonexistent token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer nonexistent_token")
        |> get(~p"/auth/whoami")

      assert json_response(conn, 401)["code"] == "unauthenticated"
    end

    test "returns session info for valid token", %{conn: conn} do
      # Create a real session
      {ctx, _user} =
        Sanctum.Context.build(
          user_id: "github|https://github.com|whoami-#{System.unique_integer([:positive])}",
          email: "whoami@example.com",
          provider: "github",
          permissions: [:execute, :read],
          namespace: "testns",
          authenticated: true
        )
        |> Sanctum.TestContext.person!()

      {:ok, session} = Sanctum.TestContext.create_session(ctx)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{session.token}")
        |> get(~p"/auth/whoami")

      response = json_response(conn, 200)
      assert response["ok"] == true
      assert response["session"]["user_id"] == ctx.user_id
      assert response["session"]["email"] == "whoami@example.com"
      assert response["session"]["provider"] == "github"
      assert response["session"]["created_at"] != nil
      assert response["session"]["expires_at"] != nil

      # Clean up
      Sanctum.Session.destroy(session.token)
    end
  end
end
