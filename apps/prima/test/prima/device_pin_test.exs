# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.DevicePinTest do
  @moduledoc """
  The home-assisted PIN's wire as data (`tests/fixtures/device_pin.json`):
  the suite's names, the evaluator identifier, the `pin_reset` proof and
  every substitution of what it binds, the wait after each charged
  attempt, the count's sequences through `Prima.DevicePin.evaluate/2` and
  `reset/2`, and the exact requests and answers. The group arithmetic and
  RFC 9497's vectors are the evaluating side's (`Sanctum.DevicePinTest`).
  """

  use ExUnit.Case, async: true

  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.DevicePin
  alias Prima.Identity.Encoding

  @vectors Path.expand("../../../../tests/fixtures/device_pin.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp unb64(value) do
    {:ok, bytes} = Base.url_decode64(value, padding: false)
    bytes
  end

  defp tag({:error, reason}), do: tag(reason)
  defp tag({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp tag(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp count(map),
    do: %{
      attempts: map["attempts"],
      revision: map["revision"],
      next_allowed_at: map["next_allowed_at"]
    }

  test "the suite is the implementation's" do
    suite = vectors()["suite"]
    assert suite["name"] == DevicePin.suite()
    assert suite["mode"] == DevicePin.mode()
    assert Base.decode16!(suite["context_string"], case: :lower) == DevicePin.context_string()
    assert DevicePin.context_string() == "OPRFV1-" <> <<0>> <> "-ristretto255-SHA512"
    assert suite["element_bytes"] == DevicePin.element_bytes()
  end

  test "an evaluator is pev_ and 32 bytes, and nothing else is one" do
    v = vectors()["evaluator"]
    for id <- v["valid"], do: assert(DevicePin.evaluator?(id), id)
    for id <- v["invalid"], do: refute(DevicePin.evaluator?(id), id)

    assert DevicePin.evaluator_bytes() == v["bytes"]
    spelled = DevicePin.evaluator(:binary.copy(<<5>>, v["bytes"]))
    assert spelled in v["valid"]
    assert String.starts_with?(spelled, v["prefix"])
  end

  test "pin_reset takes exactly the binding, the freshness and the revision" do
    v = vectors()
    %{"pin_reset" => %{"fresh" => fresh, "fields" => fields}} = v["purpose_fields"]
    assert :pin_reset in Challenge.purposes()
    assert Challenge.fresh?(:pin_reset) == fresh
    assert Enum.map(Challenge.purpose_fields(:pin_reset), &Atom.to_string/1) == fields

    challenge = Map.delete(v["proofs"]["pin_reset"], "sig")

    assert Enum.sort(Map.keys(challenge)) ==
             Enum.sort(
               ~w(protocol purpose home athanor client_id device_key nonce expires_at) ++ fields
             )

    for field <- Map.keys(challenge) do
      assert {:error, {:missing_field, ^field}} = Challenge.decode(Map.delete(challenge, field))
    end

    assert {:error, {:unknown_field, "extra"}} = Challenge.decode(Map.put(challenge, "extra", 1))

    for bad <- [-1, 1.5, "1", nil, 9_007_199_254_740_992] do
      assert {:error, {:invalid_field, "revision"}} =
               Challenge.decode(Map.put(challenge, "revision", bad)),
             inspect(bad)
    end
  end

  test "the worked proof is device_1's signature over its exact challenge and reads back" do
    v = vectors()
    proof = v["proofs"]["pin_reset"]
    seed = unb64(v["keys"]["device_1"]["seed"])

    for {name, %{"seed" => seed, "public" => public}} <- v["keys"] do
      {derived, _private} = :crypto.generate_key(:eddsa, :ed25519, unb64(seed))
      assert Encoding.b64(derived) == public, name
    end

    assert {:ok, decoded} = Proof.decode(proof)
    assert Proof.encode(decoded) == proof
    assert Proof.encode(Proof.sign(decoded.challenge, seed)) == proof

    challenge = decoded.challenge

    assert {:ok, built} =
             Challenge.new(
               purpose: :pin_reset,
               home: challenge.home,
               athanor: challenge.athanor,
               client_id: challenge.client_id,
               device_key: challenge.device_key,
               nonce: challenge.nonce,
               now: challenge.expires_at - Challenge.lifetime_ms(),
               revision: challenge.revision
             )

    assert built == challenge
  end

  test "every reset proof is held to the evaluation the home holds, to its result" do
    for %{"name" => name, "held" => held, "proof" => proof, "now" => now} = vector <-
          vectors()["verify"] do
      held =
        if held do
          {:ok, challenge} = Challenge.decode(held)
          challenge
        end

      result = Proof.verify(proof, held, now)

      case vector do
        %{"result" => "ok"} ->
          assert result == :ok, name

        %{"error" => "challenge_mismatch", "field" => field} ->
          assert result == {:error, {:challenge_mismatch, String.to_existing_atom(field)}}, name

        %{"error" => error} ->
          assert tag(result) == error, name
      end
    end
  end

  test "the wait after each charged attempt, capped, and the count's ceiling" do
    v = vectors()["delay"]
    assert v["cap_ms"] == DevicePin.cap_ms()
    assert v["max_attempts"] == DevicePin.max_attempts()

    for %{"attempts" => attempts, "delay_ms" => delay} <- v["cases"] do
      assert DevicePin.delay_ms(attempts) == delay, "#{attempts}"
    end

    assert DevicePin.charged(DevicePin.max_attempts()) == DevicePin.max_attempts()
    assert DevicePin.allowed?(nil, 0)
    assert DevicePin.allowed?(5, 5)
    refute DevicePin.allowed?(5, 4)
  end

  test "every sequence of evaluations and resets leaves the count the fixture says" do
    for %{"name" => name, "start" => start, "steps" => steps} <- vectors()["accounting"] do
      Enum.reduce(steps, count(start), fn step, current ->
        expect = step["expect"]

        case {step, expect} do
          {%{"do" => "evaluate", "at" => at}, %{"result" => "charged"}} ->
            assert {:charged, next} = DevicePin.evaluate(current, at), name
            assert next == count(expect), name
            next

          {%{"do" => "evaluate", "at" => at}, %{"result" => "pin_wait", "next_allowed_at" => n}} ->
            assert DevicePin.evaluate(current, at) == {:wait, n}, name
            current

          {%{"do" => "reset", "revision" => revision}, %{"result" => "reset"}} ->
            assert {:reset, next} = DevicePin.reset(current, revision), name
            assert next == count(expect), name
            next

          {%{"do" => "reset", "revision" => revision}, %{"result" => "stale"}} ->
            assert DevicePin.reset(current, revision) == :stale, name
            assert current == count(expect), name
            current
        end
      end)
    end
  end

  test "an evaluation request is exactly its evaluator and one element" do
    v = vectors()
    [evaluator | _] = v["evaluator"]["valid"]
    blinded = Encoding.b64(:binary.copy(<<9>>, 32))
    request = %{"evaluator" => evaluator, "blinded" => blinded}

    assert v["exchange"]["evaluate"]["request"] == Enum.sort(Map.keys(request))

    assert DevicePin.decode_evaluate(request) ==
             {:ok, %{evaluator: evaluator, blinded: :binary.copy(<<9>>, 32)}}

    assert {:error, {:unknown_field, "extra"}} =
             DevicePin.decode_evaluate(Map.put(request, "extra", "x"))

    assert {:error, {:missing_field, "blinded"}} =
             DevicePin.decode_evaluate(Map.delete(request, "blinded"))

    for bad <- [
          [blinded, blinded],
          Encoding.b64(:binary.copy(<<9>>, 31)),
          Encoding.b64(:binary.copy(<<9>>, 64)),
          blinded <> "=",
          nil
        ] do
      assert {:error, {:invalid_field, "blinded"}} =
               DevicePin.decode_evaluate(%{request | "blinded" => bad}),
             inspect(bad)
    end

    for bad <- v["evaluator"]["invalid"] do
      assert {:error, {:invalid_field, "evaluator"}} =
               DevicePin.decode_evaluate(%{request | "evaluator" => bad}),
             bad
    end

    assert {:error, _} = DevicePin.decode_evaluate([request])
  end

  test "the answer carries the evaluated element and the reset challenge, read back" do
    v = vectors()
    {:ok, %Proof{challenge: reset}} = Proof.decode(v["proofs"]["pin_reset"])
    evaluated = :binary.copy(<<3>>, 32)
    answer = DevicePin.encode_evaluated(evaluated, reset)

    assert Enum.sort(Map.keys(answer)) == v["exchange"]["evaluate"]["answer"]
    assert DevicePin.decode_evaluated(answer) == {:ok, %{evaluated: evaluated, reset: reset}}

    {:ok, confirm} =
      Challenge.new(
        purpose: :confirm,
        home: reset.home,
        athanor: reset.athanor,
        client_id: reset.client_id,
        device_key: reset.device_key,
        nonce: reset.nonce,
        now: 0,
        ref: "cnr_" <> Encoding.b64(:binary.copy(<<4>>, 32)),
        digest: "sha256:" <> String.duplicate("0", 64)
      )

    assert {:error, {:invalid_field, "reset"}} =
             DevicePin.decode_evaluated(%{answer | "reset" => Challenge.encode(confirm)})
  end

  test "a reset request is exactly one pin_reset proof" do
    v = vectors()
    proof = v["proofs"]["pin_reset"]
    assert v["exchange"]["reset"]["request"] == ["proof"]
    assert {:ok, %Proof{}} = DevicePin.decode_reset(%{"proof" => proof})

    assert {:error, {:unknown_field, "evaluator"}} =
             DevicePin.decode_reset(%{"proof" => proof, "evaluator" => "x"})

    lock =
      "../../../../tests/fixtures/device_unlock.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["proofs", "lock"])

    assert {:error, {:invalid_field, "proof"}} = DevicePin.decode_reset(%{"proof" => lock})
    assert {:error, {:invalid_field, "proof"}} = DevicePin.decode_reset(%{"proof" => [proof]})
  end

  test "the wait's refusal names the instant, and the refusals are the exchange's" do
    refusals = vectors()["exchange"]["refusals"]
    body = DevicePin.wait(1_790_000_001_000)
    assert Enum.sort(Map.keys(body)) == Enum.sort(refusals["pin_wait"])
    assert body["error"] == "pin_wait"
    assert refusals["codes"]["pin_wait"] == 429
    assert refusals["codes"]["not_found"] == 404
    assert refusals["codes"]["bad_request"] == 400
  end
end
