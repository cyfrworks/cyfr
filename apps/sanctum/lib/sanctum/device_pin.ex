# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.DevicePin do
  @moduledoc """
  A six-digit PIN this home helps a remote software device keep
  (`Prima.DevicePin`, `tests/fixtures/device_pin.json`). The device
  blinds a hash of its PIN; this home evaluates the blinded element under
  the device's evaluator key, RFC 9497's OPRF mode over ristretto255 with
  SHA-512 (libsodium's group operations), and charges the attempt first;
  the device unblinds the answer into the key that unwraps its signing
  key. The home never sees the PIN, nor anything that checks one: a copy
  of the device's disk guesses only through this home, one charged
  evaluation at a time.

  ## Enrollment and replacement

  `enroll/1` gives the calling device an evaluator: a protected software
  device of the person, named by the credential the call holds, never by
  an argument (its device channel's client, or the client its unlocked
  session was issued to). It is a sensitive change, `device_pin`
  (`Sanctum.Pairing`'s table), confirmed on this device or another of the
  person's (`Sanctum.Consent.Authz`), and an addition: once the person
  holds a passkey or a paired device, a re-authentication alone does not
  confirm it (`Sanctum.Pairing.addition_confirmed/1`). The evaluator key
  is a random scalar sealed at rest (`Sanctum.Cipher`, bound to the
  athanor, the evaluator and the client); the answer is `%{evaluator}`,
  the identifier the device keeps, which this home stores only as its
  SHA-256. A replacement stands beside the device's confirmed evaluator
  until its own first reset (`Arca.DevicePinEvaluators`), so a device that
  saved nothing still unlocks under the old.

  ## Evaluation

  `evaluate/1` takes `{evaluator, blinded}` from a locked device, with no
  session and no channel: the identifier locates the evaluator and grants
  nothing else. A request that is not exactly that, or whose element is
  not a valid ristretto255 encoding or is the identity, is `:bad_request`
  before anything is read. Then the attempt is charged and the
  evaluation's reset challenge drawn, committed before the element is
  evaluated (`Arca.DevicePinEvaluators.charge/2`): an answer always
  follows its own committed charge, and a lost answer is never refunded.
  An unknown identifier, a revoked device's and a suspended one's (a
  declared restore, until its person re-enables it) are one refusal,
  `:not_found`; inside the wait, `{:pin_wait, next_allowed_at}` charges
  nothing.

  ## Reset

  `reset/1` takes the device key's `pin_reset` proof over the reset
  challenge its last evaluation answered, after the device unwrapped its
  key: verified over the challenge rebuilt from the stored row and the
  client's stored key, on the database's clock, it clears the count and
  spends the challenge. A proof for an earlier evaluation, a stale
  revision, a replay, another device's key or binding, or an expired
  challenge is `:proof_refused` and changes nothing.

  The ingress meters both entries per source address (the router's
  pipeline); the per-device wait is this module's.
  """

  alias Prima.DeviceCert.{Challenge, Proof}
  alias Sanctum.{Cipher, CipherAAD, Context, Pairing, Person}
  alias Sanctum.Consent.Authz

  @identity <<0::256>>

  @typedoc "Why an evaluation or a reset is refused."
  @type refusal ::
          :bad_request
          | :not_found
          | {:pin_wait, non_neg_integer()}
          | :proof_refused
          | :unavailable

  # ===========================================================================
  # Enrollment
  # ===========================================================================

  @doc """
  Enroll an evaluator for the calling device (the module doc), under the
  `device_pin` confirmation. Answers `%{evaluator: identifier}`.

  Refusals: `:not_a_device` (no protected device's credential),
  `:not_software` (a chip holds the device's key), `:not_standing`, the
  consent signal and the confirmation's refusals, `:unavailable`.
  """
  @spec enroll(Context.t()) :: {:ok, %{evaluator: String.t()}} | {:error, term()}
  def enroll(%Context{} = ctx) do
    with {:ok, client} <- own_client(ctx),
         change = enroll_change(client),
         :ok <- Authz.check(ctx, :device_pin, change) do
      id = Prima.UUID7.generate_id("dpe")
      evaluator = Prima.DevicePin.new_evaluator()
      key = :libsodium_crypto_core_ristretto255.scalar_random()

      {:ok, sealed} =
        Cipher.encrypt(key, CipherAAD.device_pin_key(client.athanor_id, id, client.id))

      attrs = %{
        id: id,
        user_id: client.user_id,
        paired_client_id: client.id,
        identifier_digest: digest(evaluator),
        sealed_key: sealed
      }

      verify = fn ->
        with :ok <- Authz.consume(ctx, {:device_pin, change}),
             do: Pairing.addition_confirmed(ctx)
      end

      case Arca.DevicePinEvaluators.enroll(Context.actor(ctx), attrs, verify) do
        {:ok, _row} ->
          Authz.consumed(ctx)
          {:ok, %{evaluator: evaluator}}

        {:error, :not_found} ->
          {:error, :not_standing}

        {:error, reason}
        when reason in [:database_error, :not_owner, :confirmation_unconsumed, :no_athanor] ->
          {:error, :unavailable}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The device the call's own credential names: its device channel's
  # client, or the client the unlocked session was issued to.
  defp own_client(%Context{user_id: user_id, athanor_id: athanor_id} = ctx)
       when is_binary(user_id) and is_binary(athanor_id) and athanor_id != "" do
    with {:ok, client_id} <- credential_client(ctx) do
      case Arca.PairedClients.list(Context.actor(ctx), user_id: user_id, standing: :active) do
        {:ok, clients} ->
          case Enum.find(clients, &(&1.id == client_id)) do
            %{holder_kind: "software"} = client -> {:ok, client}
            %{holder_kind: "chip"} -> {:error, :not_software}
            _none -> {:error, :not_a_device}
          end

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  defp own_client(%Context{}), do: {:error, :not_a_device}

  defp credential_client(%Context{auth_method: :device, client_id: client_id})
       when is_binary(client_id),
       do: {:ok, client_id}

  defp credential_client(%Context{session_token_hash: hash}) when is_binary(hash) do
    case Arca.SessionStorage.get_session(hash) do
      {:ok, %{client_id: client_id}} when is_binary(client_id) -> {:ok, client_id}
      {:ok, _no_client} -> {:error, :not_a_device}
      {:error, :not_found} -> {:error, :not_a_device}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp credential_client(%Context{}), do: {:error, :not_a_device}

  # What confirming the enrollment approves: a PIN this home evaluates for
  # this one device, by its name.
  defp enroll_change(client) do
    name = client.display_name || client.id

    %{
      operation: "pin.enroll",
      arguments: %{"client_id" => client.id},
      resource: name,
      details: %{"device" => name}
    }
  end

  # ===========================================================================
  # Evaluation
  # ===========================================================================

  @doc """
  Evaluate one blinded element for a locked device (the module doc).
  Answers the wire's `{evaluated, reset}` map (`Prima.DevicePin.encode_evaluated/2`).
  """
  @spec evaluate(term()) :: {:ok, map()} | {:error, refusal()}
  def evaluate(params) do
    with {:ok, %{evaluator: evaluator, blinded: blinded}} <- request(params),
         :ok <- element(blinded),
         {:ok, charged} <- charge(evaluator),
         {:ok, key} <- unseal(charged.evaluator),
         {:ok, evaluated} <- multiply(key, blinded),
         {:ok, reset} <- reset_challenge(charged) do
      {:ok, Prima.DevicePin.encode_evaluated(evaluated, reset)}
    end
  end

  defp request(params) do
    case Prima.DevicePin.decode_evaluate(params) do
      {:ok, request} -> {:ok, request}
      {:error, _malformed} -> {:error, :bad_request}
    end
  end

  # RFC 9497's DeserializeElement: a canonical encoding of a group element
  # that is not the identity.
  defp element(@identity), do: {:error, :bad_request}

  defp element(blinded) do
    if :libsodium_crypto_core_ristretto255.is_valid_point(blinded) == 1,
      do: :ok,
      else: {:error, :bad_request}
  end

  defp charge(evaluator) do
    nonce = :crypto.strong_rand_bytes(Challenge.nonce_bytes())

    case Arca.DevicePinEvaluators.charge(digest(evaluator), nonce) do
      {:ok, charged} -> {:ok, charged}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:pin_wait, next_allowed_at}} -> {:error, {:pin_wait, next_allowed_at}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp unseal(%{sealed_key: sealed, athanor_id: athanor_id, id: id, paired_client_id: client_id}) do
    case Cipher.decrypt(sealed, CipherAAD.device_pin_key(athanor_id, id, client_id)) do
      {:ok, key} -> {:ok, key}
      {:error, _refused} -> {:error, :unavailable}
    end
  end

  defp multiply(key, blinded) do
    case :libsodium_crypto_scalarmult_ristretto255.crypto_scalarmult_ristretto255(key, blinded) do
      evaluated when is_binary(evaluated) -> {:ok, evaluated}
      _refused -> {:error, :bad_request}
    end
  end

  defp reset_challenge(%{evaluator: evaluator, client: client, now: now}) do
    case Challenge.new(
           purpose: :pin_reset,
           home: Person.home(),
           athanor: evaluator.athanor_id,
           client_id: evaluator.paired_client_id,
           device_key: client.device_public_key,
           nonce: evaluator.reset_nonce,
           now: now,
           revision: evaluator.revision
         ) do
      {:ok, challenge} -> {:ok, challenge}
      {:error, _malformed} -> {:error, :unavailable}
    end
  end

  # ===========================================================================
  # Reset
  # ===========================================================================

  @doc """
  Clear the count of the evaluator whose last evaluation drew the proof's
  challenge (the module doc). Answers `%{"reset" => true}`.
  """
  @spec reset(term()) :: {:ok, map()} | {:error, refusal()}
  def reset(params) do
    with {:ok, %Proof{challenge: presented} = proof} <- reset_request(params) do
      verify = fn evaluator, client, now -> proven(proof, evaluator, client, now) end

      case Arca.DevicePinEvaluators.reset(
             presented.athanor,
             presented.client_id,
             presented.nonce,
             verify
           ) do
        {:ok, _cleared} -> {:ok, %{"reset" => true}}
        {:error, reason} when reason in [:not_found, :proof_refused] -> {:error, :proof_refused}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  defp reset_request(params) do
    case Prima.DevicePin.decode_reset(params) do
      {:ok, proof} -> {:ok, proof}
      {:error, _malformed} -> {:error, :bad_request}
    end
  end

  # The challenge the evaluation answered, rebuilt from the stored row and
  # the client's stored key, and the proof held to it on the database's
  # clock.
  defp proven(proof, evaluator, client, now) do
    with {:ok, held} <-
           Challenge.new(
             purpose: :pin_reset,
             home: Person.home(),
             athanor: evaluator.athanor_id,
             client_id: evaluator.paired_client_id,
             device_key: client.device_public_key,
             nonce: evaluator.reset_nonce,
             now: evaluator.reset_expires_at - Challenge.lifetime_ms(),
             revision: evaluator.revision
           ),
         :ok <- Proof.verify(proof, held, now) do
      :ok
    else
      {:error, _refused} -> {:error, :proof_refused}
    end
  end

  defp digest(evaluator), do: :crypto.hash(:sha256, evaluator)
end
