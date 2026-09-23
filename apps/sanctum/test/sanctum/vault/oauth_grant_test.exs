# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.OAuthGrantStandingTest do
  @moduledoc """
  A grant writes a credential only for an actor that still stands where
  it started the grant (`Sanctum.Vault.OAuthGrant.complete/3`): the
  session that authorized it is revalidated, and an actor with no session
  is held to the rule an athanor-owned channel stands by. A refusal is
  answered before the provider is asked for anything.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Sanctum.{Caller, Context}
  alias Sanctum.Tenancy.{Athanors, Members, Users}
  alias Sanctum.Vault.OAuthGrant

  @redirect "https://cyfr.test/auth/oauth/callback"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp person! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|grant-#{n}",
        provider: "github",
        email: "grant#{n}@example.com",
        verified: true
      })

    {:ok, estate} = Athanors.create_group(user.id, "Grant #{n}")
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: estate.id)

    {:ok, session} =
      Sanctum.TestContext.create_session(
        Context.build(
          user_id: user.id,
          provider: "github",
          athanor_id: estate.id,
          auth_method: :oidc,
          authenticated: true
        )
      )

    {:ok, ctx} = Caller.establish(session.token, focus: estate.id)
    ctx
  end

  # The pending record `authorize_url/2` mints for `ctx`. Its token URL is
  # one nothing answers: a grant that got as far as the exchange would say
  # the endpoint is unreachable, not that its actor no longer stands.
  defp pending!(pending) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Arca.Cache.put(
      {:vault_oauth_pending, state},
      Map.merge(
        %{
          target: %{
            kind: :new,
            entry_id: nil,
            name: "Mail",
            provider: "google",
            endpoints: %{
              "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
              "token_url" => "https://127.0.0.1:9/token"
            },
            scopes: ["mail"]
          },
          redirect_uri: @redirect,
          code_verifier: "verifier"
        },
        pending
      ),
      120_000
    )

    state
  end

  defp for_context(ctx), do: pending!(%{context: ctx, actor: Context.actor(ctx)})

  defp entries(athanor_id) do
    Arca.Repo.all(from(v in Arca.Schemas.VaultEntry, where: v.athanor_id == ^athanor_id))
  end

  test "a session revoked since the grant started writes nothing" do
    ctx = person!()
    state = for_context(ctx)

    Arca.Repo.delete_all(
      from(s in Arca.Schemas.Session, where: s.token_hash == ^ctx.session_token_hash)
    )

    assert {:error, :not_standing} = OAuthGrant.complete(state, "code", @redirect)
    assert entries(ctx.athanor_id) == []
  end

  test "a person denied since the grant started writes nothing" do
    ctx = person!()
    state = for_context(ctx)

    Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^ctx.user_id),
      set: [status: "denied"]
    )

    assert {:error, :not_standing} = OAuthGrant.complete(state, "code", @redirect)
    assert entries(ctx.athanor_id) == []
  end

  test "a seat lost in the grant's estate writes nothing there" do
    ctx = person!()
    state = for_context(ctx)

    Arca.Repo.delete_all(
      from(m in Arca.Schemas.Membership,
        where: m.user_id == ^ctx.user_id and m.athanor_id == ^ctx.athanor_id
      )
    )

    assert {:error, :not_standing} = OAuthGrant.complete(state, "code", @redirect)
    assert entries(ctx.athanor_id) == []
  end

  test "a store that cannot answer is unavailable, and writes nothing" do
    ctx = person!()
    state = for_context(ctx)
    Arca.Repo.query!("ALTER TABLE sessions RENAME TO sessions_unavailable")

    assert {:error, :unavailable} = OAuthGrant.complete(state, "code", @redirect)
  end

  test "an actor with no session is held to the channel rule: an archived estate writes nothing" do
    ctx = person!()
    state = pending!(%{actor: Context.actor(ctx)})

    Arca.Repo.update_all(from(a in Arca.Schemas.Athanor, where: a.id == ^ctx.athanor_id),
      set: [status: "archived"]
    )

    assert {:error, :not_standing} = OAuthGrant.complete(state, "code", @redirect)
    assert entries(ctx.athanor_id) == []
  end

  test "a standing actor goes on to the exchange" do
    ctx = person!()
    state = for_context(ctx)

    assert {:error, reason} = OAuthGrant.complete(state, "code", @redirect)
    refute reason in [:not_standing, :unavailable]
  end
end
