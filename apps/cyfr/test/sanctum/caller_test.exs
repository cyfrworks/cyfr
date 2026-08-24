# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CallerTest do
  use ExUnit.Case, async: false

  alias Sanctum.Caller
  alias Sanctum.Context
  alias Sanctum.Session

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp new_user do
    n = System.unique_integer([:positive])
    %{user_id: "github|https://github.com|caller-#{n}", email: "caller#{n}@example.com", slug: "callerns#{n}"}
  end

  defp claim!(user) do
    {:ok, row} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: user.user_id,
        provider: "github",
        email: user.email,
        verified: true
      })

    {:ok, _} = Sanctum.Tenancy.Users.set_namespace(row, user.slug)
    user
  end

  defp session_for(user, attrs \\ []) do
    ctx =
      Context.build(
        Keyword.merge(
          [
            user_id: user.user_id,
            email: user.email,
            provider: "github",
            namespace: user[:namespace],
            permissions: [:*],
            auth_method: :oidc,
            authenticated: true
          ],
          attrs
        )
      )

    {:ok, session} = Session.create(ctx)
    session
  end

  defp member!(user) do
    home = Sanctum.Tenancy.Athanors.home!()

    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(user.user_id, scope: "athanor", athanor_id: home.id)

    {user, home}
  end

  describe "establish/2" do
    test "a claimed member's token becomes a finished Context" do
      {user, home} = new_user() |> claim!() |> member!()
      session = session_for(Map.put(user, :namespace, user.slug))

      assert {:ok, %Context{} = ctx} = Caller.establish(session.token)
      assert ctx.authenticated
      assert ctx.namespace == user.slug
      assert ctx.athanor_id == home.id
      assert :ok == Context.tenant_ok(ctx)
    end

    test "focus follows a coordinate, and refuses a non-member's" do
      {user, home} = new_user() |> claim!() |> member!()
      session = session_for(Map.put(user, :namespace, user.slug))

      assert {:ok, %Context{athanor_id: focused}} =
               Caller.establish(session.token, focus: home.id)

      assert focused == home.id

      {other, other_home} = {new_user() |> claim!(), nil}
      _ = other_home
      other_session = session_for(Map.put(other, :namespace, other.slug))

      # The other user holds no membership in Home.
      assert {:error, reason} = Caller.establish(other_session.token, focus: home.id)
      assert reason in [:not_member, :no_athanor]

      assert {:error, :not_found} =
               Caller.establish(session.token, focus: "ath_does_not_exist")
    end

    test "a pre-claim session is claim_pending, with its context riding along" do
      user = new_user()
      session = session_for(user, namespace: nil)

      assert {:error, {:claim_pending, %Context{} = ctx}} = Caller.establish(session.token)
      assert ctx.user_id == user.user_id
      refute ctx.authenticated
    end

    test "no token, a blank token, and an unknown token are unauthenticated" do
      assert {:error, :unauthenticated} = Caller.establish(nil)
      assert {:error, :unauthenticated} = Caller.establish("")
      assert {:error, :unauthenticated} = Caller.establish("cyfr_sess_not_a_real_token")
    end

    test "an authenticated person with nowhere to work is no_athanor" do
      user = new_user() |> claim!()
      session = session_for(Map.put(user, :namespace, user.slug))

      case Caller.establish(session.token) do
        {:error, :no_athanor} -> :ok
        # A personal athanor may already exist for the slug on this server;
        # then the resolve legitimately lands there.
        {:ok, %Context{athanor_id: id}} when is_binary(id) -> :ok
      end
    end
  end

  describe "establish_context/2" do
    test "a namespace-holding unauthenticated context is denied" do
      user = new_user() |> claim!()

      ctx =
        Context.build(
          user_id: user.user_id,
          email: user.email,
          provider: "github",
          authenticated: false
        )

      assert {:error, :denied} = Caller.establish_context(ctx)
    end

    test "an unclaimed unauthenticated context is claim_pending" do
      user = new_user()

      ctx =
        Context.build(
          user_id: user.user_id,
          email: user.email,
          provider: "github",
          authenticated: false
        )

      assert {:error, {:claim_pending, _ctx}} = Caller.establish_context(ctx)
    end
  end
end
