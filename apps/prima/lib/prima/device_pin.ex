# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.DevicePin do
  @moduledoc """
  The wire of a six-digit PIN a home helps a remote software device keep
  (`tests/fixtures/device_pin.json`). The device blinds a hash of its PIN
  (RFC 9497's OPRF mode, ristretto255-SHA512), the home evaluates the
  blinded element under the evaluator key it keeps for that device and
  charges the attempt first, and the device unblinds the answer into the
  key that unwraps its signing key. The home never sees the PIN or
  anything that checks one.

    * **The evaluator** is named by an identifier the home draws at
      enrollment, `pev_` and 32 random bytes in unpadded base64url. It is
      no client id, and it reaches evaluation alone: no session, preview,
      confirmation or other operation.
    * **Evaluate**, `POST /device/pin/evaluate`, takes exactly
      `{evaluator, blinded}`, the blinded element its 32 encoded bytes.
      It answers `{evaluated, reset}`: the evaluated element, and the
      `pin_reset` challenge (`Prima.DeviceCert.Challenge`) whose nonce is
      this evaluation's and whose `revision` is the counter revision this
      evaluation's charge left.
    * **Reset**, `POST /device/pin/reset`, takes exactly `{proof}`: the
      device key's proof over that challenge, which clears the count only
      while the revision is still the current one.
    * **The wait.** After the `n`th charged attempt since the count was
      last cleared, the next evaluation waits `min(2^(n-1), 3600)`
      seconds (`delay_ms/1`), refused until then as `pin_wait` with the
      instant it is allowed again (`wait/1`); at that instant it is
      allowed. The count saturates at `max_attempts/0`, and there is no
      permanent lockout.

  Every binary is unpadded base64url and every instant integer Unix
  milliseconds (`Prima.Identity.Encoding`). A request holding a field it
  does not name, or missing one, is refused before anything is read.
  Whether a blinded element is a valid group element is the evaluating
  side's check, made with the group implementation.
  """

  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Encoding

  @suite "ristretto255-SHA512"
  @mode 0
  @element_bytes 32
  @evaluator_bytes 32
  @evaluator ~r/\Apev_[A-Za-z0-9_-]{43}\z/
  @cap_ms 3_600_000
  # The count saturates here: the largest a 32-bit signed integer column
  # holds on every adapter.
  @max_attempts 2_147_483_647

  @doc "The RFC 9497 ciphersuite."
  @spec suite() :: String.t()
  def suite, do: @suite

  @doc "The RFC 9497 mode: OPRF, no proof of the evaluation."
  @spec mode() :: 0
  def mode, do: @mode

  @doc ~S"""
  The RFC 9497 context string: `"OPRFV1-"`, the mode as one byte, `"-"`
  and the suite.
  """
  @spec context_string() :: binary()
  def context_string, do: "OPRFV1-" <> <<@mode>> <> "-" <> @suite

  @doc "The length of an encoded group element, in bytes."
  @spec element_bytes() :: pos_integer()
  def element_bytes, do: @element_bytes

  @doc "The longest wait between two evaluations, in milliseconds."
  @spec cap_ms() :: pos_integer()
  def cap_ms, do: @cap_ms

  @doc "The count's ceiling: a charge past it leaves it there."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc "A fresh evaluator identifier."
  @spec new_evaluator() :: String.t()
  def new_evaluator, do: "pev_" <> Encoding.b64(:crypto.strong_rand_bytes(@evaluator_bytes))

  @doc "Whether a value is an evaluator identifier."
  @spec evaluator?(term()) :: boolean()
  def evaluator?(value), do: is_binary(value) and Regex.match?(@evaluator, value)

  @doc """
  The wait after the `attempts`th charged attempt, in milliseconds:
  `min(2^(attempts-1), 3600)` seconds, none before any.
  """
  @spec delay_ms(non_neg_integer()) :: non_neg_integer()
  def delay_ms(0), do: 0
  def delay_ms(attempts) when is_integer(attempts) and attempts > 12, do: @cap_ms

  def delay_ms(attempts) when is_integer(attempts) and attempts > 0,
    do: min(Bitwise.bsl(1, attempts - 1) * 1_000, @cap_ms)

  @doc "The count after one more charged attempt, saturating at `max_attempts/0`."
  @spec charged(non_neg_integer()) :: pos_integer()
  def charged(attempts) when is_integer(attempts) and attempts >= 0,
    do: min(attempts + 1, @max_attempts)

  @doc """
  Whether an evaluation at `now` may proceed under the instant the last
  charge allowed the next one: at that instant it may, and with no such
  instant (none charged since the count was cleared) it always may.
  """
  @spec allowed?(non_neg_integer() | nil, non_neg_integer()) :: boolean()
  def allowed?(nil, _now), do: true
  def allowed?(next_allowed_at, now), do: now >= next_allowed_at

  @typedoc "An evaluator's count: attempts since it was last cleared, its revision and the wait."
  @type count :: %{
          attempts: non_neg_integer(),
          revision: non_neg_integer(),
          next_allowed_at: non_neg_integer() | nil
        }

  @doc """
  An evaluation at `now` against `count`: refused `{:wait, next_allowed_at}`
  before the wait is over, else charged, one more attempt, the revision
  advanced and the next wait set from `now`. Nothing is answered before the
  charged count is kept.
  """
  @spec evaluate(count(), non_neg_integer()) :: {:charged, count()} | {:wait, non_neg_integer()}
  def evaluate(%{attempts: attempts, revision: revision, next_allowed_at: next}, now)
      when is_integer(now) do
    if allowed?(next, now) do
      attempts = charged(attempts)

      {:charged,
       %{attempts: attempts, revision: revision + 1, next_allowed_at: now + delay_ms(attempts)}}
    else
      {:wait, next}
    end
  end

  @doc """
  A reset proven for `revision`: cleared, and the revision advanced, only
  while `revision` is the count's own, so a charge after the proven
  evaluation, or an earlier reset, leaves it `:stale`.
  """
  @spec reset(count(), non_neg_integer()) :: {:reset, count()} | :stale
  def reset(%{revision: revision}, revision),
    do: {:reset, %{attempts: 0, revision: revision + 1, next_allowed_at: nil}}

  def reset(%{}, _revision), do: :stale

  @doc "Read an evaluation request: exactly `evaluator` and one blinded element."
  @spec decode_evaluate(term()) ::
          {:ok, %{evaluator: String.t(), blinded: binary()}} | {:error, Encoding.reason()}
  def decode_evaluate(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.fields(map, ~w(evaluator blinded), []),
         {:ok, evaluator} <- Encoding.check(map, "evaluator", &evaluator?/1),
         {:ok, blinded} <- Encoding.binary(map, "blinded", @element_bytes),
         do: {:ok, %{evaluator: evaluator, blinded: blinded}}
  end

  def decode_evaluate(_value), do: {:error, {:invalid_field, "request"}}

  @doc "The evaluation's answer: the evaluated element and the reset challenge."
  @spec encode_evaluated(binary(), Challenge.t()) :: map()
  def encode_evaluated(evaluated, %Challenge{purpose: :pin_reset} = reset)
      when byte_size(evaluated) == @element_bytes,
      do: %{"evaluated" => Encoding.b64(evaluated), "reset" => Challenge.encode(reset)}

  @doc "Read the evaluation's answer, as the device does."
  @spec decode_evaluated(term()) ::
          {:ok, %{evaluated: binary(), reset: Challenge.t()}}
          | {:error, Encoding.reason() | :wrong_protocol}
  def decode_evaluated(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.fields(map, ~w(evaluated reset), []),
         {:ok, evaluated} <- Encoding.binary(map, "evaluated", @element_bytes),
         {:ok, %Challenge{purpose: :pin_reset} = reset} <- Challenge.decode(map["reset"]) do
      {:ok, %{evaluated: evaluated, reset: reset}}
    else
      {:ok, %Challenge{}} -> {:error, {:invalid_field, "reset"}}
      {:error, _reason} = error -> error
    end
  end

  def decode_evaluated(_value), do: {:error, {:invalid_field, "answer"}}

  @doc "Read a reset request: exactly one `pin_reset` proof."
  @spec decode_reset(term()) ::
          {:ok, Proof.t()} | {:error, Encoding.reason() | :wrong_protocol}
  def decode_reset(map) when is_map(map) and not is_struct(map) do
    with :ok <- Encoding.fields(map, ~w(proof), []),
         {:ok, %Proof{challenge: %Challenge{purpose: :pin_reset}} = proof} <-
           Proof.decode(map["proof"]) do
      {:ok, proof}
    else
      {:ok, %Proof{}} -> {:error, {:invalid_field, "proof"}}
      {:error, _reason} = error -> error
    end
  end

  def decode_reset(_value), do: {:error, {:invalid_field, "request"}}

  @doc "The `pin_wait` refusal's body: the instant the next evaluation is allowed."
  @spec wait(non_neg_integer()) :: map()
  def wait(next_allowed_at) when is_integer(next_allowed_at),
    do: %{"error" => "pin_wait", "next_allowed_at" => next_allowed_at}
end
