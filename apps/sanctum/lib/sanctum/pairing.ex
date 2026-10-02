# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Pairing do
  @moduledoc """
  The pairing ceremony, which changes need a fresh confirmation, and which
  clients can give one.

  Three facts stay apart: who a person is, established by their session;
  which devices they have connected; and whether a change needs a fresh
  confirmation. None of them is a rank, and the rule is the same for every
  person: members stay equals.

  ## The ceremony

    * `begin/2` — a person, under their session in the athanor in focus,
      opens a pairing invitation: a 128-bit random bearer secret, stored
      only as its hash (`Arca.PairingInvitations`), for this home, alive
      five minutes, reserving the client id the device it pairs will
      hold. It is a sensitive change (`device_pairing`): a device paired
      from a stolen session would outlive the session, so the
      confirmation is asked before anything is written and consumed in
      the transaction that opens the invitation, and its preview states
      that whoever presents the invitation pairs a device.
    * `complete/3` — the new glass, holding neither a session nor a
      certificate of this home's, presents the secret and its device
      public key and is answered a `pair` challenge; it signs the
      challenge with its device key and presents the proof, and the home
      records the paired client and issues its first certificate, or, for
      a remote person, records the one their own home issued (below).
      A remote person's glass that brings no certificate is answered the
      challenge with what their home must certify (`certify`), and its
      proof is refused until it brings one.
      The invitation names the person
      and athanor, and nothing about the caller does: a session cookie
      the browser still holds never chooses the person. The person's
      standing and seat are locked and checked, the invitation rechecked
      and consumed, the client recorded and the certificate issued and
      recorded, in one transaction (`Arca.PairingInvitations.consume/4`),
      so a closed invitation never reopens and a person denied or gone
      from the athanor is paired nothing.
    * `renew/2` — a paired device's replacement certificate, through its
      device channel's renewal exchange alone: after the channel verified
      a fresh `renew` challenge it issued and holds against the key the
      paired-client row stores (`Sanctum.DeviceCerts.verify_connect/3`),
      with the proof consumed once, and only while the client and its
      person stand; a revoked pairing is never revived.
    * `revoke/2` — a person ends one of their paired clients, with its
      certificates and the confirmations it confirmed, in one transaction
      (`Arca.PairedClients.revoke/2`). A sensitive change
      (`pairing_revocation`).
    * `list/1` — the person's paired clients in the athanor in focus.

  A local person's certificate is signed by their live key at this home
  (`Sanctum.Person.issue_device_cert/4`) with a `local` subject, whose
  issuer and audience are both this home. Local pairing reads no
  directory and needs no identifier.

  ## Pairing a remote person's device

  This home cannot sign for a person whose keys are at another home. Their
  invitation reserves the client id as any does. A first call with no
  certificate is answered, beside the `pair` challenge, `certify:
  %{audience, athanor, client_id}`: this home, the invitation's athanor
  and the reserved client id, which the invitation's bearer may know and
  the glass takes to the person's own home. That home certifies that id,
  the device key, this home and the athanor (`person.certify`, after a
  fresh confirmation there), and the glass presents that certificate with
  its completion (`complete/3`'s `:certificate`). Here the person's head is read fresh from their
  directory, and the certificate must be signed by its current live key,
  under its current `key_epoch`, for exactly the person's identifier, the
  reserved client id, the submitted device key, this home as its audience
  and the invitation's athanor, unexpired; the glass's proof over the
  `pair` challenge shows it holds that device key. Then the client is
  recorded with that certificate, bound to the epoch under the person's
  lock, in the invitation's one transaction. A certificate offered for a
  local person's invitation, or a proof with none for a remote person's,
  is refused. A remote certificate is not renewed here: the glass renews
  it at the person's own home by a proof of its device key
  (`person.renew_certificate`), or is certified there again.

  Every completion and every renewal is counted against the verification
  bounds before it is verified (`Sanctum.DeviceCerts.claim_verification/1`):
  20 a minute per source address and 200 a minute for the installation.

  ## The pair challenge

  The glass completes through two stateless calls, so the challenge the
  first answers must be one the second can recognise without storing it.
  Its nonce is an HMAC-SHA256 keyed by the invitation's secret over this
  home, the athanor, the reserved client id, the device key and the
  challenge's expiry: only the home and the invitation's bearer can make
  it, and the proof over it binds the device key to that one invitation.
  The invitation is consumed with the issuance, so a proof is redeemed at
  most once.

  ## The action table

  Each action a confirmation can concern, and what it needs:

  | Action | Needs |
  |---|---|
  | `:grant` | the session |
  | `:approval` | the session |
  | `:credential_entry` | a fresh confirmation |
  | `:credential_issuance` | a fresh confirmation |
  | `:vault_unlock` | a fresh confirmation |
  | `:home_transfer` | a fresh confirmation |
  | `:pairing_revocation` | a fresh confirmation |
  | `:recovery_material` | a fresh confirmation |
  | `:device_pairing` | a fresh confirmation |
  | `:passkey_registration` | a fresh confirmation |
  | `:remote_sign_in` | a fresh confirmation |
  | `:key_rotation` | a fresh confirmation |
  | `:sign_in_methods` | a fresh confirmation |

  `sensitive?/1` answers the table. `vault_unlock` and `home_transfer`
  have no operation until their features land, and stay sensitive.
  `action_for/1` maps each operation that confirms something to its
  action.

  `fresh_required?/2` is what the deciding sites ask
  (`Sanctum.Consent.Authz.confirm/3`): the table's answer, so a sensitive
  change needs a pending confirmation proven by a passkey assertion or a
  fresh re-authentication, whoever makes it.

  ## Who can confirm

  `can_confirm?/1` answers whether the context has a person behind it who
  can give a proof: a signed-in browser session (`:oidc`), or a paired
  device (`:device`) whose paired client stands, read here
  (`Sanctum.DeviceCerts.client_standing/1`). A key, a guest body, a
  tincture, a webhook, a schedule, the system and an anonymous caller
  confirm nothing. The system layer reads it to hide a control and never
  decides by it: the operation a confirmation dispatches is decided where
  the change is.
  """

  alias Prima.DeviceCert
  alias Prima.DeviceCert.{Challenge, Proof}
  alias Prima.Identity.Encoding
  alias Sanctum.{Context, DeviceCerts, Person}
  alias Sanctum.Consent.Authz

  @table %{
    grant: :session,
    approval: :session,
    credential_entry: :fresh,
    credential_issuance: :fresh,
    vault_unlock: :fresh,
    home_transfer: :fresh,
    pairing_revocation: :fresh,
    recovery_material: :fresh,
    device_pairing: :fresh,
    passkey_registration: :fresh,
    remote_sign_in: :fresh,
    key_rotation: :fresh,
    sign_in_methods: :fresh
  }

  # Each operation that confirms something, as `tool.action`, the spelling
  # a pending confirmation records (`Prima.Confirmation`).
  @operations %{
    "vault.create" => :credential_entry,
    "vault.rotate" => :credential_entry,
    "vault.authorize" => :credential_entry,
    "oauth.set_client" => :credential_entry,
    "key.create" => :credential_issuance,
    "key.rotate" => :credential_issuance,
    "webhook.create" => :credential_issuance,
    "webhook.rotate" => :credential_issuance,
    "pairing.revoke" => :pairing_revocation,
    "person.enroll" => :recovery_material,
    "person.kit" => :recovery_material,
    "person.enroll_holder" => :recovery_material,
    "passkey.register" => :passkey_registration,
    "passkey.revoke" => :passkey_registration,
    "passkey.recover_admin" => :passkey_registration,
    "pairing.begin" => :device_pairing,
    "person.certify" => :device_pairing,
    "person.assert" => :remote_sign_in,
    "person.rotate" => :key_rotation,
    "person.link_door" => :sign_in_methods,
    "person.unlink_door" => :sign_in_methods
  }

  # A pairing invitation: 128 random bits, alive five minutes.
  @secret_bytes 16
  @invitation_ms 300_000
  @invitation_minutes div(@invitation_ms, 60_000)

  @nonce_protocol "cyfr-device-pair-nonce/v1"

  @typedoc "An action the table names."
  @type action ::
          :grant
          | :approval
          | :credential_entry
          | :credential_issuance
          | :vault_unlock
          | :home_transfer
          | :pairing_revocation
          | :recovery_material
          | :device_pairing
          | :passkey_registration
          | :remote_sign_in
          | :key_rotation
          | :sign_in_methods

  @typedoc """
  An opened invitation: its raw bearer `invitation_secret` (16 bytes,
  shown to the person once, in the pairing code, and stored nowhere), the
  `client_id` it reserves for the device that redeems it, and when it
  expires.
  """
  @type invitation :: %{
          invitation_secret: binary(),
          client_id: String.t(),
          expires_at: DateTime.t()
        }

  @typedoc """
  What the new glass submits to `complete/3`: its device public key
  (32 raw bytes), once it holds the `pair` challenge its `proof`, and,
  for a remote person's invitation, the `certificate` their own home
  issued for the reserved client (with both calls).
  """
  @type submission :: %{
          required(:device_key) => binary(),
          optional(:proof) => Proof.t() | map() | nil,
          optional(:certificate) => DeviceCert.t() | nil
        }

  @typedoc """
  What a remote person's own home is to certify for the glass: this home
  as the audience, the invitation's athanor and the client id it reserved.
  """
  @type certify :: %{audience: String.t(), athanor: String.t(), client_id: String.t()}

  @typedoc "A paired client and the certificate it connects under."
  @type paired :: %{client_id: String.t(), certificate: DeviceCert.t()}

  @typedoc "What a device submits to `renew/2`: its client, its device key and its proof."
  @type renewal :: %{
          required(:client_id) => String.t(),
          required(:device_key) => binary(),
          required(:proof) => Proof.t() | map()
        }

  @typedoc """
  The ceremony's refusals, beside the ones it passes on from the stores,
  the gate's standing checks and a confirmation:

    * `:invalid_invitation` — no pending, unexpired invitation has that
      secret: unknown, used, withdrawn or expired alike, so the answer
      says nothing about which.
    * `:proof_refused` — the proof does not answer the challenge under the
      device key submitted, or the challenge is not one this home issued
      for that invitation or client.
    * `:wrong_audience` — the invitation is for another home.
    * `:certificate_required` — a remote person's invitation's proof
      presented without their home's certificate; `:certificate_unexpected`,
      a local person's offered one.
    * `:certificate_refused` — the certificate offered is not their home's
      for exactly this person, client, device key, home and athanor under
      their current live key, or has expired.
    * `:identity_stale` — a remote person's directory could not be read
      fresh.
    * `:remote_identity_unavailable` — a renewal of a remote person's
      certificate, which their own home certifies again instead.
    * `:not_standing` — the person is denied, the athanor archived or the
      person no longer seated in it.
    * `:revoked` — the paired client was revoked.
    * `:renewal_exchange_only` — a renewal from anything but the renewal
      exchange of the client's own device channel: an ordinary device
      context, a session or any other.
    * `:replayed` — a renewal proof already consumed.
    * `{:rate_limited, retry_after_ms}` — a verification bound is spent.
    * `:unavailable` — the store could not answer.
  """
  @type refusal ::
          :invalid_invitation
          | :proof_refused
          | :wrong_audience
          | :certificate_required
          | :certificate_unexpected
          | :certificate_refused
          | :identity_stale
          | :remote_identity_unavailable
          | :not_standing
          | :revoked
          | :renewal_exchange_only
          | :replayed
          | {:rate_limited, non_neg_integer()}
          | :unavailable
          | term()

  # ---------------------------------------------------------------------------
  # The ceremony
  # ---------------------------------------------------------------------------

  @doc """
  Open a pairing invitation for the person of `ctx` in the athanor in
  focus (the module doc). `args` takes nothing yet.

  The `device_pairing` confirmation is asked first
  (`Sanctum.Consent.Authz.check/3`) and consumed inside the transaction
  that opens the invitation (`Sanctum.Consent.Authz.consume/2`), under the
  person, athanor and seat locked and checked at the generations the
  context read, and the credential the context holds (its session, or a
  paired device's client and certificate) locked and checked after them
  (`Sanctum.Issuance`). Answers `t:invitation/0`.
  """
  @spec begin(Context.t(), map()) :: {:ok, invitation()} | {:error, refusal()}
  def begin(%Context{} = ctx, args) when is_map(args) do
    change = invitation_change()

    with :ok <- person_focused(ctx),
         :ok <- Authz.check(ctx, :device_pairing, change),
         {:ok, expectation} <- Sanctum.Issuance.expectation(ctx, []),
         {:ok, membership_id} <- seated(expectation) do
      secret = :crypto.strong_rand_bytes(@secret_bytes)

      attrs = %{
        user_id: ctx.user_id,
        membership_id: membership_id,
        secret_hash: secret_hash(secret),
        audience_home: Person.home(),
        lifetime_ms: @invitation_ms,
        source: expectation.source
      }

      # The invitation opens under the standing the context read and the
      # credential it holds, locked last of them, and its confirmation is
      # consumed with it; any of them refusing writes nothing.
      policy = Sanctum.Issuance.verify(expectation)

      verify = fn locked ->
        with :ok <- policy.(locked), do: Authz.consume(ctx, {:device_pairing, change})
      end

      case Arca.PairingInvitations.open(Context.actor(ctx), attrs, verify) do
        {:ok, invitation} ->
          # Announced once the confirmation's consumption committed with
          # the invitation it approved.
          Authz.consumed(ctx)

          {:ok,
           %{
             invitation_secret: secret,
             client_id: invitation.prospective_client_id,
             expires_at: invitation.expires_at
           }}

        {:error, :database_error} ->
          {:error, :unavailable}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  What confirming a pairing approves (`t:Sanctum.Consent.Authz.change/0`),
  the change `begin/2` decides: the invitation is a bearer capability, and
  the preview says so.
  """
  @spec invitation_change() :: Sanctum.Consent.Authz.change()
  def invitation_change do
    %{
      operation: "pairing.begin",
      arguments: %{},
      details: %{
        "invitation" =>
          "Whoever presents this pairing code within #{@invitation_minutes} minutes pairs a " <>
            "device that acts as you in this athanor until you revoke it."
      }
    }
  end

  @doc """
  Complete a pairing from the new glass: `secret` is the invitation's raw
  16-byte bearer secret and `submission` its device key and, on the
  second call, its proof (`t:submission/0`).

  Without a proof, answers `%{challenge: challenge}`, the `pair`
  challenge for this invitation and device key, and for a remote person's
  invitation offered no certificate also `certify: %{audience, athanor,
  client_id}`, what their own home is to certify. With the proof over it,
  locks and checks the person's standing and seat, records the paired
  client under the reserved id, issues its first certificate and consumes
  the invitation, in one transaction, and answers `t:paired/0`.

  `ctx` is the caller's, and anonymous: its address is what the
  verification bounds are counted by, and nothing in it chooses the
  person. Every call is counted before anything is verified.
  """
  @spec complete(Context.t(), binary(), submission()) ::
          {:ok, %{required(:challenge) => Challenge.t(), optional(:certify) => certify()}}
          | {:ok, paired()}
          | {:error, refusal()}
  def complete(%Context{} = ctx, secret, %{device_key: device_key} = submission)
      when is_binary(secret) and byte_size(secret) == @secret_bytes and is_binary(device_key) and
             byte_size(device_key) == 32 do
    now = now_ms()

    with :ok <- DeviceCerts.claim_verification(ctx.client_ip),
         {:ok, invitation} <- pending_invitation(secret, now),
         :ok <- this_home(invitation),
         {:ok, issuer} <-
           issuer(invitation, device_key, Map.get(submission, :certificate), now) do
      case {Map.get(submission, :proof), issuer} do
        {nil, :certify} -> certify_first(secret, invitation, device_key, now)
        {nil, _issuer} -> challenged(secret, invitation, device_key, now)
        {_proof, :certify} -> {:error, :certificate_required}
        {proof, issuer} -> redeem(secret, invitation, device_key, proof, issuer, now)
      end
    end
  end

  def complete(%Context{}, _secret, _submission), do: {:error, :invalid_invitation}

  # Routing only, before any lock: the redemption rechecks the state and
  # expiry on the database's clock under the invitation's lock.
  defp pending_invitation(secret, now) do
    case Arca.PairingInvitations.lookup(secret_hash(secret)) do
      {:ok, %{state: "pending", expires_at: expires_at} = invitation} ->
        if DateTime.to_unix(expires_at, :millisecond) > now,
          do: {:ok, invitation},
          else: {:error, :invalid_invitation}

      {:ok, _closed} ->
        {:error, :invalid_invitation}

      {:error, :not_found} ->
        {:error, :invalid_invitation}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp this_home(%{audience_home: audience}) do
    if audience == Person.home(), do: :ok, else: {:error, :wrong_audience}
  end

  # Who certifies the device: this home, for a person whose keys are here,
  # with no certificate offered; or the person's own home, whose
  # certificate for exactly this invitation's client, the device key, this
  # home and the athanor is verified under the head their directory names
  # now (`Sanctum.DeviceCerts.remote_subject/3`, read live).
  defp issuer(invitation, device_key, certificate, now) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), invitation.user_id) do
      {:ok, %{provenance: "remote", identifier: identifier}} when is_binary(identifier) ->
        remote_issuer(invitation, identifier, device_key, certificate, now)

      {:ok, %{provenance: "remote"}} ->
        {:error, :unavailable}

      {:ok, _local} ->
        local_issuer(invitation.user_id, certificate)

      {:error, :not_found} ->
        local_issuer(invitation.user_id, certificate)

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp local_issuer(user_id, nil) do
    with :ok <- DeviceCerts.local_identity(user_id), do: {:ok, :local}
  end

  defp local_issuer(_user_id, _certificate), do: {:error, :certificate_unexpected}

  # No certificate yet: the glass is told what to have certified.
  defp remote_issuer(_invitation, _identifier, _device_key, nil, _now), do: {:ok, :certify}

  defp remote_issuer(invitation, identifier, device_key, %DeviceCert{} = certificate, now) do
    with :ok <- binds?(certificate, invitation, identifier, device_key),
         {:ok, %{user_id: user_id, certificate: certificate}} <-
           remote_certificate(certificate, now) do
      if user_id == invitation.user_id,
        do: {:ok, {:remote, identifier, certificate}},
        else: {:error, :certificate_refused}
    end
  end

  defp remote_issuer(_invitation, _identifier, _device_key, _certificate, _now),
    do: {:error, :certificate_refused}

  # The exact binding the invitation reserved, before anything is read:
  # the person's identifier, the reserved client id, the submitted device
  # key, this home and the invitation's athanor.
  defp binds?(certificate, invitation, identifier, device_key) do
    if match?(%{kind: :identity, identifier: ^identifier}, certificate.subject) and
         certificate.client_id == invitation.prospective_client_id and
         certificate.device_key == device_key and certificate.audience == Person.home() and
         certificate.athanor == invitation.athanor_id,
       do: :ok,
       else: {:error, :certificate_refused}
  end

  defp remote_certificate(certificate, now) do
    case DeviceCerts.remote_subject(certificate, now, :live) do
      {:ok, subject} -> {:ok, subject}
      {:error, reason} when reason in [:identity_stale, :unavailable] -> {:error, reason}
      {:error, _refused} -> {:error, :certificate_refused}
    end
  end

  # A remote person's glass that brings no certificate: the challenge, and
  # what their own home is to certify for it.
  defp certify_first(secret, invitation, device_key, now) do
    with {:ok, answer} <- challenged(secret, invitation, device_key, now) do
      {:ok,
       Map.put(answer, :certify, %{
         audience: Person.home(),
         athanor: invitation.athanor_id,
         client_id: invitation.prospective_client_id
       })}
    end
  end

  defp challenged(secret, invitation, device_key, now) do
    with {:ok, challenge} <-
           pair_challenge(secret, invitation, device_key, now + Challenge.lifetime_ms()) do
      {:ok, %{challenge: challenge}}
    end
  end

  # The `pair` challenge expiring at `expires_at`: this home, the athanor,
  # the reserved client id, the device key, and the nonce only the home
  # and the invitation's bearer can make.
  defp pair_challenge(secret, invitation, device_key, expires_at) do
    nonce =
      :crypto.mac(
        :hmac,
        :sha256,
        secret,
        Encoding.jcs!(%{
          "protocol" => @nonce_protocol,
          "home" => Person.home(),
          "athanor" => invitation.athanor_id,
          "client_id" => invitation.prospective_client_id,
          "device_key" => Encoding.b64(device_key),
          "expires_at" => expires_at
        })
      )

    case Challenge.new(
           purpose: :pair,
           home: Person.home(),
           athanor: invitation.athanor_id,
           client_id: invitation.prospective_client_id,
           device_key: device_key,
           nonce: nonce,
           now: expires_at - Challenge.lifetime_ms()
         ) do
      {:ok, challenge} -> {:ok, challenge}
      {:error, _malformed} -> {:error, :unavailable}
    end
  end

  defp redeem(secret, invitation, device_key, proof, issuer, now) do
    with {:ok, proof} <- read_proof(proof),
         :ok <- issued_window(proof, now),
         {:ok, expected} <-
           pair_challenge(secret, invitation, device_key, proof.challenge.expires_at),
         :ok <- verified(Proof.verify(proof, expected, now)) do
      actor = Prima.Actor.in_athanor(invitation.athanor_id)

      actor
      |> Arca.PairingInvitations.consume(
        secret_hash(secret),
        &redeemable(&1, invitation),
        &paired(actor, &1, device_key, issuer)
      )
      |> redeemed()
    end
  end

  # The standing a redemption is held to, over the rows locked for it: the
  # person the invitation names active, the athanor open, and their seat
  # there (or their platform row) still active.
  defp redeemable(%{user: user, athanor: athanor, membership: membership}, invitation) do
    if active?(user, invitation.user_id) and match?(%{status: "active"}, athanor) and
         seated?(membership, invitation),
       do: :ok,
       else: {:error, :not_standing}
  end

  defp active?(%{status: "active", id: user_id}, user_id), do: true
  defp active?(_user, _user_id), do: false

  defp seated?(
         %{status: "active", user_id: user_id, scope: "athanor", athanor_id: athanor_id},
         %{user_id: user_id, athanor_id: athanor_id}
       ),
       do: true

  defp seated?(%{status: "active", user_id: user_id, scope: "platform"}, %{user_id: user_id}),
    do: true

  defp seated?(_membership, _invitation), do: false

  # Inside the redemption's transaction: the client under the reserved id,
  # standing on the invitation that paired it, and its first certificate:
  # issued here for a local person, or their own home's, recorded bound to
  # the `key_epoch` the cached head still names under the person's lock.
  defp paired(actor, invitation, device_key, issuer) do
    with {:ok, client} <-
           Arca.PairedClients.record(actor, %{
             id: invitation.prospective_client_id,
             user_id: invitation.user_id,
             source_kind: "device_cert",
             source_id: invitation.id,
             device_public_key: device_key
           }),
         {:ok, certificate} <- first_certificate(client, issuer),
         {:ok, _row} <- record_certificate(actor, client, certificate) do
      {:ok, %{client_id: client.id, certificate: certificate}}
    end
  end

  defp first_certificate(client, :local), do: certify(client)
  defp first_certificate(_client, {:remote, _identifier, certificate}), do: {:ok, certificate}

  defp redeemed({:ok, paired}), do: {:ok, paired}

  defp redeemed({:error, reason}) when reason in [:not_found, :consumed, :revoked, :expired],
    do: {:error, :invalid_invitation}

  defp redeemed({:error, :database_error}), do: {:error, :unavailable}
  defp redeemed({:error, reason}), do: {:error, reason}

  @doc """
  Issue a paired device's replacement certificate (the module doc).

  `ctx` is the renewal exchange's context and no other: the one the
  device channel obtains from `Sanctum.DeviceCerts.verify_connect/3` for
  a `renew` proof against the challenge the channel issued and holds,
  which names the client and carries no certificate and so no deadline.
  An ordinary device context, one established under a certificate, is
  refused `:renewal_exchange_only`, so an intent naming `pairing.renew`
  issues nothing; so is every other context. `renewal` names that client,
  its device key and the proof (`t:renewal/0`) the channel verified.

  The proof is held again here: a `renew` challenge for this home, the
  context's athanor and client and the device key the paired-client row
  stores, signed by that key and unexpired. The client must stand, and
  its person keep their standing and seat and hold their keys here. Then
  the proof is consumed: its challenge's nonce is claimed once, durably,
  for the challenge's lifetime (`Arca.RequestRateWindows`, a bound of one
  per nonce), so of any number of renewals presenting one proof, on any
  member, one alone goes on to issue, and every other is `:replayed`. A
  proof consumed by an issuance that then fails is spent: the glass asks
  for another challenge. The certificate is recorded under the member's
  live ownership, against the active client and its stored key
  (`Arca.DeviceCertificates.record/2`). Answers `t:paired/0`.
  """
  @spec renew(Context.t(), renewal()) :: {:ok, paired()} | {:error, refusal()}
  def renew(
        %Context{
          auth_method: :device,
          authenticated: authenticated?,
          credential_deadline: nil,
          client_id: client_id,
          user_id: user_id,
          athanor_id: a
        } = ctx,
        %{client_id: client_id, device_key: device_key, proof: proof}
      )
      when authenticated? == true and is_binary(client_id) and is_binary(user_id) and
             is_binary(a) and is_binary(device_key) do
    now = now_ms()
    actor = Prima.Actor.in_athanor(a)

    with {:ok, proof} <- read_proof(proof),
         :ok <- renewal_proof(proof, ctx, device_key, now),
         {:ok, client} <- DeviceCerts.paired_client(a, user_id, client_id),
         :ok <- stored_key(client, device_key),
         :ok <- DeviceCerts.local_identity(user_id),
         {:ok, _standing} <- DeviceCerts.standing(user_id, a),
         :ok <- consumed(proof),
         {:ok, certificate} <- certify(client),
         {:ok, _row} <- record_certificate(actor, client, certificate) do
      {:ok, %{client_id: client_id, certificate: certificate}}
    end
  end

  def renew(%Context{}, _renewal), do: {:error, :renewal_exchange_only}

  defp renewal_proof(%Proof{challenge: %Challenge{} = presented} = proof, ctx, device_key, now) do
    expected = %Challenge{
      presented
      | purpose: :renew,
        home: Person.home(),
        athanor: ctx.athanor_id,
        client_id: ctx.client_id,
        device_key: device_key
    }

    with :ok <- issued_window(proof, now), do: verified(Proof.verify(proof, expected, now))
  end

  defp stored_key(%{device_public_key: device_key}, device_key), do: :ok
  defp stored_key(_client, _device_key), do: {:error, :proof_refused}

  # A renewal proof is consumed once: its challenge's nonce, claimed in a
  # window of one, as wide as the challenge lives, which every member
  # shares and a conditional write decides. The claim is a pre-
  # authentication bound (`Arca.RequestRateWindows`), keyed by the nonce the
  # channel drew, and a second claim of one nonce finds the bound spent.
  defp consumed(%Proof{challenge: %Challenge{nonce: nonce}}) do
    case Arca.RequestRateWindows.claim(
           Prima.Actor.system(),
           :device_renewal_proof,
           Encoding.b64(nonce),
           1,
           Challenge.lifetime_ms()
         ) do
      :ok -> :ok
      {:error, {:rate_limited, _retry_after_ms}} -> {:error, :replayed}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  @doc """
  Revoke the paired client `client_id`, one of the context person's in
  the athanor in focus, with its certificates and the confirmations it
  confirmed (`Arca.PairedClients.revoke/2`). A sensitive change
  (`pairing_revocation`, `Sanctum.Consent.Authz.confirm/3`). Its device
  channel refuses the client's next request, and closes at its next
  standing check. Answers the client's row as revoked.
  """
  @spec revoke(Context.t(), String.t()) :: {:ok, map()} | {:error, refusal()}
  def revoke(%Context{} = ctx, client_id) when is_binary(client_id) do
    with :ok <- person_focused(ctx),
         {:ok, client} <- own_client(ctx, client_id),
         :ok <-
           Authz.confirm(ctx, :pairing_revocation, %{
             operation: "pairing.revoke",
             arguments: %{"client_id" => client_id},
             resource: client.label || client_id
           }) do
      case Arca.PairedClients.revoke(Context.actor(ctx), client_id) do
        {:ok, row} -> {:ok, row}
        {:error, :database_error} -> {:error, :unavailable}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp own_client(ctx, client_id) do
    case Arca.PairedClients.list(Context.actor(ctx), user_id: ctx.user_id, standing: :all) do
      {:ok, rows} ->
        case Enum.find(rows, &(&1.id == client_id)) do
          nil -> {:error, {:not_found, "paired client", client_id}}
          row -> {:ok, row}
        end

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  @doc """
  The context person's active paired clients in the athanor in focus,
  oldest first: each with its id, label, the credential it stands on,
  when it was paired, when its current certificate expires (nil for none
  current), and whether it is the client `ctx` itself came through.
  """
  @spec list(Context.t()) :: {:ok, [map()]} | {:error, refusal()}
  def list(%Context{} = ctx) do
    actor = Context.actor(ctx)

    with :ok <- person_focused(ctx) do
      case Arca.PairedClients.list(actor, user_id: ctx.user_id, standing: :active) do
        {:ok, rows} -> {:ok, Enum.map(rows, &listed(actor, &1, ctx))}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  defp listed(actor, row, ctx) do
    expires_at =
      case Arca.DeviceCertificates.current(actor, row.id) do
        {:ok, certificate} -> certificate.expires_at
        {:error, _none} -> nil
      end

    %{
      client_id: row.id,
      label: row.label,
      source: row.source_kind,
      paired_at: row.inserted_at,
      certificate_expires_at: expires_at,
      current: row.id == ctx.client_id
    }
  end

  # ---------------------------------------------------------------------------
  # Certificates
  # ---------------------------------------------------------------------------

  # The person's live key vouching for the client's device key, here: a
  # `local` subject, whose issuer and audience are this home. A person with
  # no local key set holds their keys at another home.
  defp certify(client) do
    case Person.issue_device_cert(client.user_id, client.device_public_key, client.id, %{
           subject: :local,
           audience: Person.home(),
           athanor: client.athanor_id
         }) do
      {:ok, certificate} -> {:ok, certificate}
      {:error, :not_found} -> {:error, :remote_identity_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  # The certificate on the client's row, as signed: its JCS bytes and
  # their digest, under the member's live ownership and the client's lock.
  # An identity subject's names its identifier and `key_epoch`, which the
  # store binds to the cached head's under the person's lock.
  defp record_certificate(actor, client, %DeviceCert{} = certificate) do
    bytes = Encoding.jcs!(DeviceCert.encode(certificate))

    case Arca.DeviceCertificates.record(actor, %{
           paired_client_id: client.id,
           user_id: client.user_id,
           subject_kind: Atom.to_string(certificate.subject.kind),
           identifier: Map.get(certificate.subject, :identifier),
           key_epoch: Map.get(certificate.subject, :key_epoch),
           device_public_key: certificate.device_key,
           issuing_home: certificate.issuer,
           audience_home: certificate.audience,
           not_before: DateTime.from_unix!(certificate.not_before, :millisecond),
           expires_at: DateTime.from_unix!(certificate.expires_at, :millisecond),
           certificate: bytes,
           digest: Prima.Digest.sha256(bytes)
         }) do
      {:ok, row} -> {:ok, row}
      {:error, :client_not_active} -> {:error, :not_standing}
      {:error, :database_error} -> {:error, :unavailable}
      # A remote person's head moved between the certificate's check and
      # its record: it is chained to a key no longer current.
      {:error, :stale_key_epoch} -> {:error, :certificate_refused}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Proofs
  # ---------------------------------------------------------------------------

  defp read_proof(%Proof{} = proof), do: {:ok, proof}

  defp read_proof(map) when is_map(map) do
    case Proof.decode(map) do
      {:ok, proof} -> {:ok, proof}
      {:error, _malformed} -> {:error, :proof_refused}
    end
  end

  defp read_proof(_proof), do: {:error, :proof_refused}

  # A challenge this home issued expires at most one lifetime from now: one
  # that expires later was not issued here.
  defp issued_window(%Proof{challenge: %Challenge{expires_at: expires_at}}, now) do
    if expires_at <= now + Challenge.lifetime_ms(), do: :ok, else: {:error, :proof_refused}
  end

  defp verified(:ok), do: :ok
  defp verified({:error, _refused}), do: {:error, :proof_refused}

  defp secret_hash(secret), do: Prima.Digest.sha256(secret)

  # ---------------------------------------------------------------------------
  # The context
  # ---------------------------------------------------------------------------

  # A person, signed in, working in an athanor.
  defp person_focused(%Context{authenticated: true, anonymous: false, user_id: u, athanor_id: a})
       when is_binary(u) and u != "" and is_binary(a) and a != "",
       do: :ok

  defp person_focused(%Context{authenticated: true, anonymous: false, user_id: u})
       when is_binary(u) and u != "",
       do: {:error, :missing_tenant}

  defp person_focused(%Context{}), do: {:error, :unauthenticated}

  # The membership the context's focus rests on: the one the invitation is
  # opened under and redeemed against.
  defp seated(%{membership_id: membership_id}) when is_binary(membership_id),
    do: {:ok, membership_id}

  defp seated(_expectation), do: {:error, :not_standing}

  defp now_ms, do: System.os_time(:millisecond)

  # ---------------------------------------------------------------------------
  # The action table
  # ---------------------------------------------------------------------------

  @doc "Every action the table names, sorted."
  @spec actions() :: [action()]
  def actions, do: @table |> Map.keys() |> Enum.sort()

  @doc """
  Whether the table names `action` a sensitive change, one that needs a
  fresh confirmation for every person, rather than the session alone.
  """
  @spec sensitive?(action()) :: boolean()
  def sensitive?(action) when is_map_key(@table, action), do: Map.fetch!(@table, action) == :fresh

  @doc """
  The action the operation `operation` (`tool.action`) confirms, or `nil`
  for an operation that confirms nothing.
  """
  @spec action_for(String.t()) :: action() | nil
  def action_for(operation) when is_binary(operation), do: Map.get(@operations, operation)

  @doc """
  Whether `action`, asked for under `ctx`, needs a fresh confirmation
  before it is decided: the table's answer, the same for every person and
  every client. A local person's first passkey registration may instead
  rest on a recent local sign-in, which `Sanctum.Passkeys.register/2`
  decides before it asks.
  """
  @spec fresh_required?(action(), Context.t()) :: boolean()
  def fresh_required?(action, %Context{}) when is_map_key(@table, action), do: sensitive?(action)

  @doc """
  Whether the client behind `ctx` has a person behind it who can give a
  proof, on the external plane, authenticated and not anonymous: a
  browser session (`:oidc`) that names its person and no paired client,
  or a paired device (`:device`) that names its person and a paired
  client that stands (`Sanctum.DeviceCerts.client_standing/1`, read from
  the store). Every other context — a key, a guest body, a tincture, a
  webhook, a schedule, the system — `false`.
  """
  @spec can_confirm?(Context.t()) :: boolean()
  def can_confirm?(%Context{plane: :external, authenticated: true, anonymous: false} = ctx) do
    case ctx do
      %Context{auth_method: :oidc, client_id: nil} ->
        person?(ctx.user_id)

      %Context{auth_method: :device, client_id: client_id} when is_binary(client_id) ->
        person?(ctx.user_id) and DeviceCerts.client_standing(ctx) == :ok

      %Context{} ->
        false
    end
  end

  def can_confirm?(%Context{}), do: false

  defp person?(user_id), do: is_binary(user_id) and user_id != ""
end
