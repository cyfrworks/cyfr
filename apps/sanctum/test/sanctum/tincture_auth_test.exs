# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TinctureAuthTest do
  # async: false — API-key validation hits the shared Arca.Repo sandbox.
  use ExUnit.Case, async: false

  require Ecto.Query

  alias Sanctum.Context
  alias Sanctum.TinctureAuth

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp conn(query_string, remote_ip \\ {127, 0, 0, 1}) do
    %Plug.Conn{query_string: query_string, remote_ip: remote_ip}
  end

  defp bearer_conn(token, remote_ip \\ {127, 0, 0, 1}) do
    %Plug.Conn{
      query_string: "",
      remote_ip: remote_ip,
      req_headers: [{"authorization", "Bearer " <> token}]
    }
  end

  describe "authenticate/1 — no / invalid credentials" do
    test "blank query string → :unauthenticated" do
      assert TinctureAuth.authenticate(conn("")) == :unauthenticated
    end

    test "a presented non-session bearer is a named refusal, not silence" do
      assert TinctureAuth.authenticate(bearer_conn("not-a-cyfr-key")) ==
               {:error, :invalid_credential}
    end

    test "an unknown session bearer is refused by name" do
      assert TinctureAuth.authenticate(bearer_conn("sess_does_not_exist")) ==
               {:error, :invalid_credential}
    end

    test "malformed remote_ip does not crash (client_ip rescue → nil)" do
      # cyfr-prefixed but invalid key; the point is client_ip/1's rescue path
      # is exercised without raising.
      assert TinctureAuth.authenticate(bearer_conn("cyfr_pk_bogus", nil)) ==
               {:error, :invalid_credential}
    end
  end

  describe "authenticate/1 — credentials are never accepted from a query string" do
    test "a valid API key in ?_key= does not authenticate", %{ctx: ctx} do
      ctx = Sanctum.TestContext.issuer!(ctx)
      {:ok, %{api_key: key}} = Sanctum.ApiKey.create(ctx, %{name: "query-key"})

      # Valid credential, wrong channel. A URL reaches browser history, Referer
      # and proxy logs, so only the scoped ?_t= token may travel there.
      assert TinctureAuth.authenticate(conn("_key=#{key}")) == :unauthenticated
      assert {:ok, %Context{}} = TinctureAuth.authenticate(bearer_conn(key))
    end

    test "a session id in ?_session= does not authenticate", %{ctx: ctx} do
      {:ok, session} = Sanctum.Session.create(Sanctum.TestContext.issuer!(ctx))

      assert TinctureAuth.authenticate(conn("_session=#{session.token}")) == :unauthenticated
    end
  end

  # Session tokens authenticate through the Authorization header.
  describe "authenticate/1 — session-token path" do
    test "a bearer session token authenticates, carrying the recorded namespace",
         %{ctx: ctx} do
      # `Session.load` reads the namespace from the users row.
      {ctx, user} = Sanctum.TestContext.person!(ctx, %{email: "testns@example.com"})
      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(user, ctx.namespace)

      # A restored session is re-validated against current memberships; the
      # test user must actually be a member of the athanor it works in.
      Sanctum.TestContext.athanor!()

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "athanor", athanor_id: ctx.athanor_id)

      {:ok, session} =
        Sanctum.Session.create(ctx, generation_snapshot: Sanctum.TestContext.snapshot!(ctx))

      assert {:ok, %Context{} = out} = TinctureAuth.authenticate(bearer_conn(session.token))

      # Tincture access always runs athanor-scoped, whatever the operator's
      # console happened to be doing.
      assert out.auth_method == :session
      assert out.scope == :athanor
      assert out.authenticated
    end

    # The establish memo bounds establishing, not validating: what it answers
    # is revalidated against the stored session before this surface admits it.
    test "a session revoked behind a warm memo is refused", %{ctx: ctx} do
      original = Application.fetch_env(:sanctum, :caller_memo_ttl_ms)
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 60_000)

      on_exit(fn ->
        Arca.Cache.delete_match({:established, :_, :_, :_})

        case original do
          {:ok, value} -> Application.put_env(:sanctum, :caller_memo_ttl_ms, value)
          :error -> Application.delete_env(:sanctum, :caller_memo_ttl_ms)
        end
      end)

      ctx = Sanctum.TestContext.issuer!(ctx)

      {:ok, session} =
        Sanctum.Session.create(ctx, generation_snapshot: Sanctum.TestContext.snapshot!(ctx))

      assert {:ok, %Context{}} = TinctureAuth.authenticate(bearer_conn(session.token))

      hash = Sanctum.Session.token_hash(session.token)

      Arca.Repo.delete_all(
        Ecto.Query.from(s in Arca.Schemas.Session, where: s.token_hash == ^hash)
      )

      assert {:error, :invalid_credential} = TinctureAuth.authenticate(bearer_conn(session.token))
    end

    # A publisher namespace is not identity: a person without one goes
    # through the same establish as anyone, on the athanor their membership
    # grants.
    test "a person without a namespace authenticates like anyone else, athanor-scoped", %{
      ctx: ctx
    } do
      {ctx, _user} = Sanctum.TestContext.person!(ctx)

      {:ok, athanor} =
        Sanctum.Tenancy.Athanors.create_group(
          ctx.user_id,
          "Tincture #{System.unique_integer([:positive])}"
        )

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "athanor", athanor_id: athanor.id)

      session_ctx = %{ctx | namespace: nil, athanor_id: athanor.id}

      {:ok, session} =
        Sanctum.Session.create(session_ctx,
          generation_snapshot: Sanctum.TestContext.snapshot!(session_ctx)
        )

      assert {:ok, %Context{} = out} = TinctureAuth.authenticate(bearer_conn(session.token))
      assert out.scope == :athanor
      assert out.authenticated
      assert out.namespace == nil
      assert out.athanor_id == athanor.id
    end
  end

  describe "authenticate/1 — API key path" do
    test "a bearer API key yields an :api_key context", %{ctx: ctx} do
      ctx = Sanctum.TestContext.issuer!(ctx)
      {:ok, %{api_key: key}} = Sanctum.ApiKey.create(ctx, %{name: "tincture-key"})

      assert {:ok, %Context{} = out} = TinctureAuth.authenticate(bearer_conn(key))
      assert out.auth_method == :api_key
      assert out.authenticated == true
    end
  end

  describe "authenticate/1 — tenant gate" do
    test "a session that resolves to no athanor is refused by name" do
      # A signed-in user with no membership carries no athanor. The tincture
      # surface still stamps scope :athanor / authenticated, but the tenant
      # gate refuses a context that names no athanor (the tincture HTTP
      # isolation guarantee) — and says so.
      {unresolved, _user} =
        Context.build(
          user_id: "github|https://github.com|nowhere-#{System.unique_integer([:positive])}",
          email: "nowhere@example.com",
          provider: "github",
          athanor_id: nil,
          permissions: [:execute],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )
        |> Sanctum.TestContext.person!()

      {:ok, session} =
        Sanctum.Session.create(unresolved,
          generation_snapshot: Sanctum.TestContext.snapshot!(unresolved)
        )

      assert TinctureAuth.authenticate(bearer_conn(session.token)) ==
               {:error, :no_athanor}
    end
  end

  describe "authenticate/1 — a denied person's surviving session" do
    test "is refused, not re-upgraded", %{ctx: ctx} do
      {ctx, user} = Sanctum.TestContext.person!(ctx, %{email: "denied-tincture@example.com"})
      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(user, ctx.namespace)
      Sanctum.TestContext.athanor!()

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "athanor", athanor_id: ctx.athanor_id)

      {:ok, session} =
        Sanctum.Session.create(ctx, generation_snapshot: Sanctum.TestContext.snapshot!(ctx))

      assert {:ok, %Context{}} = TinctureAuth.authenticate(bearer_conn(session.token))

      # Mark the row denied WITHOUT `Users.deny/1`'s session revocation —
      # the race window between an operator's deny and its reconcile. The
      # old blanket upgrade re-authenticated exactly this session.
      {:ok, _} =
        Arca.Schemas.User
        |> Arca.Repo.get!(user.id)
        |> Ecto.Changeset.change(status: "denied")
        |> Arca.Repo.update()

      Sanctum.Caller.invalidate_hash(Sanctum.Session.token_hash(session.token))

      assert TinctureAuth.authenticate(bearer_conn(session.token)) == {:error, :denied}
    end
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

      assert {:ok, opened} = TinctureAuth.verify_asset_credential(credential, client_ip: "127.0.0.1")
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
      assert {:error, :invalid_credential} = TinctureAuth.verify_asset_credential(credential <> "x")

      {:ok, access} = TinctureAuth.issue_access_token(ctx, "acme", "dash")
      assert {:error, :invalid_credential} = TinctureAuth.verify_asset_credential(access)

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

      assert {:ok, authority} = TinctureAuth.verify_frame_credential(bearer, client_ip: "127.0.0.1")

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
      {:ok, %{id: id}} = TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())

      {:ok, other} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: "github|https://github.com|frame-other",
          provider: "github",
          email: "frame-other@example.com",
          verified: true
        })

      {:ok, _} = Sanctum.Tenancy.Members.ensure(other.id, scope: "athanor", athanor_id: "ath_acme")
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
      {:ok, %{credential: first}} = TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())
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
      {:ok, %{credential: bearer}} = TinctureAuth.mint_frame_credential(ctx, @tincture, @digest, 1, frame_id())
      assert {:error, :invalid_credential} = TinctureAuth.verify_frame_credential(bearer <> "x")

      {:ok, %{credential: asset}} = TinctureAuth.mint_asset_credential(ctx, @digest)
      assert {:error, :invalid_credential} = TinctureAuth.verify_frame_credential(asset)

      {:ok, access} = TinctureAuth.issue_access_token(ctx, "acme", "dash")
      assert {:error, :invalid_credential} = TinctureAuth.verify_frame_credential(access)
    end
  end
end
