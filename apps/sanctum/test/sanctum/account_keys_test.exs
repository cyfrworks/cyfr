# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.AccountKeysTest do
  @moduledoc """
  The keys of a person's account as Settings lists them, against a
  scripted directory serving the account's log: every key the log lists,
  in the order they were added, a passkey by its maker and a device by
  the name its hello gave here, and under each the person's sessions here
  that it signed, their own marked; and one of those sessions ended by
  its id, and nothing else.
  """

  # The directory seam and the head cache are process-wide.
  use ExUnit.Case, async: false

  alias Arca.Schemas.User
  alias Sanctum.{AccountKeys, Context, Session}
  alias Sanctum.Test.DirectoryServer

  @apple "fbfc3007-154e-4ecc-8c0b-6e020557d7bd"
  @safari "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Prima.Test.Env.put_app_env(:sanctum, :access_mode, :public)

    person = person!()
    %{account: account, dir: dir} = DirectoryServer.member!(person.id)
    account = DirectoryServer.add_passkey!(dir.dir, account, aaguid: @apple)
    account = DirectoryServer.add_passkey!(dir.dir, account)
    _head = DirectoryServer.cached!(account)
    %{person: person, account: account, dir: dir}
  end

  defp person! do
    now = DateTime.utc_now()

    %User{}
    |> User.changeset(%{
      id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
      admission: "open",
      first_seen_at: now,
      last_seen_at: now,
      created_at: now,
      updated_at: now
    })
    |> Arca.Repo.insert!()
  end

  # A session the key `kid` signed for at the account's head, recording
  # what `user_agent` names: its token's hash and its row's id.
  defp session!(person, account, kid, user_agent \\ nil) do
    hash = :crypto.strong_rand_bytes(32)
    {browser, system} = Sanctum.UserAgent.words(user_agent)

    :ok =
      Arca.SessionStorage.create_session(
        hash,
        %{
          user_id: person.id,
          provider: "passkey",
          kid: kid,
          head: DirectoryServer.head(account),
          browser: browser,
          system: system,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        lock: %{user_id: person.id, athanor_id: nil, source: nil},
        verify: fn _rows -> :ok end
      )

    {:ok, rows} = Arca.SessionStorage.list_live(person.id)
    %{hash: hash, id: Enum.find(rows, &(&1.token_hash == hash)).id}
  end

  # The device's client here, named as its hello named it.
  defp paired!(person, account, {pub, _priv}, name) do
    athanor = Prima.Actor.in_athanor("ath_ak_#{System.unique_integer([:positive])}")

    {:ok, _client} =
      Arca.PairedClients.record(athanor, %{
        user_id: person.id,
        source_kind: "device_cert",
        source_id: "req_#{System.unique_integer([:positive])}",
        device_public_key: pub,
        kid: Prima.Identity.Key.kid(pub),
        head: DirectoryServer.head(account),
        display_name: name
      })

    :ok
  end

  # Another person here, by an account of their own at the same directory.
  defp stranger!(dir) do
    stranger = person!()
    account = DirectoryServer.account!(dir.dir, dir.url)
    :ok = DirectoryServer.account_person!(stranger.id, account)
    {stranger, account}
  end

  defp ctx(person, own_hash),
    do:
      Context.build(
        user_id: person.id,
        auth_method: :oidc,
        authenticated: true,
        session_token_hash: own_hash,
        permissions: Context.person_permissions()
      )

  test "lists every key the log lists, by maker or name, with the person's own sessions here under each",
       %{person: person, account: account, dir: dir} do
    [device] = account.devices
    [apple, plain] = account.passkeys
    [_genesis, device_added, apple_added, plain_added] = account.log
    device_kid = DirectoryServer.kid(device)
    apple_kid = Prima.Identity.Key.kid(apple.pub)
    plain_kid = Prima.Identity.Key.kid(plain.pub)

    paired!(person, account, device, "Moon's terminal")
    own = session!(person, account, apple_kid, @safari)
    other = session!(person, account, apple_kid)
    terminal = session!(person, account, device_kid)

    # Another person's session is never theirs to see.
    {stranger, theirs} = stranger!(dir)
    _not_listed = session!(stranger, theirs, DirectoryServer.kid(hd(theirs.devices)), @safari)

    assert {:ok, %{keys: keys, account_page: page}} = AccountKeys.list(ctx(person, own.hash))
    assert page == account.url <> "/account/devices"

    assert Enum.map(keys, &Map.delete(&1, :sessions)) == [
             %{
               kid: device_kid,
               kind: "device",
               code: String.slice(device_kid, 7, 16),
               added_at: iso(device_added.at),
               maker: nil,
               name: "Moon's terminal"
             },
             %{
               kid: apple_kid,
               kind: "passkey",
               code: String.slice(apple_kid, 7, 16),
               added_at: iso(apple_added.at),
               maker: "Apple Passwords",
               name: nil
             },
             %{
               kid: plain_kid,
               kind: "passkey",
               code: String.slice(plain_kid, 7, 16),
               added_at: iso(plain_added.at),
               maker: nil,
               name: nil
             }
           ]

    [device_row, apple_row, plain_row] = keys
    assert Enum.map(device_row.sessions, & &1.session_id) == [terminal.id]

    assert Enum.sort(Enum.map(apple_row.sessions, & &1.session_id)) ==
             Enum.sort([own.id, other.id])

    assert plain_row.sessions == []

    mine = Enum.find(apple_row.sessions, &(&1.session_id == own.id))
    assert %{browser: "Safari", system: "macOS", current: true} = mine
    assert is_binary(mine.signed_in_at) and is_binary(mine.last_seen_at)
    refute Enum.find(apple_row.sessions, &(&1.session_id == other.id)).current
  end

  test "ends one session of the person's own by its id, and nothing else", %{
    person: person,
    account: account,
    dir: dir
  } do
    apple_kid = Prima.Identity.Key.kid(hd(account.passkeys).pub)
    own = session!(person, account, apple_kid)
    other = session!(person, account, apple_kid)
    {stranger, stranger_account} = stranger!(dir)

    theirs =
      session!(stranger, stranger_account, DirectoryServer.kid(hd(stranger_account.devices)))

    assert {:error, :not_found} = Session.end_own(ctx(person, own.hash), theirs.id)
    assert {:error, :not_found} = Session.end_own(ctx(person, own.hash), "ses_unknown")
    assert :ok = Session.end_own(ctx(person, own.hash), other.id)

    {:ok, rows} = Arca.SessionStorage.list_live(person.id)
    assert Enum.map(rows, & &1.id) == [own.id]
    {:ok, stranger_rows} = Arca.SessionStorage.list_live(stranger.id)
    assert Enum.map(stranger_rows, & &1.id) == [theirs.id]
  end

  test "only a person signed in lists keys or ends a session", %{person: person} do
    anonymous = %{ctx(person, nil) | authenticated: false}
    assert {:error, :unauthenticated} = AccountKeys.list(anonymous)
    assert {:error, :unauthenticated} = AccountKeys.list(%{ctx(person, nil) | plane: :guest})
    assert {:error, :unauthenticated} = Session.end_own(anonymous, "ses_any")
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
