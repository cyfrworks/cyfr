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

    * The new glass generates its device key first, before any
      invitation exists, and shows the key's digest
      (`Prima.Device.key_digest/1`), as the code the person carries to a
      client already theirs.
    * `begin/2` — a person, under their session in the athanor in focus,
      opens a pairing invitation for that digest: a 128-bit random secret,
      stored only as its hash (`Arca.PairingInvitations`), for this home,
      alive five minutes, reserving the client id the device it pairs
      will hold, and naming the one device key that may complete it. It
      is a sensitive change (`device_pairing`): a device paired from a
      stolen session would outlive the session, so the confirmation is
      asked for exactly that key digest before anything is written and
      consumed in the transaction that opens the invitation, its preview
      names the digest, and the invitation records which passkey or
      paired client confirmed it (below).
    * `complete/3` — the new glass, holding neither a session nor a
      certificate of this home's, presents the secret and its device
      public key, which must be the key the invitation names, and is
      answered a `pair` challenge; it signs the
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
      recorded, in one transaction (`Arca.PairingInvitations.consume/5`),
      so a closed invitation never reopens and a person denied or gone
      from the athanor is paired nothing. In that transaction, under the
      invitation's lock and before the certificate is signed, the
      presented key's digest must be the invitation's and the passkey or
      paired client that confirmed it must still stand; any other key,
      one whose own proof is valid included, pairs nothing.
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
    * `reenable/3` — after a declared restore suspended every paired
      client, the person makes one active again (`:restore_reenable`):
      while their restore is open, on a confirmation a door this home
      re-authenticates or an emailed code gave (`restore_confirmed/1`), or
      with their recovery kit (`kit_confirmed/2`); the re-enabling closes
      their restore. No certificate is issued here: the glass
      reconnects under its certificate while it is unexpired, or renews
      through its channel (`renew/2`), which an active client is admitted
      to again.

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

  A completion is counted against the verification bounds
  (`Sanctum.DeviceCerts`, its module doc): the source address's window
  is read first, counting nothing. A secret that names a pending
  invitation makes the attempt that invitation's person's, counted
  against their own 20 a minute before anything more is read, and never
  against the address or the installation. Any other is no one's: it is
  counted against the address (20 a minute) and the installation (200 a
  minute) and refused. So a flood of guessed codes, from any number of
  addresses, leaves the invitation's bearer able to complete.

  ## Adding a method or a device once one exists

  Three changes add a way to act as the person here: pairing a device
  (`device_pairing`, `begin/2` and a remote certification,
  `Sanctum.RemoteCertification`), registering a passkey
  (`passkey_registration`, `Sanctum.Passkeys.register/2`) and linking a
  door (`sign_in_methods`, `Sanctum.SignIn.link_door/3`). Once the person
  holds, or ever held, a passkey or a paired device here, each needs a
  confirmation attributed to one of them: a passkey assertion
  (`confirmed_passkey_id`), or a confirmation given on a standing paired
  client (`confirmed_client_id`), whatever proof that client gave. A fresh
  re-authentication from a session that names no client confirms every
  other change, and not these. Before the first passkey or device, a fresh
  re-authentication bootstraps the first, and the bootstrap is latched by
  whichever first method commits first (`Arca.PersonIdentities`, its
  `first_method_at`): the first passkey's registration or the first
  device's completed pairing, each setting the mark in the transaction that
  writes it, under the person's lock. Revoking every passkey and device
  never reopens it: a person who has lost them recovers with their kit or
  through the administrator's recovery. `addition_confirmed/1` decides it
  for a write that runs in the person's transaction after the
  confirmation's consumption; the pairing's own invitation records its
  confirmer, and an invitation that names none completes only as the
  write that sets the latch.

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
  | `:credential_sharing` | a fresh confirmation |
  | `:vault_unlock` | a fresh confirmation |
  | `:home_transfer` | a fresh confirmation |
  | `:pairing_revocation` | a fresh confirmation |
  | `:recovery_material` | a fresh confirmation |
  | `:device_pairing` | a fresh confirmation |
  | `:passkey_registration` | a fresh confirmation |
  | `:remote_sign_in` | a fresh confirmation |
  | `:key_rotation` | a fresh confirmation |
  | `:sign_in_methods` | a fresh confirmation |
  | `:seal_change` | a fresh confirmation |
  | `:restore_reenable` | a fresh confirmation, from a door or the kit while the person recovers |

  `sensitive?/1` answers the table. `vault_unlock` and `home_transfer`
  have no operation until their features land, and stay sensitive.
  `action_for/1` maps each operation that confirms something to its
  action. `credential_sharing` is a widening of who or what may use an
  instance entry (`instance_entry.set_audience`,
  `instance_entry.set_component_policy`); whether a request widens is
  decided from the stored entry by `Sanctum.InstanceEntries`, which asks
  for the confirmation only then.

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
    credential_sharing: :fresh,
    vault_unlock: :fresh,
    home_transfer: :fresh,
    pairing_revocation: :fresh,
    recovery_material: :fresh,
    device_pairing: :fresh,
    passkey_registration: :fresh,
    remote_sign_in: :fresh,
    key_rotation: :fresh,
    sign_in_methods: :fresh,
    seal_change: :fresh,
    restore_reenable: :fresh
  }

  # Each operation that confirms something, as `tool.action`, the spelling
  # a pending confirmation records (`Prima.Confirmation`). The two rebinds
  # confirm a widening only: their deciding site decides which rebind
  # widens and asks there (`Sanctum.Vault.rebind_confirmation/5`), so this
  # table makes no narrowing rebind confirm anything. `seal.change` is the
  # spelling of the seal's change (`Sanctum.Seal.change/2`), which the
  # system layer makes and no gate operation exposes.
  @operations %{
    "vault.create" => :credential_entry,
    "vault.rotate" => :credential_entry,
    "vault.rebind" => :credential_entry,
    "vault.authorize" => :credential_entry,
    "oauth.set_client" => :credential_entry,
    "instance_entry.create" => :credential_entry,
    "instance_entry.rotate" => :credential_entry,
    "instance_entry.rebind" => :credential_entry,
    "instance_entry.set_audience" => :credential_sharing,
    "instance_entry.set_component_policy" => :credential_sharing,
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
    "person.unlink_door" => :sign_in_methods,
    "seal.change" => :seal_change,
    "key.reenable" => :restore_reenable,
    "webhook.reenable" => :restore_reenable,
    "pairing.reenable" => :restore_reenable,
    "passkey.reenable" => :restore_reenable
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
          | :credential_sharing
          | :vault_unlock
          | :home_transfer
          | :pairing_revocation
          | :recovery_material
          | :device_pairing
          | :passkey_registration
          | :remote_sign_in
          | :key_rotation
          | :sign_in_methods
          | :seal_change
          | :restore_reenable

  @typedoc """
  An opened invitation: its raw `invitation_secret` (16 bytes, shown to
  the person once, in the pairing code, and stored nowhere), the
  `client_id` it reserves for the device that redeems it, the
  `key_digest` of the one device key that may, and when it expires.
  """
  @type invitation :: %{
          invitation_secret: binary(),
          client_id: String.t(),
          key_digest: String.t(),
          expires_at: DateTime.t()
        }

  @typedoc """
  Who gave a consumed confirmation: the passkey whose assertion proved it,
  the paired client it was given on, or `nil` for neither.
  """
  @type confirmer :: {:passkey, String.t()} | {:device, String.t()} | nil

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
  What a re-enabling after a declared restore rests on: the confirmation
  `ctx` names (`Sanctum.Consent.Authz`), or a recovery kit's credential,
  its person and the digest of the credential the kit ingress issued.
  """
  @type proof :: :confirmation | {:kit, %{user_id: String.t(), credential_digest: String.t()}}

  @typedoc """
  The ceremony's refusals, beside the ones it passes on from the stores,
  the gate's standing checks and a confirmation:

    * `:invalid_invitation` — no pending, unexpired invitation has that
      secret: unknown, used, withdrawn or expired alike, so the answer
      says nothing about which.
    * `:key_mismatch` — the device key presented is not the one whose
      digest the invitation was opened for.
    * `:confirmer_revoked` — the passkey or paired client that confirmed
      the invitation no longer stands.
    * `t:Prima.Refusal.t/0` with reason `:standing_confirmer_required`
      (`addition_refusal/0`) — a device, passkey or door added on a
      confirmation no passkey or paired client gave, once the person's
      first-method latch is set.
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
          | :key_mismatch
          | :confirmer_revoked
          | Prima.Refusal.t()
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
  focus (the module doc). `args` names `key_digest` (or `"key_digest"`),
  the digest of the device key the new glass shows
  (`Prima.Device.key_digest/1`).

  The `device_pairing` confirmation is asked first, for exactly that key
  digest (`Sanctum.Consent.Authz.check/3`), and consumed inside the
  transaction that opens the invitation (`Sanctum.Consent.Authz.consume/2`),
  under the person, athanor and seat locked and checked at the
  generations the context read, and the credential the context holds (its
  session, or a paired device's client and certificate) locked and checked
  after them (`Sanctum.Issuance`). The invitation records the passkey or
  paired client the consumed confirmation names, read from its row in that
  transaction; one that names neither opens only while the person's
  first-method latch is open (the module doc). Answers `t:invitation/0`.
  """
  @spec begin(Context.t(), map()) :: {:ok, invitation()} | {:error, refusal()}
  def begin(%Context{} = ctx, args) when is_map(args) do
    with :ok <- person_focused(ctx),
         {:ok, key_digest} <- key_digest_argument(args),
         change = invitation_change(key_digest),
         :ok <- Authz.check(ctx, :device_pairing, change),
         {:ok, expectation} <- Sanctum.Issuance.expectation(ctx, []),
         {:ok, membership_id} <- seated(expectation) do
      secret = :crypto.strong_rand_bytes(@secret_bytes)

      attrs = %{
        user_id: ctx.user_id,
        membership_id: membership_id,
        secret_hash: secret_hash(secret),
        key_digest: key_digest,
        confirmation_ref: confirmation_ref(ctx),
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
             key_digest: invitation.key_digest,
             expires_at: invitation.expires_at
           }}

        {:error, :database_error} ->
          {:error, :unavailable}

        {:error, :first_method_used} ->
          {:error, addition_refusal()}

        {:error, :confirmation_unconsumed} ->
          {:error, :unavailable}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp key_digest_argument(args) do
    digest = Map.get(args, :key_digest, Map.get(args, "key_digest"))

    if Prima.Device.key_digest?(digest),
      do: {:ok, digest},
      else:
        {:error,
         {:invalid_argument,
          "The key_digest is the code the new device shows: unpadded base64url of 32 bytes"}}
  end

  defp confirmation_ref(%Context{confirmation_id: id}) when is_binary(id) and id != "",
    do: Prima.Confirmation.ref(id)

  defp confirmation_ref(%Context{}), do: nil

  @doc """
  What confirming a pairing approves (`t:Sanctum.Consent.Authz.change/0`),
  the change `begin/2` decides: an invitation for the device key whose
  digest is `key_digest`, which the preview names as the code the new
  device shows (`Prima.Device.key_code/1`).
  """
  @spec invitation_change(String.t()) :: Sanctum.Consent.Authz.change()
  def invitation_change(key_digest) when is_binary(key_digest) do
    code = Prima.Device.key_code(key_digest)

    %{
      operation: "pairing.begin",
      arguments: %{"key_digest" => key_digest},
      resource: "the device showing " <> code,
      details: %{
        "device" => code,
        "invitation" =>
          "The device that shows this code, and no other, pairs within " <>
            "#{@invitation_minutes} minutes and acts as you in this athanor until you revoke it."
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

  `ctx` is the caller's, and anonymous: its address is what a call that
  names no invitation is counted by, and nothing in it chooses the
  person. A call that names one is counted against its person's budget
  before anything more is read (the module doc).
  """
  @spec complete(Context.t(), binary(), submission()) ::
          {:ok, %{required(:challenge) => Challenge.t(), optional(:certify) => certify()}}
          | {:ok, paired()}
          | {:error, refusal()}
  def complete(%Context{} = ctx, secret, %{device_key: device_key} = submission)
      when is_binary(secret) and byte_size(secret) == @secret_bytes and is_binary(device_key) and
             byte_size(device_key) == 32 do
    now = now_ms()
    source = ctx.client_ip

    with :ok <- DeviceCerts.verification_room(source),
         {:ok, invitation} <- invitation(secret, now, source),
         :ok <- DeviceCerts.claim_attributed({:person, invitation.user_id}),
         :ok <- this_home(invitation),
         :ok <- approved_key(invitation, device_key),
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

  # The invitation the secret names, which makes the attempt its person's:
  # only the invitation's bearer holds the secret. A secret that names no
  # pending invitation is no one's, counted against the address and the
  # installation.
  defp invitation(secret, now, source) do
    case pending_invitation(secret, now) do
      {:ok, invitation} -> {:ok, invitation}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, refused} -> DeviceCerts.refuse_unattributed(source, refused)
    end
  end

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

  # Routing only, before any challenge is answered: the key presented is
  # the one the invitation was opened for. The redemption holds it again
  # under the invitation's lock.
  defp approved_key(%{key_digest: expected}, device_key) when is_binary(expected) do
    if Plug.Crypto.secure_compare(expected, Prima.Device.key_digest(device_key)),
      do: :ok,
      else: {:error, :key_mismatch}
  end

  defp approved_key(_invitation, _device_key), do: {:error, :key_mismatch}

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
        Prima.Device.key_digest(device_key),
        &redeemable(&1, invitation),
        &paired(actor, &1, device_key, issuer)
      )
      |> redeemed()
    end
  end

  # The standing a redemption is held to, over the rows locked for it: the
  # person the invitation names active, the athanor open, and their seat
  # there still active. A platform row is no seat: an invitation resting on
  # one, however it was opened, pairs nothing.
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
  defp redeemed({:error, :first_method_used}), do: {:error, addition_refusal()}
  defp redeemed({:error, :no_identity}), do: {:error, :unavailable}
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
  Re-enable the paired client `client_id`, which a declared restore
  suspended, under `proof` (`t:proof/0`). Answers `%{client: %{client_id:,
  label:, standing: "active"}, recovery_closed:}`, `recovery_closed` true
  when this closed the person's open restore, as re-enabling a method
  does (`Arca.PairedClients.reenable/4`).

  With `:confirmation`, `ctx` is the person's own, in the athanor in focus
  where the client is: a sensitive change (`:restore_reenable`), asked
  first and consumed in the transaction that writes the client, where,
  while the person's restore is open, a confirmation a passkey or a paired
  client gave is refused (`restore_confirmed/1`), so no suspended method
  approves its own return. With `{:kit, %{user_id:, credential_digest:}}`
  the kit ingress has verified the person's recovery kit; the client may
  be in any athanor of theirs, and the write admits it only while the
  credential stands under their open restore (`kit_confirmed/2`).

  No certificate is issued: the device reconnects under its certificate
  while it is unexpired, or renews it through its channel (`renew/2`),
  which reads the client active again.

  Refusals: `{:not_found, "paired client", id}`, a `t:Prima.Refusal.t/0`
  with reason `:revoked` (a revoked client is never revived) or
  `:not_suspended`, `kit_refusal/0` (the kit's credential no longer
  stands), `restore_source_refusal/0`, the consent signal, and the
  context's and the stores' own (`:unauthenticated`, `:missing_tenant`,
  `:unavailable`).
  """
  @spec reenable(Context.t(), String.t(), proof()) :: {:ok, map()} | {:error, refusal()}
  def reenable(%Context{} = ctx, client_id, :confirmation) when is_binary(client_id) do
    with :ok <- person_focused(ctx),
         {:ok, client} <- own_client(ctx, client_id),
         :ok <- reenable_ready(client),
         change = reenable_change(client),
         :ok <- Authz.check(ctx, :restore_reenable, change) do
      verify = fn _row ->
        with :ok <- Authz.consume(ctx, {:restore_reenable, change}), do: restore_confirmed(ctx)
      end

      case Arca.PairedClients.reenable(Context.actor(ctx), ctx.user_id, client_id, verify: verify) do
        {:ok, row} ->
          Authz.consumed(ctx)
          {:ok, reenabled(row)}

        {:error, reason} ->
          {:error, reenable_refusal(reason, client_id)}
      end
    end
  end

  def reenable(
        %Context{},
        client_id,
        {:kit, %{user_id: user_id, credential_digest: digest}}
      )
      when is_binary(client_id) and is_binary(user_id) and is_binary(digest) do
    with {:ok, client} <- persons_client(user_id, client_id) do
      case Arca.PairedClients.reenable(
             Prima.Actor.in_athanor(client.athanor_id),
             user_id,
             client_id,
             verify: fn _row -> kit_confirmed(user_id, digest) end
           ) do
        {:ok, row} -> {:ok, reenabled(row)}
        {:error, reason} -> {:error, reenable_refusal(reason, client_id)}
      end
    end
  end

  def reenable(%Context{}, _client_id, _proof),
    do: {:error, {:invalid_argument, "Name the paired client and how its return is proven"}}

  # Read before anything is asked, so a person is never asked to confirm a
  # return the write would refuse; the write reads it again under its lock.
  defp reenable_ready(%{standing: "suspended"}), do: :ok
  defp reenable_ready(%{standing: "revoked"}), do: {:error, reenable_refusal(:revoked, nil)}
  defp reenable_ready(_active), do: {:error, reenable_refusal(:not_suspended, nil)}

  defp reenable_change(client) do
    %{
      operation: "pairing.reenable",
      arguments: %{"client_id" => client.id},
      resource: client.label || client.id,
      details: %{
        "effect" =>
          "This device, suspended when this home was restored from a backup, stands for you again"
      }
    }
  end

  # The person's client of that id in whichever athanor holds it, for the
  # kit, which names no athanor.
  defp persons_client(user_id, client_id) do
    case Arca.PairedClients.list(Prima.Actor.system(), user_id: user_id, standing: :all) do
      {:ok, rows} ->
        case Enum.find(rows, &(&1.id == client_id)) do
          nil -> {:error, {:not_found, "paired client", client_id}}
          row -> {:ok, row}
        end

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp reenabled(row) do
    %{
      client: %{client_id: row.id, label: row.label, standing: row.standing},
      recovery_closed: row.closed_restore_ids != []
    }
  end

  defp reenable_refusal(:not_found, client_id), do: {:not_found, "paired client", client_id}

  defp reenable_refusal(:revoked, _client_id),
    do: %Prima.Refusal{
      class: :conflict,
      reason: :revoked,
      message:
        "This device's pairing was revoked, and a revoked pairing is never re-enabled: " <>
          "pair it again"
    }

  defp reenable_refusal(:not_suspended, _client_id),
    do: %Prima.Refusal{
      class: :conflict,
      reason: :not_suspended,
      message: "This device is not suspended: there is nothing to re-enable"
    }

  defp reenable_refusal(reason, _client_id)
       when reason in [:database_error, :not_owner, :no_athanor],
       do: :unavailable

  defp reenable_refusal(reason, _client_id), do: reason

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
  # Adding a method or a device
  # ---------------------------------------------------------------------------

  @additions ~w(pairing.begin person.certify passkey.register person.link_door)

  @doc """
  Whether the operation `operation` (`tool.action`) adds a way to act as
  the person here (the module doc): pairing a device, certifying one for
  another home, registering a passkey or linking a door.
  """
  @spec addition?(String.t()) :: boolean()
  def addition?(operation) when is_binary(operation), do: operation in @additions

  @doc """
  Who gave the confirmation `ctx.confirmation_id` names (`t:confirmer/0`),
  read from its record in the context's athanor: the passkey whose
  assertion proved it, else the paired client it was given on, else
  `nil`. A record is attributed once, when it is confirmed, and never
  again, so the answer read once it is confirmed holds through its
  consumption. A context that names no record, or a record of another
  person, is `nil`.
  """
  @spec confirmer(Context.t()) :: {:ok, confirmer()} | {:error, :unavailable}
  def confirmer(%Context{confirmation_id: id, athanor_id: a, user_id: u} = ctx)
      when is_binary(id) and id != "" and is_binary(a) and a != "" and is_binary(u) do
    case Arca.PendingConfirmations.get(Context.actor(ctx), Prima.Confirmation.ref(id)) do
      {:ok, %{user_id: ^u, confirmed_passkey_id: passkey_id}} when is_binary(passkey_id) ->
        {:ok, {:passkey, passkey_id}}

      {:ok, %{user_id: ^u, confirmed_client_id: client_id}} when is_binary(client_id) ->
        {:ok, {:device, client_id}}

      {:ok, _unattributed} ->
        {:ok, nil}

      {:error, :not_found} ->
        {:ok, nil}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  def confirmer(%Context{}), do: {:ok, nil}

  @doc """
  Whether the addition whose confirmation `ctx` just consumed may be
  written, inside the transaction that writes it (the module doc): a
  confirmation a passkey or paired client gave always may; one neither
  gave only while the person's first-method latch is open, read under
  the person's lock (`Arca.PersonIdentities.first_method_open?/2`), so a
  latch set by a write that committed first refuses it and one that starts
  later waits. A write that itself sets the latch claims it instead
  (`Sanctum.Passkeys`, `Arca.PairingInvitations`).
  """
  @spec addition_confirmed(Context.t()) :: :ok | {:error, Prima.Refusal.t() | :unavailable}
  def addition_confirmed(%Context{user_id: user_id} = ctx) when is_binary(user_id) do
    case confirmer(ctx) do
      {:ok, nil} ->
        case Arca.PersonIdentities.first_method_open?(Prima.Actor.system(), user_id) do
          {:ok, true} -> :ok
          {:ok, false} -> {:error, addition_refusal()}
          {:error, _unanswered} -> {:error, :unavailable}
        end

      {:ok, _confirmer} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def addition_confirmed(%Context{}), do: {:error, addition_refusal()}

  @doc """
  The refusal of an addition confirmed by neither a passkey nor a paired
  client once the person's first-method latch is set, in the one refusal
  shape every surface renders.
  """
  @spec addition_refusal() :: Prima.Refusal.t()
  def addition_refusal do
    %Prima.Refusal{
      class: :forbidden,
      reason: :standing_confirmer_required,
      message:
        "Once you hold a passkey or a paired device here, adding a device, a passkey or a " <>
          "sign-in needs a confirmation from one of them: confirm with your passkey, or on a " <>
          "device you paired"
    }
  end

  # ---------------------------------------------------------------------------
  # After a declared restore
  # ---------------------------------------------------------------------------

  @doc """
  Whether the change whose confirmation `ctx` just consumed may be written
  while the person recovers from a declared restore, inside the
  transaction that writes it, the person's `restore_people` row locked
  there (`Arca.SecurityTransitions.restore_open!/1`): while the row is
  open, only a confirmation no passkey and no paired client gave — a door
  this home re-authenticated, a forced-fresh sign-in or an emailed code —
  may; once it has closed, any confirmation may. A restored passkey or
  device is suspended and asserts nothing, so this holds even if one were
  to stand again some other way before the person recovers.
  """
  @spec restore_confirmed(Context.t()) :: :ok | {:error, Prima.Refusal.t() | :unavailable}
  def restore_confirmed(%Context{user_id: user_id} = ctx) when is_binary(user_id) do
    case Arca.SecurityTransitions.restore_open!(user_id) do
      nil ->
        :ok

      _restore_id ->
        case confirmer(ctx) do
          {:ok, nil} -> :ok
          {:ok, _passkey_or_device} -> {:error, restore_source_refusal()}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def restore_confirmed(%Context{}), do: {:error, restore_source_refusal()}

  @doc """
  Whether a re-enabling the recovery kit proves may be written, inside the
  transaction that writes it, after the item's lock: the person's
  `restore_people` row is open, locked there
  (`Arca.SecurityTransitions.restore_open!/1`), and the kit credential
  whose digest is `credential_digest` stands under it, unexpired
  (`Arca.SecurityTransitions.kit_stands!/2`). Otherwise `kit_refusal/0`:
  the kit authorizes nothing once the person's restore has closed.
  """
  @spec kit_confirmed(String.t(), String.t()) :: :ok | {:error, Prima.Refusal.t()}
  def kit_confirmed(user_id, credential_digest)
      when is_binary(user_id) and is_binary(credential_digest) do
    with restore_id when is_binary(restore_id) <-
           Arca.SecurityTransitions.restore_open!(user_id),
         {:ok, _restore_id} <- Arca.SecurityTransitions.kit_stands!(user_id, credential_digest) do
      :ok
    else
      _closed_or_spent -> {:error, kit_refusal()}
    end
  end

  @doc """
  The refusal of a recovery kit's credential that no longer stands: it
  expired, or the person's restore has closed.
  """
  @spec kit_refusal() :: Prima.Refusal.t()
  def kit_refusal do
    %Prima.Refusal{
      class: :unauthenticated,
      reason: :not_standing,
      message:
        "Your recovery kit's credential no longer stands here: it expired, or your recovery " <>
          "from the restore has ended"
    }
  end

  @doc """
  The refusal of a confirmation a passkey or paired device gave while the
  person recovers from a declared restore, in the one refusal shape every
  surface renders.
  """
  @spec restore_source_refusal() :: Prima.Refusal.t()
  def restore_source_refusal do
    %Prima.Refusal{
      class: :forbidden,
      reason: :restore_source_required,
      message:
        "This home was restored from a backup: until you re-enable a passkey or a device, " <>
          "confirm with a fresh sign-in, an emailed code or your recovery kit"
    }
  end

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
