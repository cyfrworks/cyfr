# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DeviceUnlockTest do
  @moduledoc """
  A protected device (`Sanctum.DeviceUnlock`), through its public entries,
  admitted by its hello (`Sanctum.Test.Devices`, against a scripted
  directory).

  An unlock answers a 32-byte ticket that a browser redeems once, for a
  session of the device's person that names the device, expires within 60
  seconds and the certificate whatever `session_ttl_hours` says, which a
  browser's refresh never moves and the device's channel slides without
  reviving. A lock proof needs no freshness, retires exactly its session,
  repeats as a success, never ends a successor, and spent before the
  ticket leaves the ticket redeeming nothing. A revocation or a revoked
  certificate before the redemption refuses it, and after it ends the
  session. A browser's session and another device's proof unlock nothing.
  """

  # The directory seam, the setup token, the directory setting and the
  # access mode are process-wide.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{PairedClient, Session, User}
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Sanctum.{Context, DeviceUnlock}
  alias Sanctum.Test.{DirectoryServer, Devices}

  @token String.duplicate("6d", 32)

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup %{tls: tls} = tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    dir = DirectoryServer.start!(tls)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, dir.url)
    Prima.Test.Env.put_app_env(:sanctum, :access_mode, :public)
    # The installation holds no person inside this test's transaction.
    Arca.Repo.delete_all(User)
    %{dir: dir}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp key, do: :crypto.generate_key(:eddsa, :ed25519)
  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
  defp signed(challenge, private), do: Proof.encode(Proof.sign(challenge, private))

  # The box's setup: its key admitted by its hello as the first person's device.
  defp enrolled!(%{dir: dir}) do
    account = DirectoryServer.account!(dir.dir, dir.url)
    Devices.admitted!(account, List.last(account.devices), {:setup, @token})
  end

  defp connected!(device), do: Devices.connected!(device)

  defp unlocked!(ctx, {_public, private}) do
    {:ok, %{challenge: challenge}} = DeviceUnlock.unlock(ctx, %{})
    {:ok, answer} = DeviceUnlock.unlock(ctx, %{"proof" => signed(challenge, private)})
    answer
  end

  defp lock_proof(device, session_id, key \\ nil) do
    {_public, private} = key || device.key
    certificate = device.certificate

    {:ok, challenge} =
      Challenge.new(
        purpose: :lock,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: certificate.client_id,
        device_key: elem(device.key, 0),
        session_id: session_id
      )

    signed(challenge, private)
  end

  defp session_row(session_id), do: Arca.Repo.get(Session, session_id)
  defp client_row(client_id), do: Arca.Repo.get!(PairedClient, client_id)

  # The client's current certificate revoked through its store, the one
  # revocation statement every transition runs.
  defp revoke_certificate!(athanor_id, client_id) do
    actor = Prima.Actor.in_athanor(athanor_id)
    {:ok, current} = Arca.DeviceCertificates.current(actor, client_id)
    {:ok, _revoked} = Arca.DeviceCertificates.revoke(actor, current.id)
  end

  defp revoke_client!(device) do
    actor = Prima.Actor.in_athanor(device.certificate.athanor)
    {:ok, _row} = Arca.PairedClients.revoke(actor, device.certificate.client_id)
  end

  # ---------------------------------------------------------------------------
  # Unlock
  # ---------------------------------------------------------------------------

  describe "unlock" do
    setup context do
      device = enrolled!(context)
      %{device: device, ctx: connected!(device)}
    end

    test "answers a ticket a browser redeems once for a session bound to the device", %{
      device: device,
      ctx: ctx
    } do
      answer = unlocked!(ctx, device.key)
      assert byte_size(Base.url_decode64!(answer.ticket, padding: false)) == 32
      assert "ses_" <> _ = answer.session_id
      # The unlock reserves the session as a row no token loads; the
      # ticket's redemption activates it.
      assert %Session{provider: "unlock_reserved", token_prefix: nil} =
               session_row(answer.session_id)

      assert {:ok, %{token: token, expires_at: expires_at}} = DeviceUnlock.redeem(answer.ticket)
      assert {:error, :invalid_ticket} = DeviceUnlock.redeem(answer.ticket)

      row = session_row(answer.session_id)
      assert row.client_id == device.certificate.client_id
      assert row.provider == "unlock"
      assert row.user_id == ctx.user_id
      assert DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), 61, :second)) == :lt

      assert {:ok, %Context{} = session_ctx} = Sanctum.Session.load(token)
      assert session_ctx.auth_method == :oidc
      assert session_ctx.client_id == nil
      assert session_ctx.credential_deadline == row.expires_at
    end

    test "a ticket that is not one, or another's, redeems nothing", %{device: device, ctx: ctx} do
      _answer = unlocked!(ctx, device.key)

      for ticket <- [nil, "", "short", b64(:crypto.strong_rand_bytes(32))] do
        assert {:error, :invalid_ticket} = DeviceUnlock.redeem(ticket), inspect(ticket)
      end
    end

    test "a proof answers its unlock challenge once, and a proof of another key or purpose none",
         %{device: device, ctx: ctx} do
      {_public, private} = device.key
      {:ok, %{challenge: challenge}} = DeviceUnlock.unlock(ctx, %{})
      {_other, other_private} = key()

      assert {:error, :proof_refused} =
               DeviceUnlock.unlock(ctx, %{"proof" => signed(challenge, other_private)})

      # Taken by that refusal.
      assert {:error, :proof_refused} =
               DeviceUnlock.unlock(ctx, %{"proof" => signed(challenge, private)})

      {:ok, %{challenge: challenge}} = DeviceUnlock.unlock(ctx, %{})
      lock = lock_proof(device, challenge.session_id)
      assert {:error, :proof_refused} = DeviceUnlock.unlock(ctx, %{"proof" => lock})
      assert {:error, :invalid_request} = DeviceUnlock.unlock(ctx, %{"proof" => lock, "x" => 1})
    end

    test "session_ttl_hours zero lifts no bound off a device's session", %{
      device: device,
      ctx: ctx
    } do
      :ok = Sanctum.Test.Settings.put("session_ttl_hours", 0)
      answer = unlocked!(ctx, device.key)
      {:ok, %{expires_at: expires_at}} = DeviceUnlock.redeem(answer.ticket)
      assert DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), 61, :second)) == :lt

      assert DateTime.compare(session_row(answer.session_id).expires_at, ~U[9999-01-01 00:00:00Z]) ==
               :lt
    end

    test "a browser's refresh never moves a device's session; its channel slides it, never past the certificate and never reviving",
         %{device: device, ctx: ctx} do
      answer = unlocked!(ctx, device.key)
      {:ok, %{token: token}} = DeviceUnlock.redeem(answer.ticket)
      before = session_row(answer.session_id).expires_at

      assert {:error, :invalid_session} = Sanctum.Session.refresh(token)
      assert :ok = Sanctum.Session.refresh_if_stale(token)
      assert {:ok, _ctx} = Sanctum.Caller.establish(token)
      assert session_row(answer.session_id).expires_at == before

      Process.sleep(5)
      assert {:ok, [_slid]} = DeviceUnlock.slide(ctx, [answer.session_id])
      slid = session_row(answer.session_id).expires_at
      assert DateTime.compare(slid, before) == :gt
      assert DateTime.compare(slid, ctx.credential_deadline) != :gt

      # Past its expiry, nothing revives it.
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      from(s in Session, where: s.id == ^answer.session_id)
      |> Arca.Repo.update_all(set: [expires_at: past])

      assert {:ok, []} = DeviceUnlock.slide(ctx, [answer.session_id])
      assert session_row(answer.session_id).expires_at == past
      assert {:error, :invalid_session} = Sanctum.Session.load(token)
    end

    test "a browser's session and a context of no device unlock nothing",
         %{device: device, ctx: ctx} do
      answer = unlocked!(ctx, device.key)
      {:ok, %{token: token}} = DeviceUnlock.redeem(answer.ticket)
      {:ok, browser} = Sanctum.Session.load(token)

      assert {:error, :not_a_device} = DeviceUnlock.unlock(browser, %{})

      assert {:error, :not_a_device} =
               DeviceUnlock.lock(browser, %{"proof" => lock_proof(device, answer.session_id)})

      assert {:error, :not_a_device} =
               DeviceUnlock.unlock(Context.build(authenticated: false), %{})
    end
  end

  describe "lock" do
    setup context do
      device = enrolled!(context)
      ctx = connected!(device)
      answer = unlocked!(ctx, device.key)
      {:ok, %{token: token}} = DeviceUnlock.redeem(answer.ticket)
      %{device: device, ctx: ctx, session_id: answer.session_id, token: token}
    end

    test "retires exactly its session without freshness, repeats as a success and never ends a successor",
         %{device: device, ctx: ctx, session_id: session_id, token: token} do
      proof = lock_proof(device, session_id)
      successor = unlocked!(ctx, device.key)
      {:ok, %{token: successor_token}} = DeviceUnlock.redeem(successor.ticket)

      assert {:ok, %{locked: true}} = DeviceUnlock.lock(ctx, %{"proof" => proof})
      assert session_row(session_id) == nil
      assert {:error, :invalid_session} = Sanctum.Session.load(token)

      assert {:ok, %{locked: true}} = DeviceUnlock.lock(ctx, %{"proof" => proof})
      assert %Session{} = session_row(successor.session_id)
      assert {:ok, _ctx} = Sanctum.Session.load(successor_token)
    end

    test "a proof of another key, another session's or another purpose's locks nothing",
         %{device: device, ctx: ctx, session_id: session_id, token: token} do
      assert {:error, :proof_refused} =
               DeviceUnlock.lock(ctx, %{"proof" => lock_proof(device, session_id, key())})

      {:ok, %{challenge: unlock}} = DeviceUnlock.unlock(ctx, %{})

      assert {:error, :proof_refused} =
               DeviceUnlock.lock(ctx, %{"proof" => signed(unlock, elem(device.key, 1))})

      assert {:ok, _ctx} = Sanctum.Session.load(token)
      assert %Session{} = session_row(session_id)
    end

    test "before the ticket's redemption leaves the ticket redeeming nothing", %{
      device: device,
      ctx: ctx
    } do
      answer = unlocked!(ctx, device.key)

      assert {:ok, %{locked: true}} =
               DeviceUnlock.lock(ctx, %{"proof" => lock_proof(device, answer.session_id)})

      assert {:error, :invalid_ticket} = DeviceUnlock.redeem(answer.ticket)
      assert session_row(answer.session_id) == nil
    end

    test "the channel's end retires its sessions and its unspent tickets", %{
      device: device,
      ctx: ctx,
      session_id: session_id,
      token: token
    } do
      pending = unlocked!(ctx, device.key)
      :ok = DeviceUnlock.closed(ctx.user_id, ctx.client_id, [session_id, pending.session_id])
      assert {:error, :invalid_session} = Sanctum.Session.load(token)
      assert {:error, :invalid_ticket} = DeviceUnlock.redeem(pending.ticket)
    end
  end

  describe "retirement" do
    setup context do
      device = enrolled!(context)
      %{device: device, ctx: connected!(device)}
    end

    test "a revocation before the redemption refuses it, and after it ends the session", %{
      device: device,
      ctx: ctx
    } do
      first = unlocked!(ctx, device.key)
      second = unlocked!(ctx, device.key)
      {:ok, %{token: token}} = DeviceUnlock.redeem(first.ticket)

      revoke_client!(device)

      assert session_row(first.session_id) == nil
      assert {:error, :invalid_session} = Sanctum.Session.load(token)
      assert {:error, :not_standing} = DeviceUnlock.redeem(second.ticket)
      assert session_row(second.session_id) == nil
    end

    test "a certificate revoked before the redemption refuses it, and after it the session no longer loads",
         %{device: device, ctx: ctx} do
      first = unlocked!(ctx, device.key)
      second = unlocked!(ctx, device.key)
      {:ok, %{token: token}} = DeviceUnlock.redeem(first.ticket)

      revoke_certificate!(device.certificate.athanor, device.certificate.client_id)

      assert {:error, :invalid_session} = Sanctum.Session.load(token)
      assert {:error, :not_standing} = DeviceUnlock.redeem(second.ticket)
    end
  end

  # ---------------------------------------------------------------------------
  # Confirmation
  # ---------------------------------------------------------------------------
end
