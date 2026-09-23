# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DerivedCredentialRetirementTest do
  @moduledoc """
  A tincture access token (`?_t=`) and an asset token (`/_s/`) are narrowed
  derivatives of one stored session or API key, held to that credential's
  rows at every use. Every transition that retires the source, the person,
  the estate or the membership the focus rested on retires both tokens for
  good; a restore brings none back. A key creator leaving the estate keeps
  the key's tokens standing, by the key's own rule. A store that cannot
  answer is `:unavailable` and opens nothing.

  The first case is the assessment's reproduction, kept as a permanent
  regression: a service key's token, the person denied and allowed again.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Sanctum.{ApiKey, Caller, Context, Session, TinctureAuth}
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @person "github|https://github.com|u1"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # S7TinctureTokenTest's fixture: the stored person and an active
    # two-member tenant.
    {:ok, user} =
      Users.upsert_from_provider(%{
        id: @person,
        provider: "github",
        email: "u1@example.com",
        verified: true
      })

    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: "ath_acme")

    {:ok, _} =
      Members.ensure("github|https://github.com|u2", scope: "athanor", athanor_id: "ath_acme")

    {:ok, user: user}
  end

  # ---- sources ---------------------------------------------------------------

  defp session_ctx(user, athanor_id \\ "ath_acme") do
    ctx =
      Context.build(
        user_id: user.id,
        provider: "github",
        athanor_id: athanor_id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(ctx)
    {:ok, established} = Caller.establish(session.token, focus: athanor_id)
    {session, established}
  end

  defp key_ctx(user, attrs \\ %{}, ip \\ "127.0.0.1") do
    {_session, ctx} = session_ctx(user)
    name = "svc-#{System.unique_integer([:positive])}"

    {:ok, %{api_key: raw}} =
      ApiKey.create(ctx, Map.merge(%{name: name, type: :service}, attrs))

    {:ok, key_ctx} = Caller.establish({:api_key, raw}, client_ip: ip)
    {name, raw, %{key_ctx | client_ip: ip}}
  end

  defp access!(ctx) do
    {:ok, token} = TinctureAuth.issue_access_token(ctx, "acme", "dash")
    token
  end

  defp asset!(ctx) do
    {:ok, token} = TinctureAuth.issue_asset_token(ctx, "acme", "dash")
    token
  end

  # Both derivatives, minted from one source context.
  defp minted!(ctx), do: {access!(ctx), asset!(ctx)}

  defp use_access(token) do
    TinctureAuth.authenticate(%Plug.Conn{
      query_string: "_t=#{token}",
      remote_ip: {127, 0, 0, 1},
      path_params: %{"publisher" => "acme", "tincture_name" => "dash"}
    })
  end

  defp use_asset(token, athanor_id \\ "ath_acme") do
    request =
      Context.build(athanor_id: athanor_id, scope: :athanor, authenticated: false)
      |> Map.put(:client_ip, "127.0.0.1")

    TinctureAuth.verify_asset_token(token, request, "acme", "dash")
  end

  # What each token is answered, side by side: `:ok`, or the refusal. An
  # access token's use is answered in the request vocabulary
  # (`Sanctum.Caller`), an asset token's in the check's own.
  defp answers({access, asset}), do: {answer(use_access(access)), answer(use_asset(asset))}

  defp answer({:ok, %Context{}}), do: :ok
  defp answer({:error, reason}), do: reason

  @opens {:ok, :ok}
  @retired {:not_standing, :not_standing}

  # ---- §15 recipe 1 ----------------------------------------------------------

  describe "the assessment's reproduction" do
    test "a service key's token stays refused after the person is denied and allowed", %{
      user: user
    } do
      {_name, _raw, ctx} = key_ctx(user)
      tokens = minted!(ctx)
      assert answers(tokens) == @opens

      {:ok, denied} = Users.deny(user)
      assert use_access(elem(tokens, 0)) == {:error, :not_standing}

      {:ok, _} = Users.allow(denied)
      assert use_access(elem(tokens, 0)) == {:error, :not_standing}
      assert {:error, :not_standing} = use_asset(elem(tokens, 1))
    end
  end

  # ---- §14.11's transition table ---------------------------------------------

  describe "a previously minted access and asset token, after" do
    test "the source session is logged out — another sign-in restores nothing", %{user: user} do
      {session, ctx} = session_ctx(user)
      tokens = minted!(ctx)
      assert answers(tokens) == @opens

      :ok = Session.destroy(session.token)
      assert answers(tokens) == @retired

      _other = session_ctx(user)
      assert answers(tokens) == @retired
    end

    test "the source session is deleted by its row key", %{user: user} do
      {session, ctx} = session_ctx(user)
      tokens = minted!(ctx)
      :ok = Session.destroy_by_hash(Session.token_hash(session.token))
      assert answers(tokens) == @retired
    end

    test "the source session expires", %{user: user} do
      {session, ctx} = session_ctx(user)
      tokens = minted!(ctx)
      expire!(session)
      assert answers(tokens) == @retired
    end

    test "the source key is revoked — a new key with the same name restores nothing", %{
      user: user
    } do
      {name, _raw, ctx} = key_ctx(user)
      tokens = minted!(ctx)
      assert answers(tokens) == @opens

      :ok = ApiKey.revoke(ctx, name)
      assert answers(tokens) == @retired

      {_session, owner} = session_ctx(user)
      {:ok, _} = ApiKey.create(owner, %{name: name, type: :service})
      assert answers(tokens) == @retired
    end

    test "the source key is rotated", %{user: user} do
      {name, _raw, ctx} = key_ctx(user)
      tokens = minted!(ctx)
      {_session, owner} = session_ctx(user)
      {:ok, %{api_key: rotated}} = ApiKey.rotate(owner, name)

      # A rotation is a new credential under the same name: the row the
      # tokens were minted from is retired with its secret.
      assert answers(tokens) == @retired
      {:ok, successor} = Caller.establish({:api_key, rotated}, client_ip: "127.0.0.1")
      refute successor.api_key_id == ctx.api_key_id
    end

    test "the person is denied, then allowed", %{user: user} do
      {_session, ctx} = session_ctx(user)
      tokens = minted!(ctx)
      {:ok, denied} = Users.deny(user)
      assert answers(tokens) == @retired
      {:ok, _} = Users.allow(denied)
      assert answers(tokens) == @retired
    end

    test "the tenant is archived, then reopened", %{user: user} do
      {_session, ctx} = session_ctx(user)
      tokens = minted!(ctx)
      {:ok, athanor} = Athanors.get("ath_acme")
      {:ok, archived} = Athanors.archive(athanor)
      assert answers(tokens) == @retired
      {:ok, _} = Athanors.unarchive(archived)
      assert answers(tokens) == @retired
    end

    test "the session person's membership is removed, then rejoined", %{user: user} do
      {_session, ctx} = session_ctx(user)
      tokens = minted!(ctx)
      {:ok, athanor} = Athanors.get("ath_acme")
      :ok = Members.remove_member(athanor, user_id: user.id)
      assert answers(tokens) == {:not_standing, :not_member}

      {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: "ath_acme")
      assert answers(tokens) == {:not_standing, :not_member}
    end

    test "the key creator leaves while the key, the creator and the tenant stand", %{
      user: user
    } do
      {_name, _raw, ctx} = key_ctx(user)
      tokens = minted!(ctx)
      {:ok, athanor} = Athanors.get("ath_acme")
      :ok = Members.remove_member(athanor, user_id: user.id)

      # A key's focus is the key: it outlives its creator's seat on purpose.
      assert answers(tokens) == @opens
    end

    test "the platform grant behind the focus is removed, then granted again" do
      n = System.unique_integer([:positive])

      {:ok, operator} =
        Users.upsert_from_provider(%{
          id: "github|https://github.com|op-#{n}",
          provider: "github",
          email: "op#{n}@example.com",
          verified: true
        })

      {:ok, _} = Members.ensure_platform(operator.id)
      {_session, ctx} = session_ctx(operator)
      {:ok, platform} = Members.platform_seat(operator.id)
      assert ctx.credential_binding.focus_basis == platform.id
      tokens = minted!(ctx)
      assert answers(tokens) == @opens

      :ok = Members.revoke_platform(operator.id)
      assert answers(tokens) == {:not_standing, :not_member}

      {:ok, _} = Members.ensure_platform(operator.id)
      assert answers(tokens) == {:not_standing, :not_member}
    end

    test "the store cannot answer: unavailable, and nothing is minted or opened", %{
      user: user
    } do
      {_session, ctx} = session_ctx(user)
      tokens = minted!(ctx)
      outage!()

      assert answers(tokens) == {:unavailable, :unavailable}
      assert TinctureAuth.issue_access_token(ctx, "acme", "dash") == {:error, :unavailable}
      assert TinctureAuth.issue_asset_token(ctx, "acme", "dash") == {:error, :unavailable}
    end
  end

  # ---- lineage and lifetime --------------------------------------------------

  describe "a derived token's lineage" do
    test "an access token cannot mint an access token, and an asset token mints nothing", %{
      user: user
    } do
      {_session, ctx} = session_ctx(user)
      {:ok, access_ctx} = use_access(access!(ctx))
      assert {:error, :not_primary} = TinctureAuth.issue_access_token(access_ctx, "acme", "dash")

      # The access token's context may mint the asset prefix it serves...
      {:ok, asset} = TinctureAuth.issue_asset_token(access_ctx, "acme", "dash")
      {:ok, asset_ctx} = use_asset(asset)

      # ...and the context an asset token narrows mints nothing.
      assert {:error, :not_primary} = TinctureAuth.issue_access_token(asset_ctx, "acme", "dash")
      assert {:error, :not_primary} = TinctureAuth.issue_asset_token(asset_ctx, "acme", "dash")
    end

    test "an access token's context with its method changed is still not a primary source",
         %{user: user} do
      {_session, ctx} = session_ctx(user)
      {:ok, access_ctx} = use_access(access!(ctx))

      # The binding names the session the token came from, but the context
      # holds no session row key of its own to agree with it.
      for method <- [:session, :oidc] do
        flipped = %{access_ctx | auth_method: method}

        assert {:error, :missing_generation} =
                 TinctureAuth.issue_access_token(flipped, "acme", "dash")

        assert {:error, :missing_generation} =
                 TinctureAuth.issue_asset_token(flipped, "acme", "dash")
      end

      # Nor does a key id that is not the binding's source.
      key_flip = %{access_ctx | auth_method: :api_key, api_key_id: "key_other"}

      assert {:error, :missing_generation} =
               TinctureAuth.issue_access_token(key_flip, "acme", "dash")
    end

    test "a key context whose key id is not its binding's source mints nothing", %{user: user} do
      {_name, _raw, key} = key_ctx(user)
      assert key.credential_binding.source_kind == :api_key

      # The binding names the key the context was established from; a
      # context carrying another key's id does not agree with it.
      moved = %{key | api_key_id: "key_other"}

      assert {:error, :missing_generation} =
               TinctureAuth.issue_access_token(moved, "acme", "dash")

      assert {:error, :missing_generation} = TinctureAuth.issue_asset_token(moved, "acme", "dash")
    end

    test "a context with no source lineage mints nothing", %{user: user} do
      bare =
        Context.build(
          user_id: user.id,
          athanor_id: "ath_acme",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      assert {:error, :missing_generation} = TinctureAuth.issue_access_token(bare, "acme", "dash")

      identity = %{
        bare
        | credential_binding: %{
            source_kind: :identity,
            source_id: nil,
            focus_basis: nil,
            user_generation: 1,
            athanor_generation: 1
          }
      }

      assert {:error, :missing_generation} =
               TinctureAuth.issue_access_token(identity, "acme", "dash")
    end

    test "a key with no person behind it mints nothing", %{user: user} do
      {_name, raw, _ctx} = key_ctx(user)

      {1, _} =
        Arca.Repo.update_all(
          from(k in Arca.Schemas.ApiKey, where: k.created_by == ^user.id),
          set: [created_by: "system"]
        )

      {:ok, orphan} = Caller.establish({:api_key, raw}, client_ip: "127.0.0.1")
      assert orphan.credential_binding == nil

      assert {:error, :missing_generation} =
               TinctureAuth.issue_access_token(orphan, "acme", "dash")
    end

    test "a member that does not hold the control plane mints nothing", %{user: user} do
      {_session, ctx} = session_ctx(user)
      Arca.ControlPlane.record(:lost)
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)

      assert {:error, :not_owner} = TinctureAuth.issue_access_token(ctx, "acme", "dash")
      assert {:error, :not_owner} = TinctureAuth.issue_asset_token(ctx, "acme", "dash")
    end

    test "cross-purpose tokens are refused both ways", %{user: user} do
      {_session, ctx} = session_ctx(user)
      {access, asset} = minted!(ctx)

      assert use_access(asset) == {:error, :invalid_credential}
      assert use_asset(access) == {:error, :invalid_credential}
    end

    test "a forged, an older or an incomplete envelope is refused", %{user: user} do
      {_session, ctx} = session_ctx(user)
      {:ok, claims} = TinctureAuth.verify_access_token(access!(ctx))
      payload = signed_payload(claims)
      secret = TinctureAuth.signing_secret()

      # The earlier codecs verify nothing: there is no legacy fallback.
      older =
        Phoenix.Token.sign(secret, "tincture_access_v4", %{
          u: user.id,
          a: "ath_acme",
          n: "ns",
          p: "acme",
          t: "dash",
          m: :person
        })

      assert use_access(older) == {:error, :invalid_credential}

      # A payload of another version or missing a field.
      for bad <- [%{payload | v: 2}, Map.delete(payload, :focus_basis)] do
        assert use_access(Phoenix.Token.sign(secret, "tincture_access_v5", bad)) ==
                 {:error, :invalid_credential}
      end

      # A well-formed envelope naming a credential that was never issued: the
      # binding check, not the signature, is what refuses it.
      forged = %{
        payload
        | source_id: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      }

      assert use_access(Phoenix.Token.sign(secret, "tincture_access_v5", forged)) ==
               {:error, :not_standing}

      # Nor may a key-sourced claim borrow a session's focus.
      as_key = %{payload | source_kind: "api_key", focus_basis: "key"}

      assert use_access(Phoenix.Token.sign(secret, "tincture_access_v5", as_key)) ==
               {:error, :not_standing}
    end

    test "a token expires with a source that expires sooner than the hour", %{user: user} do
      {session, ctx} = session_ctx(user)
      soon = expire!(session, 600)

      {:ok, access} = TinctureAuth.issue_access_token(ctx, "acme", "dash")
      {:ok, claims} = TinctureAuth.verify_access_token(access)
      assert DateTime.compare(claims.expires_at, DateTime.truncate(soon, :second)) != :gt
      assert {:ok, seconds} = TinctureAuth.expires_in(access)
      assert seconds <= 600
    end

    test "an asset token cannot outlive its access parent", %{user: user} do
      {_session, ctx} = session_ctx(user)
      {:ok, access_ctx} = use_access(access!(ctx))
      parent = DateTime.add(DateTime.utc_now(), 300, :second)

      {:ok, asset} =
        TinctureAuth.issue_asset_token(
          %{access_ctx | credential_deadline: parent},
          "acme",
          "dash"
        )

      {:ok, narrowed} = use_asset(asset)
      assert DateTime.compare(narrowed.credential_deadline, parent) != :gt
      assert DateTime.diff(narrowed.credential_deadline, DateTime.utc_now()) <= 300
    end

    test "an asset envelope names its own athanor and tincture", %{user: user} do
      {_session, ctx} = session_ctx(user)
      asset = asset!(ctx)

      assert use_asset(asset, "ath_other") == {:error, :invalid_credential}

      request = Context.build(athanor_id: "ath_acme", scope: :athanor, authenticated: false)

      assert {:error, :invalid_credential} =
               TinctureAuth.verify_asset_token(asset, request, "acme", "billing")
    end
  end

  describe "a key's allowlist on the derived path" do
    setup %{user: user} do
      {name, raw, ctx} = key_ctx(user, %{ip_allowlist: ["203.0.113.0/24"]}, "203.0.113.9")
      {:ok, name: name, raw: raw, key: ctx}
    end

    defp access_from(token, ip) do
      TinctureAuth.authenticate(%Plug.Conn{
        query_string: "_t=#{token}",
        remote_ip: ip,
        path_params: %{"publisher" => "acme", "tincture_name" => "dash"}
      })
    end

    defp asset_from(token, ip) do
      request =
        Context.build(athanor_id: "ath_acme", scope: :athanor, authenticated: false)
        |> Map.put(:client_ip, ip)

      TinctureAuth.verify_asset_token(token, request, "acme", "dash")
    end

    test "a token minted from an admitted address opens from one", %{key: key} do
      {access, asset} = minted!(key)
      assert {:ok, %Context{}} = access_from(access, {203, 0, 113, 20})
      assert {:ok, %Context{}} = asset_from(asset, "203.0.113.20")
    end

    test "a token used from an address the key's allowlist refuses is refused", %{key: key} do
      {access, asset} = minted!(key)
      assert access_from(access, {198, 51, 100, 1}) == {:error, :ip_not_allowed}
      assert asset_from(asset, "198.51.100.1") == {:error, :ip_not_allowed}
      assert asset_from(asset, nil) == {:error, :ip_not_allowed}
    end

    test "a mint from a refused address or from none is refused", %{key: key} do
      assert {:error, :ip_not_allowed} =
               TinctureAuth.issue_access_token(%{key | client_ip: "198.51.100.1"}, "acme", "dash")

      assert {:error, :ip_not_allowed} =
               TinctureAuth.issue_access_token(%{key | client_ip: nil}, "acme", "dash")

      assert {:error, :ip_not_allowed} =
               TinctureAuth.issue_asset_token(%{key | client_ip: "198.51.100.1"}, "acme", "dash")

      assert {:error, :ip_not_allowed} =
               TinctureAuth.issue_asset_token(%{key | client_ip: nil}, "acme", "dash")
    end
  end

  describe "a generation snapshot" do
    test "is refused by a build compiled without the test permission", %{user: user} do
      bare =
        Context.build(
          user_id: user.id,
          athanor_id: "ath_acme",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      snapshot = Sanctum.TestContext.snapshot!(bare)
      assert {:ok, _} = Sanctum.Issuance.snapshot(true, bare, snapshot)
      assert {:error, :missing_generation} = Sanctum.Issuance.snapshot(false, bare, snapshot)
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp expire!(session, seconds \\ -60) do
    at = DateTime.add(DateTime.utc_now(), seconds, :second)

    {1, _} =
      Arca.Repo.update_all(
        where(Arca.Schemas.Session, token_hash: ^Session.token_hash(session.token)),
        set: [expires_at: at]
      )

    Sanctum.Caller.drop_memo(Session.token_hash(session.token))
    at
  end

  # The session table is gone for the length of the test (the sandbox rolls
  # the rename back): every read of it fails the way an outage does.
  defp outage! do
    Arca.Repo.query!("ALTER TABLE sessions RENAME TO sessions_unavailable")
  end

  defp signed_payload(claims) do
    %{
      v: 1,
      purpose: "access",
      user_id: claims.user_id,
      athanor_id: claims.athanor_id,
      publisher: claims.publisher,
      tincture_name: claims.tincture_name,
      user_generation: claims.user_generation,
      athanor_generation: claims.athanor_generation,
      source_kind: Atom.to_string(claims.source_kind),
      source_id: claims.source_id,
      focus_basis: claims.focus_basis,
      expires_at: DateTime.to_unix(claims.expires_at)
    }
  end
end
