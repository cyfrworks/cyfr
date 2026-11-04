# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.SignInWindowTest do
  @moduledoc """
  A sign-in method's re-authentication and an emailed code prove who signed
  in or who reads a mailbox, not a key the person holds, so they confirm a
  record only inside two windows (`Sanctum.Pairing.sign_in_may_confirm/2`):
  while the person recovers from a declared restore, any record; before
  their first passkey or device ever existed, only that first one. Outside
  them the code's owner refuses where it is sent and where it confirms, so
  a window that closed after the code went out confirms nothing, and
  revoking every passkey and device never reopens the latch.
  `confirmation.pending` offers them only inside the window, and marks a
  record `enroll` for a person who must add a passkey or device first.
  """

  # The code transport is the node's configuration.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.PersonIdentity
  alias Sanctum.Auth.EmailVerification
  alias Sanctum.{Context, Pairing, TestContext}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    Prima.Test.Env.put_app_env(:sanctum, :confirmation_code_transport, TestContext.MailSink)

    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|window-#{n}",
        provider: "github",
        email: "window#{n}@example.com",
        verified: true
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

  # An everyday sensitive change, and a first method's: opened as records.
  defp everyday(ctx) do
    {:error, {:confirmation_required, %{id: id}}} =
      Sanctum.Consent.Authz.check(ctx, :credential_entry, %{
        operation: "vault.create",
        arguments: %{"name" => "prod-key"},
        resource: "prod-key"
      })

    Prima.Confirmation.ref(id)
  end

  defp first_device(ctx) do
    digest = Prima.Device.key_digest(elem(:crypto.generate_key(:eddsa, :ed25519), 0))

    {:error, {:confirmation_required, %{id: id}}} =
      Pairing.begin(ctx, %{"key_digest" => digest})

    Prima.Confirmation.ref(id)
  end

  defp latch!(user_id) do
    {1, _} =
      Arca.Repo.update_all(from(p in PersonIdentity, where: p.user_id == ^user_id),
        set: [first_method_at: DateTime.utc_now()]
      )
  end

  defp mailed!(ctx, ref) do
    assert {:ok, %{method: "email"}} = EmailVerification.send_code(ctx, ref)
    assert_receive {:confirmation_code_mail, mail}
    TestContext.MailSink.code(mail)
  end

  defp record(ctx, ref) do
    {:ok, row} = Arca.PendingConfirmations.get(Context.actor(ctx), ref)
    row
  end

  defp pending(ctx, ref) do
    {:ok, %{confirmations: [record]}} =
      Sanctum.Providers.Confirmation.handle(ctx, %{"action" => "pending", "request" => ref})

    record
  end

  test "before any passkey or device, a code confirms the first one and nothing else", %{
    ctx: ctx
  } do
    first = first_device(ctx)
    code = mailed!(ctx, first)
    assert {:ok, %{state: "confirmed"}} = EmailVerification.verify_code(ctx, first, code)

    other = everyday(ctx)

    assert {:error, %Prima.Refusal{reason: :enrollment_first}} =
             EmailVerification.send_code(ctx, other)

    record = pending(ctx, other)
    refute "email" in record.methods
    assert record.enroll
    assert record(ctx, other).state == "pending"

    refute pending(ctx, first_device(ctx)).enroll
    assert "email" in pending(ctx, first_device(ctx)).methods
  end

  test "once a method existed, a code confirms nothing, a first device's included, and revoking it all reopens nothing",
       %{ctx: ctx, user: user} do
    latch!(user.id)

    for ref <- [everyday(ctx), first_device(ctx)] do
      assert {:error, %Prima.Refusal{reason: :method_held}} =
               EmailVerification.send_code(ctx, ref)

      refute "email" in pending(ctx, ref).methods
      refute pending(ctx, ref).enroll
    end

    # No passkey or device stands now, and the latch still holds.
    assert {:ok, false} = Arca.PersonIdentities.first_method_open?(Prima.Actor.system(), user.id)
  end

  test "a code sent inside the window confirms nothing once it closed", %{ctx: ctx, user: user} do
    first = first_device(ctx)
    code = mailed!(ctx, first)

    # Another first method commits meanwhile, a passkey registered elsewhere.
    latch!(user.id)

    assert {:error, %Prima.Refusal{reason: :method_held}} =
             EmailVerification.verify_code(ctx, first, code)

    assert record(ctx, first).state == "pending"
  end

  test "while the person recovers from a declared restore, a code confirms any record", %{
    ctx: ctx,
    user: user
  } do
    # A first passkey, by the code while the window was open: the person now
    # holds a method, which a declared restore suspends.
    _authenticator = TestContext.passkey!(user.id)

    # The restore voids what was pending; the change is asked once it ran.
    {:ok, _} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
    assert {:ok, %{restore_id: _}} = Arca.SecurityTransitions.restore(slot: :none)
    ref = everyday(ctx)

    code = mailed!(ctx, ref)
    assert {:ok, %{state: "confirmed"}} = EmailVerification.verify_code(ctx, ref, code)
  end

  test "the store records a home's assertion as naming no client here", %{ctx: ctx} do
    ref = everyday(ctx)

    assert {:error, {:invalid, %{client_id: _}}} =
             Arca.PendingConfirmations.confirm(Context.actor(ctx), ref, %{
               proof: "home",
               client_id: "pcl_x"
             })
  end

  test "before the first passkey or device, a code cannot confirm linking another sign-in method",
       %{ctx: ctx, user: user} do
    n = System.unique_integer([:positive])

    identity = %{
      key: "oidcc|https://idp.test|extra-#{n}",
      provider: "oidcc",
      email: "extra#{n}@idp.test",
      verified: true
    }

    {:ok, ticket} = Sanctum.SignIn.link_ticket(ctx, identity)

    {:error, {:confirmation_required, %{id: id, operation: "person.link_door"}}} =
      Sanctum.SignIn.link_door(ctx, "oidcc", ticket)

    ref = Prima.Confirmation.ref(id)
    assert {:ok, true} = Arca.PersonIdentities.first_method_open?(Prima.Actor.system(), user.id)

    assert {:error, %Prima.Refusal{reason: :enrollment_first}} =
             EmailVerification.send_code(ctx, ref)

    assert pending(ctx, ref).enroll
    refute "email" in pending(ctx, ref).methods
  end

  test "a code held for linking a door cannot confirm it in the never-held window", %{
    ctx: ctx,
    user: user
  } do
    n = System.unique_integer([:positive])

    identity = %{
      key: "oidcc|https://idp.test|held-#{n}",
      provider: "oidcc",
      email: "held#{n}@idp.test",
      verified: true
    }

    {:ok, ticket} = Sanctum.SignIn.link_ticket(ctx, identity)
    {:error, {:confirmation_required, %{id: id}}} = Sanctum.SignIn.link_door(ctx, "oidcc", ticket)
    ref = Prima.Confirmation.ref(id)

    code =
      case EmailVerification.send_code(ctx, ref) do
        {:ok, %{method: "email"}} ->
          assert_receive {:confirmation_code_mail, mail}
          TestContext.MailSink.code(mail)

        {:error, %Prima.Refusal{reason: :enrollment_first}} ->
          "000000"
      end

    result = EmailVerification.verify_code(ctx, ref, code)

    if match?({:ok, _}, result) do
      assert {:ok, %{linked: true}} =
               Sanctum.SignIn.link_door(%{ctx | confirmation_id: id}, "oidcc", ticket)

      assert {:ok, true} = Arca.PersonIdentities.first_method_open?(Prima.Actor.system(), user.id)
    end

    assert {:error, %Prima.Refusal{reason: :enrollment_first}} = result
  end
end
