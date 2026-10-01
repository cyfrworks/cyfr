# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Person do
  @moduledoc """
  A person's online keys at their home: the live key, which signs device
  certificates, person assertions for doors and the envelopes of their
  sign-in carries, and the operational key, which signs their log's
  genesis and the rotations that replace the live key and nothing else.

  ## Where the keys are

  Both are Ed25519 key pairs minted at the person's first admitted sign-in
  (`mint_keys/1`, the `also:` closure `Sanctum.Tenancy.Users` hands
  `Arca.Users.mint/4`), so the person row, their first door and their key
  set commit in one transaction and no person exists without keys. The
  public halves and the sealed private halves are columns of the person's
  own identity row (`Arca.PersonIdentities`, provenance `local`), never an
  athanor's vault, since a person's keys outlive every athanor. Each
  private half is sealed with `Sanctum.Cipher` under
  `Sanctum.CipherAAD.person_key/2`: the person's frame and the key's role,
  so a sealed key never opens for another person or as another role.

  Holding both online keys at one home is purpose separation only: they
  share the home's compromise boundary. Recovery keys are held away from
  the home, and no function here reads, adds or replaces one.

  ## Who holds a private key

  Every use of a person's private key is in this module or in
  `Sanctum.Recovery`; the keyring's re-seal (`Sanctum.Cipher.Rotation`)
  moves the sealed bytes to a new key and signs nothing. A private key is
  opened, used and dropped inside one private step: it never leaves this
  module, never reaches a log, an error term, telemetry or an inspect, and
  a raise while one is in hand is answered `{:error, :unavailable}` with
  only the exception's module logged, since the raise's stacktrace would
  carry the key in its arguments. A key opens only when its public half is
  the one the row names, so a sealed column moved to another role opens
  nothing and signs nothing.

  ## Refusals

    * `:not_found` — the person has no local key set: no identity row, or
      a remote person, whose keys live at another home.
    * `:not_enrolled` — the request needs an identifier and the person has
      none yet; `:already_enrolled`, a genesis for a person who has one.
    * `:stale_key_epoch` — an envelope or an assertion naming a head the
      person's row no longer holds.
    * `:wrong_audience` — a local-subject certificate for another home.
    * `:unavailable` — the keys cannot be opened: the store or the keyring
      cannot answer, or a sealed key does not open as its role.

  A person assertion (`sign_assertion/3`) answers, besides these, the
  `confirmation_required` signal and the confirmation's other refusals,
  `{:invalid_argument, _}` for a sign-in no pending carry of theirs names,
  and `{:conflict, _}` for one that can no longer be signed.

  A malformed argument is refused as the Prima shape it would have built
  refuses it (`{:invalid_field, name}`).
  """

  require Logger

  alias Prima.Identity
  alias Prima.Identity.Entry
  alias Sanctum.CipherAAD

  @typedoc "What a device certificate is issued for: its subject's kind, the home it is presented to and the athanor."
  @type cert_request :: %{
          required(:subject) => :local | :identity,
          required(:audience) => String.t(),
          required(:athanor) => String.t()
        }

  @typedoc """
  A staged rotation, the fields `Arca.IdentityAttempts.open/3` takes for
  one: the signed rotate entry's JCS bytes, its hash (also the attempt's
  request digest), and the new live key, its private half sealed to the
  person as their live key.
  """
  @type staged_rotation :: %{
          entry: binary(),
          entry_hash: String.t(),
          staged_live_public_key: binary(),
          staged_live_key_sealed: binary()
        }

  @typedoc """
  What a person assertion is asked for: the relying home, its challenge
  (raw bytes) and the carry it serves, and optionally the `key_epoch` the
  asker expects it signed under.
  """
  @type assertion_request :: %{
          required(:audience) => String.t(),
          required(:challenge) => binary(),
          required(:action_id) => String.t(),
          optional(:key_epoch) => String.t() | nil
        }

  @doc """
  Mint the person's live and operational key set and write it on their
  identity row, provenance `local`, unenrolled: the `also:` closure a first
  admitted sign-in hands `Arca.Users.mint/4`, run inside the transaction
  that writes the person row, after the installation guard admitted it.

  One key set per person: a person who holds one is refused `:conflict`
  and keeps theirs. `:unavailable` when a key cannot be sealed, and the
  identity store's own refusals (`:not_owner` for a member that no longer
  owns its slot, `:database_error`) otherwise; any refusal rolls the whole
  mint back.
  """
  @spec mint_keys(%{required(:id) => String.t(), optional(atom()) => term()}) ::
          :ok
          | {:error,
             :unavailable
             | :conflict
             | :cross_tenant
             | :not_owner
             | :database_error
             | {:invalid, map()}}
  def mint_keys(%{id: user_id}) when is_binary(user_id) and user_id != "" do
    with {:ok, live} <- new_key(user_id, :live),
         {:ok, operational} <- new_key(user_id, :operational),
         {:ok, _row} <-
           Arca.PersonIdentities.create(Prima.Actor.system(), %{
             user_id: user_id,
             provenance: "local",
             live_public_key: live.public,
             live_key_sealed: live.sealed,
             operational_public_key: operational.public,
             operational_key_sealed: operational.sealed
           }) do
      :ok
    end
  end

  @doc """
  This home as certificates and assertions name it: the origin of
  `Sanctum.origin/0`, its scheme and host lowercased and a default port and
  any path dropped, so a public URL served under a path or spelled with
  capitals still names one home. Issuance and every audience check use it.
  A value that is still no origin `Prima.Identity.Encoding.home?/1`
  accepts fails closed where it is used, as a certificate's malformed
  `issuer`.
  """
  @spec home() :: String.t()
  def home do
    case URI.parse(Sanctum.origin()) do
      %URI{scheme: scheme, host: host, port: port}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        scheme = String.downcase(scheme)
        host = String.downcase(host)

        if port in [nil, URI.default_port(scheme)],
          do: scheme <> "://" <> host,
          else: scheme <> "://" <> host <> ":" <> Integer.to_string(port)

      _unparsed ->
        Sanctum.origin()
    end
  end

  @doc """
  A device certificate for `device_key` (32 raw bytes), held by the paired
  client `client_id`, for the home `request.audience` and the athanor
  `request.athanor`, signed by the person's live key.

  `issuer` is this home (`home/0`); `not_before` is now and
  `expires_at` is now plus the `device_cert_seconds` setting, both Unix
  milliseconds. The subject is one of:

    * `:local` — `%{kind: :local, user_id: user_id}`, valid only here, so
      its audience must be this home (`:wrong_audience` otherwise). It
      needs no identifier and reads no directory: an unenrolled person
      pairs locally.
    * `:identity` — `%{kind: :identity, identifier: …, key_epoch: …}`, the
      person's identifier and the `key_epoch` of the head their identity
      row names, for any home. It needs enrollment (`:not_enrolled`).

  Refusals: `:not_found`, `:not_enrolled`, `:wrong_audience`,
  `:unavailable` (the live key cannot be opened, or the validity setting
  cannot be read), and a malformed argument as `Prima.DeviceCert.new/1`
  refuses it.
  """
  @spec issue_device_cert(String.t(), binary(), String.t(), cert_request()) ::
          {:ok, Prima.DeviceCert.t()}
          | {:error,
             :not_found
             | :not_enrolled
             | :wrong_audience
             | :unavailable
             | Prima.DeviceCert.reason()}
  def issue_device_cert(user_id, device_key, client_id, %{
        subject: kind,
        audience: audience,
        athanor: athanor
      })
      when is_binary(user_id) and is_binary(device_key) and kind in [:local, :identity] do
    with {:ok, row} <- key_set(user_id),
         {:ok, subject} <- subject(kind, row, audience),
         {:ok, seconds} <- cert_seconds(),
         now = System.os_time(:millisecond),
         {:ok, cert} <-
           Prima.DeviceCert.new(
             device_key: device_key,
             client_id: client_id,
             subject: subject,
             issuer: home(),
             audience: audience,
             athanor: athanor,
             not_before: now,
             expires_at: now + seconds * 1_000
           ) do
      with_key(row, :live, fn live -> {:ok, Prima.DeviceCert.sign(cert, live)} end)
    end
  end

  @doc """
  Stage a rotation of the person's live key after the head
  `expected_head`, and write nothing: a new live key pair, its private
  half sealed as the person's live key, and the rotate entry naming its
  public half (`Prima.Identity.Entry.rotate/2`), signed by the operational
  key.

  Answers the rotation fields `Arca.IdentityAttempts.open/3` takes
  (`t:staged_rotation/0`), with `entry_hash` as the request digest too.
  Every call makes a new key, so a caller stages once per attempt and
  keeps the answer; the key replaces the live key only when an accepted,
  still-current attempt activates it.

  Refusals: `:not_found`, `:not_enrolled` (only an enrolled person has a
  log to extend), `:unavailable` (the operational key cannot be opened, or
  the new key cannot be sealed), and a malformed head as
  `Prima.Identity.Entry.rotate/2` refuses it.
  """
  @spec sign_rotate(String.t(), String.t()) ::
          {:ok, staged_rotation()}
          | {:error, :not_found | :not_enrolled | :unavailable | Prima.Identity.Encoding.reason()}
  def sign_rotate(user_id, expected_head) when is_binary(user_id) and is_binary(expected_head) do
    with {:ok, row} <- key_set(user_id),
         {:ok, row} <- enrolled(row),
         {:ok, staged} <- new_key(user_id, :live),
         {:ok, unsigned} <- Entry.rotate(expected_head, staged.public),
         {:ok, entry} <-
           with_key(row, :operational, fn operational ->
             {:ok, Identity.sign(unsigned, operational)}
           end) do
      {:ok,
       %{
         entry: Identity.canonical(entry),
         entry_hash: Identity.hash(entry),
         staged_live_public_key: staged.public,
         staged_live_key_sealed: staged.sealed
       }}
    end
  end

  @doc """
  The genesis entry of the person's identity log, and write nothing: their
  live and operational public keys, the recovery set `recovery_keys`
  (raw public keys) and the directory `directory` that will order it
  (`Prima.Identity.Entry.genesis/1`), signed by their operational key.

  Answers the genesis's JCS bytes (what enrollment stores and registers),
  the identifier they hash to and the entry's hash, its `key_epoch`. The
  same keys, set and directory sign to the same bytes, since Ed25519
  signing is deterministic.

  Refusals: `:not_found` (no local key set), `:already_enrolled` (the
  person has an identifier), `:unavailable` (the operational key cannot
  be opened), and a malformed set or directory as
  `Prima.Identity.Entry.genesis/1` refuses it.
  """
  @spec sign_genesis(String.t(), [binary()], String.t()) ::
          {:ok, %{genesis: binary(), identifier: String.t(), genesis_hash: String.t()}}
          | {:error,
             :not_found | :already_enrolled | :unavailable | Prima.Identity.Encoding.reason()}
  def sign_genesis(user_id, recovery_keys, directory)
      when is_binary(user_id) and is_list(recovery_keys) and is_binary(directory) do
    with {:ok, row} <- key_set(user_id),
         :ok <- unenrolled(row),
         {:ok, unsigned} <-
           Entry.genesis(
             live_key: row.live_public_key,
             operational_key: row.operational_public_key,
             recovery_keys: recovery_keys,
             directory: directory
           ),
         {:ok, genesis} <-
           with_key(row, :operational, fn operational ->
             {:ok, Identity.sign(unsigned, operational)}
           end) do
      {:ok,
       %{
         genesis: Identity.canonical(genesis),
         identifier: Identity.identifier(genesis),
         genesis_hash: Identity.hash(genesis)
       }}
    end
  end

  @doc """
  Sign a sign-in carry's envelope (`Prima.Carry.Envelope`) with the
  person's live key. The envelope must name the person's identifier and
  the `key_epoch` their identity row holds now, the head every remote home
  verifies it against.

  Refusals: `:not_found`, `:not_enrolled`, `:stale_key_epoch` (an
  envelope naming another identifier or an older head), `:unavailable`
  (the live key cannot be opened).
  """
  @spec sign_envelope(String.t(), Prima.Carry.Envelope.t()) ::
          {:ok, Prima.Carry.Envelope.t()}
          | {:error, :not_found | :not_enrolled | :stale_key_epoch | :unavailable}
  def sign_envelope(user_id, %Prima.Carry.Envelope{} = envelope) when is_binary(user_id) do
    with {:ok, row} <- key_set(user_id),
         {:ok, row} <- enrolled(row),
         :ok <- current(envelope, row) do
      with_key(row, :live, fn live -> {:ok, Prima.Carry.Envelope.sign(envelope, live)} end)
    end
  end

  defp current(%Prima.Carry.Envelope{identifier: identifier, key_epoch: epoch}, %{
         identifier: identifier,
         head_hash: epoch
       }),
       do: :ok

  defp current(_envelope, _row), do: {:error, :stale_key_epoch}

  defp unenrolled(%{identifier: nil}), do: :ok
  defp unenrolled(_row), do: {:error, :already_enrolled}

  @doc """
  A person assertion for the CYFR door (`Prima.PersonAssertion`): the live
  key vouching to `request.audience` for one sign-in, over its
  `challenge` (the 32 raw bytes that home issued) and the carry
  `action_id`, under the `key_epoch` the person's row holds. A
  `request.key_epoch`, when given, must be that one.

  It is decided in this order:

    1. the context's person, enrolled here with their keys (`:not_enrolled`;
       a person whose keys are at another home, `:not_found`);
    2. the `key_epoch` named, the row's (`:stale_key_epoch`);
    3. the audience, another home's origin;
    4. the carry: the person's own pending action naming exactly that
       audience as its destination, signed under the row's head (a
       sign-in no pending carry names, or one begun before the keys
       changed, is refused);
    5. an exact retry, the action already holding this challenge and its
       assertion, answers that assertion after the requester's standing
       is read again, with no new proof;
    6. the challenge, attached to the action once
       (`Arca.CarryActions.attach_challenge/3`) before any proof is asked,
       so the proof is over a challenge that can no longer change; another
       challenge needs another sign-in;
    7. `remote_sign_in` (`Sanctum.Consent.Authz.check/3`), whose preview
       names the audience: a session alone is answered
       `confirmation_required` and nothing is signed;
    8. the assertion, signed by the live key and expiring with the action,
       recorded on the action with the proof consumed in the same
       transaction (`Arca.CarryActions.record_assertion/4`).

  Answers `{:ok, %{assertion: %Prima.PersonAssertion{}, genesis: map}}`:
  what the browser carries back to the audience, the genesis beside the
  assertion so that home can find the person's directory. `opts` takes
  nothing yet.
  """
  @spec sign_assertion(Sanctum.Context.t(), assertion_request(), keyword()) ::
          {:ok, %{assertion: Prima.PersonAssertion.t(), genesis: map()}} | {:error, term()}
  def sign_assertion(
        %Sanctum.Context{user_id: user_id} = ctx,
        %{audience: audience, challenge: challenge, action_id: action_id} = request,
        opts
      )
      when is_binary(audience) and is_binary(challenge) and is_binary(action_id) and
             is_list(opts) do
    actor = Sanctum.Context.actor(ctx)

    with {:ok, row} <- assertion_signer(actor, user_id),
         :ok <- named_epoch(request, row),
         :ok <- other_home(audience),
         :ok <- challenge_bytes(challenge),
         {:ok, action} <- pending_carry(actor, action_id, audience, row),
         {:ok, genesis} <- own_genesis(actor, user_id) do
      case recorded(action, challenge) do
        {:ok, assertion} ->
          with :ok <- still_standing(ctx), do: {:ok, %{assertion: assertion, genesis: genesis}}

        :none ->
          signed_assertion(ctx, actor, row, action, challenge, genesis)
      end
    end
  end

  # The person who signs: their own local, enrolled key set, read as
  # themselves.
  defp assertion_signer(actor, user_id) do
    case identity(actor, user_id) do
      {:ok, %{provenance: "local", identifier: identifier} = row} when is_binary(identifier) ->
        enrolled(row)

      {:ok, %{provenance: "local"}} ->
        {:error, :not_enrolled}

      {:ok, _remote} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_enrolled}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp named_epoch(%{key_epoch: epoch}, %{head_hash: head}) when is_binary(epoch) do
    if epoch == head, do: :ok, else: {:error, :stale_key_epoch}
  end

  defp named_epoch(_request, _row), do: :ok

  defp other_home(audience) do
    cond do
      not Prima.Identity.Encoding.home?(audience) ->
        {:error, {:invalid_argument, "The audience is a home's origin, like https://hub.example"}}

      audience == home() ->
        {:error, {:invalid_argument, "An assertion is for another home than this one"}}

      true ->
        :ok
    end
  end

  defp challenge_bytes(challenge) do
    if byte_size(challenge) == Prima.PersonAssertion.challenge_bytes(),
      do: :ok,
      else: {:error, {:invalid_argument, "The challenge is the 32 bytes that home issued"}}
  end

  # The person's own source action, naming the audience as its destination,
  # still open and signed under the head their row holds now.
  defp pending_carry(actor, action_id, audience, row) do
    case Arca.CarryActions.get(actor, action_id) do
      {:ok, %{kind: "source", destination_home: ^audience, key_epoch: epoch} = action} ->
        cond do
          action.phase not in ["pending", "delivered"] ->
            {:error,
             {:conflict, "This sign-in is no longer pending; begin a new one from your home"}}

          epoch != row.head_hash ->
            {:error,
             {:conflict,
              "This sign-in was begun under keys your identity has since replaced; begin it again"}}

          true ->
            {:ok, action}
        end

      {:ok, _another} ->
        {:error,
         {:invalid_argument, "No pending sign-in of yours names that home; begin one first"}}

      {:error, reason} when reason in [:not_found, :cross_tenant] ->
        {:error,
         {:invalid_argument, "No pending sign-in of yours names that home; begin one first"}}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp own_genesis(actor, user_id) do
    with {:ok, %{genesis: genesis}} <- Arca.IdentityAttempts.genesis(actor, user_id),
         {:ok, %{} = map} <- Prima.Json.decode(genesis) do
      {:ok, map}
    else
      {:error, :not_found} -> {:error, :not_enrolled}
      _unanswered -> {:error, :unavailable}
    end
  end

  # The assertion an exact retry answers: the one already recorded for this
  # very challenge.
  defp recorded(%{assertion: bytes, challenge: attached}, challenge)
       when is_binary(bytes) and is_binary(attached) do
    with true <- attached == Prima.Identity.Encoding.b64(challenge),
         {:ok, %{} = map} <- Prima.Json.decode(bytes),
         {:ok, assertion} <- Prima.PersonAssertion.decode(map) do
      {:ok, assertion}
    else
      _other -> :none
    end
  end

  defp recorded(_action, _challenge), do: :none

  defp still_standing(ctx) do
    case Sanctum.Caller.revalidate_session(ctx) do
      {:ok, _standing} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp signed_assertion(ctx, actor, row, action, challenge, genesis) do
    change = assertion_change(action, challenge, row)

    with {:ok, action} <- attach(actor, action, challenge),
         :ok <- Sanctum.Consent.Authz.check(ctx, :remote_sign_in, change),
         {:ok, unsigned} <-
           Prima.PersonAssertion.new(
             identifier: row.identifier,
             audience: action.destination_home,
             challenge: challenge,
             action_id: action.action_id,
             key_epoch: row.head_hash,
             expires_at: DateTime.to_unix(action.expires_at, :millisecond)
           )
           |> shaped(),
         {:ok, signed} <-
           with_key(row, :live, fn live -> {:ok, Prima.PersonAssertion.sign(unsigned, live)} end),
         {:ok, recorded} <- record(ctx, actor, action, signed, change) do
      Sanctum.Consent.Authz.consumed(ctx)
      # The assertion is on its way to the audience: the carry is delivered,
      # which a lost reply's retry reads as such. A failed move changes
      # nothing the browser holds.
      _ = Arca.CarryActions.deliver(actor, recorded.id, recorded.revision)
      {:ok, %{assertion: signed, genesis: genesis}}
    end
  end

  # What confirming an assertion approves: signing in at that home, for
  # this carry and challenge, under this head.
  defp assertion_change(action, challenge, row) do
    %{
      operation: "person.assert",
      arguments: %{
        "audience" => action.destination_home,
        "challenge" => Prima.Identity.Encoding.b64(challenge),
        "action_id" => action.action_id,
        "key_epoch" => row.head_hash
      },
      resource: action.destination_home,
      details: %{
        "effect" =>
          "Signs you in at #{action.destination_home}, which learns this home's address."
      }
    }
  end

  defp attach(actor, action, challenge) do
    case Arca.CarryActions.attach_challenge(actor, action.id, %{
           challenge: Prima.Identity.Encoding.b64(challenge),
           challenge_digest: Prima.Digest.sha256(challenge)
         }) do
      {:ok, attached} ->
        {:ok, attached}

      {:error, :challenge_attached} ->
        {:error,
         {:conflict,
          "This sign-in already carries another challenge from that home; begin a new one"}}

      {:error, reason} when reason in [:expired, :not_open] ->
        {:error, {:conflict, "This sign-in is no longer pending; begin a new one from your home"}}

      {:error, reason} when reason in [:not_found, :cross_tenant] ->
        {:error,
         {:invalid_argument, "No pending sign-in of yours names that home; begin one first"}}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # The assertion recorded once on its action, the proof consumed in the
  # same transaction: either both happen or neither.
  defp record(ctx, actor, action, signed, change) do
    bytes = Prima.Identity.Encoding.jcs!(Prima.PersonAssertion.encode(signed))

    case Arca.CarryActions.record_assertion(
           actor,
           action.id,
           %{assertion: bytes, assertion_digest: Prima.Digest.sha256(bytes)},
           also: fn _action ->
             Sanctum.Consent.Authz.consume(ctx, {:remote_sign_in, change})
           end
         ) do
      {:ok, recorded} ->
        {:ok, recorded}

      {:error, :assertion_recorded} ->
        {:error, {:conflict, "This sign-in already holds another assertion; begin a new one"}}

      {:error, reason} when reason in [:expired, :not_open] ->
        {:error, {:conflict, "This sign-in is no longer pending; begin a new one from your home"}}

      {:error, {:conflict, _sentence} = conflict} ->
        {:error, conflict}

      {:error, reason} when reason in [:not_owner, :database_error] ->
        {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp shaped({:ok, assertion}), do: {:ok, assertion}
  defp shaped({:error, _malformed}), do: {:error, :unavailable}

  # ---- the identity row ------------------------------------------------------

  defp identity(actor, user_id) when is_binary(user_id),
    do: Arca.PersonIdentities.get(actor, user_id)

  defp identity(_actor, _user_id), do: {:error, :not_found}

  # The person's local key set: a remote person's row holds none. Read as
  # the server, as every read of a person's rows is (`Sanctum.Tenancy.Users`):
  # the caller named the person, and a person is not a row inside an
  # athanor.
  defp key_set(user_id) do
    case identity(Prima.Actor.system(), user_id) do
      {:ok,
       %{provenance: "local", live_key_sealed: live, operational_key_sealed: operational} = row}
      when is_binary(live) and is_binary(operational) ->
        {:ok, row}

      {:ok, _no_local_keys} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp enrolled(%{enrollment: "enrolled", identifier: identifier, head_hash: head} = row)
       when is_binary(identifier) and is_binary(head),
       do: {:ok, row}

  defp enrolled(_row), do: {:error, :not_enrolled}

  # A local subject means something only at the home that issued it.
  defp subject(:local, row, audience) do
    if audience == home(),
      do: {:ok, %{kind: :local, user_id: row.user_id}},
      else: {:error, :wrong_audience}
  end

  # Every entry of a person's log introduces their live key, so the head
  # their row names is its `key_epoch` (`Prima.Identity.State`).
  defp subject(:identity, row, _audience) do
    with {:ok, row} <- enrolled(row),
         do: {:ok, %{kind: :identity, identifier: row.identifier, key_epoch: row.head_hash}}
  end

  # A certificate's validity refuses a stale value: a store that cannot
  # answer it issues nothing, as a session is not issued on a window this
  # member cannot read.
  defp cert_seconds do
    case Arca.PlatformSettings.effective("device_cert_seconds") do
      {:ok, seconds} when is_integer(seconds) and seconds > 0 ->
        {:ok, seconds}

      {:ok, other} ->
        Logger.error(
          "[Sanctum.Person] the stored device_cert_seconds #{inspect(other)} is not a " <>
            "positive whole number of seconds; refusing until it is"
        )

        {:error, :unavailable}

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, reason} when reason in [:uninstalled, :unknown_key] ->
        raise "[Sanctum.Person] device_cert_seconds cannot be read: the setting is #{reason}"
    end
  end

  # ---- private keys ------------------------------------------------------------

  # A fresh Ed25519 pair, its private half sealed to the frame and role at
  # once: what leaves is the public half and ciphertext.
  defp new_key(user_frame, role) do
    guarded("sealing a new #{role} key", fn ->
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, sealed} = Sanctum.Cipher.encrypt(private, CipherAAD.person_key(user_frame, role))
      {:ok, %{public: public, sealed: sealed}}
    end)
  end

  # The one signer: open the row's `role` key, hand it to `use` and answer
  # what `use` answers. The key opens only under the person's frame and its
  # own role, and is used only when its public half is the one the row
  # names; anything else is `:unavailable`, and nothing is signed.
  defp with_key(row, role, use) do
    {sealed, public} = role_columns(row, role)

    guarded("opening the #{role} key", fn ->
      with {:ok, private} <-
             Sanctum.Cipher.decrypt(sealed, CipherAAD.person_key(row.user_id, role)),
           true <- public_half?(private, public) do
        use.(private)
      else
        _unopened ->
          Logger.error("[Sanctum.Person] the #{role} key of #{row.user_id} does not open")
          {:error, :unavailable}
      end
    end)
  end

  defp role_columns(row, :live), do: {row.live_key_sealed, row.live_public_key}

  defp role_columns(row, :operational),
    do: {row.operational_key_sealed, row.operational_public_key}

  defp public_half?(private, public) when byte_size(private) == 32 do
    {derived, _private} = :crypto.generate_key(:eddsa, :ed25519, private)
    derived == public
  end

  defp public_half?(_private, _public), do: false

  # Every step that holds a private key runs here. A raise inside one would
  # carry the key into a crash report through its stacktrace's arguments,
  # so it is answered `:unavailable` and only the exception's module is
  # logged.
  defp guarded(step, fun) do
    fun.()
  rescue
    exception ->
      Logger.error("[Sanctum.Person] #{step} failed (#{inspect(exception.__struct__)})")
      {:error, :unavailable}
  end
end
