# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DevicePinTest do
  @moduledoc """
  A remote software device's six-digit PIN (`Sanctum.DevicePin`), through
  its public entries, with the device's half played here by libsodium's
  ristretto255 and SHA-512 as RFC 9497 spells them
  (`tests/fixtures/device_pin.json`).

  The evaluation is RFC 9497's: the published vectors pass through this
  home's own evaluation. An evaluator is enrolled for the calling software
  device alone, under a `device_pin` confirmation it or another device of
  the person gives. Every evaluation is charged before it is answered,
  never refunded, waits `min(2^(n-1), 3600)` seconds after the nth
  charge, and a malformed or batched request is refused before any
  charge. A reset needs the device key's proof over the last evaluation's
  challenge, and an earlier success, a replay, another binding or an
  expired challenge clear nothing. A revoked device's evaluator is gone,
  a suspended one's refused until the person re-enables the device, each
  refused as an unknown one is. The identifier opens no session.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Sanctum.Test.Newcomers, only: [identity: 0]

  alias Arca.Schemas.{DevicePinEvaluator, PairedClient, User}
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Sanctum.{Context, DeviceCerts, DevicePin, DeviceUnlock}

  @token String.duplicate("6e", 32)
  @source "198.51.100.31"
  @vectors Path.expand("../../../../tests/fixtures/device_pin.json", __DIR__)

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Sanctum.Test.Newcomers.directory!()
    Arca.Repo.delete_all(User)
    :ok
  end

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  # ---------------------------------------------------------------------------
  # The device's half, RFC 9497's client over libsodium
  # ---------------------------------------------------------------------------

  alias :libsodium_crypto_core_ristretto255, as: Group
  alias :libsodium_crypto_scalarmult_ristretto255, as: Mult

  defp context_string, do: Prima.DevicePin.context_string()

  # RFC 9380's expand_message_xmd over SHA-512.
  defp expand(msg, dst, len) do
    dst_prime = dst <> <<byte_size(dst)>>
    ell = div(len + 63, 64)
    b0 = :crypto.hash(:sha512, <<0::1024>> <> msg <> <<len::16>> <> <<0>> <> dst_prime)
    b1 = :crypto.hash(:sha512, b0 <> <<1>> <> dst_prime)

    {blocks, _last} =
      Enum.map_reduce(2..ell//1, b1, fn i, prev ->
        b = :crypto.hash(:sha512, :crypto.exor(b0, prev) <> <<i>> <> dst_prime)
        {b, b}
      end)

    binary_part(IO.iodata_to_binary([b1 | blocks]), 0, len)
  end

  defp hash_to_group(input),
    do: Group.from_hash(expand(input, "HashToGroup-" <> context_string(), 64))

  defp hash_to_scalar(input, dst), do: Group.scalar_reduce(expand(input, dst, 64))

  defp derive_key(seed, info) do
    input = seed <> <<byte_size(info)::16>> <> info
    hash_to_scalar(input <> <<0>>, "DeriveKeyPair" <> context_string())
  end

  defp blind(input, blind), do: Mult.crypto_scalarmult_ristretto255(blind, hash_to_group(input))

  defp finalize(input, blind, evaluated) do
    unblinded = Mult.crypto_scalarmult_ristretto255(Group.scalar_invert(blind), evaluated)

    :crypto.hash(
      :sha512,
      <<byte_size(input)::16>> <> input <> <<byte_size(unblinded)::16>> <> unblinded <> "Finalize"
    )
  end

  # One unlock with `pin`: blinded, evaluated here, finalized; answers the
  # PRF output and the wire answer.
  defp unlock(evaluator, pin) do
    r = Group.scalar_random()

    case DevicePin.evaluate(%{"evaluator" => evaluator, "blinded" => b64(blind(pin, r))}, @source) do
      {:ok, answer} ->
        {:ok, %{evaluated: evaluated}} = Prima.DevicePin.decode_evaluated(answer)
        {:ok, finalize(pin, r, evaluated), answer}

      error ->
        error
    end
  end

  defp reset_proof(answer, private), do: %{"proof" => signed(answer["reset"], private)}

  defp signed(%{} = challenge_map, private) do
    {:ok, challenge} = Challenge.decode(challenge_map)
    Proof.encode(Proof.sign(challenge, private))
  end

  # ---------------------------------------------------------------------------
  # The person's devices
  # ---------------------------------------------------------------------------

  defp key, do: :crypto.generate_key(:eddsa, :ed25519)
  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
  defp unb64(value), do: Base.url_decode64!(value, padding: false)

  # The installation's first person, enrolled with a device whose key a
  # software holder keeps (`holder` "chip" for a chip's).
  defp enrolled!(holder \\ "software") do
    {public, private} = k = key()
    identity = identity()

    {:ok, %{challenge: challenge}} =
      DeviceUnlock.enrollment_challenge({:setup, @token}, %{
        "admission" => "setup",
        "device_key" => b64(public),
        "request_id" => identity.request_id,
        "holder_kind" => holder,
        "display_name" => "Garden Pi"
      })

    {:ok, answer} =
      DeviceUnlock.enroll({:setup, @token}, %{
        "proof" => Proof.encode(Proof.sign(challenge, private)),
        "name" => identity.name,
        "recovery_secret" => b64(identity.recovery_secret)
      })

    Map.put(answer, :key, k)
  end

  defp connected!(%{certificate: certificate, key: {_public, private}}) do
    {:ok, challenge} =
      Challenge.new(
        purpose: :connect,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: certificate.client_id,
        device_key: certificate.device_key,
        nonce: :crypto.strong_rand_bytes(32),
        now: System.system_time(:millisecond)
      )

    {:ok, ctx} =
      DeviceCerts.verify_connect(
        %{client_id: certificate.client_id, certificate: certificate, source: @source},
        Proof.sign(challenge, private),
        challenge
      )

    ctx
  end

  # The device confirms the pending change `secret` names with a proof of
  # its own key over the record's challenge.
  defp confirm_on!(ctx, secret, {_public, private}) do
    ref = Prima.Confirmation.ref(secret)

    {:ok, %{confirmations: [record]}} =
      Sanctum.Providers.Confirmation.handle(ctx, %{"action" => "pending", "request" => ref})

    {:ok, %{state: "confirmed"}} =
      Sanctum.Providers.Confirmation.handle(ctx, %{
        "action" => "confirm",
        "ref" => ref,
        "device_proof" => signed(record.challenge, private)
      })

    :ok
  end

  # An evaluator for the device of `ctx`, confirmed on the device itself.
  defp pin!(device, ctx) do
    {:error, {:confirmation_required, %{id: secret}}} = DevicePin.enroll(ctx)
    :ok = confirm_on!(ctx, secret, device.key)
    {:ok, %{evaluator: evaluator}} = DevicePin.enroll(%{ctx | confirmation_id: secret})
    evaluator
  end

  defp row(evaluator),
    do: Arca.Repo.get_by!(DevicePinEvaluator, identifier_digest: :crypto.hash(:sha256, evaluator))

  defp set!(evaluator, fields) do
    id = row(evaluator).id
    {1, _} = Arca.Repo.update_all(from(e in DevicePinEvaluator, where: e.id == ^id), set: fields)
  end

  # The wait over: the stored instant moved into the past.
  defp waited!(evaluator), do: set!(evaluator, next_allowed_at: 0)

  defp standing!(device, standing) do
    id = device.certificate.client_id

    {1, _} =
      Arca.Repo.update_all(from(p in PairedClient, where: p.id == ^id), set: [standing: standing])
  end

  defp device(_tags) do
    device = enrolled!()
    %{device: device, ctx: connected!(device)}
  end

  # ---------------------------------------------------------------------------
  # RFC 9497
  # ---------------------------------------------------------------------------

  describe "RFC 9497" do
    setup :device

    test "the published vectors pass through this home's evaluation", %{device: device, ctx: ctx} do
      v = vectors()
      rfc = v["rfc9497"]
      assert v["suite"]["name"] == Prima.DevicePin.suite()
      assert Base.decode16!(v["suite"]["context_string"], case: :lower) == context_string()

      sk = Base.decode16!(rfc["sk_s"], case: :lower)

      assert derive_key(
               Base.decode16!(rfc["seed"], case: :lower),
               Base.decode16!(rfc["key_info"], case: :lower)
             ) == sk

      evaluator = pin!(device, ctx)
      stored = row(evaluator)

      {:ok, sealed} =
        Sanctum.Cipher.encrypt(
          sk,
          Sanctum.CipherAAD.device_pin_key(stored.athanor_id, stored.id, stored.paired_client_id)
        )

      set!(evaluator, sealed_key: sealed)

      for vector <- rfc["vectors"] do
        input = Base.decode16!(vector["input"], case: :lower)
        r = Base.decode16!(vector["blind"], case: :lower)
        blinded = blind(input, r)
        assert Base.encode16(blinded, case: :lower) == vector["blinded_element"]

        waited!(evaluator)

        assert {:ok, answer} =
                 DevicePin.evaluate(
                   %{"evaluator" => evaluator, "blinded" => b64(blinded)},
                   @source
                 )

        evaluated = unb64(answer["evaluated"])
        assert Base.encode16(evaluated, case: :lower) == vector["evaluation_element"]
        assert Base.encode16(finalize(input, r, evaluated), case: :lower) == vector["output"]
      end
    end

    test "the refused elements are refused before any charge", %{device: device, ctx: ctx} do
      evaluator = pin!(device, ctx)

      for %{"name" => name, "blinded" => blinded} <- vectors()["elements"]["refused"] do
        assert {:error, :bad_request} =
                 DevicePin.evaluate(%{"evaluator" => evaluator, "blinded" => blinded}, @source),
               name
      end

      assert %{attempts: 0, revision: 0} = row(evaluator)
    end
  end

  # ---------------------------------------------------------------------------
  # Enrollment
  # ---------------------------------------------------------------------------

  describe "enroll" do
    setup :device

    test "asks a device_pin confirmation, and answers an evaluator once it is given",
         %{device: device, ctx: ctx} do
      assert {:error, {:confirmation_required, %{id: secret, operation: "pin.enroll"}}} =
               DevicePin.enroll(ctx)

      assert Arca.Repo.all(DevicePinEvaluator) == []
      :ok = confirm_on!(ctx, secret, device.key)
      assert {:ok, %{evaluator: evaluator}} = DevicePin.enroll(%{ctx | confirmation_id: secret})
      assert Prima.DevicePin.evaluator?(evaluator)

      stored = row(evaluator)
      assert stored.paired_client_id == ctx.client_id
      refute stored.sealed_key =~ evaluator
      # Consumed: the same secret enrolls nothing again.
      refute match?({:ok, _}, DevicePin.enroll(%{ctx | confirmation_id: secret}))
    end

    test "is an addition: a browser's session offers only a passkey to confirm it",
         %{ctx: ctx} do
      {:error, {:confirmation_required, %{id: secret}}} = DevicePin.enroll(ctx)

      browser =
        Context.build(
          user_id: ctx.user_id,
          provider: "github",
          athanor_id: ctx.athanor_id,
          permissions: Context.person_permissions(),
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, session} = Sanctum.TestContext.create_session(browser)
      {:ok, signed_in} = Sanctum.Caller.establish(session.token)

      {:ok, %{confirmations: [record]}} =
        Sanctum.Providers.Confirmation.handle(signed_in, %{
          "action" => "pending",
          "request" => Prima.Confirmation.ref(secret)
        })

      # Restricted: neither a fresh sign-in nor an emailed code, only a
      # passkey this person holds (they hold none) or a paired device.
      assert record.restricted
      assert record.methods -- ["passkey"] == []
    end

    test "the unlocked session of the device enrolls its own client", %{device: device, ctx: ctx} do
      {:ok, %{challenge: challenge}} = DeviceUnlock.unlock(ctx, %{})

      {:ok, %{ticket: ticket}} =
        DeviceUnlock.unlock(ctx, %{
          "proof" => signed(Challenge.encode(challenge), elem(device.key, 1))
        })

      {:ok, %{token: token}} = DeviceUnlock.redeem(ticket)
      {:ok, session} = Sanctum.Caller.establish(token)
      assert session.client_id == nil

      {:error, {:confirmation_required, %{id: secret}}} = DevicePin.enroll(session)
      :ok = confirm_on!(ctx, secret, device.key)

      assert {:ok, %{evaluator: evaluator}} =
               DevicePin.enroll(%{session | confirmation_id: secret})

      assert row(evaluator).paired_client_id == ctx.client_id
    end

    test "a replacement stands beside the old evaluator until its first reset, as the fixture orders",
         %{device: device, ctx: ctx} do
      for %{"name" => name, "steps" => steps} <- vectors()["replacement"] do
        Arca.Repo.delete_all(DevicePinEvaluator)
        {_public, private} = device.key

        Enum.reduce(steps, %{}, fn step, held ->
          case step do
            %{"do" => "enroll", "evaluator" => label} ->
              Map.put(held, label, pin!(device, ctx))

            %{"do" => "evaluate", "evaluator" => label, "expect" => expect} ->
              wait_over(held[label])

              case {unlock(held[label], "123456"), expect} do
                {{:ok, _output, answer}, "charged"} -> Map.put(held, {:answer, label}, answer)
                {{:error, :not_found}, "not_found"} -> held
                {other, _} -> flunk("#{name}: #{label} answered #{inspect(other)}")
              end

            %{"do" => "reset", "evaluator" => label, "expect" => "reset"} ->
              assert {:ok, %{"reset" => true}} =
                       DevicePin.reset(reset_proof(held[{:answer, label}], private), @source),
                     name

              held
          end
        end)
      end
    end
  end

  describe "a device without a software holder" do
    test "a chip's device and a browser's session enroll nothing" do
      chip = connected!(enrolled!("chip"))
      assert {:error, :not_software} = DevicePin.enroll(chip)

      browser =
        Context.build(
          user_id: chip.user_id,
          provider: "passkey",
          athanor_id: chip.athanor_id,
          permissions: Context.person_permissions(),
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, session} = Sanctum.TestContext.create_session(browser)
      {:ok, opener} = Sanctum.Caller.establish(session.token)
      assert {:error, :not_a_device} = DevicePin.enroll(opener)
    end
  end

  defp wait_over(evaluator) do
    case Arca.Repo.get_by(DevicePinEvaluator, identifier_digest: :crypto.hash(:sha256, evaluator)) do
      nil -> :ok
      _row -> waited!(evaluator)
    end
  end

  # ---------------------------------------------------------------------------
  # Evaluation, the wait and the reset
  # ---------------------------------------------------------------------------

  describe "evaluate" do
    setup :device

    setup %{device: device, ctx: ctx} do
      %{evaluator: pin!(device, ctx)}
    end

    test "one PIN answers one output, another another, and each answer was charged",
         %{evaluator: evaluator} do
      {:ok, first, answer} = unlock(evaluator, "123456")
      assert Enum.sort(Map.keys(answer)) == vectors()["exchange"]["evaluate"]["answer"]
      assert %{attempts: 1, revision: 1} = row(evaluator)

      waited!(evaluator)
      {:ok, again, _} = unlock(evaluator, "123456")
      waited!(evaluator)
      {:ok, other, _} = unlock(evaluator, "123457")

      assert first == again
      refute first == other
      assert %{attempts: 3, revision: 3} = row(evaluator)
    end

    test "a lost answer is no refund: the attempt stays charged", %{evaluator: evaluator} do
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          _answer = unlock(evaluator, "123456")
          send(parent, :evaluated)
          # The caller dies before anyone reads the answer.
          exit(:killed_after_answer)
        end)

      assert_receive :evaluated, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      assert %{attempts: 1, revision: 1} = row(evaluator)
      assert {:error, {:pin_wait, _}} = unlock(evaluator, "123456")
    end

    test "a request that is not exactly one element is refused before any charge",
         %{evaluator: evaluator} do
      blinded = b64(blind("123456", Group.scalar_random()))

      for bad <- [
            %{"evaluator" => evaluator, "blinded" => [blinded, blinded]},
            %{"evaluator" => evaluator, "blinded" => blinded, "blinded2" => blinded},
            %{"evaluator" => evaluator},
            %{"evaluator" => evaluator, "blinded" => blinded <> blinded},
            %{"evaluator" => "pcl_x", "blinded" => blinded},
            [%{"evaluator" => evaluator, "blinded" => blinded}],
            nil
          ] do
        assert {:error, :bad_request} = DevicePin.evaluate(bad, @source), inspect(bad)
      end

      assert %{attempts: 0, revision: 0} = row(evaluator)
    end

    test "inside the wait nothing is charged, and the wait doubles to its ceiling",
         %{evaluator: evaluator} do
      {:ok, _, _} = unlock(evaluator, "000000")
      %{next_allowed_at: next} = row(evaluator)
      assert {:error, {:pin_wait, ^next}} = unlock(evaluator, "000000")
      assert %{attempts: 1, revision: 1} = row(evaluator)

      for {before, wait_ms} <- [{1, 2_000}, {11, 2_048_000}, {12, 3_600_000}, {200, 3_600_000}] do
        set!(evaluator, attempts: before, next_allowed_at: 0)
        {:ok, _, _} = unlock(evaluator, "000000")
        %{attempts: attempts, next_allowed_at: next, reset_expires_at: expires} = row(evaluator)
        assert attempts == before + 1
        # The challenge expires a minute after the charge's instant.
        assert next - (expires - 60_000) == wait_ms, "after #{attempts}"
      end

      max = Prima.DevicePin.max_attempts()
      set!(evaluator, attempts: max - 1, next_allowed_at: 0)
      {:ok, _, _} = unlock(evaluator, "000000")
      assert row(evaluator).attempts == max
      set!(evaluator, next_allowed_at: 0)
      {:ok, _, _} = unlock(evaluator, "000000")
      assert row(evaluator).attempts == max
    end

    test "a source past 30 calls a minute is refused before anything is read, another is not",
         %{evaluator: evaluator} do
      for _ <- 1..30 do
        assert {:error, :bad_request} = DevicePin.evaluate(%{"x" => 1}, "203.0.113.9")
      end

      assert {:error, {:rate_limited, retry}} =
               DevicePin.evaluate(%{"evaluator" => evaluator, "blinded" => "x"}, "203.0.113.9")

      assert retry in 1..60
      # The reset is metered on its own.
      assert {:error, :bad_request} = DevicePin.reset(%{"proof" => %{}}, "203.0.113.9")
      assert {:ok, _, _} = unlock(evaluator, "123456")
    end

    test "evaluations at once are each charged, one answered and the rest told to wait",
         %{evaluator: evaluator} do
      results =
        1..6
        |> Enum.map(fn i -> Task.async(fn -> unlock(evaluator, "00000#{i}") end) end)
        |> Task.await_many(30_000)

      assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:pin_wait, _}}, &1)) == 5
      assert %{attempts: 1, revision: 1} = row(evaluator)
    end
  end

  describe "reset" do
    setup :device

    setup %{device: device, ctx: ctx} do
      %{evaluator: pin!(device, ctx)}
    end

    test "the device key's proof over the last evaluation clears the count once",
         %{device: device, evaluator: evaluator} do
      {_public, private} = device.key
      {:ok, _, first} = unlock(evaluator, "111111")
      waited!(evaluator)
      {:ok, _, second} = unlock(evaluator, "111111")

      # The earlier evaluation's success, arriving after the later charge.
      assert {:error, :proof_refused} = DevicePin.reset(reset_proof(first, private), @source)
      assert %{attempts: 2, revision: 2} = row(evaluator)

      assert {:ok, %{"reset" => true}} = DevicePin.reset(reset_proof(second, private), @source)
      assert %{attempts: 0, revision: 3, next_allowed_at: nil} = row(evaluator)

      # Replayed.
      assert {:error, :proof_refused} = DevicePin.reset(reset_proof(second, private), @source)
      assert %{revision: 3} = row(evaluator)

      # The count cleared, the next evaluation waits for nothing.
      assert {:ok, _, _} = unlock(evaluator, "111111")
    end

    test "another key, a substituted binding or an expired challenge clears nothing",
         %{device: device, evaluator: evaluator} do
      {_public, private} = device.key
      {:ok, _, answer} = unlock(evaluator, "222222")
      {_other, other_private} = key()

      assert {:error, :proof_refused} =
               DevicePin.reset(reset_proof(answer, other_private), @source)

      for {field, value} <- [
            {"revision", answer["reset"]["revision"] + 1},
            {"nonce", b64(:crypto.strong_rand_bytes(32))},
            {"home", "https://elsewhere.example"},
            {"athanor", "ath_elsewhere"},
            {"client_id", "pcl_elsewhere"}
          ] do
        forged = put_in(answer, ["reset", field], value)

        assert {:error, :proof_refused} = DevicePin.reset(reset_proof(forged, private), @source),
               field
      end

      assert {:error, :bad_request} = DevicePin.reset(%{"proof" => "x"}, @source)
      assert {:error, :bad_request} = DevicePin.reset(%{"proof" => answer["reset"]}, @source)

      set!(evaluator, reset_expires_at: System.system_time(:millisecond) - 1)
      assert {:error, :proof_refused} = DevicePin.reset(reset_proof(answer, private), @source)
      assert %{attempts: 1} = row(evaluator)
    end
  end

  # ---------------------------------------------------------------------------
  # Standing
  # ---------------------------------------------------------------------------

  describe "standing" do
    setup :device

    setup %{device: device, ctx: ctx} do
      %{evaluator: pin!(device, ctx)}
    end

    test "unknown, suspended and revoked are one refusal, and a re-enabled device evaluates again",
         %{device: device, ctx: ctx, evaluator: evaluator} do
      unknown = Prima.DevicePin.evaluator(:crypto.strong_rand_bytes(32))
      assert {:error, :not_found} = unlock(unknown, "123456")

      standing!(device, "suspended")
      assert {:error, :not_found} = unlock(evaluator, "123456")
      assert %{attempts: 0} = row(evaluator)

      # The person's recovery re-enables the device (`Arca.PairedClients.reenable/4`).
      {:ok, _} =
        Arca.PairedClients.reenable(Context.actor(ctx), ctx.user_id, ctx.client_id,
          verify: fn _row -> :ok end
        )

      assert {:ok, _, _} = unlock(evaluator, "123456")

      {:ok, _} = Arca.PairedClients.revoke(Context.actor(ctx), ctx.client_id)
      assert {:error, :not_found} = unlock(evaluator, "123456")
      assert Arca.Repo.all(DevicePinEvaluator) == []
    end

    test "a store that cannot read the count refuses and answers nothing", %{evaluator: evaluator} do
      Arca.Repo.query!("ALTER TABLE device_pin_evaluators RENAME TO device_pin_evaluators_gone")
      assert {:error, :unavailable} = unlock(evaluator, "123456")
    end

    test "the identifier opens no session and authenticates no call", %{evaluator: evaluator} do
      assert {:error, _} = Sanctum.Caller.establish(evaluator)
      assert {:error, _} = Sanctum.Session.load(evaluator)
      assert {:error, _} = DeviceUnlock.redeem(evaluator)
    end
  end

  test "another row, client or athanor cannot unseal an evaluator key" do
    device = enrolled!()
    ctx = connected!(device)
    evaluator = pin!(device, ctx)
    stored = row(evaluator)

    {:ok, scalar} =
      Sanctum.Cipher.decrypt(
        stored.sealed_key,
        Sanctum.CipherAAD.device_pin_key(stored.athanor_id, stored.id, stored.paired_client_id)
      )

    for {a, e, c} <- [
          {stored.athanor_id <> "_other", stored.id, stored.paired_client_id},
          {stored.athanor_id, stored.id <> "_other", stored.paired_client_id},
          {stored.athanor_id, stored.id, stored.paired_client_id <> "_other"}
        ] do
      assert {:error, _} =
               Sanctum.Cipher.decrypt(
                 stored.sealed_key,
                 Sanctum.CipherAAD.device_pin_key(a, e, c)
               )
    end

    assert byte_size(scalar) == 32
  end

  test "the cell source meter still refuses after this node's meter is cleared" do
    source = "203.0.113.219"

    for _ <- 1..30 do
      assert {:error, :bad_request} = DevicePin.evaluate(%{}, source)
      Prima.Test.RateLimiter.reset!()
    end

    assert {:error, {:rate_limited, _}} = DevicePin.evaluate(%{}, source)
  end
end
