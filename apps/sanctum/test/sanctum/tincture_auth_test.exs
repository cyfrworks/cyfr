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
               mode: :live,
               deadline: ^deadline
             } = authority

      assert %{purpose: "live"} = Arca.Repo.get(Arca.Schemas.FrameCredential, id)

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
      assert {:ok, %{credential: resumed, id: ^id}} = TinctureAuth.resume_frame(ctx, id)
      assert %{state: "active"} = Arca.Repo.get(Arca.Schemas.FrameCredential, id)
      assert {:ok, _} = TinctureAuth.verify_frame_credential(bearer)
      assert {:ok, _} = TinctureAuth.verify_frame_credential(resumed)
      assert {:ok, %{state: "revoked"}} = TinctureAuth.revoke_frame(ctx, id)
      assert {:error, :revoked} = TinctureAuth.verify_frame_credential(bearer)
      assert {:error, :revoked} = TinctureAuth.resume_frame(ctx, id)
    end

    for {change, act} <- [suspended: :suspend_frame, revoked: :revoke_frame] do
      @tag change: change, act: act
      test "#{act} announces the standing change once it is stored, naming the credential and never its bearer",
           %{source: ctx, change: change, act: act} do
        {:ok, %{credential: bearer, id: id}} =
          TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

        handler = "frame-credential-#{change}-#{System.unique_integer([:positive])}"
        test_pid = self()

        :ok =
          :telemetry.attach(
            handler,
            [:cyfr, :sanctum, :frame_credential, :changed],
            fn _event, measurements, metadata, _config ->
              send(test_pid, {:frame_credential_changed, measurements, metadata})
            end,
            nil
          )

        on_exit(fn -> :telemetry.detach(handler) end)

        assert {:ok, %{id: ^id}} = apply(TinctureAuth, act, [ctx, id])
        assert %{state: stored} = Arca.Repo.get(Arca.Schemas.FrameCredential, id)
        assert stored == Atom.to_string(change)

        assert_receive {:frame_credential_changed, %{count: 1}, metadata}
        assert metadata == %{user_id: ctx.user_id, credential_id: id, change: change}
        refute inspect(metadata) =~ bearer
      end
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
               grant_revision: 2,
               mode: :live
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

    test "a renew rotates the bearer, and the one it replaced ends at its own deadline", %{
      source: ctx
    } do
      settings!(3_600, 2)

      {:ok, %{credential: old, id: id, deadline: old_deadline}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 4, frame_id())

      settings!(3_600, 900)

      assert {:ok, %{credential: new, id: ^id, deadline: deadline}} =
               TinctureAuth.renew_frame(ctx, id)

      refute new == old
      assert DateTime.compare(deadline, old_deadline) == :gt
      assert DateTime.diff(deadline, DateTime.utc_now()) in 890..900
      assert %{state: "active", deadline: ^deadline} = frame_row(id)

      # A stream opened with the old bearer is held to the old deadline.
      assert {:ok, %{credential_deadline: ^old_deadline}} =
               Sanctum.Caller.establish({:frame_credential, old}, client_ip: "127.0.0.1")

      assert {:ok, %{credential_deadline: ^deadline}} =
               Sanctum.Caller.establish({:frame_credential, new}, client_ip: "127.0.0.1")

      # Past the old bearer's own deadline it is refused, while the row and
      # the new bearer stand.
      Prima.Test.Wait.wait_until(
        fn ->
          TinctureAuth.verify_frame_credential(old) == {:error, :expired_credential} and
            match?({:ok, %{id: ^id}}, TinctureAuth.verify_frame_credential(new)) and
            DateTime.compare(frame_row(id).deadline, DateTime.utc_now()) == :gt
        end,
        5_000,
        "the old bearer refused at its own deadline while the row stands"
      )
    end

    test "a renewed bearer binds the row's own version digest and grant revision", %{
      source: ctx
    } do
      frame = frame_id()

      {:ok, %{id: id}} = TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 4, frame)
      {:ok, %{credential: renewed}} = TinctureAuth.renew_frame(ctx, id)

      assert {:ok,
              %{
                id: ^id,
                frame_id: ^frame,
                reference: @tincture,
                version_digest: @digest,
                grant_revision: 4,
                mode: :live
              }} = TinctureAuth.verify_frame_credential(renewed)

      assert %{version_digest: @digest, grant_revision: 4} = frame_row(id)
    end

    test "a suspended, a revoked or a validation row is not renewed, and nothing is written", %{
      source: ctx
    } do
      {:ok, %{id: suspended}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      {:ok, _} = TinctureAuth.suspend_frame(ctx, suspended)

      {:ok, %{id: revoked}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      {:ok, _} = TinctureAuth.revoke_frame(ctx, revoked)

      {:ok, %{id: validation}} =
        TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 1, frame_id())

      before = Map.new([suspended, revoked, validation], &{&1, frame_row(&1)})

      assert {:error, :suspended} = TinctureAuth.renew_frame(ctx, suspended)
      assert {:error, :revoked} = TinctureAuth.renew_frame(ctx, revoked)
      assert {:error, :validation} = TinctureAuth.renew_frame(ctx, validation)

      for {id, row} <- before, do: assert(frame_row(id) == row)
    end

    test "a member that lost its slot renews nothing", %{source: ctx} do
      {:ok, %{id: id}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      row = frame_row(id)
      lose_slot!()

      assert {:error, :not_owner} = TinctureAuth.renew_frame(ctx, id)
      assert %{deadline: deadline, updated_at: updated_at} = frame_row(id)
      assert {deadline, updated_at} == {row.deadline, row.updated_at}
    end

    test "a renew never sets a deadline past the session's own expiry", %{
      source: ctx,
      session: session
    } do
      {:ok, %{id: id}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      ends = expire_session_in!(session, 100)

      assert {:ok, %{credential: renewed, deadline: deadline}} = TinctureAuth.renew_frame(ctx, id)
      refute DateTime.compare(deadline, ends) == :gt
      assert DateTime.diff(ends, deadline, :millisecond) < 1_000

      assert {:ok, %{deadline: bound}} = TinctureAuth.verify_frame_credential(renewed)
      refute DateTime.compare(bound, ends) == :gt
    end

    test "a renew or a resume from another source of the same person is refused", %{
      source: ctx,
      user: user
    } do
      {:ok, %{id: id}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      {_session, other} = session_ctx!(user)
      row = frame_row(id)

      assert {:error, :not_found} = TinctureAuth.renew_frame(other, id)
      {:ok, _} = TinctureAuth.suspend_frame(ctx, id)
      suspended = frame_row(id)
      assert {:error, :not_found} = TinctureAuth.resume_frame(other, id)
      assert frame_row(id) == suspended
      assert suspended.deadline == row.deadline
    end

    test "a resume after the deadline passed while suspended rotates the bearer", %{source: ctx} do
      settings!(3_600, 2)

      {:ok, %{credential: old, id: id}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      {:ok, _} = TinctureAuth.suspend_frame(ctx, id)

      Prima.Test.Wait.wait_until(
        fn -> DateTime.compare(frame_row(id).deadline, DateTime.utc_now()) == :lt end,
        5_000,
        "the suspended row's deadline to pass"
      )

      settings!(3_600, 900)

      assert {:ok, %{credential: new, id: ^id, deadline: deadline}} =
               TinctureAuth.resume_frame(ctx, id)

      assert DateTime.diff(deadline, DateTime.utc_now()) in 890..900
      assert %{state: "active", deadline: ^deadline} = frame_row(id)
      assert {:ok, %{id: ^id, deadline: ^deadline}} = TinctureAuth.verify_frame_credential(new)
      assert {:error, :expired_credential} = TinctureAuth.verify_frame_credential(old)
    end

    test "a resume that does not rotate signs nothing and keeps the row's deadline", %{
      source: ctx
    } do
      settings!(3_600, 2)

      {:ok, %{credential: bearer, id: id, deadline: deadline}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      {:ok, _} = TinctureAuth.suspend_frame(ctx, id)
      settings!(3_600, 900)

      assert {:ok, answer} = TinctureAuth.resume_frame(ctx, id, rotate: false)
      assert answer == %{id: id, deadline: deadline}
      assert %{state: "active", deadline: ^deadline} = frame_row(id)
      assert {:ok, %{deadline: ^deadline}} = TinctureAuth.verify_frame_credential(bearer)

      {:ok, _} = TinctureAuth.suspend_frame(ctx, id)

      Prima.Test.Wait.wait_until(
        fn -> DateTime.compare(frame_row(id).deadline, DateTime.utc_now()) == :lt end,
        5_000,
        "the suspended row's deadline to pass"
      )

      suspended = frame_row(id)
      assert {:error, :expired} = TinctureAuth.resume_frame(ctx, id, rotate: false)
      assert frame_row(id) == suspended
    end

    test "a resume of a revoked row, or of one retention removed, fails", %{source: ctx} do
      {:ok, %{id: id}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      {:ok, _} = TinctureAuth.revoke_frame(ctx, id)
      assert {:error, :revoked} = TinctureAuth.resume_frame(ctx, id)

      {:ok, swept} =
        Arca.FrameCredentials.delete_revoked_before(DateTime.add(DateTime.utc_now(), 60),
          athanor_id: "ath_acme"
        )

      assert swept >= 1
      assert frame_row(id) == nil
      assert {:error, :not_found} = TinctureAuth.resume_frame(ctx, id)
      assert {:error, :not_found} = TinctureAuth.renew_frame(ctx, id)
    end

    test "a bearer this server did not sign as one opens nothing", %{source: ctx} do
      {:ok, %{credential: bearer}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      assert {:error, :invalid_credential} = TinctureAuth.verify_frame_credential(bearer <> "x")

      {:ok, %{credential: asset}} = TinctureAuth.mint_asset_credential(ctx, @digest)
      assert {:error, :invalid_credential} = TinctureAuth.verify_frame_credential(asset)
    end

    test "a context's frame names its mode, and a frame without a known one is refused" do
      frame = %{
        id: "frc_mode",
        frame_id: "frm_mode_aaaaaaaa",
        reference: @tincture,
        version_digest: @digest,
        grant_revision: 0
      }

      for mode <- [:live, :validation] do
        assert %Context{frame: %{mode: ^mode}} = framed_context(Map.put(frame, :mode, mode))
      end

      for malformed <- [frame, Map.put(frame, :mode, "live"), Map.put(frame, :mode, :trial)] do
        assert_raise ArgumentError, ~r/frame is malformed/, fn -> framed_context(malformed) end
      end
    end
  end

  describe "the page's frame" do
    setup do
      Arca.Cache.init()
      settings!(3_600, 900)
      user = frame_person!()
      {_session, ctx} = session_ctx!(user)
      {:ok, %{credential: credential}} = TinctureAuth.mint_asset_credential(ctx, @digest)
      {:ok, authority} = TinctureAuth.verify_asset_credential(credential, client_ip: "127.0.0.1")
      {:ok, user: user, source: ctx, authority: authority}
    end

    defp page_frame_id, do: "frm_#{System.unique_integer([:positive])}_page"

    defp opened!(ctx, mint \\ :mint_frame_credential, digest \\ @digest) do
      frame = page_frame_id()
      {:ok, %{id: id}} = apply(TinctureAuth, mint, [ctx, @tincture, digest, 0, frame])
      {frame, id}
    end

    test "answers the version a standing frame of the credential's person and version opened",
         %{source: ctx, authority: authority} do
      opened = {:ok, %{reference: @tincture, version_digest: @digest}}

      {live, live_id} = opened!(ctx)
      assert TinctureAuth.page_frame(authority, live) == opened

      # Suspended is still the open's: its page is shown again when it is.
      {:ok, _} = TinctureAuth.suspend_frame(ctx, live_id)
      assert TinctureAuth.page_frame(authority, live) == opened

      # A validation trial's frame is a page's too.
      {trial, _id} = opened!(ctx, :mint_validation_credential)
      assert TinctureAuth.page_frame(authority, trial) == opened
    end

    test "a revoked, expired, absent or other version's frame is not found",
         %{source: ctx, authority: authority} do
      {revoked, revoked_id} = opened!(ctx)
      {:ok, _} = TinctureAuth.revoke_frame(ctx, revoked_id)

      {expired, expired_id} = opened!(ctx)

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(f in Arca.Schemas.FrameCredential, where: f.id == ^expired_id),
          set: [deadline: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      {another_version, _id} = opened!(ctx, :mint_frame_credential, @other_digest)

      for frame <- [revoked, expired, another_version, page_frame_id()] do
        assert {:error, :not_found} = TinctureAuth.page_frame(authority, frame), frame
      end
    end

    test "another person's frame and another athanor's are not found", %{
      source: ctx,
      authority: authority
    } do
      {:ok, other} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: "github|https://github.com|page-other",
          provider: "github",
          email: "page-other@example.com",
          verified: true
        })

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(other.id, scope: "athanor", athanor_id: "ath_acme")

      {_session, theirs} = session_ctx!(other)
      {their_frame, _id} = opened!(theirs)

      # The person's own row of the same version, in another athanor.
      elsewhere = page_frame_id()

      {:ok, _row} =
        Arca.FrameCredentials.mint(Prima.Actor.in_athanor("ath_page_other"), %{
          user_id: ctx.user_id,
          publisher: @tincture.publisher,
          name: @tincture.name,
          version: @tincture.version,
          version_digest: @digest,
          grant_revision: 0,
          frame_id: elsewhere,
          source_kind: "session",
          source_id: ctx.credential_binding.source_id,
          deadline: DateTime.add(DateTime.utc_now(), 600, :second)
        })

      for frame <- [their_frame, elsewhere] do
        assert {:error, :not_found} = TinctureAuth.page_frame(authority, frame), frame
      end
    end
  end

  defp frame_row(id), do: Arca.Repo.get(Arca.Schemas.FrameCredential, id)

  # This member loses its slot for the rest of the test, and has it back
  # after.
  defp lose_slot! do
    key = {Arca.ControlPlane, :standing}
    previous = :persistent_term.get(key, :absent)

    on_exit(fn ->
      if previous == :absent,
        do: :persistent_term.erase(key),
        else: :persistent_term.put(key, previous)
    end)

    Arca.ControlPlane.record(:lost)
  end

  # `Prima.CredentialShape` pins `Plug.Crypto`'s signed form, whose header
  # the library keeps private: every credential minted here is held to it,
  # so the pin cannot drift from what is issued.
  describe "the signed credentials' shape" do
    setup do
      Arca.Cache.init()
      settings!(3_600, 900)
      user = frame_person!()
      {_session, ctx} = session_ctx!(user)
      {:ok, source: ctx}
    end

    test "every asset, frame and validation credential is a signed token the sanitizer redacts",
         %{source: ctx} do
      {:ok, %{credential: asset}} = TinctureAuth.mint_asset_credential(ctx, @digest)

      {:ok, %{credential: live}} =
        TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      {:ok, %{credential: validation}} =
        TinctureAuth.mint_validation_credential(ctx, @tincture, @digest, 1, frame_id())

      for credential <- [asset, live, validation] do
        assert Prima.CredentialShape.match?(:signed_token, credential)

        [_header, payload, _signature] = String.split(credential, ".")
        assert byte_size(payload) <= Prima.CredentialShape.signed_token_payload_max()

        assert Prima.Sanitizer.sanitize(%{"path" => "/_s/#{credential}/index.html"}) ==
                 %{"path" => "/_s/[REDACTED]/index.html"}
      end
    end
  end

  defp framed_context(frame) do
    Context.build(
      user_id: "usr_framed",
      athanor_id: "ath_acme",
      scope: :athanor,
      auth_method: :tincture,
      authenticated: true,
      frame: frame
    )
  end
end
