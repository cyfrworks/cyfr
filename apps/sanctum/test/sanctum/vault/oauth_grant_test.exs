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

    {:ok, athanor} = Athanors.create_group(user.id, "Grant #{n}")
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: athanor.id)

    {:ok, session} =
      Sanctum.TestContext.create_session(
        Context.build(
          user_id: user.id,
          provider: "github",
          athanor_id: athanor.id,
          auth_method: :oidc,
          authenticated: true
        )
      )

    {:ok, ctx} = Caller.establish(session.token, focus: athanor.id)
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

    assert {:error, :unauthenticated} = OAuthGrant.complete(state, "code", @redirect)
    assert entries(ctx.athanor_id) == []
  end

  test "a person denied since the grant started writes nothing" do
    ctx = person!()
    state = for_context(ctx)

    Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^ctx.user_id),
      set: [status: "denied"]
    )

    assert {:error, :unauthenticated} = OAuthGrant.complete(state, "code", @redirect)
    assert entries(ctx.athanor_id) == []
  end

  test "a seat lost in the grant's athanor writes nothing there" do
    ctx = person!()
    state = for_context(ctx)

    Arca.Repo.delete_all(
      from(m in Arca.Schemas.Membership,
        where: m.user_id == ^ctx.user_id and m.athanor_id == ^ctx.athanor_id
      )
    )

    assert {:error, :unauthenticated} = OAuthGrant.complete(state, "code", @redirect)
    assert entries(ctx.athanor_id) == []
  end

  test "a store that cannot answer is unavailable, and writes nothing" do
    ctx = person!()
    state = for_context(ctx)
    Arca.Repo.query!("ALTER TABLE sessions RENAME TO sessions_unavailable")

    assert {:error, :unavailable} = OAuthGrant.complete(state, "code", @redirect)
  end

  test "a remote person whose identity cannot be confirmed fresh is paused as unavailable" do
    ctx = person!()
    state = for_context(ctx)
    stale_remote!(ctx.user_id)

    {answer, log} =
      ExUnit.CaptureLog.with_log(fn -> OAuthGrant.complete(state, "code", @redirect) end)

    # A pause, as when the store cannot answer, never "no longer signed in":
    # the callback answers 503 and the session stands.
    assert {:error, :unavailable} = answer
    assert log =~ "freshness bound"
    assert entries(ctx.athanor_id) == []

    assert Arca.Repo.exists?(
             from(s in Arca.Schemas.Session, where: s.token_hash == ^ctx.session_token_hash)
           )
  end

  # `user_id` made a person whose keys are at another home: their identity
  # row `remote`, their head cached but past its bound, and their directory
  # a loopback port this home cannot reach.
  defp stale_remote!(user_id) do
    directory = "https://localhost:1"
    Arca.Repo.delete_all(from(p in Arca.Schemas.PersonIdentity, where: p.user_id == ^user_id))

    {live, _} = :crypto.generate_key(:eddsa, :ed25519)
    {operational_pub, operational} = :crypto.generate_key(:eddsa, :ed25519)
    {recovery, _} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, genesis} =
      Prima.Identity.Entry.genesis(
        live_key: live,
        operational_key: operational_pub,
        recovery_keys: [recovery],
        directory: directory
      )

    genesis = Prima.Identity.sign(genesis, operational)
    identifier = Prima.Identity.identifier(genesis)
    head = Prima.Identity.hash(genesis)

    {:ok, _} =
      Arca.PersonIdentities.create(Prima.Actor.system(), %{
        user_id: user_id,
        provenance: "remote",
        identifier: identifier,
        directory_url: directory
      })

    {:ok, _} =
      Arca.DirectoryHeads.put(Prima.Actor.system(), %{
        identifier: identifier,
        genesis: Prima.Identity.canonical(genesis),
        directory_url: directory,
        head_hash: head,
        key_epoch: head,
        state: ~s({"head":"#{head}"})
      })

    Arca.Repo.update_all(
      from(h in Arca.Schemas.DirectoryHead, where: h.identifier == ^identifier),
      set: [verified_at: DateTime.add(DateTime.utc_now(), -400, :second)]
    )

    :ok
  end

  test "an actor with no session is held to the channel rule: an archived athanor writes nothing" do
    ctx = person!()
    state = pending!(%{actor: Context.actor(ctx)})

    Arca.Repo.update_all(from(a in Arca.Schemas.Athanor, where: a.id == ^ctx.athanor_id),
      set: [status: "archived"]
    )

    assert {:error, :unauthenticated} = OAuthGrant.complete(state, "code", @redirect)
    assert entries(ctx.athanor_id) == []
  end

  test "a standing actor goes on to the exchange" do
    ctx = person!()
    state = for_context(ctx)

    assert {:error, reason} = OAuthGrant.complete(state, "code", @redirect)
    refute reason in [:unauthenticated, :unavailable]
  end
end
