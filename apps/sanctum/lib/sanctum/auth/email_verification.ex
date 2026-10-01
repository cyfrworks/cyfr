# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.EmailVerification do
  @moduledoc """
  The email-verification guard for the browser callback (`ueberauth_oidcc`).

  The device-flow path (`Sanctum.Auth.DeviceFlow.fetch_user_info/2`) applies
  its own per-provider rule directly on the userinfo JSON it fetches.

  Rule: reject a missing email; reject an explicitly unverified one. Generic
  OIDC issuers do not always emit `email_verified`, so its absence is
  accepted for `:oidcc`; any other provider must assert `true`.

  ## A one-time code for one confirmation

  A person's verified email can prove freshness for one pending
  confirmation (`Prima.Confirmation`): `send_code/2` draws a six-digit
  code, holds only its keyed digest on the record, and sends it to the
  address the person's `users` row holds as verified; `verify_code/3`
  confirms the record with proof `email_code` when the code matches. Both
  name the record by its public ref (`Prima.Confirmation.ref/1`). The
  code is bound to that record's ref, used once, and expires with it.

    * At most five guesses per confirmation: each is counted in a durable
      window as long as the record lives (`Arca.RequestRateWindows`), and
      five wrong ones cancel the record. A sixth guess finds it cancelled.
    * Sending again invalidates the earlier code and does not extend the
      record. Sends are bounded, three per confirmation and ten an hour
      per person.
    * The code, and the address, reach no log, error term or telemetry.

  Delivery is a transport's, configured as `:sanctum,
  :confirmation_code_transport`: a module whose `deliver/1` takes `%{to:,
  subject:, text:}`. This tree ships none, so a home without one answers
  `:email_unavailable` and the method is not offered; the suite
  configures a capture sink.
  """

  alias Prima.Identity.Encoding
  alias Sanctum.Consent.Authz
  alias Sanctum.Context

  @type result :: :ok | {:error, :missing_email | :email_not_verified}
  @type claim :: true | false | :unknown

  @guesses 5
  @sends_per_confirmation 3
  @sends_per_person 10
  @person_window_ms 3_600_000
  # A confirmation's own windows are as wide as any record lives
  # (`confirmation_seconds` is at most an hour); a window's width is part
  # of what it counts, so it never follows the record's remaining life.
  @record_window_ms 3_600_000
  @code_space 1_000_000

  @doc """
  Whether a code can reach the person `user_id`: a transport is configured
  and their `users` row holds a verified email.
  """
  @spec code_available?(String.t()) :: boolean()
  def code_available?(user_id) when is_binary(user_id) do
    not is_nil(transport()) and match?({:ok, _email}, verified_email(user_id))
  end

  @doc """
  Send a one-time code for the pending confirmation `ref` of the
  context's own person, in the context's athanor, replacing any earlier
  one. Answers `%{method: "email", expires_at:}`, never the code.

  Refusals: `:email_unavailable` (no transport, or no verified email),
  `{:not_found, "confirmation", ref}`, `:not_pending`, `{:rate_limited,
  seconds}`, `:unavailable`.
  """
  @spec send_code(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def send_code(%Context{} = ctx, ref) when is_binary(ref) do
    actor = Context.actor(ctx)

    with {:ok, user_id} <- confirming_person(ctx),
         {:ok, transport} <- configured_transport(),
         {:ok, email} <- verified_email(user_id),
         {:ok, row} <- pending_record(actor, ref, user_id),
         :ok <-
           claim(:confirmation_code_send, row.ref, @sends_per_confirmation, @record_window_ms),
         :ok <-
           claim(:confirmation_code_send_person, user_id, @sends_per_person, @person_window_ms) do
      code = draw()

      case Arca.PendingConfirmations.put_challenge(actor, row.ref, %{
             email_code_hash: code_hash(row.ref, code)
           }) do
        {:ok, held} ->
          deliver(transport, email, code, held)

        {:error, :not_pending} ->
          {:error, :not_pending}

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  @doc """
  Confirm the pending confirmation `ref` of the context's own person with
  `code`, the one `send_code/2` sent for it, with proof `email_code`,
  naming the paired client `ctx.client_id` names, if any. Answers the
  confirmed record's `%{ref:, state:, expires_at:}`.

  Refusals: `:code_refused` (no code sent, or another code; five of them
  cancel the record), `:confirmation_cancelled` (a guess past the five),
  `{:not_found, "confirmation", ref}`, `:not_pending` (already confirmed,
  consumed or ended), `:unavailable`.
  """
  @spec verify_code(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def verify_code(%Context{} = ctx, ref, code) when is_binary(ref) and is_binary(code) do
    actor = Context.actor(ctx)

    with {:ok, user_id} <- confirming_person(ctx),
         {:ok, row} <- pending_record(actor, ref, user_id),
         :ok <- guessed(actor, row) do
      if is_binary(row.email_code_hash) and
           Plug.Crypto.secure_compare(code_hash(row.ref, String.trim(code)), row.email_code_hash) do
        confirmed(actor, row, ctx.client_id)
      else
        wrong(actor, row)
      end
    end
  end

  defp confirming_person(%Context{} = ctx) do
    if Sanctum.Pairing.can_confirm?(ctx) and is_binary(ctx.athanor_id) and ctx.athanor_id != "",
      do: {:ok, ctx.user_id},
      else: {:error, :unauthenticated}
  end

  defp transport, do: Application.get_env(:sanctum, :confirmation_code_transport)

  defp configured_transport do
    case transport() do
      module when is_atom(module) and not is_nil(module) -> {:ok, module}
      _none -> {:error, :email_unavailable}
    end
  end

  defp verified_email(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, %{email: email, email_verified: true}} when is_binary(email) and email != "" ->
        {:ok, email}

      {:ok, _unverified} ->
        {:error, :email_unavailable}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp pending_record(actor, ref, user_id) do
    case Arca.PendingConfirmations.get(actor, ref) do
      {:ok, %{user_id: ^user_id, state: "pending"} = row} -> {:ok, row}
      {:ok, %{user_id: ^user_id}} -> {:error, :not_pending}
      {:ok, _another} -> {:error, {:not_found, "confirmation", ref}}
      {:error, :not_found} -> {:error, {:not_found, "confirmation", ref}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # Every guess is counted, durably, for as long as the record lives: a
  # guess past the five finds the record cancelled.
  defp guessed(actor, row) do
    case claim(:confirmation_code_guess, row.ref, @guesses, @record_window_ms) do
      :ok ->
        :ok

      {:error, {:rate_limited, _seconds}} ->
        cancel(actor, row)
        {:error, :confirmation_cancelled}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wrong(actor, row) do
    case Arca.PendingConfirmations.count_code_failure(actor, row.ref, @guesses) do
      {:ok, %{state: "cancelled"} = cancelled} ->
        Authz.announce(:cancelled, cancelled)
        {:error, :code_refused}

      {:ok, _counted} ->
        {:error, :code_refused}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp confirmed(actor, row, client_id) do
    case Arca.PendingConfirmations.confirm(actor, row.ref, %{
           proof: "email_code",
           client_id: client_id
         }) do
      {:ok, confirmed} ->
        Authz.announce(:confirmed, confirmed)
        {:ok, %{ref: confirmed.ref, state: confirmed.state, expires_at: confirmed.expires_at}}

      {:error, reason} when reason in [:not_pending, :expired, :revoked] ->
        {:error, reason}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp cancel(actor, row) do
    case Arca.PendingConfirmations.cancel(actor, row.ref) do
      {:ok, cancelled} -> Authz.announce(:cancelled, cancelled)
      {:error, _closed} -> :ok
    end
  end

  defp deliver(transport, email, code, row) do
    message = %{
      to: email,
      subject: "Your CYFR confirmation code",
      text:
        "Your code to confirm #{row.operation} is #{code}. It works once, for this change " <>
          "alone, until #{DateTime.to_iso8601(row.expires_at)}. If you did not ask for it, " <>
          "ignore it and cancel the change where you are signed in."
    }

    case transport.deliver(message) do
      :ok -> {:ok, %{method: "email", expires_at: row.expires_at}}
      _failed -> {:error, :email_unavailable}
    end
  end

  defp claim(bucket, key, cap, window_ms) do
    case Arca.RequestRateWindows.claim(Prima.Actor.system(), bucket, key, cap, window_ms) do
      :ok ->
        :ok

      {:error, {:rate_limited, retry_after_ms}} ->
        {:error, {:rate_limited, div(retry_after_ms + 999, 1000)}}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # Six digits, uniform: 8 random bytes reduced mod 10^6 skew no digit
  # beyond one part in 10^13.
  defp draw do
    <<n::unsigned-64>> = :crypto.strong_rand_bytes(8)
    n |> rem(@code_space) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  # A keyed digest bound to the record: a leaked row gives nothing to try
  # codes against, and a code for one record matches no other.
  defp code_hash(ref, code) do
    :crypto.mac(
      :hmac,
      :sha256,
      Authz.derived_key("email-code"),
      Encoding.jcs!(%{"ref" => ref, "code" => code})
    )
    |> Base.encode16(case: :lower)
  end

  @doc """
  Verify the email on a Ueberauth.Auth struct for the given provider.

  Reads the claim wherever the strategy put it: `raw_info.userinfo`, then
  `raw_info.claims`.
  """
  @spec verify(atom(), String.t() | nil, map() | any()) :: result()
  def verify(_provider, email, _extra) when email in [nil, ""], do: {:error, :missing_email}

  # Respect the claim when present, accept its absence: a missing-claim
  # rejection would break valid deployments, while an issuer that explicitly
  # says `false` is a real signal.
  def verify(:oidcc, _email, extra) do
    case email_verified_claim(extra) do
      false -> {:error, :email_not_verified}
      _ -> :ok
    end
  end

  # Unknown provider: fail closed — only an explicit `email_verified == true`
  # is trusted.
  def verify(_other, _email, extra) do
    case email_verified_claim(extra) do
      true -> :ok
      _ -> {:error, :email_not_verified}
    end
  end

  @doc """
  `verify/3`, and what the provider actually asserted: `{:ok, true}` when
  it proved the address and `{:ok, :unknown}` when it said nothing. An
  explicit `false` is a refusal. The door admits an exact email entry only
  on `true`.
  """
  @spec verify_with_claim(atom(), String.t() | nil, map() | any()) ::
          {:ok, claim()} | {:error, :missing_email | :email_not_verified}
  def verify_with_claim(provider, email, extra) do
    with :ok <- verify(provider, email, extra) do
      case email_verified_claim(extra) do
        true -> {:ok, true}
        _ -> {:ok, :unknown}
      end
    end
  end

  # Userinfo takes precedence over id-token claims.
  defp email_verified_claim(%{raw_info: %{userinfo: %{"email_verified" => v}}}), do: v
  defp email_verified_claim(%{raw_info: %{claims: %{"email_verified" => v}}}), do: v
  defp email_verified_claim(_), do: :unknown
end
