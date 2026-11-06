# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PasskeysTest do
  @moduledoc """
  The passkeys of a person's account that signed in here, against a
  scripted directory serving the account's log: a passkey's first
  sign-in records it as the person's paired client, in their own athanor,
  by its key and the head it was verified under, and every session it
  signs in stands on that client and slides with use. Listed by its key
  beside the person's devices, it holds no key to certify; revoked here,
  it is signed out of this CYFR alone, its next sign-in recording it
  anew. A declared restore suspends it, and a key removed from the
  account ends it at the next refresh.
  """

  # The directory seam, the setup token, the public URL and the directory
  # setting are process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{PairedClient, Session, User}
  alias Prima.Identity.Key
  alias Sanctum.{Context, Pairing, Passkeys, SignIn}
  alias Sanctum.Test.DirectoryServer

  @token String.duplicate("7a", 32)
  @origin "https://cyfr.example"
  @browser {:browser, "csrf-of-this-browser"}

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup %{tls: tls} = tags do
    Arca.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    dir = DirectoryServer.start!(tls)

    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Prima.Test.Env.put_app_env(:sanctum, :public_url, @origin)
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, dir.url)
    Prima.Test.Env.put_app_env(:sanctum, :access_mode, :public)

    # The installation holds no person inside this test's transaction: the
    # first person is setup's.
    Arca.Repo.delete_all(User)

    account = DirectoryServer.add_passkey!(dir.dir, DirectoryServer.account!(dir.dir, dir.url))
    {user, _token} = signed_in!(account, hd(account.passkeys), admission: {:setup, @token})
    %{dir: dir, account: account, user: user}
  end

  # A sign-in at this CYFR by the account's `passkey`: the person and the
  # session's token.
  defp signed_in!(account, passkey, opts \\ []) do
    {:ok, %{request: request}} = SignIn.request(:sign_in, @browser, opts)
    answer = DirectoryServer.passkey_answer(request, account, passkey)
    {:ok, %{user: user, session_token: token}} = SignIn.answer(answer, @browser)
    {user, token}
  end

  defp kid(passkey), do: Key.kid(passkey.pub)

  defp clients(user_id),
    do:
      Arca.Repo.all(
        from(p in PairedClient,
          where: p.user_id == ^user_id and p.source_kind == "passkey",
          order_by: [asc: p.inserted_at, asc: p.id]
        )
      )

  defp session_row(token),
    do: Arca.Repo.get_by!(Session, token_hash: Sanctum.Session.token_hash(token))

  defp sessions(user_id),
    do: Arca.Repo.all(from(s in Session, where: s.user_id == ^user_id, select: s.token_hash))

  # The person's own context, focused on their own athanor.
  defp ctx(user) do
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get_by_owner(user.id)

    Context.build(
      user_id: user.id,
      athanor_id: athanor.id,
      auth_method: :oidc,
      authenticated: true,
      permissions: Context.person_permissions()
    )
  end

  describe "a sign-in by a passkey" do
    test "records it once as the person's client, by its key and head, and its sessions stand on it",
         %{account: account, user: user} do
      passkey = hd(account.passkeys)
      [client] = clients(user.id)
      {:ok, athanor} = Sanctum.Tenancy.Athanors.get_by_owner(user.id)

      assert %{
               standing: "active",
               device_public_key: nil,
               holder_kind: nil,
               display_name: nil
             } = client

      assert {client.athanor_id, client.source_id, client.kid, client.head} ==
               {athanor.id, client.id, kid(passkey), DirectoryServer.head(account)}

      # Signed in again, by the same passkey: the same client, a new session on it.
      {_user, token} = signed_in!(account, passkey)
      assert [^client] = clients(user.id)
      assert session_row(token).client_id == client.id
      assert session_row(token).kid == kid(passkey)
    end

    test "of another passkey of the account records that one beside it", %{
      dir: dir,
      account: account,
      user: user
    } do
      account = DirectoryServer.add_passkey!(dir.dir, account)
      [first, second] = account.passkeys
      {_user, _token} = signed_in!(account, second)

      assert Enum.map(clients(user.id), & &1.kid) == [kid(first), kid(second)]

      assert {:ok, listed} = Passkeys.list(ctx(user))
      assert Enum.sort(Enum.map(listed, & &1.kid)) == Enum.sort([kid(first), kid(second)])
    end

    test "is listed with the person's devices, holding no certificate and reporting nothing",
         %{account: account, user: user} do
      [client] = clients(user.id)

      assert {:ok, [listed]} = Pairing.list(ctx(user))

      assert %{
               source: "passkey",
               certificate_expires_at: nil,
               holder_kind: nil,
               display_name: nil,
               storage: nil
             } = listed

      assert listed.client_id == client.id

      assert {:ok, [%{kid: kid, client_id: client_id}]} = Passkeys.list(ctx(user))
      assert {kid, client_id} == {kid(hd(account.passkeys)), client.id}
    end

    test "has no key to certify: no certificate is recorded for its client", %{
      account: account,
      user: user
    } do
      [client] = clients(user.id)
      # A certificate for a key the client never proved: it holds none.
      device_key = :crypto.strong_rand_bytes(32)

      assert {:error, :no_device_key} =
               Arca.DeviceCertificates.record(Prima.Actor.in_athanor(client.athanor_id), %{
                 paired_client_id: client.id,
                 user_id: user.id,
                 identifier: account.identifier,
                 kid: Key.kid(device_key),
                 head: client.head,
                 device_public_key: device_key,
                 issuing_home: @origin,
                 audience_home: @origin,
                 not_before: DateTime.utc_now(),
                 expires_at: DateTime.add(DateTime.utc_now(), 3600),
                 certificate: "{}",
                 digest: Prima.Digest.sha256("{}")
               })
    end

    test "mints a session that slides with use as any session does", %{account: account} do
      {_user, token} = signed_in!(account, hd(account.passkeys))
      row = session_row(token)

      assert {:ok, %Context{credential_deadline: nil}, _due} = Sanctum.Session.load_sliding(token)

      # Pushed back to just past its refresh point, it slides on use.
      soon = DateTime.add(DateTime.utc_now(), 60, :second)

      {1, _} =
        Arca.Repo.update_all(from(s in Session, where: s.id == ^row.id), set: [expires_at: soon])

      :ok = Sanctum.Session.refresh_if_stale(token)
      assert DateTime.compare(Arca.Repo.get!(Session, row.id).expires_at, soon) == :gt
    end
  end

  describe "revoking a passkey" do
    test "signs it out of this CYFR alone, and its next sign-in records it anew", %{
      dir: dir,
      account: account,
      user: user
    } do
      account = DirectoryServer.add_passkey!(dir.dir, account)
      [first, second] = account.passkeys
      {_user, ended} = signed_in!(account, first)
      {_user, kept} = signed_in!(account, second)
      [revoked, standing] = clients(user.id)
      ended_hashes = for s <- sessions(user.id), session_row_client(s) == revoked.id, do: s

      assert {:ok, %{kid: revoked_kid, sessions: count}} = Passkeys.revoke(ctx(user), kid(first))
      assert {revoked_kid, count} == {kid(first), length(ended_hashes)}

      assert Arca.Repo.get!(PairedClient, revoked.id).standing == "revoked"
      assert Arca.Repo.get!(PairedClient, standing.id).standing == "active"
      assert {:error, :invalid_session} = Sanctum.Session.load(ended)
      assert {:ok, %Context{}} = Sanctum.Session.load(kept)
      refute Enum.any?(ended_hashes, &(&1 in sessions(user.id)))

      assert {:error, {:not_found, "passkey", _kid}} = Passkeys.revoke(ctx(user), kid(first))

      # The key stays in the account: it signs in again, as a new client.
      {_user, again} = signed_in!(account, first)
      fresh = session_row(again).client_id
      refute fresh == revoked.id
      assert Arca.Repo.get!(PairedClient, fresh).standing == "active"
    end

    test "a revocation the store refuses ends nothing and announces nothing", %{
      account: account,
      user: user
    } do
      {_user, token} = signed_in!(account, hd(account.passkeys))
      [client] = clients(user.id)
      test = self()
      handler = {__MODULE__, make_ref()}
      on_exit(fn -> :telemetry.detach(handler) end)

      :ok =
        :telemetry.attach_many(
          handler,
          [[:cyfr, :sanctum, :sessions, :revoked], [:cyfr, :sanctum, :caller, :invalidated]],
          fn event, _measurements, _metadata, _config -> send(test, {:announced, event}) end,
          nil
        )

      # The store revokes the client and cannot delete its sessions, inside
      # the case's own transaction.
      fail_deletes!()
      assert {:error, :unavailable} = Passkeys.revoke(ctx(user), kid(hd(account.passkeys)))
      allow_deletes!()

      refute_received {:announced, _event}
      assert Arca.Repo.get!(PairedClient, client.id).standing == "active"
      assert {:ok, %Context{}} = Sanctum.Session.load(token)
    end

    test "only a person signed in reads or revokes", %{account: account, user: user} do
      anonymous = %{ctx(user) | authenticated: false}

      assert {:error, :unauthenticated} = Passkeys.list(anonymous)

      assert {:error, :unauthenticated} =
               Passkeys.revoke(%{ctx(user) | plane: :guest}, kid(hd(account.passkeys)))
    end
  end

  test "a declared restore suspends its client, and a fresh sign-in records a new one", %{
    account: account,
    user: user
  } do
    [client] = clients(user.id)

    {:ok, _} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
    assert {:ok, %{restore_id: _}} = Arca.SecurityTransitions.restore(slot: :none)
    assert Arca.Repo.get!(PairedClient, client.id).standing == "suspended"
    assert {:ok, []} = Passkeys.list(ctx(user))

    {_user, token} = signed_in!(account, hd(account.passkeys))
    fresh = session_row(token).client_id
    refute fresh == client.id
    assert Arca.Repo.get!(PairedClient, fresh).standing == "active"
  end

  test "a passkey removed from the account ends its client and sessions at the next refresh", %{
    dir: dir,
    account: account,
    user: user
  } do
    passkey = hd(account.passkeys)
    {_user, token} = signed_in!(account, passkey)
    [client] = clients(user.id)

    _account = DirectoryServer.remove_key!(dir.dir, account, kid(passkey))
    assert {:ok, _head} = Sanctum.IdentityFreshness.fresh!(account.identifier)

    assert Arca.Repo.get!(PairedClient, client.id).standing == "revoked"
    assert {:error, :invalid_session} = Sanctum.Session.load(token)
  end

  defp session_row_client(hash) do
    Arca.Repo.one(from(s in Session, where: s.token_hash == ^hash, select: s.client_id))
  end

  # A delete from the sessions table refused by the store, per adapter.
  defp fail_deletes! do
    if Arca.Test.Adapter.sqlite?() do
      Arca.Repo.query!(
        "CREATE TRIGGER pk_fail_delete BEFORE DELETE ON sessions " <>
          "BEGIN SELECT RAISE(ABORT, 'injected delete failure'); END"
      )
    else
      Arca.Repo.query!(
        "CREATE FUNCTION pk_fail_delete() RETURNS trigger LANGUAGE plpgsql AS " <>
          "$$ BEGIN RAISE EXCEPTION 'injected delete failure'; END $$"
      )

      Arca.Repo.query!(
        "CREATE TRIGGER pk_fail_delete BEFORE DELETE ON sessions " <>
          "FOR EACH ROW EXECUTE FUNCTION pk_fail_delete()"
      )
    end
  end

  defp allow_deletes! do
    if Arca.Test.Adapter.sqlite?(),
      do: Arca.Repo.query!("DROP TRIGGER pk_fail_delete"),
      else: Arca.Repo.query!("DROP TRIGGER pk_fail_delete ON sessions")
  end
end
