# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CallerRefreshTest do
  @moduledoc """
  A request whose own refresh of the account's head retires its session is
  refused: `Sanctum.Caller` reads the session again after the refresh's
  walk, at establish and at a retained context's revalidation, so a
  session the walk deleted (its key removed, or the account recovered)
  never stands for the context loaded before it.
  """

  # The access mode, the directory client's seam and the establish memo
  # are process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{DirectoryHead, Session, User}
  alias Sanctum.Caller
  alias Sanctum.Test.DirectoryServer

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup %{tls: tls} = tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    Prima.Test.Env.put_app_env(:sanctum, :access_mode, :public)
    Prima.Test.Env.put_app_env(:sanctum, :caller_memo_ttl_ms, 0)
    on_exit(fn -> Arca.Cache.delete_match({:established, :_, :_}) end)

    dir = DirectoryServer.start!(tls)
    account = DirectoryServer.account!(dir.dir, dir.url)
    person = member!(account)
    [device] = account.devices
    token = session!(person, DirectoryServer.kid(device), DirectoryServer.head(account))
    %{dir: dir, account: account, person: person, device: device, token: token}
  end

  defp member!(account) do
    now = DateTime.utc_now()

    person =
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

    :ok = DirectoryServer.account_person!(person.id, account)
    {:ok, _athanor} = Sanctum.Provisioning.mint_personal(Arca.Data.project(person))
    person
  end

  # A session the device's key signed for at `head`, as a sign-in mints one.
  defp session!(person, kid, head) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    :ok =
      Arca.SessionStorage.create_session(
        Sanctum.Session.token_hash(token),
        %{
          user_id: person.id,
          provider: "device",
          kid: kid,
          head: head,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        lock: %{user_id: person.id, athanor_id: nil, source: nil},
        verify: fn _rows -> :ok end
      )

    token
  end

  defp aged!(identifier) do
    {1, _} =
      Arca.Repo.update_all(from(h in DirectoryHead, where: h.identifier == ^identifier),
        set: [verified_at: DateTime.add(Arca.ServerMetaStorage.now!(), -3_600, :second)]
      )

    :ok
  end

  defp session_row(token),
    do: Arca.Repo.get_by(Session, token_hash: Sanctum.Session.token_hash(token))

  test "a request whose own refresh removes its key is refused", ctx do
    assert {:ok, _ctx} = Caller.establish(ctx.token, refresh: false)

    DirectoryServer.remove_key!(ctx.dir.dir, ctx.account, DirectoryServer.kid(ctx.device))
    aged!(ctx.account.identifier)

    assert {:error, :unauthenticated} = Caller.establish(ctx.token, refresh: false)
    refute session_row(ctx.token)
  end

  test "a request whose own refresh recovers its account is refused", ctx do
    assert {:ok, _ctx} = Caller.establish(ctx.token, refresh: false)

    DirectoryServer.recover!(ctx.dir.dir, ctx.account)
    aged!(ctx.account.identifier)

    assert {:error, :unauthenticated} = Caller.establish(ctx.token, refresh: false)
    refute session_row(ctx.token)
  end

  test "a retained context whose revalidation's refresh removes its key is refused", ctx do
    assert {:ok, held} = Caller.establish(ctx.token, refresh: false)

    DirectoryServer.remove_key!(ctx.dir.dir, ctx.account, DirectoryServer.kid(ctx.device))
    aged!(ctx.account.identifier)

    assert {:error, :unauthenticated} = Caller.revalidate_session(held)
    refute session_row(ctx.token)
  end

  test "a refresh that retires nothing of the session leaves the request standing", ctx do
    DirectoryServer.add_device!(ctx.dir.dir, ctx.account)
    aged!(ctx.account.identifier)

    assert {:ok, held} = Caller.establish(ctx.token, refresh: false)
    assert {:ok, _ctx} = Caller.revalidate_session(held)
    assert session_row(ctx.token)
  end
end
