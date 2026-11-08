# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Pairing do
  @moduledoc """
  The devices connected here, which changes need a fresh confirmation,
  and which clients can give one.

  Three facts stay apart: who a person is, established by their session;
  which devices they have connected; and whether a change needs a fresh
  confirmation. None of them is a rank, and the rule is the same for every
  person: members stay equals.

  ## The devices connected here

  A device of a person's account comes here by its hello
  (`Sanctum.DeviceUnlock`), which pairs it as a paired client that is a
  key of the account (`kid`) and issues its first certificate under this
  CYFR's installation key (`Sanctum.DeviceCerts`).

    * `renew/2` — a paired device's replacement certificate, through its
      device channel's renewal exchange alone: after the channel verified
      a fresh `renew` challenge it issued and holds against the key the
      paired-client row stores (`Sanctum.DeviceCerts.verify_connect/3`),
      with the proof consumed once, and only while the client and its
      person stand; a revoked client is never revived. The certificate is
      issued under the account head this CYFR holds now, under the
      issuance fence.
    * `revoke/2` — a person ends one of their paired clients, with its
      certificates and the confirmations it confirmed, in one transaction
      (`Arca.PairedClients.revoke/2`). A sensitive change
      (`pairing_revocation`).
    * `list/1` — the person's paired clients in the athanor in focus, a
      protected device's with what it reports of its disks
      (`Sanctum.DeviceUnlock.storage/2`).

  ## After a declared restore

  A declared restore suspends every paired client and revokes every
  certificate (`Arca.SecurityTransitions`), and nothing re-enables them: a
  device comes back by a fresh hello, which pairs it anew. What the person
  re-enables is an API key or a webhook they created
  (`Sanctum.ApiKey.reenable/2`, `Sanctum.Webhook.reenable/2`), each a
  sensitive change (`:restore_reenable`); `restore_checklist/1` lists
  those and what the restore asked for again in their athanor.

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
  | `:restore_reenable` | a fresh confirmation |
  | `:directory_tombstone` | a fresh confirmation, the platform administrator's |

  `sensitive?/1` answers the table. `vault_unlock` and `home_transfer`
  are sensitive, and no operation makes either (each is *Not built yet*
  in ARCHITECTURE.md). `credential_sharing` is offering a key to more
  people than before: a new share (`share.create`) and a share's audience
  widened to everyone or to another group (`share.set_audience`), decided
  by `Sanctum.Shares`. Whether a change widens is decided from the stored
  row, and the confirmation is asked only then.

  `sensitive?/1` is what the deciding sites ask
  (`Sanctum.Consent.Authz.confirm/3`): the table's answer, so a sensitive
  change needs a pending confirmation that a key of the person's account
  confirmed, whoever makes it. No setting or client turns a row off: the
  table is this module's constant, the same at every home.

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
  alias Sanctum.{Context, DeviceCerts}
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
    restore_reenable: :fresh,
    directory_tombstone: :fresh
  }

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
          | :restore_reenable
          | :directory_tombstone

  @typedoc "A paired client and the certificate it connects under."
  @type paired :: %{client_id: String.t(), certificate: DeviceCert.t()}

  @typedoc """
  What a device submits to `renew/2`: its client, its device key and its
  proof, as its channel forwards it (`Prima.DeviceCert.Proof`'s JSON map).
  """
  @type renewal :: %{
          required(:client_id) => String.t(),
          required(:device_key) => binary(),
          required(:proof) => map()
        }

  @typedoc """
  The refusals, beside the ones passed on from the stores, the gate's
  standing checks and a confirmation:

    * `:proof_refused` — the proof does not answer the challenge under the
      device key the client's row stores, or the challenge is not one this
      CYFR issued for that client.
    * `:stale_head` — the account's head moved while the certificate was
      issued: nothing was written, and the next renewal issues under the
      new head.
    * `:not_standing` — the person is denied, the athanor archived or the
      athanor no longer theirs.
    * `:revoked` — the paired client was revoked.
    * `:renewal_exchange_only` — a renewal from anything but the renewal
      exchange of the client's own device channel: an ordinary device
      context, a session or any other.
    * `:replayed` — a renewal proof already consumed.
    * `:unavailable` — the store could not answer.
  """
  @type refusal ::
          :proof_refused
          | :stale_head
          | :not_standing
          | :revoked
          | :renewal_exchange_only
          | :replayed
          | :unavailable
          | term()

  # ---------------------------------------------------------------------------
  # The devices connected here
  # ---------------------------------------------------------------------------

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
  its person keep their standing and athanor. Then
  the proof is consumed: its challenge's nonce is claimed once, durably,
  for the challenge's lifetime (`Arca.RequestRateWindows`, a bound of one
  per nonce), so of any number of renewals presenting one proof, on any
  member, one alone goes on to issue, and every other is `:replayed`. A
  proof consumed by an issuance that then fails is spent: the glass asks
  for another challenge. The certificate is issued under the account head
  this CYFR holds for the person now and recorded under the issuance
  fence (`Sanctum.DeviceCerts.issue/2`): a head that moves meanwhile is
  `:stale_head`. Answers `t:paired/0`.
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

    with {:ok, proof} <- read_proof(proof),
         :ok <- renewal_proof(proof, ctx, device_key, now),
         {:ok, client} <- DeviceCerts.paired_client(a, user_id, client_id),
         :ok <- stored_key(client, device_key),
         {:ok, _standing} <- DeviceCerts.standing(user_id, a),
         {:ok, head} <- account_head(user_id),
         :ok <- consumed(proof),
         {:ok, certificate} <- DeviceCerts.issue(client, head) do
      {:ok, %{client_id: client_id, certificate: certificate}}
    end
  end

  def renew(%Context{}, _renewal), do: {:error, :renewal_exchange_only}

  defp renewal_proof(%Proof{challenge: %Challenge{} = presented} = proof, ctx, device_key, now) do
    with {:ok, home} <- Sanctum.SignIn.audience() do
      expected = %Challenge{
        presented
        | purpose: :renew,
          home: home,
          athanor: ctx.athanor_id,
          client_id: ctx.client_id,
          device_key: device_key
      }

      with :ok <- issued_window(proof, now), do: verified(Proof.verify(proof, expected, now))
    end
  end

  # The account head this CYFR holds for the person now: the head a
  # renewed certificate is issued under.
  defp account_head(user_id) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{head_hash: head}} when is_binary(head) -> {:ok, head}
      {:ok, _none} -> {:error, :not_standing}
      {:error, :not_found} -> {:error, :not_standing}
      {:error, _unanswered} -> {:error, :unavailable}
    end
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
  (`pairing_revocation`, `Sanctum.Consent.Authz.confirm/3`). Once the
  revocation commits it is announced as a standing change of the person
  (`Sanctum.Telemetry.sessions_revoked/1`), so every holder of their
  context, the client's device channel among them, reads the standing
  again at once rather than at its next ping, and the channel refuses the
  client and closes. Answers the client's row as revoked.

  Until a lost device's pairing is revoked, what it cached and the device
  key it holds are the exposure: that key renews its certificate while the
  pairing stands (`renew/2`), so a certificate's expiry does not end it.
  The revocation erases nothing the device already received.
  """
  @spec revoke(Context.t(), String.t()) :: {:ok, map()} | {:error, refusal()}
  def revoke(%Context{} = ctx, client_id) when is_binary(client_id) do
    with :ok <- person_focused(ctx),
         {:ok, client} <- own_client(ctx, client_id) do
      revoke_client(ctx, client)
    end
  end

  defp revoke_client(ctx, %{id: client_id}) do
    with :ok <-
           Authz.confirm(ctx, :pairing_revocation, %{
             operation: "pairing.revoke",
             arguments: %{"client_id" => client_id},
             resource: client_id
           }) do
      case Arca.PairedClients.revoke(Context.actor(ctx), client_id) do
        {:ok, row} ->
          # The announcement makes each listener revalidate, never drop
          # unread: a holder of the person's context whose own credential
          # still stands keeps it, and only the revoked client's goes.
          :ok = Sanctum.Telemetry.sessions_revoked(row.user_id)
          {:ok, row}

        {:error, :database_error} ->
          {:error, :unavailable}

        {:error, reason} ->
          {:error, reason}
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
  oldest first, the passkeys of their account that signed in here among
  them (`Sanctum.SignIn` records them): each with its id, the credential it stands on
  (`device_cert` or `passkey`), when it was paired or first signed in
  here, when its current certificate expires (nil for none current, and
  always for a passkey), whether it is the client `ctx` itself came
  through, what holds a device's key, its name and its storage.
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
      source: row.source_kind,
      paired_at: row.inserted_at,
      certificate_expires_at: expires_at,
      current: row.id == ctx.client_id,
      holder_kind: row.holder_kind,
      display_name: row.display_name,
      storage: holder_storage(row)
    }
  end

  # What a protected device last reported of its disks within the last
  # minute (`Sanctum.DeviceUnlock.storage/2`), unknown when it reported
  # nothing; a passkey reports nothing at all.
  defp holder_storage(%{holder_kind: nil}), do: nil
  defp holder_storage(row), do: Sanctum.DeviceUnlock.storage(row.athanor_id, row.id)

  # ---------------------------------------------------------------------------
  # Proofs
  # ---------------------------------------------------------------------------

  # The proof as the glass or the channel sends it, its JSON map
  # (`Prima.DeviceCert.Proof.decode/1`, which refuses anything else).
  defp read_proof(proof) do
    case Proof.decode(proof) do
      {:ok, proof} -> {:ok, proof}
      {:error, _malformed} -> {:error, :proof_refused}
    end
  end

  # A challenge this home issued expires at most one lifetime from now: one
  # that expires later was not issued here.
  defp issued_window(%Proof{challenge: %Challenge{expires_at: expires_at}}, now) do
    if expires_at <= now + Challenge.lifetime_ms(), do: :ok, else: {:error, :proof_refused}
  end

  defp verified(:ok), do: :ok
  defp verified({:error, _refused}), do: {:error, :proof_refused}

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

  defp now_ms, do: System.os_time(:millisecond)

  # ---------------------------------------------------------------------------
  # After a declared restore
  # ---------------------------------------------------------------------------

  @doc """
  The person's restore checklist, which the system layer draws: every API
  key and webhook they created that a declared restore holds suspended,
  each re-enabled by its own operation (`key.reenable`,
  `webhook.reenable`) under a fresh confirmation, and with them every
  profile to consent to again and every vault entry to rotate in their
  athanor (`Arca.SecurityTransitions.restore_checklist/2`). `{:ok, nil}`
  while no key or webhook of theirs is suspended: only a declared restore
  suspends one, so a profile or entry blocked for another reason draws no
  checklist.
  """
  @spec restore_checklist(Context.t()) ::
          {:ok, map() | nil} | {:error, :unauthenticated | :unavailable}
  def restore_checklist(%Context{user_id: user_id}) when is_binary(user_id) and user_id != "" do
    case Arca.SecurityTransitions.restore_checklist(Prima.Actor.system(), user_id) do
      {:ok, %{api_keys: [], webhooks: []}} -> {:ok, nil}
      {:ok, list} -> {:ok, list}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  def restore_checklist(%Context{}), do: {:error, :unauthenticated}

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
