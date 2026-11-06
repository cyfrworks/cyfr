# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SessionTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Session

  setup tags do
    # Use Arca.Repo sandbox for test isolation
    Cyfr.Test.Sandbox.setup!(tags)

    # A session is issued only to a person this server knows, against the
    # standing their row was read at.
    ctx =
      Context.build(
        user_id: "github|https://github.com|session-#{System.unique_integer([:positive])}",
        email: "test@example.com",
        provider: "github",
        permissions: [:execute, :read]
      )
      |> Sanctum.TestContext.issuer!()

    {:ok, ctx: ctx}
  end

  describe "create/1" do
    test "creates session with valid token", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)

      assert session.token != nil
      assert byte_size(session.token) > 30
      assert session.user_id == ctx.user_id
      assert session.email == "test@example.com"
      assert session.provider == "github"
    end

    test "sets expiration in the future", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)

      {:ok, expires_at, _} = DateTime.from_iso8601(session.expires_at)
      now = DateTime.utc_now()

      assert DateTime.compare(expires_at, now) == :gt

      # Default idle timeout is 30 days (720h)
      diff = DateTime.diff(expires_at, now, :hour)
      assert diff >= 719 and diff <= 720
    end

    test "takes the session_ttl_hours setting, with no restart", %{ctx: ctx} do
      Cyfr.Test.Settings.put("session_ttl_hours", 1)

      {:ok, session} = Session.create(ctx)
      {:ok, expires_at, _} = DateTime.from_iso8601(session.expires_at)
      diff = DateTime.diff(expires_at, DateTime.utc_now(), :hour)
      assert diff in [0, 1]
    end

    test "each session has unique token", %{ctx: ctx} do
      {:ok, session1} = Session.create(ctx)
      {:ok, session2} = Session.create(ctx)

      assert session1.token != session2.token
    end

    test "carries no permission bag: a person's session holds every permission", %{ctx: ctx} do
      {:ok, session} = Session.create(%{ctx | permissions: MapSet.new([:read])})
      refute Map.has_key?(session, :permissions)

      assert {:ok, %{permissions: permissions}} = Session.load(session.token)
      assert MapSet.equal?(permissions, MapSet.new(Sanctum.Context.person_permissions()))
      refute MapSet.member?(permissions, :*)
    end
  end

  describe "load/1" do
    test "returns context for a valid session; a person with no publisher namespace is signed in",
         %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)
      {:ok, retrieved_ctx} = Session.load(session.token)

      assert retrieved_ctx.user_id == ctx.user_id
      assert retrieved_ctx.email == "test@example.com"
      assert retrieved_ctx.provider == "github"
      # The fixture person has no namespace: a publishing credential, not
      # identity, so the session is as authenticated as anyone's.
      assert retrieved_ctx.authenticated == true
      assert retrieved_ctx.namespace == nil
    end

    test "a session loads authenticated from the users row's namespace, and survives losing every push token" do
      n = System.unique_integer([:positive])
      user_id = "github|https://github.com|sess-#{n}"

      {:ok, row} =
        Sanctum.Test.People.linked(%{
          id: user_id,
          provider: "github",
          email: "sess#{n}@example.com",
          verified: true
        })

      {:ok, _} = Sanctum.Tenancy.Users.set_namespace(row, "sess#{n}")
      user_id = row.id

      ctx =
        Sanctum.Context.build(
          user_id: user_id,
          email: "sess#{n}@example.com",
          provider: "github",
          namespace: "sess#{n}",
          permissions: [:read]
        )

      {:ok, session} = Sanctum.TestContext.create_session(ctx)

      assert {:ok, %{authenticated: true, namespace: ns}} =
               Session.load(session.token)

      assert ns == "sess#{n}"

      # Push tokens are for pushing: none were ever stored, and storing then
      # deleting one changes nothing about who the person is.
      registry = Compendium.RegistryHost.canonical_host()

      person = Sanctum.Context.build(user_id: user_id, authenticated: true, auth_method: :oidc)

      :ok =
        Compendium.Registry.CredentialStore.put_push_token(
          person,
          registry,
          "sess#{n}",
          "t",
          "personal"
        )

      Sanctum.TestContext.drop_registry_credential!(person, registry, "sess#{n}")
      Sanctum.Namespace.invalidate(user_id)
      assert {:ok, %{authenticated: true}} = Session.load(session.token)
    end

    test "returns error for invalid token", %{ctx: _ctx} do
      assert {:error, :invalid_session} = Session.load("invalid_token")
    end

    test "a loaded session carries the interactive class", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)
      assert {:ok, %{auth_method: :oidc}} = Session.load(session.token)
    end

    test "returns error for expired session", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)

      # Manually expire the session by updating the DB directly
      token_hash = :crypto.hash(:sha256, session.token)
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      import Ecto.Query

      from(s in Arca.Schemas.Session, where: s.token_hash == ^token_hash)
      |> Arca.Repo.update_all(set: [expires_at: past])

      assert {:error, :invalid_session} = Session.load(session.token)
    end
  end

  describe "get/1" do
    test "returns full session for valid token", %{ctx: ctx} do
      {:ok, created} = Session.create(ctx)
      {:ok, retrieved} = Session.get(created.token)

      assert retrieved.token == created.token
      assert retrieved.user_id == created.user_id
      assert retrieved.created_at == created.created_at
    end
  end

  describe "refresh/1" do
    test "extends session expiration", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)
      {:ok, original_expires, _} = DateTime.from_iso8601(session.expires_at)

      # Wait a tiny bit to ensure different timestamp
      :timer.sleep(10)

      {:ok, refreshed} = Session.refresh(session.token)
      {:ok, new_expires, _} = DateTime.from_iso8601(refreshed.expires_at)

      # New expiration should be later than original
      assert DateTime.compare(new_expires, original_expires) in [:gt, :eq]
    end

    test "returns error for invalid token", %{ctx: _ctx} do
      assert {:error, :invalid_session} = Session.refresh("invalid_token")
    end
  end

  describe "refresh_if_stale/1" do
    test "no-ops for a freshly created session", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)
      {:ok, before, _} = DateTime.from_iso8601(session.expires_at)

      assert :ok = Session.refresh_if_stale(session.token)

      {:ok, after_, _} = DateTime.from_iso8601(elem(Session.get(session.token), 1).expires_at)
      assert DateTime.compare(after_, before) == :eq
    end

    test "extends a session that is due for refresh", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)

      # Move expires_at close to now so the session looks stale (last refreshed ~30d ago).
      import Ecto.Query
      token_hash = :crypto.hash(:sha256, session.token)
      soon = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)

      from(s in Arca.Schemas.Session, where: s.token_hash == ^token_hash)
      |> Arca.Repo.update_all(set: [expires_at: soon])

      assert :ok = Session.refresh_if_stale(session.token)

      {:ok, refreshed, _} = DateTime.from_iso8601(elem(Session.get(session.token), 1).expires_at)
      assert DateTime.diff(refreshed, DateTime.utc_now(), :hour) >= 719
    end

    test "is a no-op for invalid tokens", %{ctx: _ctx} do
      assert :ok = Session.refresh_if_stale("nope")
    end

    test "establishing slides a session only when it is due, on Sanctum's own pool" do
      import Ecto.Query
      # Focused on the person's own athanor, so the session establishes.
      {local, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local())
      own = Sanctum.Test.People.athanor!(user)
      {:ok, session} = Session.create(Sanctum.TestContext.issuer!(%{local | athanor_id: own.id}))
      token_hash = :crypto.hash(:sha256, session.token)
      expiry = fn -> elem(Session.get(session.token), 1).expires_at end
      refresh = {Task.Supervisor, :start_child, 2}

      # A fresh session is not due: the load says so and no refresh starts.
      assert {:ok, %Context{}, false} = Session.load_sliding(session.token)

      {_ok, calls} =
        traced([refresh], fn ->
          {:ok, _} = Sanctum.Caller.establish(session.token)
        end)

      refute started_refresh?(calls)

      # One that is due is slid by the establish that read it.
      soon = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)

      from(s in Arca.Schemas.Session, where: s.token_hash == ^token_hash)
      |> Arca.Repo.update_all(set: [expires_at: soon])

      assert {:ok, %Context{}, true} = Session.load_sliding(session.token)

      {_ok, calls} =
        traced([refresh], fn ->
          {:ok, _} = Sanctum.Caller.establish(session.token)
        end)

      assert started_refresh?(calls)

      Prima.Test.Wait.wait_until(fn ->
        {:ok, at, _} = DateTime.from_iso8601(expiry.())
        DateTime.diff(at, DateTime.utc_now(), :hour) >= 719
      end)
    end

    test "no-ops when TTL is infinite", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)
      Cyfr.Test.Settings.put("session_ttl_hours", 0)

      assert :ok = Session.refresh_if_stale(session.token)
    end
  end

  describe "destroy/1" do
    test "removes session", %{ctx: ctx} do
      {:ok, session} = Session.create(ctx)

      # Session should exist
      {:ok, _} = Session.load(session.token)

      # Destroy it
      assert :ok = Session.destroy(session.token)

      # Session should no longer exist
      assert {:error, :invalid_session} = Session.load(session.token)
    end

    test "destroying non-existent session succeeds", %{ctx: _ctx} do
      assert :ok = Session.destroy("nonexistent_token")
    end
  end

  describe "cleanup/0" do
    test "removes expired sessions", %{ctx: ctx} do
      # Create a valid session
      {:ok, valid_session} = Session.create(ctx)

      # Create and manually expire another session
      {:ok, expired_session} = Session.create(ctx)

      token_hash = :crypto.hash(:sha256, expired_session.token)
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      import Ecto.Query

      from(s in Arca.Schemas.Session, where: s.token_hash == ^token_hash)
      |> Arca.Repo.update_all(set: [expires_at: past])

      # Run cleanup
      {:ok, removed_count} = Session.cleanup()
      assert removed_count == 1

      # Valid session should still work
      {:ok, _} = Session.load(valid_session.token)

      # Expired session should be gone
      assert {:error, :invalid_session} = Session.load(expired_session.token)
    end
  end

  describe "a session a key of the account signed" do
    import Ecto.Query, only: [from: 2]

    alias Sanctum.Test.DirectoryServer

    setup %{ctx: ctx} do
      tls = DirectoryServer.tls()
      DirectoryServer.listen!()
      DirectoryServer.seam!(tls)

      on_exit(fn ->
        Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
      end)

      directory = DirectoryServer.start!(tls)
      account = DirectoryServer.account!(directory.dir, directory.url)
      :ok = DirectoryServer.account_person!(ctx.user_id, account)
      %{dir: directory.dir, account: account}
    end

    defp sessions(user_id),
      do: Arca.Repo.all(from(s in Arca.Schemas.Session, where: s.user_id == ^user_id))

    defp bound(%{token: token}) do
      {:ok, session} = Arca.SessionStorage.get_session(Session.token_hash(token))
      {session.kid, session.head}
    end

    test "names its key and the head it was verified under; a head moved since mints nothing",
         %{ctx: ctx, dir: dir, account: account} do
      kid = DirectoryServer.kid(hd(account.devices))
      verified = DirectoryServer.head(account)

      assert {:ok, session} = Session.create(ctx, kid: kid, head: verified)
      assert bound(session) == {kid, verified}

      # A key lands after the sign-in verified under `verified`, and a
      # refresh here reads it: a session under the old head is refused.
      moved = DirectoryServer.add_device!(dir, account)
      assert {:ok, %{head_hash: current}} = Sanctum.IdentityFreshness.fresh!(account.identifier)
      assert current == DirectoryServer.head(moved)

      before = sessions(ctx.user_id)
      assert {:error, :stale_head} = Session.create(ctx, kid: kid, head: verified)
      assert sessions(ctx.user_id) == before

      # Verified again under the new head, it mints.
      assert {:ok, again} = Session.create(ctx, kid: kid, head: current)
      assert bound(again) == {kid, current}
    end

    test "names both or neither, and a person with no account has no head to name",
         %{ctx: ctx, account: account} do
      kid = DirectoryServer.kid(hd(account.devices))
      head = DirectoryServer.head(account)

      assert {:error, :invalid_request} = Session.create(ctx, kid: kid)
      assert {:error, :invalid_request} = Session.create(ctx, head: head)

      # A session no key signed, as the company sign-in mints one.
      assert {:ok, unsigned} = Session.create(ctx)
      assert bound(unsigned) == {nil, nil}

      local =
        Context.build(
          user_id: "github|https://github.com|local-#{System.unique_integer([:positive])}",
          email: "local@example.com",
          provider: "github",
          permissions: [:read]
        )
        |> Sanctum.TestContext.issuer!()

      assert {:error, :stale_head} = Session.create(local, kid: kid, head: head)
      assert sessions(local.user_id) == []
    end
  end

  describe "the reserved provider restore" do
    # A restore attempt of the person's, at `phase`: the row the restore's
    # mint leaves, written as it is for the session store to read.
    defp restore_attempt!(user_id, phase) do
      id = Prima.UUID7.generate_id("iat")
      now = DateTime.utc_now()

      {1, _} =
        Arca.Repo.insert_all(Arca.Schemas.IdentityAttempt, [
          %{
            id: id,
            kind: "restore",
            request_id: Prima.UUID7.generate_id("rst"),
            user_id: user_id,
            identifier: "per_" <> String.duplicate("c", 64),
            directory_url: "https://dir.example",
            phase: phase,
            entry: "recover-request",
            request_digest: Prima.Digest.sha256("recover-#{id}"),
            expected_revision: 0,
            token_digest: Prima.Digest.sha256("token-#{id}"),
            staged_live_public_key: :crypto.strong_rand_bytes(32),
            staged_operational_public_key: :crypto.strong_rand_bytes(32),
            revision: 1,
            inserted_at: now,
            updated_at: now
          }
        ])

      id
    end

    test "an ordinary session request cannot select it", %{ctx: ctx} do
      assert {:error, :reserved_provider} = Session.create(%{ctx | provider: "restore"})

      assert {:error, :reserved_provider} =
               Session.create(%{ctx | provider: "restore"}, restore: "iat_nothing")
    end

    test "it stands only on the restore attempt that minted this very person", %{ctx: ctx} do
      restore = %{ctx | provider: "restore"}

      other =
        Sanctum.TestContext.issuer!(
          Context.build(
            user_id: "github|https://github.com|other-#{System.unique_integer([:positive])}",
            provider: "github"
          )
        )

      assert {:error, :reserved_provider} =
               Session.create(restore, restore: restore_attempt!(other.user_id, "minted"))

      assert {:error, :reserved_provider} =
               Session.create(restore, restore: restore_attempt!(ctx.user_id, "accepted"))

      assert {:ok, %{provider: "restore"} = session} =
               Session.create(restore, restore: restore_attempt!(ctx.user_id, "minted"))

      assert {:ok, %{provider: "restore"}} =
               Session.create(restore, restore: restore_attempt!(ctx.user_id, "completed"))

      # The session's original creation time is what the first-method rule
      # reads; a refresh moves only its sliding expiry.
      {:ok, row} = Arca.SessionStorage.get_session(:crypto.hash(:sha256, session.token))
      {:ok, _} = Session.refresh(session.token)
      {:ok, again} = Arca.SessionStorage.get_session(:crypto.hash(:sha256, session.token))
      assert again.inserted_at == row.inserted_at
    end
  end

  # `fun`'s answer, and the calls this process made to `mfas` while it ran,
  # in order. A process's call trace is not delivered to itself, so a
  # collector takes it; every trace message is delivered before the
  # collector is asked for what it holds.
  defp traced(mfas, fun) do
    test = self()
    collector = spawn_link(fn -> collect(test, []) end)

    on_exit(fn -> for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:global]) end)

    # A pattern applies only to a loaded module, so each is loaded first,
    # and one that matched nothing fails here rather than tracing nothing.
    for {module, _function, _arity} = mfa <- mfas do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(mfa, true, [:global]) == 1
    end

    :erlang.trace(test, true, [:call, {:tracer, collector}])

    answer =
      try do
        fun.()
      after
        :erlang.trace(test, false, [:call])
      end

    delivered = :erlang.trace_delivered(test)
    assert_receive {:trace_delivered, ^test, ^delivered}, 5_000
    send(collector, {:done, delivered})
    assert_receive {:collected, ^delivered, calls}, 5_000
    {answer, calls}
  end

  defp collect(test, calls) do
    receive do
      {:trace, ^test, :call, call} -> collect(test, [call | calls])
      {:done, ref} -> send(test, {:collected, ref, Enum.reverse(calls)})
    end
  end

  defp started_refresh?(calls) do
    Enum.any?(calls, fn
      {Task.Supervisor, :start_child, [Sanctum.TaskSupervisor | _]} -> true
      _ -> false
    end)
  end
end
