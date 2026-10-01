# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CallerFreshnessTest do
  @moduledoc """
  A retained context is revalidated from the store, never from the memo:
  `Sanctum.Caller.revalidate_session/1` rereads the session, the person
  and the focused athanor under lock, rebuilds the context from the stored
  session and refocuses it, and `fresh?/1` bounds how long a validated
  context may be acted on — from the validation, never from its reuse.

  Every revocation here is written straight to the rows, with no
  announcement and no memo drop: the missed-event case the bound exists
  for.

  A remote person's session stands, at establish and at revalidation, only
  on their identity's fresh head and only while bound to its `key_epoch`:
  past the bound with the directory unreachable the work pauses as
  `identity_stale` and the session stays, and a session bound to another
  epoch, or to none, is revoked there and then.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Sanctum.{Caller, Context, Session}
  alias Sanctum.Tenancy.{Athanors, Members, Users}

  @keys [:caller_memo_ttl_ms]

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    prev = Map.new(@keys, &{&1, Application.get_env(:sanctum, &1)})

    on_exit(fn ->
      Arca.Cache.delete_match({:established, :_, :_, :_})

      for {key, value} <- prev do
        if is_nil(value),
          do: Application.delete_env(:sanctum, key),
          else: Application.put_env(:sanctum, key, value)
      end
    end)

    :ok
  end

  # A person seated in a group of their own and a session focused on it.
  defp person! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|fresh-#{n}",
        provider: "github",
        email: "fresh#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Fresh #{n}")
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: athanor.id)

    ctx =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(ctx)
    {:ok, established} = Caller.establish(session.token, focus: athanor.id)
    %{user: user, athanor: athanor, session: session, ctx: established}
  end

  # A second athanor the same person is seated in.
  defp second_athanor!(%{user: user}) do
    {:ok, other} = Athanors.create_group(user.id, "Other #{System.unique_integer([:positive])}")
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: other.id)
    other
  end

  defp delete_session!(hash),
    do: Arca.Repo.delete_all(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash))

  defp expire_session!(hash) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    Arca.Repo.update_all(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash),
      set: [expires_at: past]
    )
  end

  defp deny_row!(user_id),
    do:
      Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^user_id),
        set: [status: "denied"]
      )

  defp drop_seat!(user_id, athanor_id) do
    Arca.Repo.delete_all(
      from(m in Arca.Schemas.Membership,
        where: m.user_id == ^user_id and m.athanor_id == ^athanor_id
      )
    )
  end

  # The wall clock `fresh?/1` reads is a whole millisecond past `instant`,
  # the unit its bound is counted in.
  defp clock_past!(instant),
    do: poll!(fn -> DateTime.diff(DateTime.utc_now(), instant, :millisecond) >= 1 end)

  # `check`'s first truthy answer, polled every millisecond for at most
  # five seconds.
  defp poll!(check, attempts \\ 5_000) do
    cond do
      result = check.() -> result
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(1) && poll!(check, attempts - 1)
    end
  end

  defp archive_row!(athanor_id),
    do:
      Arca.Repo.update_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor_id),
        set: [status: "archived"]
      )

  describe "establish/2 stamps validated_at" do
    test "a session and a key are each validated when established" do
      %{ctx: ctx} = person!()
      assert %DateTime{} = ctx.validated_at

      {:ok, %{api_key: raw}} =
        Sanctum.TestContext.create_key(ctx, %{name: "fresh-key", type: :service})

      assert {:ok, %Context{validated_at: %DateTime{}}} = Caller.establish({:api_key, raw})
    end

    test "a memo hit answers the instant of the validation it memoized, not of its reuse" do
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 60_000)
      %{session: session, athanor: athanor} = person!()

      {:ok, first} = Caller.establish(session.token, focus: athanor.id)
      Process.sleep(20)
      {:ok, again} = Caller.establish(session.token, focus: athanor.id)

      assert again.validated_at == first.validated_at
    end
  end

  describe "revalidate_session/1" do
    test "a standing session is rebuilt from the store, focus and correlation kept" do
      %{ctx: ctx, athanor: athanor, user: user} = person!()
      held = %{ctx | request_id: "req_held", client_ip: "203.0.113.9"}
      Process.sleep(5)

      assert {:ok, %Context{} = fresh} = Caller.revalidate_session(held)
      assert fresh.user_id == user.id
      assert fresh.athanor_id == athanor.id
      assert fresh.session_token_hash == ctx.session_token_hash
      assert %{source_kind: :session, focus_basis: basis} = fresh.credential_binding
      assert is_binary(basis)
      assert fresh.request_id == "req_held"
      assert fresh.client_ip == "203.0.113.9"
      assert DateTime.compare(fresh.validated_at, ctx.validated_at) == :gt
    end

    test "reads the rows, never the memo: a session deleted behind a warm memo refuses" do
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 60_000)
      %{session: session, athanor: athanor, ctx: ctx} = person!()
      {:ok, _} = Caller.establish(session.token, focus: athanor.id)

      delete_session!(ctx.session_token_hash)

      # The memo still answers establish — the exposure the bound covers…
      assert {:ok, _} = Caller.establish(session.token, focus: athanor.id)
      # …and revalidation, which reads the rows, refuses.
      assert {:error, :unauthenticated} = Caller.revalidate_session(ctx)
    end

    test "an expired session refuses" do
      %{ctx: ctx} = person!()
      expire_session!(ctx.session_token_hash)
      assert {:error, :unauthenticated} = Caller.revalidate_session(ctx)
    end

    test "a denied person refuses as not standing" do
      %{ctx: ctx, user: user} = person!()
      deny_row!(user.id)
      assert {:error, :not_standing} = Caller.revalidate_session(ctx)
    end

    test "a lost seat refuses the focus and never falls back to another athanor" do
      %{ctx: ctx, user: user, athanor: athanor} = fixture = person!()
      _other = second_athanor!(fixture)

      drop_seat!(user.id, athanor.id)

      assert {:error, :not_member} = Caller.revalidate_session(ctx)
    end

    test "an archived focus refuses the focus" do
      %{ctx: ctx, athanor: athanor} = person!()
      archive_row!(athanor.id)
      assert {:error, :not_member} = Caller.revalidate_session(ctx)
    end

    test "a focus moved to another seat of the same person is revalidated there" do
      %{ctx: ctx} = fixture = person!()
      other = second_athanor!(fixture)
      {:ok, moved} = Context.focus(ctx, other.id)

      assert {:ok, %Context{athanor_id: athanor_id}} = Caller.revalidate_session(moved)
      assert athanor_id == other.id
    end

    test "a session row key that names another person's session refuses" do
      %{ctx: mine} = person!()
      %{ctx: theirs} = person!()

      forged = %{
        mine
        | session_token_hash: theirs.session_token_hash,
          credential_binding: %{
            mine.credential_binding
            | source_id: Base.url_encode64(theirs.session_token_hash, padding: false)
          }
      }

      assert {:error, :unauthenticated} = Caller.revalidate_session(forged)
    end

    test "a session binding without its row key refuses rather than passing as another kind" do
      %{ctx: ctx} = person!()

      assert {:error, :unauthenticated} =
               Caller.revalidate_session(%{ctx | session_token_hash: nil})
    end

    test "a row key the binding does not name refuses" do
      %{ctx: ctx} = person!()
      %{ctx: other} = person!()

      assert {:error, :unauthenticated} =
               Caller.revalidate_session(%{ctx | session_token_hash: other.session_token_hash})
    end

    test "a store that cannot answer is unavailable, never a verdict" do
      %{ctx: ctx} = person!()
      Arca.Repo.query!("ALTER TABLE sessions RENAME TO sessions_unavailable")
      assert {:error, :unavailable} = Caller.revalidate_session(ctx)
    end

    test "a guest-planed context stays guest-planed and gains no permission" do
      %{ctx: ctx} = person!()
      narrowed = Context.enter_guest(%{ctx | permissions: MapSet.new([:execute])})

      assert {:ok, fresh} = Caller.revalidate_session(narrowed)
      assert fresh.plane == :guest
      assert fresh.permissions == MapSet.new([:execute])
    end

    test "other contexts keep their establishment contract and come back unchanged" do
      %{ctx: ctx} = person!()

      identity = %{
        ctx
        | session_token_hash: nil,
          credential_binding: %{ctx.credential_binding | source_kind: :identity, source_id: nil}
      }

      tincture = %{ctx | auth_method: :tincture, session_token_hash: nil}
      system = Sanctum.Context.internal()

      for other <- [identity, tincture, system] do
        assert {:ok, ^other} = Caller.revalidate_session(other)
      end
    end
  end

  describe "revalidate_session/1 — an API key's context" do
    defp key!(attrs \\ %{}) do
      %{ctx: ctx} = fixture = person!()
      name = "key-#{System.unique_integer([:positive])}"

      {:ok, %{api_key: raw}} =
        Sanctum.TestContext.create_key(ctx, Map.merge(%{name: name, type: :service}, attrs))

      {:ok, key_ctx} = Caller.establish({:api_key, raw}, client_ip: "127.0.0.1")
      Map.merge(fixture, %{key_ctx: %{key_ctx | client_ip: "127.0.0.1"}, key_name: name})
    end

    test "a standing key is reread and comes back with a new validation" do
      %{key_ctx: key_ctx} = key!()
      Process.sleep(5)

      assert {:ok, %Context{} = fresh} = Caller.revalidate_session(key_ctx)
      assert fresh.api_key_id == key_ctx.api_key_id
      assert fresh.athanor_id == key_ctx.athanor_id
      assert DateTime.compare(fresh.validated_at, key_ctx.validated_at) == :gt
    end

    test "a revoked key refuses" do
      %{ctx: ctx, key_ctx: key_ctx, key_name: name} = key!()
      :ok = Sanctum.ApiKey.revoke(ctx, name)
      assert {:error, :unauthenticated} = Caller.revalidate_session(key_ctx)
    end

    test "a denied creator and an archived athanor no longer stand" do
      %{key_ctx: key_ctx, user: user} = key!()

      Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^user.id),
        set: [status: "denied"]
      )

      assert {:error, :not_standing} = Caller.revalidate_session(key_ctx)

      %{key_ctx: key_ctx, athanor: athanor} = key!()
      archive_row!(athanor.id)
      assert {:error, :not_standing} = Caller.revalidate_session(key_ctx)
    end

    test "an allowlist that no longer admits the caller's address refuses" do
      %{key_ctx: key_ctx} = key!(%{ip_allowlist: ["127.0.0.1"]})
      assert {:ok, _} = Caller.revalidate_session(key_ctx)

      assert {:error, :unauthenticated} =
               Caller.revalidate_session(%{key_ctx | client_ip: "203.0.113.7"})

      assert {:error, :unauthenticated} = Caller.revalidate_session(%{key_ctx | client_ip: nil})
    end

    test "a key context naming another key's row refuses" do
      %{key_ctx: mine} = key!()
      %{key_ctx: theirs} = key!()

      assert {:error, :unauthenticated} =
               Caller.revalidate_session(%{mine | api_key_id: theirs.api_key_id})
    end

    test "a store that cannot answer is unavailable" do
      %{key_ctx: key_ctx} = key!()
      Arca.Repo.query!("ALTER TABLE api_keys RENAME TO api_keys_unavailable")
      assert {:error, :unavailable} = Caller.revalidate_session(key_ctx)
    end
  end

  describe "fresh?/1" do
    test "the bound runs from the validation; reusing the context never extends it" do
      # A bound no run outlasts, so every reuse below is inside it.
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 60_000)
      %{session: session, athanor: athanor} = person!()

      {:ok, ctx} = Caller.establish(session.token, focus: athanor.id)
      assert Caller.fresh?(ctx)

      # Reused through the memo after the validation, as a busy socket
      # would: the same validation every time.
      clock_past!(ctx.validated_at)

      reused =
        for _ <- 1..3 do
          {:ok, reused} = Caller.establish(session.token, focus: athanor.id)
          assert reused.validated_at == ctx.validated_at
          assert Caller.fresh?(reused)
          reused
        end

      # A bound as long as the time since the validation has run out for
      # the held context, however recently it was reused: every reuse came
      # after the validation, so less than that length before now.
      elapsed = DateTime.diff(DateTime.utc_now(), ctx.validated_at, :millisecond)
      Application.put_env(:sanctum, :caller_memo_ttl_ms, elapsed)
      refute Caller.fresh?(ctx)
      for held <- reused, do: refute(Caller.fresh?(held))

      # Revalidation reads the store, and its bound runs from then.
      assert {:ok, revalidated} = Caller.revalidate_session(ctx)
      assert DateTime.compare(revalidated.validated_at, ctx.validated_at) == :gt
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 60_000)
      assert Caller.fresh?(revalidated)
    end

    test "the memo never outlives the bound: past it, the establish reads the store again" do
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 100)
      # Established, and memoized, under the bound.
      %{session: session, athanor: athanor, ctx: ctx} = person!()

      # Once the context the memo holds is past the bound, the memo has run
      # out with it: the establish after that reads the store and answers a
      # new validation, however soon it follows.
      poll!(fn -> not Caller.fresh?(ctx) end)
      {:ok, again} = Caller.establish(session.token, focus: athanor.id)

      assert DateTime.compare(again.validated_at, ctx.validated_at) == :gt
    end

    test "within the bound, a memo answers the validation it holds" do
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 60_000)
      %{session: session, athanor: athanor, ctx: ctx} = person!()

      for _ <- 1..3 do
        {:ok, again} = Caller.establish(session.token, focus: athanor.id)
        assert again.validated_at == ctx.validated_at
        assert Caller.fresh?(again)
      end
    end

    test "a zero bound makes every context stale, and an unvalidated one is never fresh" do
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 0)
      %{ctx: ctx} = person!()
      refute Caller.fresh?(ctx)
      refute Caller.fresh?(%{ctx | validated_at: nil})
    end

    test "a validation in the future is never fresh, whatever the bound" do
      %{ctx: ctx} = person!()
      ahead = %{ctx | validated_at: DateTime.add(DateTime.utc_now(), 1, :second)}

      # The two-second default, which a naive `elapsed < ttl` would admit.
      Application.delete_env(:sanctum, :caller_memo_ttl_ms)
      refute Caller.fresh?(ahead)
      assert Caller.fresh?(%{ctx | validated_at: DateTime.utc_now()})

      Application.put_env(:sanctum, :caller_memo_ttl_ms, 0)
      refute Caller.fresh?(ahead)
    end
  end

  # ---- a remote person's session ------------------------------------------------

  # A directory this home cannot reach: an operator-listed loopback port
  # nothing listens on, or a loopback address the operator never listed.
  @unreachable "https://localhost:1"

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  # A person whose keys are at another home, admitted here: their identity
  # row is `remote`, their head cached as verified now, and a session row
  # bound to `epoch` (`:head` for the cached head's) as a door at this
  # home mints one, with a whole idle window ahead of it.
  defp remote!(epoch \\ :head) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|remote-#{n}",
        provider: "github",
        email: "remote#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Remote #{n}")
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: athanor.id)
    Arca.Repo.delete_all(from(p in Arca.Schemas.PersonIdentity, where: p.user_id == ^user.id))

    {live, _} = keypair()
    {operational_pub, operational} = keypair()
    {recovery, _} = keypair()

    {:ok, genesis} =
      Prima.Identity.Entry.genesis(
        live_key: live,
        operational_key: operational_pub,
        recovery_keys: [recovery],
        directory: @unreachable
      )

    genesis = Prima.Identity.sign(genesis, operational)
    identifier = Prima.Identity.identifier(genesis)
    head = Prima.Identity.hash(genesis)

    {:ok, _} =
      Arca.PersonIdentities.create(Prima.Actor.system(), %{
        user_id: user.id,
        provenance: "remote",
        identifier: identifier,
        directory_url: @unreachable
      })

    {:ok, _} =
      Arca.DirectoryHeads.put(Prima.Actor.system(), %{
        identifier: identifier,
        genesis: Prima.Identity.canonical(genesis),
        directory_url: @unreachable,
        head_hash: head,
        key_epoch: head,
        recovery_epoch: head,
        state: ~s({"head":"#{head}"})
      })

    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = DateTime.utc_now()

    Arca.Repo.insert_all(Arca.Schemas.Session, [
      %{
        id: Prima.UUID7.generate_id("ses"),
        token_hash: Session.token_hash(token),
        token_prefix: String.slice(token, 0, 8),
        user_id: user.id,
        provider: "cyfr",
        athanor_id: athanor.id,
        identity_key_epoch: if(epoch == :head, do: head, else: epoch),
        expires_at: DateTime.add(now, 30 * 86_400, :second),
        inserted_at: now
      }
    ])

    %{user: user, athanor: athanor, identifier: identifier, epoch: head, token: token}
  end

  defp establish(%{token: token, athanor: athanor}),
    do: Caller.establish(token, focus: athanor.id, task_supervisor: nil)

  defp session_row(%{token: token}),
    do: Arca.Repo.get_by(Arca.Schemas.Session, token_hash: Session.token_hash(token))

  defp cached_at(identifier),
    do: Arca.Repo.get!(Arca.Schemas.DirectoryHead, identifier).verified_at

  defp verified!(identifier, at) do
    {1, _} =
      Arca.Repo.update_all(
        from(h in Arca.Schemas.DirectoryHead, where: h.identifier == ^identifier),
        set: [verified_at: at]
      )

    :ok
  end

  describe "a remote person's session" do
    test "stands on a fresh head bound to its key_epoch, and reads no directory within the bound" do
      remote = remote!()
      verified_at = cached_at(remote.identifier)

      assert {:ok, %Context{} = ctx} = establish(remote)
      assert {:ok, %Context{}} = Caller.revalidate_session(ctx)

      # Answered from the cache: its verification never moved.
      assert cached_at(remote.identifier) == verified_at
    end

    test "past the bound with its directory unreachable, the work pauses and the session stands" do
      remote = remote!()
      {:ok, held} = establish(remote)
      verified!(remote.identifier, DateTime.add(DateTime.utc_now(), -301, :second))

      log =
        capture_log(fn ->
          assert {:error, :identity_stale} = establish(remote)
          assert {:error, :identity_stale} = Caller.revalidate_session(held)
        end)

      assert log =~ "300-second freshness bound"

      # A pause, not a sign-out: the session is untouched, and stands again
      # once the head is fresh.
      assert session_row(remote)
      verified!(remote.identifier, DateTime.utc_now())
      assert {:ok, %Context{}} = establish(remote)
      assert {:ok, %Context{}} = Caller.revalidate_session(held)
    end

    test "one bound to no key_epoch is refused and revoked, never exempted" do
      remote = remote!(nil)

      capture_log(fn -> assert {:error, :unauthenticated} = establish(remote) end)
      refute session_row(remote)
    end

    test "one bound to an epoch the fresh head does not name is revoked there and then" do
      remote = remote!(Prima.Digest.sha256("an older head"))

      capture_log(fn -> assert {:error, :unauthenticated} = establish(remote) end)
      refute session_row(remote)

      # A held context whose session's epoch is retired behind it is refused
      # at its revalidation, and its session revoked.
      remote = remote!()
      {:ok, held} = establish(remote)

      Arca.Repo.update_all(
        from(s in Arca.Schemas.Session, where: s.token_hash == ^held.session_token_hash),
        set: [identity_key_epoch: Prima.Digest.sha256("retired")]
      )

      capture_log(fn ->
        assert {:error, :unauthenticated} = Caller.revalidate_session(held)
      end)

      refute session_row(remote)
    end

    test "a local person's session reads no directory, whatever the cache holds" do
      %{ctx: ctx, session: session, athanor: athanor} = person!()

      assert {:ok, _} = Caller.revalidate_session(ctx)
      assert {:ok, _} = Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)
      assert Arca.Repo.all(Arca.Schemas.DirectoryHead) == []
    end
  end

  # ---- a frame its session minted ------------------------------------------------

  @tincture %{publisher: "acme", name: "dash", version: "1.0.0"}
  @digest "sha256:" <> String.duplicate("c", 64)

  # The frame credential's two settings, installed beside whatever the run
  # installed and restored after.
  defp frame_settings! do
    previous = Arca.PlatformSettings.installed()

    on_exit(fn ->
      if previous,
        do: Arca.PlatformSettings.install_defaults!(previous),
        else: Arca.PlatformSettings.uninstall()
    end)

    Arca.PlatformSettings.install_defaults!(
      Map.merge(previous || %{}, %{
        "asset_credential_window_s" => %{default: 3_600, stale: :serve},
        "frame_credential_deadline_s" => %{default: 900, stale: :serve}
      })
    )
  end

  # A frame credential minted under `remote`'s session, as the shell
  # mints one for a frame it opens.
  defp frame!(remote) do
    {:ok, ctx} = establish(remote)

    {:ok, %{credential: bearer}} =
      Sanctum.TinctureAuth.mint_frame_credential(
        %{ctx | client_ip: "127.0.0.1"},
        @tincture,
        @digest,
        1,
        "frm_#{System.unique_integer([:positive])}_remote"
      )

    bearer
  end

  defp use_frame(bearer),
    do: Caller.establish({:frame_credential, bearer}, client_ip: "127.0.0.1")

  describe "a frame credential a remote person's session minted" do
    setup do
      frame_settings!()
      :ok
    end

    test "pauses with the session while the identity cannot be confirmed fresh" do
      remote = remote!()
      bearer = frame!(remote)
      assert {:ok, %Context{frame: %{}}} = use_frame(bearer)

      verified!(remote.identifier, DateTime.add(DateTime.utc_now(), -301, :second))

      log =
        capture_log(fn ->
          assert {:error, :identity_stale} = use_frame(bearer)

          assert {:error, :identity_stale} =
                   Sanctum.TinctureAuth.verify_frame_credential(bearer, client_ip: "127.0.0.1")
        end)

      assert log =~ "freshness bound"

      # A pause, not a retirement: the session stands, and so does the frame
      # once the head is fresh again.
      assert session_row(remote)
      verified!(remote.identifier, DateTime.utc_now())
      assert {:ok, %Context{frame: %{}}} = use_frame(bearer)
    end

    test "a head that retired its session's key_epoch refuses it as the session is refused" do
      remote = remote!()
      bearer = frame!(remote)
      newer = Prima.Digest.sha256("a newer head")

      Arca.Repo.update_all(
        from(h in Arca.Schemas.DirectoryHead, where: h.identifier == ^remote.identifier),
        set: [head_hash: newer, key_epoch: newer]
      )

      capture_log(fn -> assert {:error, :unauthenticated} = use_frame(bearer) end)

      # Its session is revoked there and then, and refused the same way.
      refute session_row(remote)
      assert {:error, :unauthenticated} = establish(remote)
    end

    test "a local person's frame reads no directory" do
      %{ctx: ctx} = person!()

      {:ok, %{credential: bearer}} =
        Sanctum.TinctureAuth.mint_frame_credential(
          %{ctx | client_ip: "127.0.0.1"},
          @tincture,
          @digest,
          1,
          "frm_#{System.unique_integer([:positive])}_local"
        )

      assert {:ok, %Context{frame: %{}}} = use_frame(bearer)
      assert Arca.Repo.all(Arca.Schemas.DirectoryHead) == []
    end
  end

  test "the session's row key survives a round trip through the store unchanged" do
    %{ctx: ctx, session: session} = person!()
    assert ctx.session_token_hash == Session.token_hash(session.token)

    assert {:ok, %Context{session_token_hash: hash}} =
             Session.load_by_hash(ctx.session_token_hash, surface: :console)

    assert hash == ctx.session_token_hash
    assert {:error, :invalid_session} = Session.load_by_hash(<<0::256>>, surface: :console)
  end
end
