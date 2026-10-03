# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TinctureAuthTest do
  # async: false — API-key validation hits the shared Arca.Repo sandbox.
  use ExUnit.Case, async: false

  require Ecto.Query

  alias Sanctum.Context
  alias Sanctum.TinctureAuth

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # ---- the frame protocol's two credentials ----------------------------------

  @person "github|https://github.com|frame-person"
  @digest "sha256:" <> String.duplicate("c", 64)
  @tincture %{publisher: "acme", name: "dash", version: "1.0.0"}
  @other_digest "sha256:" <> String.duplicate("d", 64)

  # The two settings the credentials read, installed beside whatever the
  # run installed and restored after: another test reads the rest.
  defp settings!(window, deadline) do
    previous = Arca.PlatformSettings.installed()

    on_exit(fn ->
      if previous,
        do: Arca.PlatformSettings.install_defaults!(previous),
        else: Arca.PlatformSettings.uninstall()
    end)

    Arca.PlatformSettings.install_defaults!(
      Map.merge(previous || %{}, %{
        "asset_credential_window_s" => %{default: window, stale: :serve},
        "frame_credential_deadline_s" => %{default: deadline, stale: :serve}
      })
    )
  end

  defp frame_person! do
    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: @person,
        provider: "github",
        email: "frame-person@example.com",
        verified: true
      })

    {:ok, _} = Sanctum.Tenancy.Members.ensure(user.id, scope: "athanor", athanor_id: "ath_acme")
    user
  end

  defp session_ctx!(user) do
    ctx =
      Context.build(
        user_id: user.id,
        provider: "github",
        athanor_id: "ath_acme",
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(ctx)
    {:ok, established} = Sanctum.Caller.establish(session.token, focus: "ath_acme")
    {session, %{established | client_ip: "127.0.0.1"}}
  end

  defp expire_session_in!(session, seconds) do
    hash = Sanctum.Session.token_hash(session.token)
    at = DateTime.add(DateTime.utc_now(), seconds, :second)

    {1, _} =
      Arca.Repo.update_all(
        Ecto.Query.from(s in Arca.Schemas.Session, where: s.token_hash == ^hash),
        set: [expires_at: at]
      )

    Sanctum.Caller.invalidate_hash(hash)
    at
  end

  defp end_session!(session) do
    hash = Sanctum.Session.token_hash(session.token)
    Arca.Repo.delete_all(Ecto.Query.from(s in Arca.Schemas.Session, where: s.token_hash == ^hash))
    Sanctum.Caller.invalidate_hash(hash)
  end

  describe "the asset credential" do
    setup do
      Arca.Cache.init()
      settings!(3_600, 3_600)
      user = frame_person!()
      {session, ctx} = session_ctx!(user)
      {:ok, user: user, session: session, source: ctx}
    end

    test "is URL-safe, opens its version for its person, and has at most the window left", %{
      source: ctx
    } do
      assert {:ok, %{credential: credential, expires_at: expires_at}} =
               TinctureAuth.mint_asset_credential(ctx, @digest)

      assert Prima.TinctureUrl.credential?(credential)
      assert Prima.TinctureUrl.asset_path(credential, ["index.html"]) =~ "/_s/"
      refute credential =~ ctx.user_id

      assert {:ok, opened} =
               TinctureAuth.verify_asset_credential(credential, client_ip: "127.0.0.1")

      assert opened.user_id == ctx.user_id
      assert opened.athanor_id == "ath_acme"
      assert opened.version_digest == @digest
      assert opened.expires_at == expires_at
      assert opened.remaining_s > 1_800 and opened.remaining_s <= 3_600
    end

    test "is stable for one person, version and source within its window, and differs otherwise",
         %{source: ctx, user: user} do
      {:ok, %{credential: one}} = TinctureAuth.mint_asset_credential(ctx, @digest)
      {:ok, %{credential: again}} = TinctureAuth.mint_asset_credential(ctx, @digest)
      assert one == again

      {:ok, %{credential: other_version}} = TinctureAuth.mint_asset_credential(ctx, @other_digest)
      refute other_version == one

      {_session, other_source} = session_ctx!(user)
      {:ok, %{credential: other}} = TinctureAuth.mint_asset_credential(other_source, @digest)
      refute other == one
    end

    test "a window of zero is refused, asked for or set", %{source: ctx} do
      assert {:error, :invalid_window} =
               TinctureAuth.mint_asset_credential(ctx, @digest, window_s: 0)

      settings!(0, 3_600)
      assert {:error, :invalid_window} = TinctureAuth.mint_asset_credential(ctx, @digest)
    end

    test "a shorter window may be asked for, never a longer one", %{source: ctx} do
      {:ok, %{credential: short}} = TinctureAuth.mint_asset_credential(ctx, @digest, window_s: 60)
      {:ok, %{remaining_s: left}} = TinctureAuth.verify_asset_credential(short)
      assert left > 30 and left <= 60

      {:ok, %{credential: long}} =
        TinctureAuth.mint_asset_credential(ctx, @digest, window_s: 86_400)

      {:ok, %{remaining_s: capped}} = TinctureAuth.verify_asset_credential(long)
      assert capped <= 3_600
    end

    test "never outlives its source's remaining life", %{source: ctx, session: session} do
      ends = expire_session_in!(session, 100)

      {:ok, %{credential: credential, expires_at: expires_at}} =
        TinctureAuth.mint_asset_credential(ctx, @digest)

      refute DateTime.compare(expires_at, ends) == :gt
      {:ok, %{remaining_s: left}} = TinctureAuth.verify_asset_credential(credential)
      assert left <= 100
    end

    test "a retired source, or a standing transition, refuses every later fetch", %{
      source: ctx,
      session: session,
      user: user
    } do
      {:ok, %{credential: credential}} = TinctureAuth.mint_asset_credential(ctx, @digest)
      assert {:ok, _} = TinctureAuth.verify_asset_credential(credential)

      end_session!(session)
      assert {:error, :not_standing} = TinctureAuth.verify_asset_credential(credential)

      {_session, fresh} = session_ctx!(user)
      {:ok, %{credential: second}} = TinctureAuth.mint_asset_credential(fresh, @digest)
      {:ok, _} = Sanctum.Tenancy.Users.deny(user)
      assert {:error, _retired} = TinctureAuth.verify_asset_credential(second)
    end

    test "anything else is not an asset credential", %{source: ctx} do
      {:ok, %{credential: credential}} = TinctureAuth.mint_asset_credential(ctx, @digest)

      assert {:error, :invalid_credential} =
               TinctureAuth.verify_asset_credential(credential <> "x")

      {:ok, %{credential: bearer}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, "frm_asset_not")

      assert {:error, :invalid_credential} = TinctureAuth.verify_asset_credential(bearer)
      assert {:error, :invalid_version} = TinctureAuth.mint_asset_credential(ctx, "sha256:nope")
    end
  end

  describe "the frame credential" do
    setup do
      Arca.Cache.init()
      settings!(3_600, 900)
      user = frame_person!()
      {session, ctx} = session_ctx!(user)
      {:ok, user: user, session: session, source: ctx}
    end

    defp frame_id, do: "frm_#{System.unique_integer([:positive])}_open"

    test "binds the person, the version, the grant revision and the frame, under its own deadline",
         %{source: ctx} do
      frame = frame_id()

      assert {:ok, %{credential: bearer, id: id, deadline: deadline}} =
               TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 4, frame)

      refute bearer =~ ctx.user_id
      assert DateTime.diff(deadline, DateTime.utc_now()) in 890..900

      assert {:ok, authority} =
               TinctureAuth.verify_frame_credential(bearer, client_ip: "127.0.0.1")

      assert %{
               id: ^id,
               frame_id: ^frame,
               athanor_id: "ath_acme",
               reference: @tincture,
               version_digest: @digest,
               grant_revision: 4,
               deadline: ^deadline
             } = authority

      assert authority.user_id == ctx.user_id
      assert authority.credential_binding.source_kind == :session
    end

    test "without a frame id, a tincture version or a deadline, nothing is minted", %{source: ctx} do
      for missing <- [nil, "", "short", "has space in it"] do
        assert {:error, :missing_frame_id} =
                 TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, missing)
      end

      for reference <- [nil, %{@tincture | version: nil}, %{@tincture | version: "latest"}] do
        assert {:error, :invalid_reference} =
                 TinctureAuth.mint_frame_credential(ctx, reference, @digest, 1, frame_id())
      end

      settings!(3_600, 0)

      assert {:error, :missing_deadline} =
               TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      assert Arca.Repo.aggregate(Arca.Schemas.FrameCredential, :count) == 0
    end

    test "is suspended, resumed and revoked through Sanctum, and each is its standing", %{
      source: ctx
    } do
      {:ok, %{credential: bearer, id: id}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      assert {:ok, %{state: "suspended"}} = TinctureAuth.suspend_frame(ctx, id)
      assert {:error, :suspended} = TinctureAuth.verify_frame_credential(bearer)
      assert {:ok, %{state: "active"}} = TinctureAuth.resume_frame(ctx, id)
      assert {:ok, _} = TinctureAuth.verify_frame_credential(bearer)
      assert {:ok, %{state: "revoked"}} = TinctureAuth.revoke_frame(ctx, id)
      assert {:error, :revoked} = TinctureAuth.verify_frame_credential(bearer)
      assert {:error, :revoked} = TinctureAuth.resume_frame(ctx, id)
    end

    test "another person's frame reads as absent", %{source: ctx} do
      {:ok, %{id: id}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      {:ok, other} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: "github|https://github.com|frame-other",
          provider: "github",
          email: "frame-other@example.com",
          verified: true
        })

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(other.id, scope: "athanor", athanor_id: "ath_acme")

      {_session, theirs} = session_ctx!(other)

      assert {:error, :not_found} = TinctureAuth.suspend_frame(theirs, id)
      assert {:error, :not_found} = TinctureAuth.revoke_frame(theirs, id)
    end

    test "its deadline never outlives its source, and past it the bearer opens nothing", %{
      source: ctx,
      session: session
    } do
      ends = expire_session_in!(session, 100)

      {:ok, %{credential: bearer, id: id, deadline: deadline}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      refute DateTime.compare(deadline, ends) == :gt

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(f in Arca.Schemas.FrameCredential, where: f.id == ^id),
          set: [deadline: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert {:error, :expired_credential} = TinctureAuth.verify_frame_credential(bearer)
    end

    test "a retired source and a standing transition each refuse it", %{
      source: ctx,
      session: session,
      user: user
    } do
      {:ok, %{credential: first}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      end_session!(session)
      assert {:error, :not_standing} = TinctureAuth.verify_frame_credential(first)

      {_session, fresh} = session_ctx!(user)

      {:ok, %{credential: second, id: id}} =
        TinctureAuth.mint_frame_credential(fresh, @tincture, @digest, 1, frame_id())

      {:ok, _} = Sanctum.Tenancy.Users.deny(user)
      assert {:error, :revoked} = TinctureAuth.verify_frame_credential(second)

      assert %{state: "revoked"} = Arca.Repo.get(Arca.Schemas.FrameCredential, id)
    end

    test "establishes a context bound to the frame, refused once the frame stops standing", %{
      source: ctx
    } do
      frame = frame_id()

      {:ok, %{credential: bearer, id: id, deadline: deadline}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 2, frame)

      assert {:ok, framed} =
               Sanctum.Caller.establish({:frame_credential, bearer}, client_ip: "127.0.0.1")

      assert framed.frame == %{
               id: id,
               frame_id: frame,
               reference: @tincture,
               version_digest: @digest,
               grant_revision: 2
             }

      assert {framed.user_id, framed.athanor_id} == {ctx.user_id, "ath_acme"}
      assert framed.auth_method == :tincture
      assert framed.authenticated
      assert framed.credential_deadline == deadline
      assert %DateTime{} = framed.validated_at
      # No other clause stamps a frame.
      assert ctx.frame == nil

      {:ok, _} = TinctureAuth.suspend_frame(ctx, id)
      assert {:error, :suspended} = Sanctum.Caller.establish({:frame_credential, bearer})
      {:ok, _} = TinctureAuth.resume_frame(ctx, id)
      assert {:ok, _} = Sanctum.Caller.establish({:frame_credential, bearer})
      {:ok, _} = TinctureAuth.revoke_frame(ctx, id)
      assert {:error, :revoked} = Sanctum.Caller.establish({:frame_credential, bearer})

      assert {:error, :invalid_credential} =
               Sanctum.Caller.establish({:frame_credential, bearer <> "x"})
    end

    test "a bearer this server did not sign as one opens nothing", %{source: ctx} do
      {:ok, %{credential: bearer}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      assert {:error, :invalid_credential} = TinctureAuth.verify_frame_credential(bearer <> "x")

      {:ok, %{credential: asset}} = TinctureAuth.mint_asset_credential(ctx, @digest)
      assert {:error, :invalid_credential} = TinctureAuth.verify_frame_credential(asset)
    end
  end
end
