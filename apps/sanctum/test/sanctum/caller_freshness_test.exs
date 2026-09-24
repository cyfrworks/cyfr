# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CallerFreshnessTest do
  @moduledoc """
  A retained context is revalidated from the store, never from the memo:
  `Sanctum.Caller.revalidate_session/1` rereads the session, the person
  and the focused estate under lock, rebuilds the context from the stored
  session and refocuses it, and `fresh?/1` bounds how long a validated
  context may be acted on — from the validation, never from its reuse.

  Every revocation here is written straight to the rows, with no
  announcement and no memo drop: the missed-event case the bound exists
  for.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

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

    {:ok, estate} = Athanors.create_group(user.id, "Fresh #{n}")
    {:ok, _} = Members.ensure(user.id, scope: "athanor", athanor_id: estate.id)

    ctx =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: estate.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(ctx)
    {:ok, established} = Caller.establish(session.token, focus: estate.id)
    %{user: user, estate: estate, session: session, ctx: established}
  end

  # A second estate the same person is seated in.
  defp second_estate!(%{user: user}) do
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
        Sanctum.ApiKey.create(ctx, %{name: "fresh-key", type: :service})

      assert {:ok, %Context{validated_at: %DateTime{}}} = Caller.establish({:api_key, raw})
    end

    test "a memo hit answers the instant of the validation it memoized, not of its reuse" do
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 60_000)
      %{session: session, estate: estate} = person!()

      {:ok, first} = Caller.establish(session.token, focus: estate.id)
      Process.sleep(20)
      {:ok, again} = Caller.establish(session.token, focus: estate.id)

      assert again.validated_at == first.validated_at
    end
  end

  describe "revalidate_session/1" do
    test "a standing session is rebuilt from the store, focus and correlation kept" do
      %{ctx: ctx, estate: estate, user: user} = person!()
      held = %{ctx | request_id: "req_held", client_ip: "203.0.113.9"}
      Process.sleep(5)

      assert {:ok, %Context{} = fresh} = Caller.revalidate_session(held)
      assert fresh.user_id == user.id
      assert fresh.athanor_id == estate.id
      assert fresh.session_token_hash == ctx.session_token_hash
      assert %{source_kind: :session, focus_basis: basis} = fresh.credential_binding
      assert is_binary(basis)
      assert fresh.request_id == "req_held"
      assert fresh.client_ip == "203.0.113.9"
      assert DateTime.compare(fresh.validated_at, ctx.validated_at) == :gt
    end

    test "reads the rows, never the memo: a session deleted behind a warm memo refuses" do
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 60_000)
      %{session: session, estate: estate, ctx: ctx} = person!()
      {:ok, _} = Caller.establish(session.token, focus: estate.id)

      delete_session!(ctx.session_token_hash)

      # The memo still answers establish — the exposure the bound covers…
      assert {:ok, _} = Caller.establish(session.token, focus: estate.id)
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

    test "a lost seat refuses the focus and never falls back to another estate" do
      %{ctx: ctx, user: user, estate: estate} = fixture = person!()
      _other = second_estate!(fixture)

      drop_seat!(user.id, estate.id)

      assert {:error, :not_member} = Caller.revalidate_session(ctx)
    end

    test "an archived focus refuses the focus" do
      %{ctx: ctx, estate: estate} = person!()
      archive_row!(estate.id)
      assert {:error, :not_member} = Caller.revalidate_session(ctx)
    end

    test "a focus moved to another seat of the same person is revalidated there" do
      %{ctx: ctx} = fixture = person!()
      other = second_estate!(fixture)
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
        Sanctum.ApiKey.create(ctx, Map.merge(%{name: name, type: :service}, attrs))

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

    test "a denied creator and an archived estate no longer stand" do
      %{key_ctx: key_ctx, user: user} = key!()

      Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^user.id),
        set: [status: "denied"]
      )

      assert {:error, :not_standing} = Caller.revalidate_session(key_ctx)

      %{key_ctx: key_ctx, estate: estate} = key!()
      archive_row!(estate.id)
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
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 300)
      %{session: session, estate: estate} = person!()

      {:ok, ctx} = Caller.establish(session.token, focus: estate.id)
      assert Caller.fresh?(ctx)

      # Reused through the memo within the bound, as a busy socket would:
      # the same validation every time.
      for _ <- 1..3 do
        Process.sleep(60)
        {:ok, reused} = Caller.establish(session.token, focus: estate.id)
        assert reused.validated_at == ctx.validated_at
        assert Caller.fresh?(reused)
      end

      # Past the bound from the validation the held context is stale,
      # however recently it was reused — and the memo that served it has
      # run out with it, so the next establish reads the store again.
      Process.sleep(160)
      refute Caller.fresh?(ctx)

      {:ok, again} = Caller.establish(session.token, focus: estate.id)
      assert DateTime.compare(again.validated_at, ctx.validated_at) == :gt
      assert Caller.fresh?(again)

      assert {:ok, revalidated} = Caller.revalidate_session(ctx)
      assert Caller.fresh?(revalidated)
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

  test "the session's row key survives a round trip through the store unchanged" do
    %{ctx: ctx, session: session} = person!()
    assert ctx.session_token_hash == Session.token_hash(session.token)

    assert {:ok, %Context{session_token_hash: hash}} =
             Session.load_by_hash(ctx.session_token_hash, surface: :console)

    assert hash == ctx.session_token_hash
    assert {:error, :invalid_session} = Session.load_by_hash(<<0::256>>, surface: :console)
  end
end
