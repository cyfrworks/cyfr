# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.IssuanceTest do
  @moduledoc """
  The policy a credential is issued under (`Sanctum.Issuance`), from a
  paired device's context: the device's binding names its paired client,
  and an issuance from it locks that client after the person, the athanor
  and the seat, and stands only while the client, the certificate the
  context stands under and, for a person whose keys are at another home,
  the identity row they were resolved by still stand. A device context
  without its own binding issues nothing, and a session or a key issues as
  it did.

  Every device here is paired through the real ceremony
  (`Sanctum.Pairing.begin/2` under a session, `complete/3` from a glass
  holding nothing) and verified through `Sanctum.DeviceCerts`.
  """

  # The rate limiter's table is the node's and some cases change the
  # home's name: one case at a time.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{ApiKey, DeviceCertificate, PersonIdentity}
  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Sanctum.{Context, DeviceCerts, Issuance, Pairing, Person}
  alias Sanctum.Tenancy.{Athanors, Users}

  @source "198.51.100.9"

  setup tags do
    Arca.Cache.init()
    Arca.Test.Sandbox.setup!(tags)
    Prima.RateLimiter.reset()

    public_url = Application.get_env(:sanctum, :public_url)

    on_exit(fn ->
      Prima.RateLimiter.reset()

      if public_url,
        do: Application.put_env(:sanctum, :public_url, public_url),
        else: Application.delete_env(:sanctum, :public_url)
    end)

    seated!()
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A person seated in a group of their own, and the context their session
  # establishes there.
  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|issuance-#{n}",
        provider: "github",
        email: "issuance#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Issuance #{n}")

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)

    {:ok, session_ctx} =
      Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

    %{user: user, athanor: athanor, session_ctx: session_ctx}
  end

  defp begin!(session_ctx) do
    session_ctx
    |> Sanctum.TestContext.confirmed(:device_pairing, Pairing.invitation_change())
    |> Pairing.begin(%{})
  end

  # Revoking a device is a sensitive change, under the person's session and
  # a confirmation they proved, as `pairing/revoke` takes it.
  defp revoke!(session_ctx, client_id) do
    session_ctx
    |> Sanctum.TestContext.confirmed(:pairing_revocation, %{
      operation: "pairing.revoke",
      arguments: %{"client_id" => client_id},
      resource: client_id
    })
    |> Pairing.revoke(client_id)
  end

  # A device paired through the ceremony: its key pair, its client and its
  # first certificate.
  defp pair!(session_ctx) do
    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, invitation} = begin!(session_ctx)
    glass = Context.build(%{authenticated: false, client_ip: @source})
    submission = %{device_key: device_key}

    {:ok, %{challenge: challenge}} =
      Pairing.complete(glass, invitation.invitation_secret, submission)

    {:ok, %{client_id: client_id, certificate: certificate}} =
      Pairing.complete(
        glass,
        invitation.invitation_secret,
        Map.put(submission, :proof, Proof.sign(challenge, private))
      )

    %{client_id: client_id, certificate: certificate, device_key: device_key, private: private}
  end

  # The device's context, as its channel holds it once its connect proof
  # verified, then as a request under its certificate verifies it.
  defp verified!(device) do
    challenge = challenge(device, :connect)

    {:ok, ctx} =
      DeviceCerts.verify_connect(
        %{client_id: device.client_id, certificate: device.certificate, source: @source},
        Proof.sign(challenge, device.private),
        challenge
      )

    {:ok, ctx} = DeviceCerts.verify_request(device.certificate, ctx, [])
    ctx
  end

  defp challenge(device, purpose) do
    certificate = device.certificate

    {:ok, challenge} =
      Challenge.new(
        purpose: purpose,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: device.client_id,
        device_key: certificate.device_key,
        nonce: :crypto.strong_rand_bytes(Challenge.nonce_bytes()),
        now: System.system_time(:millisecond)
      )

    challenge
  end

  defp key_attrs(ctx) do
    n = System.unique_integer([:positive])

    %{
      name: "glass-key-#{n}",
      key_hash: :crypto.hash(:sha256, "glass-key-#{n}"),
      key_prefix: "cyfr_sk_gl",
      type: "service",
      created_by: ctx.user_id,
      athanor_id: ctx.athanor_id
    }
  end

  # A key minted from `ctx` the way `Sanctum.ApiKey` mints one once its
  # confirmation is consumed: in the issuance transaction, under the
  # policy `ctx`'s binding names.
  defp mint(ctx) do
    attrs = key_attrs(ctx)

    result =
      with {:ok, expectation} <- Issuance.expectation(ctx, []) do
        Arca.ApiKeyStorage.create_key(attrs,
          lock: Issuance.lock(expectation),
          verify: Issuance.verify(expectation)
        )
      end

    {result, attrs}
  end

  defp minted?(%{key_hash: hash}),
    do: Arca.Repo.exists?(from(k in ApiKey, where: k.key_hash == ^hash))

  defp key_change(attrs),
    do: %{operation: "key.create", arguments: attrs, resource: Map.fetch!(attrs, :name)}

  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}

  # ---------------------------------------------------------------------------
  # The device's binding
  # ---------------------------------------------------------------------------

  describe "a paired device's binding" do
    test "names its paired client and seat, and an issuance from it locks that client", %{
      session_ctx: session_ctx,
      user: user,
      athanor: athanor
    } do
      device = pair!(session_ctx)
      ctx = verified!(device)
      client_id = device.client_id

      assert %{
               source_kind: :device,
               source_id: ^client_id,
               focus_basis: seat_id,
               identity: nil
             } = ctx.credential_binding

      assert {:ok, %{athanor_id: athanor_id}} = Sanctum.Tenancy.Members.get(seat_id)
      assert athanor_id == athanor.id

      assert {:ok, expectation} = Issuance.expectation(ctx, [])
      deadline = DateTime.from_unix!(device.certificate.expires_at, :millisecond)
      assert expectation.source == {:device, client_id, deadline}
      assert expectation.identity == nil

      assert Issuance.lock(expectation) == %{
               user_id: user.id,
               athanor_id: athanor.id,
               membership_id: seat_id,
               source: {:device, client_id, deadline}
             }
    end

    test "a standing device mints a key under its confirmation", %{session_ctx: session_ctx} do
      ctx = session_ctx |> pair!() |> verified!()
      attrs = %{name: "from-the-glass"}

      confirmed = Sanctum.TestContext.confirmed(ctx, :credential_issuance, key_change(attrs))

      assert {:ok, %{api_key: "cyfr_pk_" <> _, name: "from-the-glass"}} =
               Sanctum.ApiKey.create(confirmed, attrs)
    end

    test "is a device context's own: no other context can carry it", %{session_ctx: session_ctx} do
      ctx = session_ctx |> pair!() |> verified!()
      binding = ctx.credential_binding

      base = [
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        credential_binding: binding,
        authenticated: true
      ]

      assert %Context{credential_binding: ^binding} =
               Context.build([auth_method: :device, client_id: ctx.client_id] ++ base)

      for {what, attrs} <- [
            a_session: [auth_method: :oidc] ++ base,
            another_client: [auth_method: :device, client_id: "pcl_another"] ++ base,
            no_client: [auth_method: :device] ++ base,
            a_local_row:
              [auth_method: :device, client_id: ctx.client_id] ++
                Keyword.put(base, :credential_binding, %{
                  binding
                  | identity: %{user_id: ctx.user_id, provenance: "local", identifier: "per_x"}
                }),
            an_identity_on_a_session:
              [auth_method: :oidc] ++
                Keyword.put(base, :credential_binding, %{
                  binding
                  | source_kind: :identity,
                    source_id: nil,
                    identity: %{user_id: ctx.user_id, provenance: "remote", identifier: "per_x"}
                })
          ] do
        refused =
          try do
            Context.build(attrs)
          rescue
            error in ArgumentError -> error.message
          end

        assert is_binary(refused) and refused =~ "credential_binding is malformed", inspect(what)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # A revocation between the request's verification and the issuance
  # ---------------------------------------------------------------------------

  describe "a revocation after the device's request was verified" do
    test "of the client refuses the issuance: nothing is minted", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      ctx = verified!(device)

      assert {:ok, %{standing: "revoked"}} = revoke!(session_ctx, device.client_id)

      assert {{:error, :not_standing}, attrs} = mint(ctx)
      refute minted?(attrs)
    end

    test "of the client refuses a key the device confirmed before it", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      attrs = %{name: "confirmed-then-revoked"}

      confirmed =
        device
        |> verified!()
        |> Sanctum.TestContext.confirmed(:credential_issuance, key_change(attrs))

      assert {:ok, %{standing: "revoked"}} = revoke!(session_ctx, device.client_id)

      # Refused before its confirmation is spent, as the device no longer
      # stands; a revocation landing after that check is the issuance's to
      # refuse (`Sanctum.IssuanceRaceTest`).
      assert {:error, :not_standing} = Sanctum.ApiKey.create(confirmed, attrs)
      refute Arca.Repo.exists?(from(k in ApiKey, where: k.name == "confirmed-then-revoked"))
    end

    test "of the certificate the context stands under refuses, though the client stands", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      ctx = verified!(device)
      actor = Prima.Actor.in_athanor(ctx.athanor_id)
      {:ok, certificate} = Arca.DeviceCertificates.current(actor, device.client_id)
      {:ok, %{status: "revoked"}} = Arca.DeviceCertificates.revoke(actor, certificate.id)

      assert {{:error, :not_standing}, attrs} = mint(ctx)
      refute minted?(attrs)
    end

    test "a certificate expired on the database's clock refuses; one of another expiry is not the context's",
         %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      ctx = verified!(device)
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:millisecond)

      # The certificate the context stands under, expired: the context's
      # deadline and the row agree, and the database's clock is past both.
      {1, _} =
        Arca.Repo.update_all(
          from(c in DeviceCertificate, where: c.paired_client_id == ^device.client_id),
          set: [expires_at: usec(past)]
        )

      assert {{:error, :not_standing}, expired} = mint(%{ctx | credential_deadline: past})
      refute minted?(expired)

      # The context still names its own expiry, which no certificate of the
      # client has any more: a later certificate is not the one it was
      # established under.
      assert {{:error, :not_standing}, other} = mint(ctx)
      refute minted?(other)
    end

    test "the person's standing still answers first: a denied person issues nothing", %{
      session_ctx: session_ctx,
      user: user
    } do
      ctx = session_ctx |> pair!() |> verified!()
      {:ok, _} = Users.deny(user)

      assert {{:error, :unauthenticated}, attrs} = mint(ctx)
      refute minted?(attrs)
    end
  end

  # ---------------------------------------------------------------------------
  # A device context with no client binding
  # ---------------------------------------------------------------------------

  describe "a device context without its own binding" do
    test "is refused, never taken for a sign-in or a session", %{session_ctx: session_ctx} do
      ctx = session_ctx |> pair!() |> verified!()
      binding = ctx.credential_binding

      for {what, forged} <- [
            no_binding: %{ctx | credential_binding: nil},
            a_sign_in_binding: %{
              ctx
              | credential_binding: %{binding | source_kind: :identity, source_id: nil}
            },
            a_session_binding: %{
              ctx
              | session_token_hash: session_ctx.session_token_hash,
                credential_binding: session_ctx.credential_binding
            },
            another_client: %{ctx | client_id: "pcl_another"},
            no_certificate: %{ctx | credential_deadline: nil},
            no_seat: %{ctx | credential_binding: %{binding | focus_basis: :key}}
          ] do
        assert Issuance.expectation(forged, []) == {:error, :missing_generation}, inspect(what)
        assert {{:error, :missing_generation}, attrs} = mint(forged)
        refute minted?(attrs), inspect(what)
      end
    end

    test "takes no generation snapshot in place of its binding", %{session_ctx: session_ctx} do
      ctx = session_ctx |> pair!() |> verified!()
      snapshot = Sanctum.TestContext.snapshot!(ctx)

      assert Issuance.expectation(%{ctx | credential_binding: nil}, generation_snapshot: snapshot) ==
               {:error, :missing_generation}

      assert {:ok, %{source: {:device, _client, _deadline}}} =
               Issuance.expectation(ctx, generation_snapshot: snapshot)
    end

    test "a device's binding on another context names no source", %{session_ctx: session_ctx} do
      ctx = session_ctx |> pair!() |> verified!()

      forged = %{session_ctx | credential_binding: ctx.credential_binding}
      assert Issuance.expectation(forged, []) == {:error, :missing_generation}
    end

    # Each tool answers it as the standing refusal it is, in the one
    # sentence every credential tool gives it (`Sanctum.Issuance`), and
    # logs nothing.
    test "the key tool answers it in the standing refusal's sentence, logging nothing", %{
      session_ctx: session_ctx
    } do
      unbound = %{verified!(pair!(session_ctx)) | credential_binding: nil}

      {answer, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Sanctum.TestContext.confirming(
            unbound,
            &Sanctum.Providers.Key.handle(&1, %{"action" => "create", "name" => "unbound-key"})
          )
        end)

      assert answer == {:error, "This session cannot issue a credential; sign in again"}
      refute log =~ "Sanctum.Providers.Key"
      refute Arca.Repo.exists?(from(k in ApiKey, where: k.name == "unbound-key"))
    end

    test "the webhook tool answers it in the standing refusal's sentence, logging nothing", %{
      session_ctx: session_ctx
    } do
      ctx = verified!(pair!(session_ctx))
      before = hook!(ctx, "unbound-hook")
      unbound = %{ctx | credential_binding: nil}

      {answer, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Sanctum.Providers.Webhook.handle(unbound, %{
            "action" => "rotate",
            "name" => "unbound-hook"
          })
        end)

      assert answer == {:error, "This session cannot issue a credential; sign in again"}
      refute log =~ "Sanctum.Providers.Webhook"

      assert Arca.Repo.get!(Arca.Schemas.Webhook, before.id).secret_encrypted ==
               before.secret_encrypted
    end

    test "the vault tool answers it in the standing refusal's sentence, never as unavailable", %{
      session_ctx: session_ctx
    } do
      ctx = verified!(pair!(session_ctx))
      unbound = %{ctx | credential_binding: nil}

      args = %{
        "action" => "create",
        "name" => "unbound-entry",
        "kind" => "api_key",
        "fields" => %{"token" => "t-1"}
      }

      {answer, log} =
        ExUnit.CaptureLog.with_log(fn -> Sanctum.Providers.Vault.handle(unbound, args) end)

      assert answer == {:error, "This session cannot issue a credential; sign in again"}
      refute log =~ "Sanctum.Providers.Vault"

      assert {:error, :not_found} =
               Arca.VaultStorage.get_by_name(Context.actor(ctx), "unbound-entry")
    end
  end

  # ---------------------------------------------------------------------------
  # Sessions and keys
  # ---------------------------------------------------------------------------

  describe "a session's or a key's issuance" do
    test "is unchanged: its source is its own credential, and it names no identity", %{
      session_ctx: session_ctx
    } do
      assert {:ok, expectation} = Issuance.expectation(session_ctx, [])
      assert expectation.source == {:session, session_ctx.session_token_hash}
      assert expectation.identity == nil

      assert Issuance.lock(expectation) |> Map.keys() |> Enum.sort() ==
               [:athanor_id, :membership_id, :source, :user_id]

      attrs = %{name: "from-the-session"}

      confirmed =
        Sanctum.TestContext.confirmed(session_ctx, :credential_issuance, key_change(attrs))

      assert {:ok, %{api_key: raw}} = Sanctum.ApiKey.create(confirmed, attrs)

      {:ok, key_ctx} = Sanctum.Caller.establish({:api_key, raw}, client_ip: @source)
      assert {:ok, %{source: {:api_key, id}, identity: nil}} = Issuance.expectation(key_ctx, [])
      assert id == key_ctx.api_key_id

      # A session's issuance refuses a retired session as it did.
      :ok = Sanctum.Session.destroy_by_hash(session_ctx.session_token_hash)
      assert {{:error, :unauthenticated}, retired} = mint(session_ctx)
      refute minted?(retired)
    end
  end

  # ---------------------------------------------------------------------------
  # A device's other credential writes, revoked inside their window
  # ---------------------------------------------------------------------------

  # A handler on the repo's statements and on a confirmation's consumption:
  # the process that put `{test, point}` under `:window_hold` is held at the
  # first event `point` names, until the test releases it. Both points
  # below fire outside any transaction, so the test can write meanwhile.
  @doc false
  def hold(event, _measurements, metadata, _config) do
    with {test, point} <- Process.get(:window_hold),
         true <- point.(event, metadata) do
      Process.delete(:window_hold)
      send(test, {:window_held, self()})

      receive do
        :release -> :ok
      end
    end

    :ok
  end

  # Once the confirmation the write needs is consumed: the request was
  # verified and confirmed, and the write's transaction has not begun.
  defp confirmed_point([:cyfr, :sanctum, :confirmation, :consumed], _metadata), do: true
  defp confirmed_point(_event, _metadata), do: false

  # Once a pairing's confirmation was checked (`Sanctum.Consent.Authz.check/3`
  # reads its record last), before the invitation's transaction, which
  # consumes it.
  defp checked_point([:arca, :repo, :query], %{source: "pending_confirmations"}), do: true
  defp checked_point(_event, _metadata), do: false

  # `write`, run by a task held at `point`, where the person revokes the
  # device under their session before the task goes on.
  defp revoked_in_window(session_ctx, client_id, point, write) do
    in_window(point, write, fn ->
      assert {:ok, %{standing: "revoked"}} = revoke!(session_ctx, client_id)
    end)
  end

  # `write`, run by a task held at `point`, where the test runs `during`
  # before the task goes on.
  defp in_window(point, write, during) do
    test = self()
    handler = "issuance-window-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [[:arca, :repo, :query], [:cyfr, :sanctum, :confirmation, :consumed]],
        &__MODULE__.hold/4,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    task =
      Task.async(fn ->
        Process.put(:window_hold, {test, point})
        write.()
      end)

    assert_receive {:window_held, held}, 5_000
    during.()
    send(held, :release)
    Task.await(task, 25_000)
  end

  defp statements(acc \\ []) do
    receive do
      {:statement, source, query} -> statements([{source, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp hook!(ctx, name) do
    {:ok, sealed} =
      Sanctum.Cipher.encrypt(
        "whsec_" <> name,
        Sanctum.CipherAAD.webhook_secret(ctx.athanor_id, name)
      )

    :ok =
      Arca.WebhookStorage.create_webhook(%{
        name: name,
        slug: "wh_" <> name <> "_#{System.unique_integer([:positive])}",
        target_ref: "reagent:local.hook-target:1.0.0",
        secret_encrypted: sealed,
        athanor_id: ctx.athanor_id,
        profile_id: "prof_fixture",
        created_by: ctx.user_id
      })

    Arca.Repo.one!(
      from(w in Arca.Schemas.Webhook,
        where: w.athanor_id == ^ctx.athanor_id and w.name == ^name
      )
    )
  end

  describe "a revocation inside a device's write window" do
    test "refuses a webhook secret's rotation: the secret stands as it was", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      ctx = verified!(device)
      before = hook!(ctx, "glass-hook")

      confirmed =
        Sanctum.TestContext.confirmed(ctx, :credential_issuance, %{
          operation: "webhook.rotate",
          arguments: %{name: "glass-hook"},
          resource: "glass-hook"
        })

      assert {:error, :not_standing} =
               revoked_in_window(session_ctx, device.client_id, &confirmed_point/2, fn ->
                 Sanctum.Webhook.rotate(confirmed, "glass-hook")
               end)

      after_window = Arca.Repo.get!(Arca.Schemas.Webhook, before.id)
      assert after_window.secret_encrypted == before.secret_encrypted
      assert {after_window.previous_secret_encrypted, after_window.rotated_at} == {nil, nil}
    end

    test "refuses a vault entry's creation: no entry is written", %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      ctx = verified!(device)
      params = %{name: "glass-entry", kind: "api_key", fields: %{"token" => "t-1"}}

      confirmed =
        Sanctum.TestContext.confirmed(ctx, :credential_entry, %{
          operation: "vault.create",
          arguments: params,
          resource: "glass-entry"
        })

      assert {:error, :not_standing} =
               revoked_in_window(session_ctx, device.client_id, &confirmed_point/2, fn ->
                 Sanctum.Vault.create(confirmed, params)
               end)

      assert {:error, :not_found} =
               Arca.VaultStorage.get_by_name(Context.actor(ctx), "glass-entry")
    end

    test "refuses a vault entry's rotation: its material stays at its revision", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      ctx = verified!(device)

      {:ok, entry} =
        Sanctum.TestContext.create_vault(session_ctx, %{
          name: "glass-rotated",
          kind: "api_key",
          fields: %{"token" => "t-1"}
        })

      {:ok, stored} = Arca.VaultStorage.get(Context.actor(ctx), entry.id)

      params = %{
        id: entry.id,
        fields: %{"token" => "t-2"},
        expected_payload_rev: stored.payload_rev
      }

      confirmed =
        Sanctum.TestContext.confirmed(ctx, :credential_entry, %{
          operation: "vault.rotate",
          arguments: params,
          resource: "glass-rotated"
        })

      assert {:error, :not_standing} =
               revoked_in_window(session_ctx, device.client_id, &confirmed_point/2, fn ->
                 Sanctum.Vault.rotate(confirmed, params)
               end)

      assert {:ok, unchanged} = Arca.VaultStorage.get(Context.actor(ctx), entry.id)

      assert {unchanged.payload_rev, unchanged.sealed_payload} ==
               {stored.payload_rev, stored.sealed_payload}
    end

    test "refuses a pairing invitation the device opens: none is opened", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      ctx = verified!(device)
      count = fn -> Arca.Repo.aggregate(Arca.Schemas.PairingInvitation, :count) end
      opened = count.()

      confirmed =
        Sanctum.TestContext.confirmed(ctx, :device_pairing, Pairing.invitation_change())

      assert {:error, :not_standing} =
               revoked_in_window(session_ctx, device.client_id, &checked_point/2, fn ->
                 Pairing.begin(confirmed, %{})
               end)

      assert count.() == opened
    end

    test "an invitation the device opens holds its client and certificate in its transaction", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)

      confirmed =
        device
        |> verified!()
        |> Sanctum.TestContext.confirmed(:device_pairing, Pairing.invitation_change())

      test = self()
      handler = "issuance-begin-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == test and is_binary(meta[:source]),
              do: send(test, {:statement, meta[:source], meta[:query]})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      assert {:ok, %{client_id: "pcl_" <> _}} = Pairing.begin(confirmed, %{})
      :telemetry.detach(handler)

      statements = statements()
      sources = Enum.map(statements, &elem(&1, 0))
      opened = Enum.find_index(sources, &(&1 == "pairing_invitations"))
      locked = Enum.find_index(sources, &(&1 == "device_certificates"))

      # The client's certificate is read only by the invitation's own
      # standing locks, after the seat and before the invitation is written.
      assert is_integer(locked) and is_integer(opened) and locked < opened, inspect(sources)
      assert Enum.at(sources, locked - 1) == "paired_clients"
      assert Enum.at(sources, locked - 2) == "memberships"

      if Arca.Repo.adapter() == Ecto.Adapters.Postgres do
        for at <- [locked - 1, locked] do
          {source, query} = Enum.at(statements, at)
          assert query =~ "FOR UPDATE", "#{source} is not locked: #{query}"
        end
      end
    end

    test "refuses a key through the key tool with the refusal's own sentence, logging nothing", %{
      session_ctx: session_ctx
    } do
      device = pair!(session_ctx)
      ctx = verified!(device)

      {answer, log} =
        ExUnit.CaptureLog.with_log(fn ->
          revoked_in_window(session_ctx, device.client_id, &confirmed_point/2, fn ->
            Sanctum.TestContext.confirming(
              ctx,
              &Sanctum.Providers.Key.handle(&1, %{"action" => "create", "name" => "glass-tool"})
            )
          end)
        end)

      assert answer == {:error, Prima.Refusal.message(:not_standing)}
      refute log =~ "Sanctum.Providers.Key"
      refute Arca.Repo.exists?(from(k in ApiKey, where: k.name == "glass-tool"))
    end

    test "refuses a rotation through the webhook tool with the refusal's own sentence, logging nothing",
         %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      ctx = verified!(device)
      before = hook!(ctx, "glass-tool-hook")

      {answer, log} =
        ExUnit.CaptureLog.with_log(fn ->
          revoked_in_window(session_ctx, device.client_id, &confirmed_point/2, fn ->
            Sanctum.TestContext.confirming(
              ctx,
              &Sanctum.Providers.Webhook.handle(&1, %{
                "action" => "rotate",
                "name" => "glass-tool-hook"
              })
            )
          end)
        end)

      assert answer == {:error, Prima.Refusal.message(:not_standing)}
      refute log =~ "Sanctum.Providers.Webhook"

      assert Arca.Repo.get!(Arca.Schemas.Webhook, before.id).secret_encrypted ==
               before.secret_encrypted
    end

    test "refuses an entry through the vault tool with the refusal's own sentence, never as unavailable",
         %{session_ctx: session_ctx} do
      device = pair!(session_ctx)
      ctx = verified!(device)

      args = %{
        "action" => "create",
        "name" => "glass-tool-entry",
        "kind" => "api_key",
        "fields" => %{"token" => "t-1"}
      }

      {answer, log} =
        ExUnit.CaptureLog.with_log(fn ->
          revoked_in_window(session_ctx, device.client_id, &confirmed_point/2, fn ->
            Sanctum.TestContext.confirming(ctx, &Sanctum.Providers.Vault.handle(&1, args))
          end)
        end)

      assert answer == {:error, Prima.Refusal.message(:not_standing)}
      refute log =~ "Sanctum.Providers.Vault"

      assert {:error, :not_found} =
               Arca.VaultStorage.get_by_name(Context.actor(ctx), "glass-tool-entry")
    end
  end

  # ---------------------------------------------------------------------------
  # A person whose keys are at another home
  # ---------------------------------------------------------------------------

  describe "a device of a person whose keys are at another home" do
    setup %{session_ctx: session_ctx, user: user, athanor: athanor} do
      alias Sanctum.Test.DirectoryServer

      tls = DirectoryServer.tls()
      DirectoryServer.listen!()
      DirectoryServer.seam!(tls)

      on_exit(fn ->
        Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
      end)

      directory = DirectoryServer.start!(tls)
      identity = DirectoryServer.identity!(directory.dir, directory.url)

      # Paired at this home under their home's certificate: the invitation
      # opened under the person's proof here, then they are remote.
      {:ok, invitation} = begin!(session_ctx)
      :ok = DirectoryServer.remote_person!(user.id, identity)
      {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)
      certificate = remote_certificate(identity, invitation.client_id, device_key, athanor)
      glass = Context.build(%{authenticated: false, client_ip: @source})
      submission = %{device_key: device_key, certificate: certificate}

      {:ok, %{challenge: challenge}} =
        Pairing.complete(glass, invitation.invitation_secret, submission)

      {:ok, %{client_id: client_id}} =
        Pairing.complete(
          glass,
          invitation.invitation_secret,
          Map.put(submission, :proof, Proof.sign(challenge, private))
        )

      device = %{
        client_id: client_id,
        certificate: certificate,
        device_key: device_key,
        private: private
      }

      %{directory: directory, identity: identity, device: device}
    end

    defp remote_certificate(identity, client_id, device_key, athanor) do
      now = System.os_time(:millisecond)

      {:ok, certificate} =
        DeviceCert.new(
          device_key: device_key,
          client_id: client_id,
          subject: %{
            kind: :identity,
            identifier: identity.identifier,
            key_epoch: Sanctum.Test.DirectoryServer.key_epoch(identity)
          },
          issuer: "https://a.example",
          audience: Person.home(),
          athanor: athanor.id,
          not_before: now,
          expires_at: now + 3_600_000
        )

      DeviceCert.sign(certificate, elem(identity.live, 1))
    end

    test "carries the identity row it was resolved by, and mints while that row names them", %{
      device: device,
      identity: identity,
      user: user
    } do
      ctx = verified!(device)
      expected = %{user_id: user.id, provenance: "remote", identifier: identity.identifier}

      assert ctx.credential_binding.identity == expected
      assert {:ok, %{identity: ^expected}} = Issuance.expectation(ctx, [])

      assert {:ok, attrs} = mint(ctx)
      assert minted?(attrs)
    end

    test "refuses once the identity row no longer names the person", %{
      device: device,
      user: user
    } do
      ctx = verified!(device)
      another = "per_" <> Prima.Digest.sha256_hex("another-#{System.unique_integer()}")

      {1, _} =
        Arca.Repo.update_all(from(p in PersonIdentity, where: p.user_id == ^user.id),
          set: [identifier: another]
        )

      assert {{:error, :not_standing}, renamed} = mint(ctx)
      refute minted?(renamed)

      {1, _} = Arca.Repo.delete_all(from(p in PersonIdentity, where: p.user_id == ^user.id))
      assert {{:error, :not_standing}, gone} = mint(ctx)
      refute minted?(gone)
    end

    test "a head that moved retired its certificate, and with it the issuance", %{
      device: device,
      directory: directory,
      identity: identity
    } do
      ctx = verified!(device)
      Sanctum.Test.DirectoryServer.rotate!(directory.dir, identity)
      {:ok, _} = Sanctum.IdentityFreshness.fresh!(identity.identifier)

      assert {{:error, :not_standing}, attrs} = mint(ctx)
      refute minted?(attrs)
    end

    # Their home certifies the glass again, rather than this home renewing
    # it (`devices-guide.md`): the glass connects here with the replacement,
    # which this home verifies against their head and keeps no row for. The
    # device stands, and nothing was revoked.
    test "a replacement certificate from their home, verified here, mints", %{
      device: device,
      identity: identity,
      athanor: athanor
    } do
      now = System.os_time(:millisecond)

      {:ok, unsigned} =
        DeviceCert.new(
          device_key: device.device_key,
          client_id: device.client_id,
          subject: %{
            kind: :identity,
            identifier: identity.identifier,
            key_epoch: Sanctum.Test.DirectoryServer.key_epoch(identity)
          },
          issuer: "https://a.example",
          audience: Person.home(),
          athanor: athanor.id,
          not_before: now,
          expires_at: now + 1_800_000
        )

      replacement = DeviceCert.sign(unsigned, elem(identity.live, 1))
      ctx = verified!(%{device | certificate: replacement})

      assert ctx.credential_deadline ==
               DateTime.from_unix!(replacement.expires_at, :millisecond)

      assert ctx.credential_binding.key_epoch == Sanctum.Test.DirectoryServer.key_epoch(identity)
      assert {:ok, attrs} = mint(ctx)
      assert minted?(attrs)
    end

    test "a head that moves inside the window refuses the issuance: nothing is minted", %{
      device: device,
      directory: directory,
      identity: identity
    } do
      ctx = verified!(device)

      # The request is held once its certificate was verified against the
      # head (`remote_subject/3`) and as its paired client is read; the head
      # moves there, through `Arca.DirectoryHeads.advance/4`.
      first_client_read = fn
        [:arca, :repo, :query], %{source: "paired_clients"} -> true
        _event, _metadata -> false
      end

      result =
        in_window(
          first_client_read,
          fn ->
            {:ok, verified} = DeviceCerts.verify_request(device.certificate, ctx, [])
            mint(verified)
          end,
          fn ->
            Sanctum.Test.DirectoryServer.rotate!(directory.dir, identity)
            {:ok, _moved} = Sanctum.IdentityFreshness.fresh!(identity.identifier)
          end
        )

      assert {{:error, :not_standing}, attrs} = result
      refute minted?(attrs)
    end

    test "a revoked client still refuses", %{device: device} do
      ctx = verified!(device)

      assert {:ok, %{standing: "revoked"}} =
               Arca.PairedClients.revoke(Prima.Actor.in_athanor(ctx.athanor_id), device.client_id)

      assert {{:error, :not_standing}, attrs} = mint(ctx)
      refute minted?(attrs)
    end
  end
end

defmodule Sanctum.IssuanceRaceTest do
  @moduledoc """
  A revocation of a paired client that commits inside a device's issuance
  transaction, after the request was verified and before the issuance
  reaches the client, refuses the issuance with `:not_standing` and
  nothing is minted. Two real connections, outside the sandbox: the
  issuance is held, by a handler on the repo's own statement events, at
  the last moment another writer can still commit before it reaches the
  client (on PostgreSQL once the person, the athanor and the seat are
  locked; on SQLite once its transaction has begun, before the one write
  lock), and the revocation commits there.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2, where: 2]

  alias Arca.Schemas.{
    ApiKey,
    Athanor,
    DeviceCertificate,
    ExternalIdentity,
    Membership,
    PairedClient,
    User
  }

  alias Ecto.Adapters.SQL.Sandbox
  alias Prima.DeviceCert
  alias Sanctum.{DeviceCerts, Issuance, Person}

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres

  setup do
    Arca.Cache.init()
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    user_id = Prima.UUID7.generate_id(Prima.PersonId.prefix())
    athanor_id = Prima.UUID7.generate_id("ath")
    client_id = Prima.UUID7.generate_id("pcl")
    {device_key, _private} = :crypto.generate_key(:eddsa, :ed25519)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(DeviceCertificate, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(PairedClient, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(ApiKey, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(Membership, athanor_id: ^athanor_id))
        Arca.Repo.delete_all(where(Membership, user_id: ^user_id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^user_id))
        Arca.Repo.delete_all(where(User, id: ^user_id))
        Arca.Repo.delete_all(where(Athanor, id: ^athanor_id))
      end)
    end)

    certificate = certificate!(user_id, athanor_id, client_id, device_key)

    ctx =
      unboxed(fn ->
        person!(user_id, athanor_id, n, now)
        paired!(user_id, athanor_id, client_id, device_key, certificate, now)

        # What `Sanctum.DeviceCerts` hands establish once a request under
        # the certificate verified: the rows it read for it.
        {:ok, client} = DeviceCerts.paired_client(athanor_id, user_id, client_id)
        {:ok, standing} = DeviceCerts.standing(user_id, athanor_id)

        {:ok, ctx} =
          Sanctum.Caller.establish_device(
            %{
              certificate: certificate,
              client: client,
              user: standing.user,
              athanor: standing.athanor,
              seat: standing.seat,
              platform_admin: standing.platform_admin
            },
            []
          )

        ctx
      end)

    {:ok, ctx: ctx, client_id: client_id, athanor_id: athanor_id}
  end

  defp person!(user_id, athanor_id, n, now) do
    {:ok, _} =
      Arca.Users.mint(
        Prima.Actor.system(),
        %{
          id: user_id,
          provider: "github",
          email: "race#{n}@example.com",
          email_verified: true,
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        },
        %{
          key: "github|https://github.com|race#{n}",
          provider: "github",
          issuer: "https://github.com",
          subject: "race#{n}",
          first_seen_at: now,
          last_seen_at: now
        }
      )

    {:ok, _} =
      Arca.Athanors.insert(Prima.Actor.system(), %{
        id: athanor_id,
        kind: "group",
        name: "Race #{n}",
        slug: "race-#{n}",
        created_by: user_id
      })

    {:ok, _} =
      Arca.Members.seat(Prima.Actor.in_athanor(athanor_id), %{user_id: user_id, added_by: "x"})
  end

  # The certificate the device stands under. Establishing a context checks
  # that the rows agree with it, not its signature: the verifier did that.
  defp certificate!(user_id, athanor_id, client_id, device_key) do
    now = System.os_time(:millisecond)
    {_public, signer} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, certificate} =
      DeviceCert.new(
        device_key: device_key,
        client_id: client_id,
        subject: %{kind: :local, user_id: user_id},
        issuer: Person.home(),
        audience: Person.home(),
        athanor: athanor_id,
        not_before: now,
        expires_at: now + 3_600_000
      )

    DeviceCert.sign(certificate, signer)
  end

  # The client and its certificate, as a pairing records them.
  defp paired!(user_id, athanor_id, client_id, device_key, certificate, now) do
    {1, _} =
      Arca.Repo.insert_all(PairedClient, [
        %{
          id: client_id,
          athanor_id: athanor_id,
          user_id: user_id,
          source_kind: "device_cert",
          source_id: client_id,
          device_public_key: device_key,
          standing: "active",
          inserted_at: now,
          updated_at: now
        }
      ])

    bytes = Prima.Identity.Encoding.jcs!(DeviceCert.encode(certificate))

    {1, _} =
      Arca.Repo.insert_all(DeviceCertificate, [
        %{
          id: Prima.UUID7.generate_id("dct"),
          athanor_id: athanor_id,
          paired_client_id: client_id,
          user_id: user_id,
          subject_kind: "local",
          device_public_key: device_key,
          issuing_home: certificate.issuer,
          audience_home: certificate.audience,
          not_before: usec(DateTime.from_unix!(certificate.not_before, :millisecond)),
          expires_at: usec(DateTime.from_unix!(certificate.expires_at, :millisecond)),
          certificate: bytes,
          digest: Prima.Digest.sha256(bytes),
          state: "active",
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}

  # A telemetry handler on every repo statement: the process that put
  # `{test, point}` under `:issuance_hold` is held at its first statement
  # `point` names, until the test releases it.
  @doc false
  def hold(_event, _measurements, metadata, _config) do
    with {test, point} <- Process.get(:issuance_hold),
         true <- point.(metadata) do
      Process.delete(:issuance_hold)
      send(test, {:issuance_held, self()})

      receive do
        :release -> :ok
      end
    end

    :ok
  end

  # Inside the issuance's transaction, the last moment another writer can
  # still commit before the issuance reaches the client.
  defp before_the_client(%{source: "memberships", query: query}),
    do: postgres?() and query =~ "FOR UPDATE"

  defp before_the_client(%{query: "begin"}), do: not postgres?()
  defp before_the_client(_metadata), do: false

  test "a revocation committing inside the issuance, before it reaches the client, refuses it", %{
    ctx: ctx,
    client_id: client_id,
    athanor_id: athanor_id
  } do
    test = self()
    handler = "issuance-race-hold-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.hold/4, nil)
    on_exit(fn -> :telemetry.detach(handler) end)

    # The request was verified: the context is the device's, standing.
    assert {:ok, expectation} = Issuance.expectation(ctx, [])
    assert {:device, ^client_id, _deadline} = expectation.source
    n = System.unique_integer([:positive])

    attrs = %{
      name: "raced-#{n}",
      key_hash: :crypto.hash(:sha256, "raced-#{n}"),
      key_prefix: "cyfr_sk_rc",
      type: "service",
      created_by: ctx.user_id,
      athanor_id: athanor_id
    }

    issuer =
      Task.async(fn ->
        Process.put(:issuance_hold, {test, &before_the_client/1})

        unboxed(fn ->
          Arca.ApiKeyStorage.create_key(attrs,
            lock: Issuance.lock(expectation),
            verify: Issuance.verify(expectation)
          )
        end)
      end)

    assert_receive {:issuance_held, holder}, 5_000

    # `pairing/revoke`'s own revocation, committed while the issuance is
    # held inside its transaction.
    assert {:ok, %{standing: "revoked"}} =
             unboxed(fn ->
               Arca.PairedClients.revoke(Prima.Actor.in_athanor(athanor_id), client_id)
             end)

    send(holder, :release)
    assert {:error, :not_standing} = Task.await(issuer, 25_000)

    refute unboxed(fn ->
             Arca.Repo.exists?(from(k in ApiKey, where: k.key_hash == ^attrs.key_hash))
           end)
  end
end
