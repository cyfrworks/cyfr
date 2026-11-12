# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.HolderIdentityTest do
  @moduledoc """
  A session stands only on its holder's identity row
  (`Sanctum.Caller.holder_identity/2`): a real session token whose holder
  has no identity row, whatever the id's shape, the server's own
  principals among them, is refused at the bearer plug and at a console
  mount, each with the answer that door gives it; with the row it stands;
  and a store that cannot read the row answers unavailable, never a
  refusal.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias CyfrWeb.Plugs.Authenticate

  # A refusal at the bearer plug: a person's session whose identity row is
  # gone is a 401; a session the store holds for an id that is no person
  # here is refused earlier, by its holder's missing `users` row, as the
  # door refuses it (a 403 for want of an athanor, or the anonymous
  # surface's denied context).

  # A person here, and a session of theirs in their own athanor: its
  # token, and the person's id.
  defp seated! do
    user = test_user()
    athanor = Sanctum.Test.People.athanor!(user.user_id)

    ctx =
      Sanctum.Context.build(
        user_id: user.user_id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(ctx)
    %{token: session.token, user_id: user.user_id, athanor: athanor}
  end

  # The session's holder with no identity row: the person's row removed,
  # or the stored session renamed to another holder, as a database a
  # restore brought back could leave it.
  defp rowless!(seated, :person) do
    Arca.Repo.delete_all(
      from(p in Arca.Schemas.PersonIdentity, where: p.user_id == ^seated.user_id)
    )

    seated
  end

  defp rowless!(seated, holder) when is_binary(holder) do
    hash = Sanctum.Session.token_hash(seated.token)

    Arca.Repo.update_all(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash),
      set: [user_id: holder]
    )

    seated
  end

  @unauthenticated %{
    "code" => "unauthenticated",
    "message" => "The presented credential is not valid. If it expired, sign in again."
  }
  @no_athanor %{
    "code" => "forbidden",
    "message" => "Unauthorized: your account has no athanor — contact your administrator"
  }

  # Each holder with no identity row, and what each door answers it: the
  # bearer plug's halt and body (`:denied` for the anonymous surface's
  # denied context, carried on unhalted), and the console mount's redirect.
  @holders [
    {"a person", :person, {401, @unauthenticated}, "/login"},
    {"the system principal", "system", {403, @no_athanor}, "/login?error=no_athanor"},
    {"the seed principal", "_seed", {403, @no_athanor}, "/login?error=no_athanor"},
    {"a webhook principal", "webhook:wh_holder", {403, @no_athanor}, "/login?error=no_athanor"},
    {"a made-up id", "github|https://github.com|holder-ghost", :denied, "/login"}
  ]

  # The person's identity rows unreadable: the store cannot answer.
  defp outage! do
    Arca.Repo.query!("ALTER TABLE person_identities RENAME TO person_identities_unavailable")
  end

  defp assert_answer(conn, {status, body}, _holder) do
    assert conn.halted
    assert conn.status == status
    assert Jason.decode!(conn.resp_body) == body
  end

  defp assert_answer(conn, :denied, holder) do
    refute conn.halted
    assert conn.status == nil
    assert %{authenticated: false, user_id: ^holder, athanor_id: nil} = conn.assigns.context
  end

  defp bearer(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> Authenticate.call(Authenticate.init([]))
  end

  describe "a session presented as a bearer" do
    test "stands on its holder's identity row", %{conn: conn} do
      seated = seated!()
      conn = bearer(conn, seated.token)

      refute conn.halted
      assert %{authenticated: true, user_id: user_id} = conn.assigns.context
      assert user_id == seated.user_id
    end

    for {label, holder, answer, _to} <- @holders do
      test "whose holder is #{label} with no identity row is refused", %{conn: conn} do
        seated = rowless!(seated!(), unquote(holder))

        capture_log(fn ->
          conn = bearer(conn, seated.token)

          assert_answer(conn, unquote(Macro.escape(answer)), unquote(holder))
        end)
      end
    end

    test "whose identity row the store cannot read answers 503, never a refusal", %{conn: conn} do
      seated = seated!()
      outage!()

      capture_log(fn ->
        conn = bearer(conn, seated.token)
        assert conn.halted
        assert conn.status == 503

        assert Jason.decode!(conn.resp_body) == %{
                 "code" => "unavailable",
                 "message" => "Authentication service unavailable — retry shortly"
               }
      end)
    end
  end

  describe "a session mounting the console" do
    test "stands on its holder's identity row", %{conn: conn} do
      seated = seated!()
      conn = Plug.Test.init_test_session(conn, %{session_key() => seated.token})

      assert {:ok, _view, _html} = live(conn, athanor_path("/settings", seated.athanor))
    end

    for {label, holder, _answer, to} <- @holders do
      test "whose holder is #{label} with no identity row is sent to #{to}", %{conn: conn} do
        seated = rowless!(seated!(), unquote(holder))
        conn = Plug.Test.init_test_session(conn, %{session_key() => seated.token})

        capture_log(fn ->
          assert {:error, {:redirect, %{to: unquote(to)}}} =
                   live(conn, athanor_path("/settings", seated.athanor))
        end)
      end
    end

    test "whose identity row the store cannot read is sent to /login?error=unavailable", %{
      conn: conn
    } do
      seated = seated!()
      conn = Plug.Test.init_test_session(conn, %{session_key() => seated.token})
      outage!()

      capture_log(fn ->
        assert {:error, {:redirect, %{to: "/login?error=unavailable"}}} =
                 live(conn, athanor_path("/settings", seated.athanor))
      end)
    end
  end
end
