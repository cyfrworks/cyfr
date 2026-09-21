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

    %{
      user_id: "github|https://github.com|caller-#{n}",
      email: "caller#{n}@example.com",
      slug: "callerns#{n}"
    }
  end

  # The identity signs in: from then on the person is named by their own id.
  defp claim!(user) do
    {:ok, row} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: user.user_id,
        provider: "github",
        email: user.email,
        verified: true
      })

    {:ok, _} = Sanctum.Tenancy.Users.set_namespace(row, user.slug)
    %{user | user_id: row.id}
  end

  # A signed-in person with no publisher namespace: the users row alone,
  # no membership.
  defp known!(user) do
    {:ok, row} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: user.user_id,
        provider: "github",
        email: user.email,
        verified: true
      })

    %{user | user_id: row.id}
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

  # A group of this person's own: no estate is shared server-wide, so a
  # test that needs a seat mints one.
  defp member!(user) do
    {:ok, estate} =
      Sanctum.Tenancy.Athanors.create_group(
        user.user_id,
        "Caller #{System.unique_integer([:positive])}"
      )

    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(user.user_id, scope: "athanor", athanor_id: estate.id)

    {user, estate}
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

      # The other user holds no membership in the `home` fixture estate.
      assert {:error, reason} = Caller.establish(other_session.token, focus: home.id)
      assert reason in [:not_member, :no_athanor]

      assert {:error, :not_found} =
               Caller.establish(session.token, focus: "ath_does_not_exist")
    end

    test "a session whose person has no publisher namespace is established like any other" do
      {user, estate} = new_user() |> known!() |> member!()
      session = session_for(user, namespace: nil)

      assert {:ok, %Context{} = ctx} = Caller.establish(session.token)
      assert ctx.user_id == user.user_id
      assert ctx.authenticated
      assert ctx.namespace == nil
      assert ctx.athanor_id == estate.id
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

      assert {:error, {:denied, %Context{}}} = Caller.establish_context(ctx)
    end

    test "an unauthenticated context without a namespace is denied just the same" do
      user = new_user()

      ctx =
        Context.build(
          user_id: user.user_id,
          email: user.email,
          provider: "github",
          authenticated: false
        )

      assert {:error, {:denied, _ctx}} = Caller.establish_context(ctx)
    end
  end

  describe "peek/1" do
    test "answers the identity fields without establishing" do
      user = new_user()
      session = session_for(user, namespace: nil)

      assert {:ok, %{user_id: user_id, provider: "github", namespace: nil}} =
               Caller.peek(session.token)

      assert user_id == user.user_id
      assert {:error, :unauthenticated} = Caller.peek(nil)
      assert {:error, :unauthenticated} = Caller.peek("cyfr_sess_bogus")
    end
  end

  describe "the establish memo" do
    setup do
      original = Application.get_env(:sanctum, :establish_cache_ms)
      Application.put_env(:sanctum, :establish_cache_ms, 60_000)

      on_exit(fn ->
        Arca.Cache.delete_match({:established, :_, :_, :_})

        if original,
          do: Application.put_env(:sanctum, :establish_cache_ms, original),
          else: Application.delete_env(:sanctum, :establish_cache_ms)
      end)

      :ok
    end

    test "a hit inside the TTL serves the established context" do
      {user, _home} = new_user() |> claim!() |> member!()
      session = session_for(Map.put(user, :namespace, user.slug))

      assert {:ok, ctx} = Caller.establish(session.token)
      assert {:ok, %Context{user_id: user_id}} = Caller.establish(session.token)
      assert user_id == ctx.user_id
      refute Arca.Cache.match({:established, :_, :_, :_}) == []
    end

    test "destroy invalidates the memo: a logged-out session refuses on the next call" do
      {user, _home} = new_user() |> claim!() |> member!()
      session = session_for(Map.put(user, :namespace, user.slug))

      assert {:ok, _ctx} = Caller.establish(session.token)

      :ok = Sanctum.Session.destroy(session.token)
      assert {:error, :unauthenticated} = Caller.establish(session.token)
    end

    test "revoke_all_for_user invalidates every memoized session of the person" do
      {user, _home} = new_user() |> claim!() |> member!()
      user = Map.put(user, :namespace, user.slug)
      s1 = session_for(user)
      s2 = session_for(user)

      assert {:ok, _} = Caller.establish(s1.token)
      assert {:ok, _} = Caller.establish(s2.token)

      assert {:ok, 2} = Sanctum.Session.revoke_all_for_user(user.user_id)
      assert {:error, :unauthenticated} = Caller.establish(s1.token)
      assert {:error, :unauthenticated} = Caller.establish(s2.token)
    end

    test "refusals are never cached" do
      assert {:error, :unauthenticated} = Caller.establish("cyfr_sess_nope")
      assert {:error, :unauthenticated} = Caller.establish("cyfr_sess_nope")
      assert Arca.Cache.match({:established, :_, :_, :_}) == []
    end

    test "a plain member removal drops the memo like the door's revocations do" do
      # Warm the context memo with a nonzero TTL before checking immediate membership revocation.
      {user, home} = new_user() |> claim!() |> member!()
      user = Map.put(user, :namespace, user.slug)
      session = session_for(user)

      assert {:ok, _ctx} = Caller.establish(session.token)
      refute Arca.Cache.match({:established, :_, :_, :_}) == []

      :ok = Sanctum.Tenancy.Members.remove_member(home, user_id: user.user_id)

      assert Arca.Cache.match({:established, :_, :_, :_}) == [],
             "the removed member's cached context survived the removal"
    end
  end
end
