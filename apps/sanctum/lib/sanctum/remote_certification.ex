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
  the certificate's `key_epoch`. Once a passkey or a paired device ever
  existed for the person here, one of them must have given that confirmation
  (`Sanctum.Pairing`, its module doc); the certification itself sets the
  person's first-method latch, so one certified on a fresh
  re-authentication is the bootstrap, and removing every passkey and
  device never reopens it. Only then is the certificate
  answered; a transaction that refuses leaves the signed certificate
  unanswered and the confirmation unconsumed.

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
      for this home and the athanor, client and device key the
      certificate names. Its nonce is 16 random bytes and the first 16
      bytes of an HMAC-SHA256, under a key derived from the keyring
      (`Sanctum.Consent.Authz.derived_key("remote-renewal")`), over those
      bytes, the binding the certificate claims (the person's identifier,
      its `key_epoch`, the other home, the athanor, the client and the
      device key) and the challenge's expiry: only this home makes one,
      and one names exactly that binding. This call reads nothing, so it
      costs anyone who asks no database work; whether a certification
      stands is answered to the proof.
    * with the `proof` over it, the proof is held to the challenge rebuilt
      from its own random half and the certificate's binding, within the
      window this home issues in, and its signature checked, before
      anything is read. Then the certification is read and held to that
      binding: the same device key and athanor, for the person this home
      holds local keys for under the identifier, active, and under the
      `key_epoch` the certificate claims, so a challenge issued before the
      record moved renews nothing. Then the person and their head must
      stand as above, the head being that `key_epoch`, and the nonce is used once,
      durably, by every member, for the challenge's life and the
      configured clock tolerance (`clock_skew_seconds`,
      `Arca.RequestRateWindows`). Then the replacement is signed, its
      `key_epoch` must be the record's, and the record's expiry moves
      (`Arca.DeviceCertifications.renew/3`), which reads every condition
      again under the person's lock. Only then is the certificate
      answered.

  A `key_epoch` change ends every certification made under the old one
  (`:certification_ended`): the glass is certified again under a fresh
  confirmation. The other home records nothing for a renewal: it checks
  each certificate against the person's head (`Sanctum.DeviceCerts`).

  ## Confirming at another home (`confirmation.confirm`'s `home_assertion`)

  A remote person's passkeys answer only their own home's RP ID, so a
  home they joined never checks one: their own home certifies the
  confirmation instead (`Prima.ConfirmationAssertion`,
  `tests/fixtures/confirmation_assertion.json`).

  `assert_confirmation/2` (`person.assert_confirmation`) is the person's
  home's half. Their browser brings what the deciding home's record
  carries for it (`at_home`: that home as `audience`, the record's
  `athanor`, `ref`, `digest`, `expires_at`, `preview` and
  `preview_digest`). The record's `digest` covers a secret this home never
  holds, so the preview is bound by its own digest: one whose
  `Prima.ConfirmationAssertion.preview_digest/1` is not the carried
  `preview_digest` is refused before anything is asked or signed, and the
  assertion signs that `preview_digest`. The change is a sensitive one
  here (`remote_confirmation`) whose preview names that home, the change
  it shows and its details, so the person sees here what they confirm
  there. Only a passkey's assertion or a protected device's
  proof confirms it, whatever window is open: a sign-in method, an emailed
  code or a session alone never vouches for the person at another home.
  Then the person's live key signs the assertion, expiring 60 seconds on
  or with the record, if sooner, and the confirmation is consumed; the
  answer is the assertion and the deciding home's fixed `/confirm` page
  with it in the fragment (`home_assertion=` and the unpadded base64url of
  its JCS bytes), which the browser navigates to and never sends in a
  request line. This home records nothing else: the deciding home's one
  confirmation of the record is the replay bound.

  `verify_confirmation/3` is the deciding home's half: the person this home holds as a remote
  identity, their head read live from their directory
  (`Sanctum.DeviceCerts.live_head/1`), and the assertion signed by that
  head's live key under its `key_epoch`, for this home, the record's
  athanor, ref and digest and the `preview_digest` of the preview the
  record stores (`preview_digest/1`), unexpired on the database's clock,
  all checked before the record is confirmed: an assertion over a preview
  of another change confirms nothing. A head the
  directory cannot answer refuses (`:identity_stale`), never trusts the
  cache. The record's one confirmation is the replay bound: it is marked
  `home`, attributed to nothing here, and counts as the person's own
  method for an addition (`Sanctum.Pairing.confirmer/1`), so a remote
  person with no device here bootstraps one without anyone else's
  passkey.

  ## Bounds

  Both calls first read the source address's verification window without
  counting (`Sanctum.DeviceCerts`, its module doc): the challenge call
  this node's alone, which reads no database; the proof call this node's
  and the cell's. A proof call whose proof verifies under the device key
  of a certification that stands (active, under the `key_epoch` the
  certificate claims and the person's head, the person active) is that
  person's, counted against their own 20 a minute before the work it asks
  for, and never against the address or the installation. Any other
  proof call is no one's, a withdrawn or ended certification's own key
  included: it is counted against the address (20 a minute) and the
  installation (200 a minute) and refused. So neither a flood naming a
  person's identifier and client nor a dead device's key can spend what
  the person's standing devices renew under. The challenge call counts
  nothing.

  ## Refusals

  The challenge call refuses only a certificate this home did not issue
  for an identity, and a spent bound; every refusal below that needs the
  record is the proof call's.

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
      issued for the certificate's binding under its device key, or
      arrived outside its window; `:replayed`, its nonce already used.
    * `:stale_key_epoch` — a certification whose person's head moved
      while it was confirmed.
    * `{:rate_limited, retry_after_ms}` — the address's, the
      installation's or the person's verification bound is spent.
    * `:unavailable`.
  """

  alias Prima.{ConfirmationAssertion, DeviceCert}
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
          "Lets a device act for you at that CYFR. It renews its certificate here by proving " <>
            "its key until your keys change, and stops when that CYFR revokes it."
      }
    }
  end

  defp request(%{"audience" => audience, "athanor" => athanor, "client_id" => client_id} = args)
       when is_binary(audience) and is_binary(athanor) and is_binary(client_id) do
    cond do
      not Encoding.home?(audience) ->
        {:error, {:invalid_argument, "The audience is a CYFR's origin, like https://hub.example"}}

      audience == Person.home() ->
        {:error,
         {:invalid_argument,
          "certify is for another CYFR; a device for this CYFR pairs here through pairing"}}

      not (Encoding.id?(athanor) and Encoding.id?(client_id)) ->
        {:error, {:invalid_argument, "The athanor and the client_id are that CYFR's ids"}}

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

    # The confirmation consumed under the person's lock and, once a
    # passkey or a paired device ever existed for the person, given by one
    # of them (`Sanctum.Pairing.addition_confirmed/1`).
    verify = fn ->
      with :ok <- Authz.consume(ctx, {:device_pairing, change}),
           do: Sanctum.Pairing.addition_confirmed(ctx)
    end

    case Arca.DeviceCertifications.certify(Context.actor(ctx), attrs, verify) do
      {:ok, row} -> {:ok, row}
      {:error, :database_error} -> {:error, :unavailable}
      {:error, :unknown_person} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Confirming at another home
  # ---------------------------------------------------------------------------

  @doc """
  Sign, for the person of `ctx`, that they confirmed one record at another
  home (the module doc). `args` carries `audience`, `athanor`, `ref`,
  `digest`, `expires_at` (Unix milliseconds), `preview` and
  `preview_digest`, the deciding home's record as its `at_home` names it.
  Answers `%{assertion: map, callback: url}`.

  Refusals: `{:invalid_argument, _}` (among them a preview whose digest is
  not `preview_digest`, refused before anything is asked or signed),
  `:expired` (the record's own expiry
  has passed), `{:confirmation_required, _}` until a passkey or protected
  device of the person's here confirms it, `:own_method_required` (it was
  confirmed some other way), `:not_found` (the person's keys are at
  another home), `:not_enrolled`, `:unavailable`.
  """
  @spec assert_confirmation(Context.t(), map()) ::
          {:ok, %{assertion: map(), callback: String.t()}} | {:error, term()}
  def assert_confirmation(%Context{user_id: user_id} = ctx, args)
      when is_binary(user_id) and is_map(args) do
    with {:ok, request} <- confirmation_request(args),
         {:ok, now} <- db_now_ms(),
         :ok <- if(request.expires_at > now, do: :ok, else: {:error, :expired}),
         change = confirmation_change(request),
         :ok <- Authz.check(ctx, :remote_confirmation, change),
         :ok <- own_method(ctx),
         {:ok, signed} <-
           Person.sign_confirmation(user_id, %{
             request
             | expires_at: min(now + ConfirmationAssertion.lifetime_ms(), request.expires_at)
           }),
         :ok <- Authz.confirm(ctx, :remote_confirmation, change) do
      encoded = ConfirmationAssertion.encode(signed)

      {:ok,
       %{
         assertion: encoded,
         callback:
           request.audience <>
             "/confirm#home_assertion=" <> (encoded |> Encoding.jcs!() |> Encoding.b64())
       }}
    end
  end

  def assert_confirmation(%Context{}, _args), do: {:error, :not_found}

  # What confirming the assertion approves: vouching at that home for that
  # record, its preview's change and details shown here as that home
  # stored them.
  defp confirmation_change(request) do
    preview = request.preview

    carried =
      Map.new(preview.details, fn {name, value} -> {"change_" <> name, value} end)

    %{
      operation: "person.assert_confirmation",
      arguments: %{
        "audience" => request.audience,
        "athanor" => request.athanor,
        "ref" => request.ref,
        "digest" => request.digest,
        "preview_digest" => request.preview_digest
      },
      resource: request.audience,
      details:
        Map.merge(carried, %{
          "audience" => request.audience,
          "change" => preview.operation,
          "change_resource" => preview.resource || "",
          "change_athanor" => preview.athanor,
          "effect" =>
            "Confirms #{preview.operation} at #{request.audience} for you, as that CYFR " <>
              "showed it. Confirm only if you asked for this change there."
        })
    }
  end

  # The record's confirmation here was given by a passkey or a protected
  # device of the person's, never by a sign-in method or a code.
  defp own_method(%Context{confirmation_id: id} = ctx) when is_binary(id) and id != "" do
    case Arca.PendingConfirmations.get(Context.actor(ctx), Prima.Confirmation.ref(id)) do
      {:ok, %{user_id: user_id, proof: proof}}
      when user_id == ctx.user_id and proof in ["passkey", "device"] ->
        :ok

      {:ok, _other} ->
        {:error, own_method_refusal()}

      {:error, :not_found} ->
        {:error, own_method_refusal()}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp own_method(%Context{}), do: {:error, own_method_refusal()}

  defp own_method_refusal do
    %Prima.Refusal{
      class: :forbidden,
      reason: :own_method_required,
      message:
        "Confirming a change at another CYFR needs your passkey or one of your devices here: " <>
          "confirm with one of them"
    }
  end

  defp confirmation_request(
         %{
           "audience" => audience,
           "athanor" => athanor,
           "ref" => ref,
           "digest" => digest,
           "expires_at" => expires_at,
           "preview" => preview,
           "preview_digest" => preview_digest
         } = args
       )
       when map_size(args) == 7 do
    with :ok <- other_home(audience),
         :ok <- bound(Encoding.id?(athanor), "The athanor is that CYFR's athanor id"),
         :ok <- bound(Prima.Confirmation.ref?(ref), "The ref is that confirmation's ref"),
         :ok <- bound(Encoding.digest?(digest), "The digest is that confirmation's sha256 digest"),
         :ok <-
           bound(is_integer(expires_at) and expires_at > 0, "The expiry is Unix milliseconds"),
         {:ok, preview} <- shown(preview, audience),
         :ok <- named(preview, preview_digest) do
      {:ok,
       %{
         audience: audience,
         athanor: athanor,
         ref: ref,
         digest: digest,
         expires_at: expires_at,
         preview: preview,
         preview_digest: preview_digest
       }}
    end
  end

  defp confirmation_request(_args),
    do:
      {:error,
       {:invalid_argument,
        "assert_confirmation needs the audience, athanor, ref, digest, expires_at, preview " <>
          "and preview_digest"}}

  defp other_home(audience) do
    cond do
      not Encoding.home?(audience) ->
        {:error, {:invalid_argument, "The audience is a CYFR's origin, like https://hub.example"}}

      audience == Person.home() ->
        {:error, {:invalid_argument, "A change here is confirmed here, not vouched for"}}

      true ->
        :ok
    end
  end

  defp bound(true, _message), do: :ok
  defp bound(_false, message), do: {:error, {:invalid_argument, message}}

  # The deciding home's preview, of a change at that home, with room for
  # this home's own details beside its own.
  defp shown(preview, audience) do
    case Prima.Confirmation.Preview.decode(preview) do
      {:ok, %{home: ^audience, details: details} = preview} when map_size(details) <= 27 ->
        if Enum.all?(Map.keys(details), &(byte_size(&1) <= 56)),
          do: {:ok, preview},
          else: {:error, {:invalid_argument, "The preview's details do not fit beside these"}}

      {:ok, %{home: ^audience}} ->
        {:error, {:invalid_argument, "The preview's details do not fit beside these"}}

      {:ok, _another_home} ->
        {:error, {:invalid_argument, "The preview is of a change at the audience"}}

      {:error, _malformed} ->
        {:error, {:invalid_argument, "The preview is that confirmation's stored preview"}}
    end
  end

  # The carried preview is the one the deciding home's `preview_digest`
  # names: its record's digest covers a secret this home never holds, so
  # only this binds what the person is shown to the record they confirm.
  defp named(preview, preview_digest) do
    if ConfirmationAssertion.preview_digest(preview) == preview_digest,
      do: :ok,
      else:
        {:error,
         {:invalid_argument,
          "The preview is not the change that confirmation's preview_digest names; " <>
            "nothing was signed"}}
  end

  @doc """
  The `preview_digest` of the preview a pending confirmation here stores
  (`Prima.ConfirmationAssertion.preview_digest/1`): what a remote person's
  record carries in its `at_home`, and what their home's assertion must
  sign. `:unavailable` for a stored preview that does not read.
  """
  @spec preview_digest(%{preview: String.t()}) :: {:ok, String.t()} | {:error, :unavailable}
  def preview_digest(%{preview: stored}) when is_binary(stored) do
    with {:ok, map} <- Jason.decode(stored),
         {:ok, preview} <- Prima.Confirmation.Preview.decode(map) do
      {:ok, ConfirmationAssertion.preview_digest(preview)}
    else
      _damaged -> {:error, :unavailable}
    end
  end

  @doc """
  Verify `assertion` (`Prima.ConfirmationAssertion`'s JSON map) as the
  remote person of `ctx` confirming `record` (its `ref`, `digest`,
  `athanor_id` and stored `preview`) here (the module doc). Refusals: `:not_remote` (a person
  whose keys this home holds confirms with their own passkey or device),
  `:proof_refused` (the assertion does not certify this record for this
  person under their current head), `:identity_stale`, `:unavailable`.
  """
  @spec verify_confirmation(Context.t(), map(), term()) ::
          :ok | {:error, :not_remote | :proof_refused | :identity_stale | :unavailable}
  def verify_confirmation(
        %Context{user_id: user_id},
        %{ref: ref, digest: digest, athanor_id: athanor_id} = record,
        assertion
      )
      when is_binary(user_id) do
    with {:ok, identifier} <- remote_identifier(user_id),
         {:ok, preview_digest} <- preview_digest(record),
         {:ok, state} <- DeviceCerts.live_head(identifier),
         {:ok, now} <- db_now_ms() do
      case ConfirmationAssertion.verify(assertion, state,
             audience: Person.home(),
             athanor: athanor_id,
             ref: ref,
             digest: digest,
             preview_digest: preview_digest,
             now: now
           ) do
        {:ok, _assertion} -> :ok
        {:error, _refused} -> {:error, :proof_refused}
      end
    end
  end

  def verify_confirmation(%Context{}, _record, _assertion), do: {:error, :proof_refused}

  # The identifier of a person this home holds as a remote identity.
  defp remote_identifier(user_id) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{provenance: "remote", identifier: identifier}} when is_binary(identifier) ->
        {:ok, identifier}

      {:ok, _local} ->
        {:error, :not_remote}

      {:error, :not_found} ->
        {:error, :not_remote}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp db_now_ms do
    {:ok, DateTime.to_unix(Arca.ServerMetaStorage.now!(), :millisecond)}
  rescue
    _unanswered -> {:error, :unavailable}
  end

  # ---------------------------------------------------------------------------
  # Renewing
  # ---------------------------------------------------------------------------

  @doc """
  Renew a certified device's certificate (the module doc), from `ctx`, an
  anonymous caller whose address the verification bounds count. `args`
  carries `certificate`, the JSON of a certificate this home issued, which
  only locates the record, and `proof`, absent on the first call.

  Answers `%{challenge: map}` without a proof, reading nothing, and
  `%{certificate: map}`, the replacement's JSON, with the proof over it.
  """
  @spec renew(Context.t(), map()) ::
          {:ok, %{challenge: map()} | %{certificate: map()}} | {:error, term()}
  def renew(%Context{} = ctx, args) when is_map(args) do
    now = now_ms()
    source = ctx.client_ip

    case Map.get(args, "proof") do
      nil ->
        with :ok <- DeviceCerts.verification_room(source, :node),
             {:ok, locator} <- locator(Map.get(args, "certificate")) do
          challenged(locator, now)
        end

      proof ->
        with :ok <- DeviceCerts.verification_room(source) do
          case attributed(Map.get(args, "certificate"), proof, now) do
            {:ok, user_id, record, proof} -> renewed(user_id, record, proof)
            {:unattributed, refused} -> DeviceCerts.refuse_unattributed(source, refused)
            {:error, :unavailable} = unanswered -> unanswered
          end
        end
    end
  end

  # A proof call is the person's once its proof, over a challenge this home
  # made for the binding the certificate claims, verifies under that
  # binding's device key, and the certification the certificate locates
  # holds that key and athanor. Everything before the reads is the
  # signature's, so a proof this home never asked for reads nothing.
  #
  # Only a certification that stands makes it so: active, for the binding
  # and the `key_epoch` the challenge covered, of a person who stands under
  # that `key_epoch` now. A withdrawn or ended certification's key is a
  # dead device's, and its calls are no one's, so it cannot spend what the
  # person's other devices renew under.
  defp attributed(certificate, proof, now) do
    with {:ok, locator} <- locator(certificate),
         {:ok, proof} <- read_proof(proof),
         {:ok, expected} <- expected(proof.challenge, locator, now),
         :ok <- verified(Proof.verify(proof, expected, now)),
         {:ok, user_id} <- local_person(locator.subject.identifier),
         {:ok, record} <- certification(user_id, locator),
         :ok <- standing_record(record),
         :ok <- claimed_epoch(record, locator),
         :ok <- current(user_id, record) do
      {:ok, user_id, record, proof}
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, refused} -> {:unattributed, refused}
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
        {:error, {:invalid_argument, "The certificate is not a device certificate a CYFR signs"}}
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

  # The record the certificate locates, holding its device key and
  # athanor, at any state; whether it stands is asked next. A record
  # holding another binding refuses as its state says.
  defp certification(user_id, %DeviceCert{} = certificate) do
    case Arca.DeviceCertifications.get(
           Prima.Actor.system(),
           user_id,
           certificate.audience,
           certificate.client_id
         ) do
      {:ok, record} ->
        cond do
          record.device_public_key == certificate.device_key and
              record.audience_athanor == certificate.athanor ->
            {:ok, record}

          record.state == "active" ->
            {:error, :binding_changed}

          true ->
            {:error, :revoked}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp standing_record(%{state: "active"}), do: :ok
  defp standing_record(_withdrawn), do: {:error, :revoked}

  # The record under the `key_epoch` the certificate claims, which the
  # challenge's HMAC covered: a challenge issued before the record moved
  # to another `key_epoch` renews nothing.
  defp claimed_epoch(record, %DeviceCert{subject: %{key_epoch: claimed}}) do
    if record.key_epoch == claimed, do: :ok, else: {:error, :certification_ended}
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

  # The challenge for the binding the certificate claims, from what it
  # carries alone: nothing is read.
  defp challenged(%DeviceCert{} = locator, now) do
    expires_at = now + Challenge.lifetime_ms()
    random = :crypto.strong_rand_bytes(@random_bytes)

    case Challenge.new(
           purpose: :renew,
           home: Person.home(),
           athanor: locator.athanor,
           client_id: locator.client_id,
           device_key: locator.device_key,
           nonce: nonce(random, locator, expires_at),
           now: now
         ) do
      {:ok, challenge} ->
        {:ok, %{challenge: Challenge.encode(challenge)}}

      {:error, _malformed} ->
        {:error, {:invalid_argument, "The certificate is not a device certificate a CYFR signs"}}
    end
  end

  # The person's own budget first, then the proof used once, then the
  # replacement, whose record's update reads every condition again under
  # the person's lock.
  defp renewed(user_id, record, proof) do
    with :ok <- DeviceCerts.claim_attributed({:person, user_id}),
         {:ok, skew_ms} <- skew_ms(),
         :ok <- consumed(proof, skew_ms),
         {:ok, certificate} <- reissued(record),
         {:ok, _record} <- extended(record, certificate) do
      {:ok, %{certificate: DeviceCert.encode(certificate)}}
    end
  end

  # The challenge this home would have issued for the binding the
  # certificate claims, from the presented one's random half and expiry,
  # inside the window it issues in: a challenge expiring later was not
  # issued here.
  defp expected(
         %Challenge{nonce: <<random::binary-size(@random_bytes), _mac::binary>>} = presented,
         %DeviceCert{} = locator,
         now
       ) do
    if presented.expires_at <= now + Challenge.lifetime_ms() do
      {:ok,
       %Challenge{
         presented
         | purpose: :renew,
           home: Person.home(),
           athanor: locator.athanor,
           client_id: locator.client_id,
           device_key: locator.device_key,
           nonce: nonce(random, locator, presented.expires_at)
       }}
    else
      {:error, :proof_refused}
    end
  end

  defp expected(_presented, _locator, _now), do: {:error, :proof_refused}

  # The binding the certificate claims, which the proof call holds the
  # record to: the person's identifier and `key_epoch`, the other home,
  # the athanor, the client and the device key.
  defp nonce(random, %DeviceCert{subject: %{kind: :identity} = subject} = locator, expires_at) do
    binding =
      Encoding.jcs!(%{
        "protocol" => @nonce_protocol,
        "home" => Person.home(),
        "identifier" => subject.identifier,
        "key_epoch" => subject.key_epoch,
        "audience" => locator.audience,
        "athanor" => locator.athanor,
        "client_id" => locator.client_id,
        "device_key" => Encoding.b64(locator.device_key),
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
