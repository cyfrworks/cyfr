# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PlatformHolderTest do
  @moduledoc """
  A passkey in the one Devices list: each credential is projected as its
  person's paired client, its platform holder (`holder_kind` `platform`,
  the credential as its source, no key), one row per credential, standing
  as the credential stands. `pairing.list` names it beside the devices and
  says whether it may sync; revoking it, through Devices or the passkey,
  ends the credential wherever it synced and the sessions its sign-ins
  made. A passkey sign-in's session names that holder and keeps the
  ordinary idle expiry, sliding with use, decided by the client's source
  and never by what it reports. The holder never signs as a device: it has
  no key to certify.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{PairedClient, Session}
  alias Sanctum.{Context, Pairing, Passkeys, TestContext}
  alias Sanctum.TestContext.Authenticator

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|platform-#{n}",
        provider: "github",
        email: "platform#{n}@example.com",
        verified: false
      })

    athanor = Sanctum.Test.People.athanor!(user)

    {:ok, session} =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )
      |> TestContext.create_session()

    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)
    %{user: user, athanor: athanor, ctx: ctx}
  end

  # The person's first passkey, under the first-method rule.
  defp registered!(ctx, opts \\ []) do
    auth = Authenticator.new("platform-#{System.unique_integer([:positive])}")
    {:ok, options} = Passkeys.register(ctx, %{})

    assert {:ok, %{status: "active", passkey: passkey}} =
             Passkeys.register(ctx, %{credential: Authenticator.registration(auth, options, opts)})

    {auth, passkey}
  end

  defp holders(user_id),
    do:
      Arca.Repo.all(
        from(p in PairedClient, where: p.user_id == ^user_id and p.source_kind == "passkey")
      )

  defp signed_in!(auth) do
    held = Passkeys.sign_in_challenge()

    assert {:ok, %{session_token: token}} =
             Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge))

    token
  end

  test "a passkey is one platform holder in the person's own athanor, with no key, listed beside the devices",
       %{ctx: ctx, user: user, athanor: athanor} do
    {_auth, passkey} = registered!(ctx, backup_eligible: true)

    assert [holder] = holders(user.id)

    assert %{
             athanor_id: athanor_id,
             source_id: source_id,
             holder_kind: "platform",
             standing: "active",
             device_public_key: nil
           } = holder

    assert {athanor_id, source_id} == {athanor.id, passkey.id}

    {:ok, [listed]} = Pairing.list(ctx)

    assert %{
             client_id: client_id,
             source: "passkey",
             holder_kind: "platform",
             synced: true,
             certificate_expires_at: nil,
             storage: nil
           } = listed

    assert client_id == holder.id
  end

  test "a credential registered without backup eligibility is listed as kept on its machine",
       %{ctx: ctx} do
    _registered = registered!(ctx)
    assert {:ok, [%{holder_kind: "platform", synced: false}]} = Pairing.list(ctx)
  end

  test "it has no key to certify: no certificate is recorded for it", %{ctx: ctx, user: user} do
    _registered = registered!(ctx)
    [holder] = holders(user.id)

    assert {:error, :no_device_key} =
             Arca.DeviceCertificates.record(Prima.Actor.in_athanor(holder.athanor_id), %{
               paired_client_id: holder.id,
               user_id: user.id,
               subject_kind: "local",
               device_public_key: :crypto.strong_rand_bytes(32),
               issuing_home: Sanctum.Person.home(),
               audience_home: Sanctum.Person.home(),
               not_before: DateTime.utc_now(),
               expires_at: DateTime.add(DateTime.utc_now(), 3600),
               certificate: "{}",
               digest: Prima.Digest.sha256("{}")
             })
  end

  test "a passkey sign-in's session names the holder and slides with use as any session does",
       %{ctx: ctx, user: user} do
    {auth, _passkey} = registered!(ctx)
    [holder] = holders(user.id)
    token = signed_in!(auth)

    row = Arca.Repo.get_by!(Session, token_hash: Sanctum.Session.token_hash(token))
    assert row.client_id == holder.id

    assert {:ok, %Context{credential_deadline: nil}, _due} = Sanctum.Session.load_sliding(token)

    # Pushed back to just past its refresh point, it slides on use.
    soon = DateTime.add(DateTime.utc_now(), 60, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in Session, where: s.id == ^row.id), set: [expires_at: soon])

    :ok = Sanctum.Session.refresh_if_stale(token)
    later = Arca.Repo.get!(Session, row.id).expires_at
    assert DateTime.compare(later, soon) == :gt
  end

  test "revoking the holder through Devices revokes the passkey everywhere and ends its sessions",
       %{ctx: ctx, user: user} do
    # The person's linked sign-in leaves them a way in once it goes.
    {auth, passkey} = registered!(ctx)
    token = signed_in!(auth)
    [holder | _] = Enum.filter(holders(user.id), &(&1.source_id == passkey.id))

    assert {:error, {:confirmation_required, %{id: id}}} = Pairing.revoke(ctx, holder.id)
    TestContext.prove!(ctx, id, auth)

    assert {:ok, %{standing: "revoked"}} =
             Pairing.revoke(%{ctx | confirmation_id: id}, holder.id)

    assert {:ok, %{state: "revoked"}} = Arca.Passkeys.get(Prima.Actor.system(), passkey.id)
    assert Arca.Repo.get!(PairedClient, holder.id).standing == "revoked"
    assert {:error, :invalid_session} = Sanctum.Session.load(token)

    # The credential signs no one in again.
    held = Passkeys.sign_in_challenge()

    assert {:error, :assertion_refused} =
             Passkeys.sign_in(held, Authenticator.assertion(auth, held.challenge))
  end

  test "the store revokes and re-enables a holder only with its credential", %{
    ctx: ctx,
    user: user
  } do
    _registered = registered!(ctx)
    [holder] = holders(user.id)
    actor = Prima.Actor.in_athanor(holder.athanor_id)

    assert {:error, :passkey_holder} = Arca.PairedClients.revoke(actor, holder.id)

    assert {:error, :passkey_holder} =
             Arca.PairedClients.reenable(actor, user.id, holder.id, verify: fn _ -> :ok end)

    assert Arca.Repo.get!(PairedClient, holder.id).standing == "active"
  end

  test "a declared restore suspends the holder with its credential, and re-enabling the passkey returns both",
       %{ctx: ctx, user: user} do
    {_auth, passkey} = registered!(ctx)
    [holder] = holders(user.id)

    {:ok, _} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
    assert {:ok, %{restore_id: _}} = Arca.SecurityTransitions.restore(slot: :none)

    assert Arca.Repo.get!(PairedClient, holder.id).standing == "suspended"

    {:ok, _active} =
      Arca.Passkeys.reenable(Prima.Actor.system(), user.id, passkey.id, verify: fn _ -> :ok end)

    assert Arca.Repo.get!(PairedClient, holder.id).standing == "active"
  end

  test "a person deleted with their passkey and its session leaves no client of no one, and a declared restore after it runs",
       %{ctx: ctx, user: user} do
    {auth, passkey} = registered!(ctx)
    _token = signed_in!(auth)
    assert [_holder] = holders(user.id)

    # The person goes, as a fixture's cleanup removes one: their passkey
    # with them, and its platform holder with the passkey.
    {1, _} = Arca.Repo.delete_all(from(u in Arca.Schemas.User, where: u.id == ^user.id))
    assert Arca.Repo.get(Arca.Schemas.Passkey, passkey.id) == nil
    assert holders(user.id) == []

    # A declared restore records every method holder's person; none of
    # them is gone.
    {:ok, _} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
    assert {:ok, %{restore_id: _}} = Arca.SecurityTransitions.restore(slot: :none)
  end

  test "the store refuses a passkey's client that is not its platform holder, and a platform holder with a key",
       %{ctx: ctx, user: user, athanor: athanor} do
    {_auth, passkey} = registered!(ctx)
    [holder] = holders(user.id)
    Arca.Repo.delete_all(from(p in PairedClient, where: p.id == ^holder.id))

    base = %{
      id: Prima.UUID7.generate_id("pcl"),
      athanor_id: athanor.id,
      user_id: user.id,
      source_kind: "passkey",
      source_id: passkey.id,
      passkey_id: passkey.id,
      standing: "active",
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    # Each attempt in its own savepoint, so a refused one leaves the test's
    # transaction usable on either adapter.
    refused? = fn row ->
      try do
        Arca.Repo.transaction(fn -> Arca.Repo.insert_all(PairedClient, [row]) end)
        false
      rescue
        _violation -> true
      end
    end

    for row <- [
          Map.put(base, :holder_kind, nil),
          Map.put(base, :holder_kind, "chip"),
          Map.merge(base, %{holder_kind: "platform", device_public_key: <<1::256>>}),
          Map.merge(base, %{holder_kind: "platform", source_kind: "device_cert"}),
          Map.merge(base, %{holder_kind: "platform", passkey_id: nil}),
          Map.merge(base, %{holder_kind: "platform", source_id: "psk_another"})
        ] do
      assert refused?.(row), inspect(Map.take(row, [:holder_kind, :source_kind]))
    end

    assert refused?.(base) == true
    refute refused?.(Map.put(base, :holder_kind, "platform"))
  end

  test "a passkey revoked after its credential was read mints no holderless session", %{ctx: ctx} do
    {auth, passkey} = registered!(ctx)
    held = Passkeys.sign_in_challenge()
    assertion = Authenticator.assertion(auth, held.challenge)
    test = self()
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _, _, meta, _ ->
          if self() == test and meta[:source] == "passkeys" and
               String.starts_with?(meta[:query] || "", "SELECT") do
            :telemetry.detach(handler)

            send(
              test,
              {:revoked_during_sign_in, Arca.Passkeys.revoke(Context.actor(ctx), passkey.id)}
            )
          end
        end,
        nil
      )

    result = Passkeys.sign_in(held, assertion)
    assert_receive {:revoked_during_sign_in, {:ok, %{passkey: %{state: "revoked"}}}}

    verdict =
      case result do
        {:ok, %{session_token: token}} ->
          row = Arca.Repo.get_by!(Session, token_hash: Sanctum.Session.token_hash(token))
          {:minted_session, row.client_id, match?({:ok, %Context{}}, Sanctum.Session.load(token))}

        refused ->
          refused
      end

    assert {:error, _refusal} = verdict
  end
end
