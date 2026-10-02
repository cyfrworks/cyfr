# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.RemoteCertification do
  @moduledoc """
  A person's devices at other homes, certified here, at the home that
  holds the person's keys: the certificate another home's glass connects
  under (`ARCHITECTURE.md` §9.2), and its renewal.

  ## Certifying (`person.certify`)

  The glass at the other home brings what that home reserved for it (the
  other home's origin as `audience`, its `athanor` and the `client_id`)
  and its `device_key`. A certification is a sensitive change
  (`device_pairing`): its preview names the other home, the athanor and
  the client. It is checked first (`Sanctum.Consent.Authz.check/3`),
  then the certificate is signed by the person's live key with an
  `identity` subject (`Sanctum.Person.issue_device_cert/4`, which writes
  nothing), and then one transaction locks the person, consumes the
  confirmation and records the certification
  (`Arca.DeviceCertifications.certify/3`) only while the person's head is
  the certificate's `key_epoch`. Only then is the certificate answered; a
  transaction that refuses leaves the signed certificate unanswered and
  the confirmation unconsumed.

  ## Renewing (`person.renew_certificate`)

  A certified device renews its certificate here without a fresh
  confirmation, by proving its device key, while the certification
  stands: the person active, local and enrolled, and the record active,
  naming the same device key, other home and athanor, under the person's
  `key_epoch` now. Nothing about the caller chooses the person: the
  certificate the glass brings only locates the record (this home as its
  issuer, the person's identifier, the other home and the client id); its
  signature and expiry are not read, so an expired certificate locates as
  well as a current one.

  Two stateless calls, as a pairing's are, so any member of the cell can
  answer either:

    * without a `proof`, the `renew` challenge (`Prima.DeviceCert.Challenge`)
      for this home, the record's athanor, client and device key. Its
      nonce is 16 random bytes and the first 16 bytes of an HMAC-SHA256,
      under a key derived from the keyring
      (`Sanctum.Consent.Authz.derived_key("remote-renewal")`), over those
      bytes, the record, its binding, its `key_epoch` and the challenge's
      expiry: only this home makes one, and one names exactly one record
      under one `key_epoch`.
    * with the `proof` over it, the proof is held to the challenge rebuilt
      from its own random half, within the window this home issues in, and
      its nonce is used once, durably, by every member, for the
      challenge's life and the configured clock tolerance
      (`clock_skew_seconds`, `Arca.RequestRateWindows`). Then the replacement is signed, its
      `key_epoch` must be the record's, and the record's expiry moves
      (`Arca.DeviceCertifications.renew/3`), which reads every condition
      again under the person's lock. Only then is the certificate
      answered.

  A `key_epoch` change ends every certification made under the old one
  (`:certification_ended`): the glass is certified again under a fresh
  confirmation. The other home records nothing for a renewal: it checks
  each certificate against the person's head (`Sanctum.DeviceCerts`).

  Every call, with or without a proof, counts against the verification
  bounds before anything is read (`Sanctum.DeviceCerts.claim_verification/1`).

  ## Refusals

    * `:not_found` — no standing certification here for what the
      certificate locates: another issuer, a person this home holds no
      local keys for, or no record of that client at that home.
    * `:certification_ended` — the person's `key_epoch` is not the
      record's: rotated or recovered since.
    * `:binding_changed` — the record now names another device key or
      athanor, from a fresh certification since.
    * `:revoked` — the record was withdrawn.
    * `:not_standing` — the person is denied.
    * `:proof_refused` — the proof does not answer a challenge this home
      issued for the record under its device key, or arrived outside its
      window; `:replayed`, its nonce already used.
    * `:stale_key_epoch` — a certification whose person's head moved
      while it was confirmed.
    * `{:rate_limited, retry_after_ms}`, `:unavailable`.
  """

  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Encoding
  alias Sanctum.{Context, DeviceCerts, Person}
  alias Sanctum.Consent.Authz

  @nonce_protocol "cyfr-remote-renewal-nonce/v1"
  @random_bytes 16
  @mac_bytes 16

  @typedoc "What a person's home certifies a device for (the module doc)."
  @type request :: %{
          device_key: binary(),
          audience: String.t(),
          athanor: String.t(),
          client_id: String.t()
        }

  # ---------------------------------------------------------------------------
  # Certifying
  # ---------------------------------------------------------------------------

  @doc """
  Certify a device of the person of `ctx` for another home (the module
  doc). `args` carries `device_key` (unpadded base64url), `audience`,
  `athanor` and `client_id`. Answers `%{certificate: map}`, the
  certificate's JSON.
  """
  @spec certify(Context.t(), map()) :: {:ok, %{certificate: map()}} | {:error, term()}
  def certify(%Context{user_id: user_id} = ctx, args) when is_binary(user_id) and is_map(args) do
    with {:ok, request} <- request(args),
         {:ok, identifier} <- enrolled(user_id),
         change = change(request),
         :ok <- Authz.check(ctx, :device_pairing, change),
         {:ok, certificate} <-
           Person.issue_device_cert(user_id, request.device_key, request.client_id, %{
             subject: :identity,
             audience: request.audience,
             athanor: request.athanor
           }),
         {:ok, _record} <- record(ctx, identifier, certificate, change) do
      # Announced once the consumption committed with the record it
      # approved.
      Authz.consumed(ctx)
      {:ok, %{certificate: DeviceCert.encode(certificate)}}
    end
  end

  def certify(%Context{}, _args), do: {:error, :not_found}

  @doc """
  What confirming a certification approves (`t:Sanctum.Consent.Authz.change/0`):
  this device key, for this client at that home and athanor.
  """
  @spec change(request()) :: Sanctum.Consent.Authz.change()
  def change(%{device_key: device_key, audience: audience, athanor: athanor, client_id: client}) do
    %{
      operation: "person.certify",
      arguments: %{
        "device_key" => Encoding.b64(device_key),
        "audience" => audience,
        "athanor" => athanor,
        "client_id" => client
      },
      resource: "a device at " <> audience,
      details: %{
        "audience" => audience,
        "athanor" => athanor,
        "client_id" => client,
        "effect" =>
          "Lets a device act for you at that home. It renews its certificate here by proving " <>
            "its key until your keys change, and stops when that home revokes it."
      }
    }
  end

  defp request(%{"audience" => audience, "athanor" => athanor, "client_id" => client_id} = args)
       when is_binary(audience) and is_binary(athanor) and is_binary(client_id) do
    cond do
      not Encoding.home?(audience) ->
        {:error, {:invalid_argument, "The audience is a home's origin, like https://hub.example"}}

      audience == Person.home() ->
        {:error,
         {:invalid_argument,
          "certify is for another home; a device for this home pairs here through pairing"}}

      not (Encoding.id?(athanor) and Encoding.id?(client_id)) ->
        {:error, {:invalid_argument, "The athanor and the client_id are that home's ids"}}

      true ->
        with {:ok, device_key} <- device_key(args["device_key"]) do
          {:ok,
           %{device_key: device_key, audience: audience, athanor: athanor, client_id: client_id}}
        end
    end
  end

  defp request(_args),
    do: {:error, {:invalid_argument, "certify needs the audience, the athanor and the client_id"}}

  defp device_key(value) when is_binary(value) do
    case Encoding.unb64(value, Encoding.key_bytes()) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, {:invalid_argument, "The device_key is a 32-byte public key, base64url"}}
    end
  end

  defp device_key(_value),
    do: {:error, {:invalid_argument, "The device_key is a 32-byte public key, base64url"}}

  # Asked before the proof: a person with no identifier is told to enroll,
  # and no confirmation is spent on a certificate that cannot be issued.
  defp enrolled(user_id) do
    case Sanctum.Tenancy.Users.identifier(user_id) do
      {:ok, identifier} when is_binary(identifier) -> {:ok, identifier}
      {:ok, nil} -> {:error, :not_enrolled}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The person locked, their confirmation consumed and the certification
  # recorded in one transaction, the head read under the lock.
  defp record(ctx, identifier, %DeviceCert{subject: subject} = certificate, change) do
    attrs = %{
      user_id: ctx.user_id,
      identifier: identifier,
      key_epoch: subject.key_epoch,
      client_id: certificate.client_id,
      device_public_key: certificate.device_key,
      audience_home: certificate.audience,
      audience_athanor: certificate.athanor,
      expires_at: DateTime.from_unix!(certificate.expires_at, :millisecond)
    }

    verify = fn -> Authz.consume(ctx, {:device_pairing, change}) end

    case Arca.DeviceCertifications.certify(Context.actor(ctx), attrs, verify) do
      {:ok, row} -> {:ok, row}
      {:error, :database_error} -> {:error, :unavailable}
      {:error, :unknown_person} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Renewing
  # ---------------------------------------------------------------------------

  @doc """
  Renew a certified device's certificate (the module doc), from `ctx`, an
  anonymous caller whose address the verification bounds count. `args`
  carries `certificate`, the JSON of a certificate this home issued, which
  only locates the record, and `proof`, absent on the first call.

  Answers `%{challenge: map}` without a proof, and `%{certificate: map}`,
  the replacement's JSON, with the proof over it.
  """
  @spec renew(Context.t(), map()) ::
          {:ok, %{challenge: map()} | %{certificate: map()}} | {:error, term()}
  def renew(%Context{} = ctx, args) when is_map(args) do
    now = now_ms()

    with :ok <- DeviceCerts.claim_verification(ctx.client_ip),
         {:ok, locator} <- locator(Map.get(args, "certificate")),
         {:ok, user_id} <- local_person(locator.subject.identifier),
         {:ok, record} <- certification(user_id, locator),
         :ok <- current(user_id, record) do
      case Map.get(args, "proof") do
        nil -> challenged(record, now)
        proof -> renewed(record, proof, now)
      end
    end
  end

  # The certificate locates a record and proves nothing: this home as its
  # issuer, an identity subject, the other home, its athanor, its client
  # and the device key.
  defp locator(map) when is_map(map) do
    case DeviceCert.decode(map) do
      {:ok, %DeviceCert{subject: %{kind: :identity}} = certificate} ->
        if certificate.issuer == Person.home(),
          do: {:ok, certificate},
          else: {:error, :not_found}

      {:ok, _local} ->
        {:error, :not_found}

      {:error, _malformed} ->
        {:error, {:invalid_argument, "The certificate is not a device certificate a home signs"}}
    end
  end

  defp locator(_value),
    do: {:error, {:invalid_argument, "The certificate is a device certificate, as JSON"}}

  # The person this home holds local keys for under `identifier`, read as
  # the server: the request names a person and holds no session.
  defp local_person(identifier) do
    case Arca.PersonIdentities.lookup_identifier(Prima.Actor.system(), identifier) do
      {:ok, %{provenance: "local", user_id: user_id}} -> {:ok, user_id}
      {:ok, _remote} -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The record the certificate locates, standing, for the same device key
  # and athanor.
  defp certification(user_id, %DeviceCert{} = certificate) do
    case Arca.DeviceCertifications.get(
           Prima.Actor.system(),
           user_id,
           certificate.audience,
           certificate.client_id
         ) do
      {:ok, %{state: "active"} = record} ->
        if record.device_public_key == certificate.device_key and
             record.audience_athanor == certificate.athanor,
           do: {:ok, record},
           else: {:error, :binding_changed}

      {:ok, _withdrawn} ->
        {:error, :revoked}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # The person active, local and enrolled, their head the record's
  # `key_epoch`; read again under the person's lock by the record's update.
  defp current(user_id, record) do
    with {:ok, user} <- user(user_id),
         :ok <- if(user.status == "active", do: :ok, else: {:error, :not_standing}) do
      case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
        {:ok, %{provenance: "local", head_hash: head}} when head == record.key_epoch -> :ok
        {:ok, %{provenance: "local"}} -> {:error, :certification_ended}
        {:ok, _remote} -> {:error, :not_found}
        {:error, :not_found} -> {:error, :not_found}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  defp user(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp challenged(record, now) do
    expires_at = now + Challenge.lifetime_ms()
    random = :crypto.strong_rand_bytes(@random_bytes)

    case Challenge.new(
           purpose: :renew,
           home: Person.home(),
           athanor: record.audience_athanor,
           client_id: record.client_id,
           device_key: record.device_public_key,
           nonce: nonce(random, record, expires_at),
           now: now
         ) do
      {:ok, challenge} -> {:ok, %{challenge: Challenge.encode(challenge)}}
      {:error, _malformed} -> {:error, :unavailable}
    end
  end

  defp renewed(record, proof, now) do
    with {:ok, proof} <- read_proof(proof),
         {:ok, expected} <- expected(proof.challenge, record, now),
         :ok <- verified(Proof.verify(proof, expected, now)),
         {:ok, skew_ms} <- skew_ms(),
         :ok <- consumed(proof, skew_ms),
         {:ok, certificate} <- reissued(record),
         {:ok, _record} <- extended(record, certificate) do
      {:ok, %{certificate: DeviceCert.encode(certificate)}}
    end
  end

  # The challenge this home would have issued for the record, from the
  # presented one's random half and expiry, inside the window it issues
  # in: a challenge expiring later was not issued here.
  defp expected(
         %Challenge{nonce: <<random::binary-size(@random_bytes), _mac::binary>>} = presented,
         record,
         now
       ) do
    if presented.expires_at <= now + Challenge.lifetime_ms() do
      {:ok,
       %Challenge{
         presented
         | purpose: :renew,
           home: Person.home(),
           athanor: record.audience_athanor,
           client_id: record.client_id,
           device_key: record.device_public_key,
           nonce: nonce(random, record, presented.expires_at)
       }}
    else
      {:error, :proof_refused}
    end
  end

  defp expected(_presented, _record, _now), do: {:error, :proof_refused}

  defp nonce(random, record, expires_at) do
    binding =
      Encoding.jcs!(%{
        "protocol" => @nonce_protocol,
        "home" => Person.home(),
        "certification" => record.id,
        "audience" => record.audience_home,
        "athanor" => record.audience_athanor,
        "client_id" => record.client_id,
        "device_key" => Encoding.b64(record.device_public_key),
        "key_epoch" => record.key_epoch,
        "random" => Encoding.b64(random),
        "expires_at" => expires_at
      })

    mac = :crypto.mac(:hmac, :sha256, Authz.derived_key("remote-renewal"), binding)
    random <> binary_part(mac, 0, @mac_bytes)
  end

  defp read_proof(map) when is_map(map) do
    case Proof.decode(map) do
      {:ok, proof} -> {:ok, proof}
      {:error, _malformed} -> {:error, :proof_refused}
    end
  end

  defp read_proof(_proof), do: {:error, :proof_refused}

  defp verified(:ok), do: :ok
  defp verified({:error, _refused}), do: {:error, :proof_refused}

  # The proof's nonce is used once, by every member: a window of one, as
  # wide as a challenge lives and the clocks may differ, so a member whose
  # clock lags still holds the challenge current after the window would
  # otherwise have closed, and finds the nonce used.
  defp consumed(%Proof{challenge: %Challenge{nonce: nonce}}, skew_ms) do
    case Arca.RequestRateWindows.claim(
           Prima.Actor.system(),
           :remote_renewal_proof,
           Encoding.b64(nonce),
           1,
           Challenge.lifetime_ms() + skew_ms
         ) do
      :ok -> :ok
      {:error, {:rate_limited, _retry_after_ms}} -> {:error, :replayed}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The configured clock tolerance; a value this member cannot read
  # refuses the renewal rather than narrowing the window.
  defp skew_ms do
    case Arca.PlatformSettings.effective("clock_skew_seconds") do
      {:ok, seconds} when is_integer(seconds) and seconds >= 0 -> {:ok, seconds * 1_000}
      _unreadable -> {:error, :unavailable}
    end
  end

  # The replacement, signed under the person's head as it is now, which
  # must still be the record's.
  defp reissued(record) do
    case Person.issue_device_cert(
           record.user_id,
           record.device_public_key,
           record.client_id,
           %{subject: :identity, audience: record.audience_home, athanor: record.audience_athanor}
         ) do
      {:ok, %DeviceCert{subject: %{key_epoch: epoch}} = certificate}
      when epoch == record.key_epoch ->
        {:ok, certificate}

      {:ok, _moved} ->
        {:error, :certification_ended}

      {:error, :not_enrolled} ->
        {:error, :certification_ended}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extended(record, certificate) do
    case Arca.DeviceCertifications.renew(Prima.Actor.system(), record.id, %{
           key_epoch: record.key_epoch,
           device_public_key: record.device_public_key,
           audience_athanor: record.audience_athanor,
           expires_at: DateTime.from_unix!(certificate.expires_at, :millisecond)
         }) do
      {:ok, row} -> {:ok, row}
      {:error, :database_error} -> {:error, :unavailable}
      {:error, :stale} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp now_ms, do: System.os_time(:millisecond)
end
