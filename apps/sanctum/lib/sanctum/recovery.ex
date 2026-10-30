# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Recovery do
  @moduledoc """
  Recovery material and restore (`ARCHITECTURE.md` §9.1): enrollment under
  a fresh confirmation, delivery of the person's recovery code until they
  say it is saved, which erases the sealed secret, another recovery code
  added by one the person holds, and restore on an installation-authorized
  empty node through durable, resumable phases. Every use of a recovery
  key, and of the keys a restore stages, is here; the person's online keys
  are used only through `Sanctum.Person`.

  A recovery code (`Prima.RecoveryCode`) is one line that spells the
  identifier and one 32-byte recovery secret, whose Ed25519 key pair
  (`Prima.Identity.derive_recovery_key/1`) is one recovery holder. The
  server composes every code it answers (`Prima.RecoveryCode.encode/2`)
  and reads every code it is given (`Prima.RecoveryCode.decode/1`); a code
  that does not read is refused `:not_a_code` or `:typo` before anything
  is read or sent. A secret the trusted form draws travels under the field
  `recovery_secret`, a code given under `recovery_code` and a code
  answered under `code`, so the redaction vocabulary (`Prima.Sanitizer`)
  keeps each out of every log.

  ## Enrollment

  `enroll/3` gives an enrolled-to-be local person an identifier at the
  directory this deployment pins (`Sanctum.directory_url/0`; no operation
  takes a directory URL). The genesis names their live and operational
  public keys, the secret's recovery key and that directory
  (`Sanctum.Person.sign_genesis/3`). The `recovery_material` confirmation
  is asked for the exact set, directory and genesis digest before
  anything is opened (`Sanctum.Consent.Authz.check/3`), and consumed in
  the transaction that opens the one enrollment attempt, which holds the
  immutable genesis and the sealed secret. Registration
  (`Sanctum.Directory.Client.register/3`) is retried under the same
  request id with the same genesis bytes until the directory answers: an
  acceptance writes the identifier, a refusal leaves the person without
  one and the attempt recorded. A retry resumes the attempt with the
  authorization it committed, and only for the secret it holds.

  An enrollment the directory has not accepted waits on the secret of the
  browser that began it. A person whose browser lost that secret abandons
  it (`abandon_enrollment/1`): the attempt ends `superseded` and the
  person is unenrolled again, free to enroll under a new secret, so a new
  identifier. A genesis the directory may already have registered stays
  there unused, under an identifier nobody holds a recovery code for. A
  retry under the abandoned request id answers `:enrollment_abandoned`
  and registers nothing.

  The accepted attempt answers the recovery code, until
  `recovery_code_saved/2` records that the person saved it and erases the
  sealed secret in the same write. `recovery_code/2` shows it again, each
  time under a fresh `recovery_material` confirmation; once it is saved
  its secret is gone, and the code is never shown again.

  `status/1` reads what the person's own settings show: the identity row,
  the attempts still in progress and the doors, never a secret or a
  sealed value. `enrollment_effect/1` is the sentence the enrollment
  preview stores.

  ## Another recovery code

  `recovery_code_add/3` adds a recovery holder through a `recover` signed
  by a recovery code the person holds, which names the person's own
  identity. It keeps the person's live and operational keys and names the
  current recovery set with the added code's key, at the revision the
  directory serves now, read fresh (`Sanctum.IdentityFreshness.fresh!/2`)
  and held to the head the person's row names. The confirmation is asked
  and consumed as enrollment's, and the accepted entry is the person's
  new head (`key_epoch`): every home that relies on the identity retires
  what was bound to the old one. The added code is shown and saved as the
  first.

  ## Restore

  `restore/3` is an ingress, not an operation: no person exists to admit
  one. It takes the person's recovery code and the installation
  capability, the deployment's `CYFR_RESTORE_TOKEN` (`:sanctum,
  :restore_token`), which is checked first, in constant time: with no
  configured token restore is disabled, and a code without this
  installation's token causes no row, no staged key and no outbound call.
  The identity is read at the directory this deployment pins
  (`Sanctum.directory_url/0`), and a deployment that pins none restores
  nothing. The code's secret is held to the identifier's current recovery
  set by a fresh read of that directory, outside any transaction and
  before the token is claimed, so a code that does not read, names no
  identity there or holds no recovery key of it spends nothing.

  Its phases are `Arca.IdentityAttempts`' restore path, each durable
  before the next begins, all under one request id drawn at the first
  open:

    1. **staged** — new live and operational keys, sealed in the
       restore's own frame (`"restore:" <> request_id`), and the signed
       `recover` replacing both, opened with the installation claim in
       one transaction (`Arca.InstallationClaims`): one empty node, one
       request, one token;
    2. **submitted** — the `recover` sent, and sent again under the same
       request id while no answer is recorded;
    3. **accepted** — the directory's acceptance recorded; a refusal ends
       the attempt `refused` with its staged keys discarded;
    4. **keys_active** — the current head read again: a later recovery
       that replaced the keys this attempt introduced ends it
       `superseded`, activating nothing;
    5. **minted** — the head read again, as a restore stopped at
       `keys_active` may have been superseded meanwhile; then the person,
       their identity row (provenance `local`, enrolled at the accepted
       head) with the staged keys re-sealed under their own frame, their
       athanor and their platform grant, all in the transaction of the
       restore's admission (`Sanctum.Newcomer`), which advances the
       attempt too, so a crash can never leave a resume refused as a
       non-empty node. The
       transaction holds the cached head that read left
       (`Arca.DirectoryHeads.certifiable!/3`): a later recovery this home
       cached in between refuses the mint and ends the attempt
       `superseded`;
    6. **completed** — the head read once more, their own athanor's fill
       asked for, and a session issued with the reserved provider
       `restore` to the holder of the capability, before the attempt ends.
       Superseded after the mint, the attempt ends `superseded` with no
       fill asked for and no session, and the person it minted stays,
       under keys their head no longer names and with no linked door or
       passkey, so the node is no longer empty for another restore;
       a session issued as a concurrent request superseded it is deleted,
       never answered.

  A restore brings back the identity alone: the person, their keys and
  their own athanor. It restores no private data, and a
  membership an athanor's home revoked stays revoked, since each
  membership is kept at its athanor's home.

  A directory that cannot answer a read before the mint or the session
  leaves the attempt where it stands, answered `:unavailable`.

  A retry under the same token finds the attempt through its claim, and
  resumes it only for a code whose identifier it restores and whose
  secret signed its request; nothing resumes at boot. A completed restore
  answers `:restored` and issues no session.

  The restored person is local, so the door admits them unless a deny
  names them (`Sanctum.Door`), and the owner signs in by passkey after
  the restore session ends. They are the installation's first person and
  so its platform administrator (`Sanctum.Newcomer`).

  ## The first method after restore

  The restore session's original creation time bounds the local
  first-method exception (`Sanctum.Passkeys.register/2`). If that window
  closes before any method is installed, `restore_challenge/1` (the
  capability again) answers a server challenge alive five minutes on the
  database's clock, the clock its use is checked against, and `reproof/3`
  takes the recovery code and that challenge: a challenge not held or
  past its expiry is refused before the directory is read, the code's
  secret must be a holder of the identity now and the head's online keys
  the ones this restore introduced; the challenge is consumed once and a
  new `restore` session issued. Neither rotates a key or repeats the
  restore, and both close once a first method exists.
  """

  require Logger
  require Sanctum.Issuance

  alias Prima.Identity
  alias Prima.Identity.{Encoding, RecoverRequest, State}
  alias Sanctum.{CipherAAD, Context}
  alias Sanctum.Consent.Authz
  alias Sanctum.Directory.Client

  @seed_bytes 32
  @reproof_ms 5 * 60 * 1000

  @typedoc "The directory client's options: `:resolver` and `:cacerts`."
  @type opts :: [resolver: module(), cacerts: [binary()]]

  @typedoc """
  The restore ingress's body: the person's recovery code under
  `"recovery_code"`, and for a reproof the `"challenge"`.
  """
  @type code_params :: %{optional(String.t()) => term()}

  # ===========================================================================
  # Enrollment
  # ===========================================================================

  @doc """
  Enroll the person of `ctx` (the module doc): `args` holds the new
  code's secret under `"recovery_secret"` and the attempt's
  `"request_id"`.

  Answers `%{attempt_id, request_id, phase, identifier, code}` once the
  directory accepted the genesis, `code` being the recovery code
  (`Prima.RecoveryCode.encode/2` over the identifier and the secret) while
  the person has not said it is saved, and absent after.

  Refusals: `{:invalid_argument, _}` (no secret, or a malformed one or
  request id), `:no_directory` (this deployment pins none), `:not_found`
  (no local key set: the person's keys are at another home),
  `:already_enrolled`, `{:attempt_in_progress, request_id}`,
  `:request_id_reused`, the consent signal `{:confirmation_required, _}`
  and the confirmation's other refusals, `:enrollment_refused` (the
  directory refused the genesis), `:enrollment_abandoned` (the person
  abandoned the attempt this request id names), and the retryable
  `:directory_unavailable` and `:unavailable`, after which a retry under
  the same request id resumes the attempt.
  """
  @spec enroll(Context.t(), map(), opts()) :: {:ok, map()} | {:error, term()}
  def enroll(%Context{} = ctx, args, opts \\ []) when is_map(args) do
    opts = client_options!(opts)

    with {:ok, user_id} <- person(ctx),
         {:ok, request_id} <- request_id(args),
         {:ok, seed} <- seed(Map.get(args, "recovery_secret")),
         {:ok, {recovery_key, _private}} <- Identity.derive_recovery_key(seed) do
      case Arca.IdentityAttempts.get_by_request(Context.actor(ctx), request_id) do
        {:ok, %{kind: "enrollment", user_id: ^user_id} = attempt} ->
          if holds_seed?(attempt, recovery_key),
            do: continue_enrollment(ctx, attempt, opts),
            else: {:error, :request_id_reused}

        {:ok, _another} ->
          {:error, :request_id_reused}

        {:error, :cross_tenant} ->
          {:error, :request_id_reused}

        {:error, :not_found} ->
          begin_enrollment(ctx, user_id, request_id, seed, recovery_key, opts)

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  @doc """
  What confirming an enrollment approves (`t:Sanctum.Consent.Authz.change/0`):
  the request, the genesis digest, the recovery set and the pinned
  directory. The secret is never in it; its public key is.
  """
  @spec enrollment_change(String.t(), map(), binary(), String.t()) :: Authz.change()
  def enrollment_change(request_id, genesis, recovery_key, directory) do
    %{
      operation: "person.enroll",
      arguments: %{
        "request_id" => request_id,
        "genesis" => genesis.genesis_hash,
        "recovery_keys" => [Encoding.b64(recovery_key)],
        "directory" => directory
      },
      resource: genesis.identifier,
      details: %{
        "directory" => directory,
        "recovery_key" => Encoding.b64(recovery_key),
        "genesis" => genesis.genesis_hash,
        "effect" => enrollment_effect(directory)
      }
    }
  end

  @doc """
  What enrolling at `directory` means, in the words the stored preview
  and the trusted enrollment form both say: the directory pinned, what
  its unavailability means, what losing every recovery code means, and
  that a recovery restores the identity alone.
  """
  @spec enrollment_effect(String.t()) :: String.t()
  def enrollment_effect(directory) when is_binary(directory) do
    effect = effect_at(directory)

    # A preview's text is bounded (`Prima.Confirmation.Preview.max_text/0`);
    # a directory URL too long to sit in the sentence as well is named by
    # the preview's `directory` detail alone.
    if byte_size(effect) <= Prima.Confirmation.Preview.max_text(),
      do: effect,
      else: effect_at("named under directory")
  end

  defp effect_at(directory) do
    "Registers your identity at the directory #{directory}, which this CYFR pins, and " <>
      "prints its recovery kit. Anyone holding a kit can replace your keys. While that " <>
      "directory cannot be reached, key rotation, recovery and identity checks by any other CYFR " <>
      "wait; if it is gone for good, they end, and no identity moves to " <>
      "another directory. If every kit is lost, nothing can add one: your identity keeps " <>
      "working here with no way to recover it. A recovery restores your identity alone, " <>
      "never your private data or the CYFR addresses your devices saved: you add those addresses " <>
      "again from surviving devices or invitations."
  end

  defp begin_enrollment(ctx, user_id, request_id, seed, recovery_key, opts) do
    with {:ok, directory} <- pinned_directory(),
         :ok <- enrollable(ctx, user_id),
         {:ok, genesis} <- Sanctum.Person.sign_genesis(user_id, [recovery_key], directory) do
      change = enrollment_change(request_id, genesis, recovery_key, directory)

      with :ok <- Authz.check(ctx, :recovery_material, change),
           {:ok, sealed} <- seal(seed, CipherAAD.person_key(user_id, :kit_seed)) do
        attrs = %{
          kind: "enrollment",
          request_id: request_id,
          user_id: user_id,
          identifier: genesis.identifier,
          directory_url: directory,
          genesis: genesis.genesis,
          request_digest: genesis.genesis_hash,
          kit_seed_sealed: sealed
        }

        also = fn _attempt -> Authz.consume(ctx, {:recovery_material, change}) end

        case Arca.IdentityAttempts.open(Context.actor(ctx), attrs, also: also) do
          {:ok, attempt} ->
            Authz.consumed(ctx)
            continue_enrollment(ctx, attempt, opts)

          {:error, reason} ->
            open_refusal(ctx, user_id, "enrollment", reason)
        end
      end
    end
  end

  defp pinned_directory do
    case Sanctum.directory_url() do
      url when is_binary(url) and url != "" -> {:ok, url}
      _none -> {:error, :no_directory}
    end
  end

  defp enrollable(ctx, user_id) do
    case Arca.PersonIdentities.get(Context.actor(ctx), user_id) do
      {:ok, %{provenance: "local", identifier: nil, enrollment: "none"}} ->
        :ok

      {:ok, %{provenance: "local", identifier: nil, enrollment: "pending"}} ->
        {:error, {:attempt_in_progress, in_progress_request(ctx, user_id, "enrollment")}}

      {:ok, %{provenance: "local"}} ->
        {:error, :already_enrolled}

      {:ok, _remote} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp continue_enrollment(ctx, %{phase: "staged"} = attempt, opts) do
    with {:ok, attempt} <- move(ctx, attempt, "submitted"),
         do: continue_enrollment(ctx, attempt, opts)
  end

  defp continue_enrollment(ctx, %{phase: "submitted"} = attempt, opts) do
    case Client.register(attempt.identifier, attempt.genesis, opts) do
      # The phase the attempt holds after the move decides the answer: an
      # abandonment that committed first leaves it `superseded`.
      {:ok, %{entry_hash: hash}} when hash == attempt.request_digest ->
        with {:ok, accepted} <- move(ctx, attempt, "accepted", %{outcome: "accepted"}),
             do: continue_enrollment(ctx, accepted, opts)

      {:ok, _other} ->
        refuse(ctx, attempt, "invalid_response", :enrollment_refused)

      {:error, reason} ->
        if refused?(reason),
          do: refuse(ctx, attempt, word(reason), :enrollment_refused),
          else: retryable(attempt, reason)
    end
  end

  defp continue_enrollment(_ctx, %{phase: phase} = attempt, _opts)
       when phase in ["accepted", "completed"],
       do: enrolled(attempt)

  defp continue_enrollment(_ctx, %{phase: "refused"}, _opts), do: {:error, :enrollment_refused}

  defp continue_enrollment(_ctx, %{phase: "superseded"}, _opts),
    do: {:error, :enrollment_abandoned}

  @doc """
  Abandon the person's enrollment the directory has not accepted
  (`person.enroll_abandon`, the module doc): a `staged` or `submitted`
  attempt ends `superseded`, its sealed secret erased, and the person is
  unenrolled in the same write (`Arca.IdentityAttempts.advance/5`). It
  discards an unfinished attempt and mints nothing, so it asks no
  confirmation. Answers `%{request_id, phase: "superseded"}`, the
  abandoned request id.

  Refusals: `:registered` (the directory accepted it: the identity stands
  and `recovery_code/2` shows its code), `:not_found` (no enrollment of the
  person's in progress: none begun, or it completed, was refused or was
  abandoned), `:unauthenticated`, `:guest_plane`, `:unavailable`.
  """
  @spec abandon_enrollment(Context.t()) :: {:ok, map()} | {:error, term()}
  def abandon_enrollment(%Context{} = ctx) do
    with {:ok, user_id} <- person(ctx),
         {:ok, attempt} <- in_progress(ctx, user_id, "enrollment"),
         do: abandon(ctx, attempt)
  end

  # Decided on the phase the attempt holds; a move that met a later phase
  # decides again on the one it read back.
  defp abandon(ctx, %{phase: phase} = attempt) when phase in ["staged", "submitted"] do
    case move(ctx, attempt, "superseded") do
      {:ok, %{phase: "superseded", request_id: request_id}} ->
        {:ok, %{request_id: request_id, phase: "superseded"}}

      {:ok, moved} ->
        abandon(ctx, moved)

      {:error, _reason} = refusal ->
        refusal
    end
  end

  defp abandon(_ctx, %{phase: "accepted"}), do: {:error, :registered}
  defp abandon(_ctx, _ended_or_none), do: {:error, :not_found}

  defp enrolled(attempt) do
    with {:ok, code} <- code(attempt) do
      answer = %{
        attempt_id: attempt.id,
        request_id: attempt.request_id,
        phase: attempt.phase,
        identifier: attempt.identifier
      }

      {:ok, if(code, do: Map.put(answer, :code, code), else: answer)}
    end
  end

  # The genesis the attempt holds names this secret's key as its recovery set.
  defp holds_seed?(%{genesis: genesis}, recovery_key) when is_binary(genesis) do
    case Prima.Json.decode(genesis) do
      {:ok, %{} = map} -> Map.get(map, "recovery_keys") == [Encoding.b64(recovery_key)]
      _other -> false
    end
  end

  defp holds_seed?(_attempt, _recovery_key), do: false

  # ===========================================================================
  # The recovery code
  # ===========================================================================

  @doc """
  Show the recovery code of the person's accepted enrollment or added code
  `attempt_id` again (`person.recovery_code`), under a fresh
  `recovery_material` confirmation each time. Answers `%{attempt_id,
  code}`.

  The secret is opened from the attempt read again once the confirmation
  answers, so a save that committed meanwhile shows nothing.

  Refusals: `{:not_found, "recovery_code", attempt_id}` (no such attempt
  of the person's), `:kit_acknowledged` (the person said it is saved, which
  erased the secret), `:not_accepted` (the directory has not accepted it),
  `:enrollment_refused`, the consent signal and the confirmation's other
  refusals, `:unavailable`.
  """
  @spec recovery_code(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def recovery_code(%Context{} = ctx, attempt_id) when is_binary(attempt_id) do
    with {:ok, user_id} <- person(ctx),
         {:ok, attempt} <- own_code_attempt(ctx, user_id, attempt_id),
         :ok <- deliverable(attempt),
         :ok <- Authz.confirm(ctx, :recovery_material, code_change(attempt)),
         {:ok, attempt} <- own_code_attempt(ctx, user_id, attempt_id),
         :ok <- deliverable(attempt),
         {:ok, code} <- code(attempt) do
      {:ok, %{attempt_id: attempt.id, code: code}}
    end
  end

  @doc """
  The person says the recovery code of `attempt_id` is saved
  (`person.recovery_code_saved`): its sealed secret is erased in that
  write, and a repeat never restores it. Answers `%{attempt_id, phase:
  "completed"}`.

  Refusals: `{:not_found, "recovery_code", attempt_id}`, `:not_accepted`,
  `:unavailable`.
  """
  @spec recovery_code_saved(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def recovery_code_saved(%Context{} = ctx, attempt_id) when is_binary(attempt_id) do
    with {:ok, user_id} <- person(ctx),
         {:ok, attempt} <- own_code_attempt(ctx, user_id, attempt_id) do
      case Arca.IdentityAttempts.acknowledge_kit(Context.actor(ctx), attempt.id) do
        {:ok, saved} -> {:ok, %{attempt_id: saved.id, phase: saved.phase}}
        {:error, :not_accepted} -> {:error, :not_accepted}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  defp own_code_attempt(ctx, user_id, attempt_id) do
    case Arca.IdentityAttempts.get(Context.actor(ctx), attempt_id) do
      {:ok, %{kind: kind, user_id: ^user_id} = attempt} when kind in ["enrollment", "holder"] ->
        {:ok, attempt}

      {:ok, _another} ->
        {:error, {:not_found, "recovery_code", attempt_id}}

      {:error, reason} when reason in [:not_found, :cross_tenant] ->
        {:error, {:not_found, "recovery_code", attempt_id}}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp deliverable(%{phase: "accepted", kit_seed_sealed: sealed}) when is_binary(sealed), do: :ok
  defp deliverable(%{phase: "completed"}), do: {:error, :kit_acknowledged}
  defp deliverable(%{phase: "refused"}), do: {:error, :enrollment_refused}
  defp deliverable(_attempt), do: {:error, :not_accepted}

  defp code_change(attempt) do
    %{
      operation: "person.recovery_code",
      arguments: %{"attempt_id" => attempt.id},
      resource: "recovery code for " <> attempt.identifier,
      details: %{
        "directory" => attempt.directory_url,
        "effect" =>
          "Shows your recovery code again. Anyone who sees it can replace your keys until you " <>
            "have it no more."
      }
    }
  end

  # The attempt's recovery code while its secret is sealed on it; nil once
  # the person said it is saved, which erased the secret. Composed under
  # `guarded/2`, since the secret is an argument of the call.
  defp code(%{kit_seed_sealed: sealed} = attempt) when is_binary(sealed) do
    with {:ok, secret} <- open(sealed, CipherAAD.person_key(attempt.user_id, :kit_seed)) do
      guarded("composing a recovery code", fn ->
        {:ok, Prima.RecoveryCode.encode(attempt.identifier, secret)}
      end)
    end
  end

  defp code(_attempt), do: {:ok, nil}

  # ===========================================================================
  # The person's identity, as their settings show it
  # ===========================================================================

  @doc """
  The identity of the person of `ctx` as their own settings read it
  (`person.status`): `provenance` and `identifier`; `directory_url`, the
  directory this home pins for enrollment (`CYFR_DIRECTORY_URL`), or nil
  when it pins none; `enrollment` (`none`, `pending` or `enrolled`) and
  `key_epoch`, the head their row names; `kits`, each enrollment or
  added-code attempt still in progress (`Arca.IdentityAttempts.in_progress/3`)
  as `%{attempt_id, kind, phase, request_id, deliverable}`, `deliverable`
  while its code's secret is still sealed for delivery; `rotation`, the
  rotation in progress as `%{request_id, phase}`, or nil; and `doors`, each
  linked door as `%{key, provider, issuer, subject}`.

  Nothing in it is a secret, a sealed value or a staged key. Refusals:
  `:unauthenticated`, `:guest_plane`, `:unavailable`, and `{:corrupt,
  :person_identity}` for a person whose identity row, minted with their
  person row, is missing.
  """
  @spec status(Context.t()) :: {:ok, map()} | {:error, term()}
  def status(%Context{} = ctx) do
    with {:ok, user_id} <- person(ctx),
         {:ok, identity} <- status_identity(ctx, user_id),
         {:ok, enrollment} <- in_progress(ctx, user_id, "enrollment"),
         {:ok, holder} <- in_progress(ctx, user_id, "holder"),
         {:ok, rotation} <- in_progress(ctx, user_id, "rotation"),
         {:ok, doors} <- doors(user_id) do
      {:ok,
       %{
         provenance: identity.provenance,
         identifier: identity.identifier,
         directory_url: pinned_or_nil(),
         enrollment: identity.enrollment,
         key_epoch: identity.head_hash,
         kits: for(attempt <- [enrollment, holder], attempt != nil, do: kit_status(attempt)),
         rotation: rotation && %{request_id: rotation.request_id, phase: rotation.phase},
         doors: doors
       }}
    end
  end

  defp status_identity(ctx, user_id) do
    case Arca.PersonIdentities.get(Context.actor(ctx), user_id) do
      {:ok, row} ->
        {:ok, Map.take(row, [:provenance, :identifier, :enrollment, :head_hash])}

      # Minted with the person row: one missing is damage.
      {:error, :not_found} ->
        {:error, {:corrupt, :person_identity}}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp in_progress(ctx, user_id, kind) do
    case Arca.IdentityAttempts.in_progress(Context.actor(ctx), user_id, kind) do
      {:ok, attempt} -> {:ok, attempt}
      {:error, :not_found} -> {:ok, nil}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp kit_status(attempt) do
    %{
      attempt_id: attempt.id,
      kind: attempt.kind,
      phase: attempt.phase,
      request_id: attempt.request_id,
      deliverable: deliverable(attempt) == :ok
    }
  end

  # The doors the person signs in through, read as the platform reads them
  # (`Arca.Users.identities/2`) for the person the context names.
  defp doors(user_id) do
    case Arca.Users.identities(system(), user_id) do
      {:ok, identities} ->
        {:ok, Enum.map(identities, &Map.take(&1, [:key, :provider, :issuer, :subject]))}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp pinned_or_nil do
    case pinned_directory() do
      {:ok, url} -> url
      {:error, :no_directory} -> nil
    end
  end

  # ===========================================================================
  # Another recovery code
  # ===========================================================================

  @doc """
  Add another recovery code to the person's recovery set (the module doc):
  `args` holds a recovery code the person holds under `"recovery_code"`,
  which signs the change, the added code's secret as `"holder" =>
  %{"recovery_secret" => secret}`, and the attempt's `"request_id"`.

  Answers as `enroll/3` does, the `code` being the added one's, and
  `key_epoch` the person's new head.

  Refusals: `:not_a_code` and `:typo` (the signing code does not read,
  refused before anything is read, asked or sent), `{:invalid_argument,
  _}` (a missing or malformed secret, the same secret twice),
  `:not_enrolled`, `:not_found`, `:not_a_holder` (the signing code names
  another identity, refused before the directory is read, or its secret
  is not a holder of the identity now), `:already_a_holder`,
  `:stale_head` (the identity's log has moved past the person's head
  here), `{:attempt_in_progress, _}`, `:request_id_reused`, the consent
  signal and the confirmation's other refusals, `:holder_refused` (the
  directory refused it), and the retryable `:directory_unavailable` and
  `:unavailable`.
  """
  @spec recovery_code_add(Context.t(), map(), opts()) :: {:ok, map()} | {:error, term()}
  def recovery_code_add(%Context{} = ctx, args, opts \\ []) when is_map(args) do
    opts = client_options!(opts)

    with {:ok, user_id} <- person(ctx),
         {:ok, request_id} <- request_id(args),
         {:ok, signer} <- Prima.RecoveryCode.decode(Map.get(args, "recovery_code")),
         {:ok, added_seed} <- holder(Map.get(args, "holder")),
         :ok <- distinct_seeds(signer.secret, added_seed),
         {:ok, {signer_key, signer_private}} <- Identity.derive_recovery_key(signer.secret),
         {:ok, {added_key, _}} <- Identity.derive_recovery_key(added_seed) do
      case Arca.IdentityAttempts.get_by_request(Context.actor(ctx), request_id) do
        {:ok, %{kind: "holder", user_id: ^user_id} = attempt} ->
          cond do
            attempt.identifier != signer.identifier ->
              {:error, :not_a_holder}

            signed_by?(attempt, signer_key) and adds?(attempt, added_key) ->
              continue_holder(ctx, attempt, opts)

            true ->
              {:error, :request_id_reused}
          end

        {:ok, _another} ->
          {:error, :request_id_reused}

        {:error, :cross_tenant} ->
          {:error, :request_id_reused}

        {:error, :not_found} ->
          seeds = %{
            identifier: signer.identifier,
            signer: {signer_key, signer_private},
            added: {added_key, added_seed}
          }

          begin_holder(ctx, user_id, request_id, seeds, opts)

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  defp begin_holder(ctx, user_id, request_id, seeds, opts) do
    %{identifier: named, signer: {signer_key, signer_private}, added: {added_key, added_seed}} =
      seeds

    with {:ok, identity} <- enrolled_identity(ctx, user_id),
         :ok <- own_identity(identity, named),
         {:ok, %{genesis: genesis}} <- own_genesis(ctx, user_id),
         {:ok, state} <- live_state(identity.identifier, genesis, opts),
         :ok <- at_own_head(state, identity),
         :ok <- holds(state, signer_key),
         :ok <- not_yet_holder(state, added_key),
         {:ok, request} <-
           RecoverRequest.new(
             identifier: identity.identifier,
             directory: state.directory,
             live_key: state.live_key,
             operational_key: state.operational_key,
             recovery_keys: state.recovery_keys ++ [added_key],
             expected_revision: state.revision,
             request_id: request_id
           )
           |> request_refusal(),
         {:ok, request} <- sign_with(request, signer_private) do
      change = holder_change(request, added_key)

      with :ok <- Authz.check(ctx, :recovery_material, change),
           {:ok, sealed} <- seal(added_seed, CipherAAD.person_key(user_id, :kit_seed)) do
        attrs = %{
          kind: "holder",
          request_id: request_id,
          user_id: user_id,
          identifier: identity.identifier,
          directory_url: state.directory,
          entry: Identity.canonical(request),
          request_digest: Identity.request_digest(request),
          expected_revision: state.revision,
          expected_head: identity.head_hash,
          kit_seed_sealed: sealed
        }

        also = fn _attempt -> Authz.consume(ctx, {:recovery_material, change}) end

        case Arca.IdentityAttempts.open(Context.actor(ctx), attrs, also: also) do
          {:ok, attempt} ->
            Authz.consumed(ctx)
            continue_holder(ctx, attempt, opts)

          {:error, reason} ->
            open_refusal(ctx, user_id, "holder", reason)
        end
      end
    end
  end

  @doc false
  # What confirming an added code approves: the request by its digest, and
  # the whole recovery set it installs. The secrets are never in it.
  @spec holder_change(RecoverRequest.t(), binary()) :: Authz.change()
  def holder_change(%RecoverRequest{} = request, added_key) do
    keys = Encoding.b64_keys(request.recovery_keys)

    %{
      operation: "person.recovery_code_add",
      arguments: %{
        "request_id" => request.request_id,
        "request" => Identity.request_digest(request),
        "recovery_keys" => keys
      },
      resource: "recovery codes for " <> request.identifier,
      details: %{
        "added_recovery_key" => Encoding.b64(added_key),
        "recovery_keys" => keys,
        "effect" =>
          "Adds another recovery code. Each code alone can replace your keys, and every other " <>
            "CYFR ends what it bound to your current keys once it sees the change."
      }
    }
  end

  defp continue_holder(ctx, %{phase: "staged"} = attempt, opts) do
    with {:ok, attempt} <- move(ctx, attempt, "submitted"),
         do: continue_holder(ctx, attempt, opts)
  end

  defp continue_holder(ctx, %{phase: "submitted"} = attempt, opts) do
    with {:ok, %{genesis: genesis}} <- own_genesis(ctx, attempt.user_id),
         {:ok, request} <- stored_request(attempt) do
      case Client.recover(attempt.identifier, genesis, request, opts) do
        {:ok, %{entry_hash: hash}} ->
          with {:ok, accepted} <-
                 move(ctx, attempt, "accepted", %{entry_hash: hash, outcome: "accepted"}) do
            with {:ok, answer} <- enrolled(accepted), do: {:ok, Map.put(answer, :key_epoch, hash)}
          end

        {:error, reason} ->
          if refused?(reason),
            do: refuse(ctx, attempt, word(reason), :holder_refused),
            else: retryable(attempt, reason)
      end
    end
  end

  defp continue_holder(_ctx, %{phase: phase} = attempt, _opts)
       when phase in ["accepted", "completed"] do
    with {:ok, answer} <- enrolled(attempt),
         do: {:ok, Map.put(answer, :key_epoch, attempt.entry_hash)}
  end

  defp continue_holder(_ctx, %{phase: "refused"}, _opts), do: {:error, :holder_refused}

  defp holder(%{"recovery_secret" => secret}), do: seed(secret)

  defp holder(_holder),
    do:
      {:error,
       {:invalid_argument,
        "The holder to add is the new code's 32-byte secret under holder.recovery_secret, " <>
          "drawn by the trusted form"}}

  defp distinct_seeds(secret, secret),
    do: {:error, {:invalid_argument, "The added code must be another than the one signing"}}

  defp distinct_seeds(_signer, _added), do: :ok

  # A recovery code names the identity it recovers: one naming another
  # identity holds nothing of this person's, refused before the directory
  # is read.
  defp own_identity(%{identifier: identifier}, identifier), do: :ok
  defp own_identity(_identity, _named), do: {:error, :not_a_holder}

  defp enrolled_identity(ctx, user_id) do
    case Arca.PersonIdentities.get(Context.actor(ctx), user_id) do
      {:ok, %{provenance: "local", enrollment: "enrolled", identifier: id} = row}
      when is_binary(id) ->
        {:ok, row}

      {:ok, %{provenance: "local"}} ->
        {:error, :not_enrolled}

      {:ok, _remote} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp own_genesis(ctx, user_id) do
    case Arca.IdentityAttempts.genesis(Context.actor(ctx), user_id) do
      {:ok, binding} -> {:ok, binding}
      {:error, :not_found} -> {:error, :not_enrolled}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The directory's head is the one the person's row names, with the keys
  # it holds: an added code's `recover` keeps exactly those.
  defp at_own_head(%State{} = state, identity) do
    if state.head == identity.head_hash and state.live_key == identity.live_public_key and
         state.operational_key == identity.operational_public_key,
       do: :ok,
       else: {:error, :stale_head}
  end

  defp not_yet_holder(%State{recovery_keys: keys}, key) do
    if key in keys, do: {:error, :already_a_holder}, else: :ok
  end

  defp adds?(attempt, added_key) do
    case stored_request(attempt) do
      {:ok, %RecoverRequest{recovery_keys: keys}} when is_list(keys) -> added_key in keys
      _other -> false
    end
  end

  # ===========================================================================
  # After a declared restore: the checklist and the recovery code's proof
  # ===========================================================================

  @kit_challenge_ms 5 * 60 * 1000
  @kit_credential_ms 10 * 60 * 1000
  @kit_challenges_per_minute 20
  @reenables ~w(key.reenable webhook.reenable pairing.reenable passkey.reenable)

  @typedoc """
  What a restore credential (`kit_proof/2`) admits, as
  `Sanctum.Caller.establish_kit/2` hands it on: the person, their open
  restore and the credential's digest, which each re-enable reads
  standing again in its own transaction.
  """
  @type kit_grant :: %{user_id: String.t(), restore_id: String.t(), credential_digest: String.t()}

  @doc """
  The person's restore checklist while they recover from a declared
  restore (`ARCHITECTURE.md` §6.9): every key, webhook, paired device and
  passkey of theirs held suspended, every profile to re-consent and every
  vault entry to rotate in the athanors they sit in, and every instance
  entry to rotate when they administer the platform
  (`Arca.SecurityTransitions.restore_checklist/3`). `{:ok, nil}` for a
  person no declared restore found, whose blocked profiles and entries are
  none of a restore's doing, and for one who has recovered with nothing
  left on it.
  """
  @spec checklist(Context.t()) :: {:ok, map() | nil} | {:error, term()}
  def checklist(%Context{} = ctx) do
    with {:ok, user_id} <- person(ctx) do
      case Arca.SecurityTransitions.restore_checklist(system(), user_id,
             platform_admin: ctx.platform_admin == true
           ) do
        {:ok, list} -> {:ok, if(empty_checklist?(list), do: nil, else: list)}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  defp empty_checklist?(%{restored: false}), do: true

  defp empty_checklist?(list) do
    is_nil(list.restore_id) and
      Enum.all?(
        [
          :api_keys,
          :webhooks,
          :paired_clients,
          :passkeys,
          :profiles,
          :vault_entries,
          :instance_entries
        ],
        &(Map.fetch!(list, &1) == [])
      )
  end

  @doc """
  A platform administrator ends the person `user_id`'s recovery from a
  declared restore (`person.close_recovery`): their `restore_people` row
  closes, so a group waiting on them admits members again and their
  confirmations are no longer held to a door or their recovery code,
  while every key, webhook, device and passkey the restore suspended stays
  suspended. A sensitive change (`restore_close`): the administrator's fresh
  confirmation is asked first and consumed in the transaction that closes
  the row, under the restore's own source rule for the administrator
  (`Sanctum.Pairing.restore_confirmed/1`). Another person's recovery is
  never touched.

  Refusals: `:platform_admin_required`, a `not_recovering` refusal for a
  person with no recovery open, the consent signal and the confirmation's
  own refusals, and `:unavailable`.
  """
  @spec close_recovery(Context.t(), term()) :: {:ok, map()} | {:error, term()}
  def close_recovery(%Context{platform_admin: true} = ctx, user_id) when is_binary(user_id) do
    change = %{
      operation: "person.close_recovery",
      arguments: %{"user_id" => user_id},
      resource: user_id,
      details: %{
        "effect" =>
          "Ends this person's recovery from the restore: their groups admit members again; " <>
            "what the restore suspended stays suspended"
      }
    }

    with :ok <- Authz.check(ctx, :restore_close, change) do
      verify = fn _person ->
        with :ok <- Authz.consume(ctx, {:restore_close, change}),
             do: Sanctum.Pairing.restore_confirmed(ctx)
      end

      case Arca.SecurityTransitions.close_restore(system(), user_id, verify: verify) do
        {:ok, %{closed_restore_ids: ids}} ->
          Authz.consumed(ctx)
          {:ok, %{user_id: user_id, closed_restore_ids: ids}}

        {:error, :not_recovering} ->
          {:error,
           %Prima.Refusal{
             class: :not_found,
             reason: :not_recovering,
             message: "That person is not recovering from a restore here"
           }}

        {:error, :database_error} ->
          {:error, :unavailable}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def close_recovery(%Context{platform_admin: true}, _user_id),
    do: {:error, {:invalid_argument, "Name the person whose recovery ends (user_id)"}}

  def close_recovery(%Context{}, _user_id), do: {:error, :platform_admin_required}

  @doc """
  A challenge for the proof of a recovery code, for the person
  `identifier` names while their row of a declared restore is open (`POST
  /restore/kit/challenge`): 32 random bytes, held by their digest for
  five minutes on the database's clock, and the restore id the proof must
  name. The identifier must name a local person of this home who is
  enrolled and in good standing; anyone else, and a person whose row has
  closed, are refused alike as `:not_recovering`. Counted against the
  person's own budget, twenty a minute, on the cell's clock
  (`Arca.RequestRateWindows`).
  """
  @spec kit_challenge(term()) ::
          {:ok, %{challenge: String.t(), restore_id: String.t(), expires_at: DateTime.t()}}
          | {:error, :not_recovering | {:rate_limited, non_neg_integer()} | :unavailable}
  def kit_challenge(identifier) do
    with {:ok, user_id, restore_id} <- recovering(identifier),
         :ok <- kit_budget(user_id),
         {:ok, now} <-
           guarded("restore challenge clock", fn -> {:ok, Arca.ServerMetaStorage.now!()} end) do
      challenge = :crypto.strong_rand_bytes(32)
      expires_at = DateTime.add(now, @kit_challenge_ms, :millisecond)

      case Arca.SecurityTransitions.put_kit_challenge(
             system(),
             user_id,
             restore_id,
             challenge_digest(challenge),
             expires_at
           ) do
        :ok ->
          {:ok,
           %{challenge: Encoding.b64(challenge), restore_id: restore_id, expires_at: expires_at}}

        {:error, :closed} ->
          {:error, :not_recovering}

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  @doc """
  Verify the proof of a recovery code (`Prima.Identity.RestoreKit`,
  protocol `cyfr/restore-kit/v1`), signed in the browser by the code's
  secret, and answer the person's restore credential (`POST
  /restore/kit`). The proof names the person's identifier, their open
  restore and a challenge this home holds for them; it must be signed by a
  recovery key of the identity's head read fresh from its directory now,
  never by a key the restored home holds. The challenge is redeemed once,
  in the transaction that records the credential, with the person's open
  row locked.

  The credential is the token `rkc_` and 32 random bytes
  (`Prima.CredentialShape`'s `:restore_kit_credential`, which the sanitizer
  redacts wherever it appears), alive ten minutes and only while the
  person's row stays open and they stand; this home keeps its digest alone,
  under which it finds the person. It admits the four re-enable operations and their
  previews and nothing else (`Sanctum.Caller.establish_kit/2`).

  Refusals: `:invalid_proof` (malformed), `:not_recovering` (no enrolled
  local person, or their row under that restore is closed),
  `:not_a_holder` (no recovery key of the fresh head signed it),
  `:challenge_refused` (not held for this person and restore, expired, or
  redeemed already), the retryable `:directory_unavailable`, and
  `:unavailable`.
  """
  @spec kit_proof(term(), opts()) ::
          {:ok, %{credential: String.t(), expires_at: DateTime.t(), user_id: String.t()}}
          | {:error, term()}
  def kit_proof(map, opts \\ []) do
    opts = client_options!(opts)

    with {:ok, proof} <- read_kit_proof(map),
         {:ok, user_id, restore_id} <- recovering(proof.identifier),
         :ok <- same_restore(proof.restore_id, restore_id),
         {:ok, %{genesis: genesis}} <- restored_genesis(user_id),
         {:ok, state} <- live_state(proof.identifier, genesis, opts),
         {:ok, _key} <- kit_signer(proof, state),
         {:ok, now} <-
           guarded("restore credential clock", fn -> {:ok, Arca.ServerMetaStorage.now!()} end) do
      token = Prima.CredentialShape.mint(:restore_kit_credential)
      expires_at = DateTime.add(now, @kit_credential_ms, :millisecond)

      case Arca.SecurityTransitions.redeem_kit_challenge(
             system(),
             user_id,
             restore_id,
             challenge_digest(proof.challenge),
             Prima.Digest.sha256(token),
             expires_at
           ) do
        :ok -> {:ok, %{credential: token, expires_at: expires_at, user_id: user_id}}
        {:error, :challenge_refused} -> {:error, :challenge_refused}
        {:error, :closed} -> {:error, :not_recovering}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  @doc false
  @spec kit_grant(term()) :: {:ok, kit_grant()} | {:error, :invalid_credential | :unavailable}
  # The restore credential `token` presents, read standing now: its person is
  # in good standing and their row under its restore is open. What
  # `Sanctum.Caller.establish_kit/2` admits on; each write reads it again.
  def kit_grant(token) when is_binary(token) do
    with true <- Prima.CredentialShape.match?(:restore_kit_credential, token),
         digest = Prima.Digest.sha256(token),
         {:ok, user_id} <- Arca.SecurityTransitions.kit_holder(system(), digest),
         {:ok, restore_id} <- Arca.SecurityTransitions.kit_credential(system(), user_id, digest) do
      {:ok, %{user_id: user_id, restore_id: restore_id, credential_digest: digest}}
    else
      {:error, :database_error} -> {:error, :unavailable}
      _refused -> {:error, :invalid_credential}
    end
  end

  def kit_grant(_token), do: {:error, :invalid_credential}

  @doc """
  The re-enable operations a restore credential admits, and nothing else.
  """
  @spec kit_operations() :: [String.t()]
  def kit_operations, do: @reenables

  @doc """
  One re-enable, or its preview, under a restore credential
  (`Sanctum.Caller.establish_kit/2` admitted it for exactly `operation`):
  with no item named, the person's items of that class held suspended
  (`key.reenable` their keys, `webhook.reenable` their webhooks,
  `pairing.reenable` their devices, `passkey.reenable` their passkeys);
  with one named (`key_id`, `webhook_id`, `client_id`, `passkey_id`),
  that item re-enabled, the credential read standing again in the
  write's own transaction. Re-enabling a device or a passkey closes the
  person's row, and with it the credential.

  `POST /restore/kit/reenable` is an ingress, not a gate operation, so a
  re-enable there is admitted while the home's storage reserve is
  depleted (`Arca.StorageReserve`), though the gate refuses the same
  re-enable then: a re-enable gives authority back rather than taking it
  away.
  """
  @spec kit_reenable(Context.t(), kit_grant(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def kit_reenable(%Context{} = ctx, %{user_id: user_id} = grant, operation, args)
      when operation in @reenables and is_map(args) do
    proof = {:kit, Map.take(grant, [:user_id, :credential_digest])}

    case {operation, Map.get(args, item_arg(operation))} do
      {_operation, nil} -> kit_preview(user_id, operation)
      {"key.reenable", id} when is_binary(id) -> Sanctum.ApiKey.reenable(ctx, id, proof)
      {"webhook.reenable", id} when is_binary(id) -> Sanctum.Webhook.reenable(ctx, id, proof)
      {"pairing.reenable", id} when is_binary(id) -> Sanctum.Pairing.reenable(ctx, id, proof)
      {"passkey.reenable", id} when is_binary(id) -> Sanctum.Passkeys.reenable(ctx, id, proof)
      {_operation, _malformed} -> {:error, {:invalid_argument, "The item id is a string"}}
    end
  end

  def kit_reenable(%Context{}, _grant, _operation, _args),
    do: {:error, :operation_not_permitted}

  defp item_arg("key.reenable"), do: "key_id"
  defp item_arg("webhook.reenable"), do: "webhook_id"
  defp item_arg("pairing.reenable"), do: "client_id"
  defp item_arg("passkey.reenable"), do: "passkey_id"

  defp kit_preview(user_id, operation) do
    case Arca.SecurityTransitions.restore_checklist(system(), user_id) do
      {:ok, list} -> {:ok, %{items: Map.fetch!(list, preview_class(operation))}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp preview_class("key.reenable"), do: :api_keys
  defp preview_class("webhook.reenable"), do: :webhooks
  defp preview_class("pairing.reenable"), do: :paired_clients
  defp preview_class("passkey.reenable"), do: :passkeys

  # The person a proof names, recovering: a local, enrolled person of this
  # home, in good standing, with a row of a declared restore open. Every
  # other answer is the same refusal, so the ingress says nothing more
  # about an identifier than that it is not recovering here.
  defp recovering(identifier) do
    with true <- Encoding.identifier?(identifier),
         {:ok, %{user_id: user_id, provenance: "local", enrollment: "enrolled"}} <-
           Arca.PersonIdentities.lookup_identifier(system(), identifier),
         {:ok, %{status: "active"}} <- Arca.Users.get(system(), user_id),
         {:ok, restore_id} when is_binary(restore_id) <-
           Arca.SecurityTransitions.restore_open(system(), user_id) do
      {:ok, user_id, restore_id}
    else
      {:error, :database_error} -> {:error, :unavailable}
      _not_recovering -> {:error, :not_recovering}
    end
  end

  defp kit_budget(user_id) do
    case Arca.RequestRateWindows.claim(
           system(),
           :restore_kit,
           user_id,
           @kit_challenges_per_minute,
           60_000
         ) do
      :ok -> :ok
      {:error, {:rate_limited, retry_after_ms}} -> {:error, {:rate_limited, retry_after_ms}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp read_kit_proof(map) do
    case Identity.RestoreKit.decode(map) do
      {:ok, proof} -> {:ok, proof}
      {:error, _malformed} -> {:error, :invalid_proof}
    end
  end

  defp same_restore(restore_id, restore_id), do: :ok
  defp same_restore(_named, _open), do: {:error, :not_recovering}

  # The genesis the person's enrollment registered: the locator of their
  # directory, which the restored identity row may name at a head the
  # directory has since moved past.
  defp restored_genesis(user_id) do
    case Arca.IdentityAttempts.genesis(system(), user_id) do
      {:ok, binding} -> {:ok, binding}
      {:error, :not_found} -> {:error, :not_recovering}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp kit_signer(proof, %State{recovery_keys: keys}) do
    case Identity.RestoreKit.signer(proof, keys) do
      {:ok, key} -> {:ok, key}
      {:error, _wrong_signer} -> {:error, :not_a_holder}
    end
  end

  # ===========================================================================
  # Restore
  # ===========================================================================

  @doc """
  Restore an identity on this empty installation (the module doc):
  `params` holds the person's recovery code under `"recovery_code"`, and
  `capability` is the installation token the request presented. The
  identity is read at the directory this deployment pins.

  Answers `{:ok, %{status: "completed", identifier, user_id,
  session_token}}`: the new session's token, for the surface to hand the
  holder of the capability and no one else.

  Refusals, each without touching anything the ones before it guard:
  `:restore_disabled` (no token configured), `:invalid_token`,
  `:no_directory` (this deployment pins none), `:not_a_code` and `:typo`
  (the code does not read), `:unknown_identity` (the pinned directory
  serves no such identifier), `:not_a_holder` (the code's secret holds no
  recovery key of the identity now), `:token_claimed` (another restore
  holds the installation, or this token's attempt restores another
  code's identity), `:token_spent`, `:not_empty` (the node holds a person),
  `:superseded`, `:refused` (the directory refused the recovery; the
  token is spent), `:restored` (a completed restore, which issues no
  session), and the retryable `{:retry, phase, seconds}` and
  `:unavailable`. While the home's storage reserve is depleted
  (`Arca.StorageReserve`) a restore, an ingress and no operation that
  takes authority away, is refused `{:unavailable, :storage_reserve}`
  once the capability is checked, before anything is read or written.
  """
  @spec restore(code_params(), String.t() | nil, opts()) :: {:ok, map()} | {:error, term()}
  def restore(params, capability, opts \\ []) do
    opts = client_options!(opts)

    with {:ok, token_digest} <- capability(capability),
         :ok <- reserve_held(),
         {:ok, directory} <- pinned_directory(),
         {:ok, code} <- parse_code(params) do
      case Arca.IdentityAttempts.get_by_token(system(), token_digest) do
        {:ok, attempt} ->
          case bound_code(attempt, code) do
            :ok -> resume_restore(attempt, code, opts)
            {:error, _another} -> {:error, another_code(attempt)}
          end

        {:error, :not_found} ->
          begin_restore(token_digest, code, directory, opts)

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  defp reserve_held,
    do:
      if(Arca.StorageReserve.depleted?(), do: {:error, Arca.StorageReserve.refusal()}, else: :ok)

  @doc """
  A first-method reproof challenge for this installation's completed
  restore (the module doc): the capability again. Answers `%{challenge,
  expires_at}`, the challenge unpadded base64url, alive five minutes from
  the database's clock (`Arca.ServerMetaStorage.now!/0`), which is the
  clock that checks it.

  Refusals: `:restore_disabled`, `:invalid_token`, `:not_restored` (no
  completed restore under this token), `:superseded`, `:closed` (a first
  method exists), `:unavailable`.
  """
  @spec restore_challenge(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def restore_challenge(capability) do
    # The database's clock, never this node's: `consume_reproof/3` compares
    # the expiry with it, so a node's skew neither stretches nor shortens
    # the five minutes. A clock the store cannot read is `:unavailable`.
    with {:ok, token_digest} <- capability(capability),
         {:ok, attempt} <- completed_restore(token_digest),
         {:ok, now} <-
           guarded("reproof clock", fn -> {:ok, Arca.ServerMetaStorage.now!()} end) do
      challenge = :crypto.strong_rand_bytes(32)
      expires_at = DateTime.add(now, @reproof_ms, :millisecond)

      case Arca.IdentityAttempts.put_reproof(
             system(),
             attempt.id,
             challenge_digest(challenge),
             expires_at
           ) do
        {:ok, _held} -> {:ok, %{challenge: Encoding.b64(challenge), expires_at: expires_at}}
        {:error, :first_method_used} -> {:error, :closed}
        {:error, :not_restored} -> {:error, :not_restored}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  @doc """
  Reprove the recovery code against a reproof challenge (the module doc):
  `params` holds the code under `"recovery_code"` and the `"challenge"`,
  and `capability` is the installation token. Answers as `restore/3`
  does, with a new session.

  Refusals: `restore_challenge/1`'s, `:not_a_code` and `:typo` (the code
  does not read), `:token_spent` (a code of an identity this restore did
  not restore, or one whose secret did not sign it), `:not_a_holder`,
  `:superseded` (a later recovery replaced this restore's keys),
  `:challenge_refused` (no challenge held, another, an expired one or one
  already used), and the retryable `{:retry, "completed", seconds}` (the
  directory could not be read).
  """
  @spec reproof(code_params(), String.t() | nil, opts()) :: {:ok, map()} | {:error, term()}
  def reproof(params, capability, opts \\ []) when is_map(params) do
    opts = client_options!(opts)

    with {:ok, token_digest} <- capability(capability),
         {:ok, code} <- parse_code(params),
         {:ok, challenge} <- challenge(Map.get(params, "challenge")),
         {:ok, attempt} <- completed_restore(token_digest),
         :ok <- bound_code(attempt, code) |> or_spent(attempt),
         :ok <- held_challenge(attempt, challenge),
         {:ok, state} <-
           live_state(attempt.identifier, attempt.genesis, opts) |> retry_at("completed"),
         :ok <- holds(state, code.recovery_key),
         :ok <- current_keys(state, attempt) do
      case Arca.IdentityAttempts.consume_reproof(
             system(),
             attempt.id,
             challenge_digest(challenge)
           ) do
        {:ok, attempt} -> restored_session(attempt)
        {:error, :no_challenge} -> {:error, :challenge_refused}
        {:error, :first_method_used} -> {:error, :closed}
        {:error, :not_restored} -> {:error, :not_restored}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  defp completed_restore(token_digest) do
    case Arca.IdentityAttempts.get_by_token(system(), token_digest) do
      {:ok, %{phase: "completed"} = attempt} -> {:ok, attempt}
      {:ok, %{phase: "superseded"}} -> {:error, :superseded}
      {:ok, _restoring} -> {:error, :not_restored}
      {:error, :not_found} -> {:error, :not_restored}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The installation capability, checked before anything else: the
  # configured token's digest, compared in constant time.
  defp capability(presented) do
    case Application.get_env(:sanctum, :restore_token) do
      configured when is_binary(configured) and configured != "" ->
        if is_binary(presented) and
             Plug.Crypto.secure_compare(
               :crypto.hash(:sha256, presented),
               :crypto.hash(:sha256, configured)
             ),
           do: {:ok, Prima.Digest.sha256(configured)},
           else: {:error, :invalid_token}

      _unset ->
        {:error, :restore_disabled}
    end
  end

  # The person's recovery code as `Prima.RecoveryCode.decode/1` reads it:
  # the identifier it names and the recovery key pair its secret derives.
  defp parse_code(%{"recovery_code" => text}) do
    with {:ok, %{identifier: identifier, secret: secret}} <- Prima.RecoveryCode.decode(text),
         {:ok, {public, private}} <- Identity.derive_recovery_key(secret) do
      {:ok, %{identifier: identifier, recovery_key: public, recovery_private: private}}
    end
  end

  defp parse_code(_params), do: {:error, :not_a_code}

  defp challenge(value) when is_binary(value) do
    case Encoding.unb64(value, 32) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :challenge_refused}
    end
  end

  defp challenge(_value), do: {:error, :challenge_refused}

  defp challenge_digest(challenge), do: Prima.Digest.sha256(challenge)

  # A challenge this restore does not hold alive is refused before the
  # directory is read; the consumption at the end decides again.
  defp held_challenge(attempt, challenge) do
    case Arca.IdentityAttempts.reproof_held(system(), attempt.id, challenge_digest(challenge)) do
      :ok -> :ok
      {:error, :no_challenge} -> {:error, :challenge_refused}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The attempt this token claimed resumes only for a code of the identity
  # it restores, whose secret signed its request.
  defp bound_code(attempt, code) do
    if attempt.identifier == code.identifier and signed_by?(attempt, code.recovery_key),
      do: :ok,
      else: {:error, :token_claimed}
  end

  defp retry_at({:error, :directory_unavailable}, phase), do: {:error, {:retry, phase, 1}}
  defp retry_at(answer, _phase), do: answer

  defp or_spent(:ok, _attempt), do: :ok
  defp or_spent({:error, _another}, attempt), do: {:error, another_code(attempt)}

  # Another code under a token already bound: the token is still another
  # restore's while it runs, and spent for good once that one ended.
  defp another_code(%{phase: phase}) when phase in ["refused", "superseded", "completed"],
    do: :token_spent

  defp another_code(_running), do: :token_claimed

  defp resume_restore(%{phase: "completed"}, _code, _opts), do: {:error, :restored}
  defp resume_restore(%{phase: "superseded"}, _code, _opts), do: {:error, :superseded}
  defp resume_restore(%{phase: "refused"}, _code, _opts), do: {:error, :refused}
  defp resume_restore(attempt, _code, opts), do: continue_restore(attempt, opts)

  defp begin_restore(token_digest, code, directory, opts) do
    with :ok <- unclaimed(token_digest),
         :ok <- empty_node(),
         {:ok, genesis} <- code_genesis(code, directory, opts),
         {:ok, state} <- live_state(code.identifier, genesis, opts) |> retry_at("none"),
         :ok <- holds(state, code.recovery_key),
         {:ok, staged} <- stage(code, state),
         {:ok, attempt} <- open_restore(token_digest, code, directory, genesis, staged) do
      continue_restore(attempt, opts)
    end
  end

  # Another restore holding the installation, or this token spent, is
  # answered before any outbound call; the claim decides again atomically.
  defp unclaimed(token_digest) do
    case Arca.InstallationClaims.get(system()) do
      {:ok, %{state: "pending"}} -> {:error, :token_claimed}
      {:ok, %{token_digest: ^token_digest}} -> {:error, :token_spent}
      {:ok, _ended} -> :ok
      {:error, :not_found} -> :ok
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp empty_node do
    case Arca.Users.list(system(), limit: 1) do
      {:ok, []} -> :ok
      {:ok, [_person]} -> {:error, :not_empty}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The genesis of the identity the code names, at the pinned directory.
  defp code_genesis(code, directory, opts) do
    case Client.genesis(code.identifier, directory, opts) do
      {:ok, genesis} ->
        {:ok, genesis}

      {:error, reason}
      when reason in [:not_found, :directory_mismatch, :identifier_mismatch, :invalid_locator] ->
        {:error, :unknown_identity}

      {:error, reason} ->
        if retryable?(reason),
          do: {:error, {:retry, "none", retry_seconds(reason)}},
          else: {:error, :unknown_identity}
    end
  end

  # New live and operational keys, sealed in the restore's own frame, and
  # the `recover` naming them, signed by the code's secret at the revision
  # the directory serves now. The request id is this attempt's for good.
  defp stage(code, %State{} = state) do
    request_id = Prima.UUID7.generate_id("rst")
    frame = "restore:" <> request_id

    guarded("staging a restore's keys", fn ->
      {live, live_private} = :crypto.generate_key(:eddsa, :ed25519)
      {operational, operational_private} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, live_sealed} =
        Sanctum.Cipher.encrypt(live_private, CipherAAD.person_key(frame, :live))

      {:ok, operational_sealed} =
        Sanctum.Cipher.encrypt(operational_private, CipherAAD.person_key(frame, :operational))

      {:ok, request} =
        RecoverRequest.new(
          identifier: code.identifier,
          directory: state.directory,
          live_key: live,
          operational_key: operational,
          expected_revision: state.revision,
          request_id: request_id
        )

      {:ok,
       %{
         request_id: request_id,
         request: Identity.sign(request, code.recovery_private),
         staged_live_public_key: live,
         staged_operational_public_key: operational,
         staged_live_key_sealed: live_sealed,
         staged_operational_key_sealed: operational_sealed
       }}
    end)
  end

  defp open_restore(token_digest, code, directory, genesis, staged) do
    attrs = %{
      kind: "restore",
      request_id: staged.request_id,
      identifier: code.identifier,
      directory_url: directory,
      genesis: genesis,
      entry: Identity.canonical(staged.request),
      request_digest: Identity.request_digest(staged.request),
      expected_revision: staged.request.expected_revision,
      token_digest: token_digest,
      staged_live_public_key: staged.staged_live_public_key,
      staged_operational_public_key: staged.staged_operational_public_key,
      staged_live_key_sealed: staged.staged_live_key_sealed,
      staged_operational_key_sealed: staged.staged_operational_key_sealed
    }

    case Arca.IdentityAttempts.open(system(), attrs) do
      {:ok, attempt} -> {:ok, attempt}
      {:error, :claimed} -> {:error, :token_claimed}
      {:error, :token_claimed} -> {:error, :token_claimed}
      {:error, :token_spent} -> {:error, :token_spent}
      {:error, :not_empty} -> {:error, :not_empty}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp continue_restore(%{phase: "staged"} = attempt, opts) do
    with {:ok, attempt} <- advance(attempt, "staged", "submitted"),
         do: continue_restore(attempt, opts)
  end

  defp continue_restore(%{phase: "submitted"} = attempt, opts) do
    with {:ok, request} <- stored_request(attempt) do
      case Client.recover(attempt.identifier, attempt.genesis, request, opts) do
        {:ok, %{entry_hash: hash}} ->
          with {:ok, attempt} <-
                 advance(attempt, "submitted", "accepted", %{
                   entry_hash: hash,
                   outcome: "accepted"
                 }),
               do: continue_restore(attempt, opts)

        {:error, reason} ->
          if refused?(reason) do
            with {:ok, _ended} <-
                   advance(attempt, "submitted", "refused", %{outcome: word(reason)}),
                 do: {:error, :refused}
          else
            {:error, {:retry, "submitted", retry_seconds(reason)}}
          end
      end
    end
  end

  # A recorded acceptance is history, not present authority: the head is
  # read again, and only keys this attempt introduced, still current, are
  # activated.
  defp continue_restore(%{phase: "accepted"} = attempt, opts) do
    case live_state(attempt.identifier, attempt.genesis, opts) do
      {:ok, state} ->
        if introduced?(state, attempt) do
          with {:ok, attempt} <- advance(attempt, "accepted", "keys_active"),
               do: continue_restore(attempt, opts)
        else
          supersede(attempt, opts)
        end

      {:error, :directory_unavailable} ->
        {:error, {:retry, "accepted", 1}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Activated keys are history too by the time the mint runs: an attempt
  # stopped here may have been superseded since, so the head is read again
  # first, and the mint holds the cached head that read left (`minted/3`),
  # so a later recovery this home caches in between refuses it. A
  # concurrent request under the same token that minted first leaves the
  # node holding this attempt's person, and one that completed first has
  # ended the claim too: read again, the attempt is past this phase.
  defp continue_restore(%{phase: "keys_active"} = attempt, opts) do
    with {:ok, genesis_hash} <- genesis_hash(attempt),
         :ok <- still_current(attempt, opts) do
      case mint_restored(attempt, genesis_hash) do
        {:ok, _person} ->
          with {:ok, attempt} <- reread(attempt), do: continue_restore(attempt, opts)

        {:error, :superseded} ->
          supersede(attempt, opts)

        {:error, refusal} when refusal in [:not_empty, :token_claimed] ->
          case reread(attempt) do
            {:ok, %{phase: "keys_active"}} -> {:error, refusal}
            {:ok, moved} -> continue_restore(moved, opts)
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The session goes only to keys the head still names, read again before
  # anything of this phase: superseded after the mint, the attempt ends
  # with no fill asked for and no session, and the person it minted
  # stays.
  defp continue_restore(%{phase: "minted", user_id: user_id} = attempt, opts)
       when is_binary(user_id) do
    with :ok <- still_current(attempt, opts),
         :ok <- provisioned(user_id),
         {:ok, answer} <- restored_session(attempt) do
      # A concurrent request that completed it first leaves it completed
      # (`advance/4` reads it back): the session issued here stands. One
      # that superseded it after this request's read leaves it superseded:
      # the session issued here never leaves, and its row goes.
      case advance(attempt, "minted", "completed") do
        {:ok, %{phase: "completed"}} -> {:ok, answer}
        {:ok, %{phase: "superseded"}} -> withdrawn(answer)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp continue_restore(%{phase: "completed"}, _opts), do: {:error, :restored}
  defp continue_restore(%{phase: "superseded"}, _opts), do: {:error, :superseded}
  defp continue_restore(%{phase: "refused"}, _opts), do: {:error, :refused}

  # A session issued to keys the attempt no longer stands for: its token is
  # never answered, and its row is deleted. A delete that fails leaves a row
  # whose token nobody holds, and is logged.
  defp withdrawn(%{session_token: token}) do
    case Sanctum.Session.destroy(token) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Sanctum.Recovery] a superseded restore's session could not be deleted: " <>
            Prima.LoggerContext.shape(reason)
        )
    end

    {:error, :superseded}
  end

  # The head read fresh, outside any transaction, still names the keys
  # this attempt introduced: `:ok`, or the attempt ends superseded. A
  # directory that cannot answer leaves the attempt where it stands, for a
  # retry under the same token to resume.
  defp still_current(attempt, opts) do
    case live_state(attempt.identifier, attempt.genesis, opts) do
      {:ok, state} -> if introduced?(state, attempt), do: :ok, else: supersede(attempt, opts)
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The attempt ends superseded from the phase it holds, and its end ends
  # the installation claim. A concurrent request that moved it first leaves
  # it at a later phase, which decides again.
  defp supersede(attempt, opts) do
    case advance(attempt, attempt.phase, "superseded", %{outcome: "superseded"}) do
      {:ok, %{phase: "superseded"}} -> {:error, :superseded}
      {:ok, moved} -> continue_restore(moved, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  # The head names the keys this attempt staged, introduced by its own
  # entry: a later recovery replaced them otherwise.
  defp introduced?(%State{} = state, attempt) do
    state.live_key == attempt.staged_live_public_key and
      state.operational_key == attempt.staged_operational_public_key and
      state.key_epoch == attempt.entry_hash
  end

  defp current_keys(%State{} = state, attempt) do
    if state.live_key == attempt.staged_live_public_key and
         state.operational_key == attempt.staged_operational_public_key,
       do: :ok,
       else: {:error, :superseded}
  end

  defp genesis_hash(%{genesis: genesis, identifier: identifier}) when is_binary(genesis) do
    case Identity.locate(genesis, identifier) do
      {:ok, entry} -> {:ok, Identity.hash(entry)}
      {:error, _malformed} -> {:error, :unavailable}
    end
  end

  defp genesis_hash(_attempt), do: {:error, :unavailable}

  # The person, their identity row with the staged keys re-sealed under
  # their own frame and the attempt's `minted` phase, in the one
  # transaction of the restore's admission (`Sanctum.Newcomer`), which the
  # installation guard admits and which writes the person's athanor and
  # their platform grant beside them: the restored person is the
  # installation's first. A cached head that no longer names the attempt's
  # keys refuses the mint as `:superseded` (`minted/3`).
  defp mint_restored(attempt, genesis_hash) do
    restore = %{
      claim: %{request_id: attempt.request_id, token_digest: attempt.token_digest},
      also: fn person -> minted(person, attempt, genesis_hash) end
    }

    case Sanctum.Newcomer.admit({:restore, restore}, :none) do
      {:ok, %{person: person}} -> {:ok, person}
      {:error, :not_empty} -> {:error, :not_empty}
      {:error, :not_claimed} -> {:error, :token_claimed}
      {:error, :restore_reserved} -> {:error, :token_claimed}
      {:error, :stale_key_epoch} -> {:error, :superseded}
      {:error, :not_owner} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  # The cached head is read after the identity row is written, under the
  # person's lock and then the head row's, the order a head's advance
  # takes: an advance this home committed since the restore's fresh read
  # refuses the mint (`:stale_key_epoch`), and one that comes later waits
  # for the mint to commit, before the `minted` phase reads the head again.
  defp minted(%{id: user_id}, attempt, genesis_hash) do
    with {:ok, keys} <- resealed(attempt, user_id),
         {:ok, _identity} <-
           Arca.PersonIdentities.create(
             system(),
             Map.merge(keys, %{
               user_id: user_id,
               provenance: "local",
               identifier: attempt.identifier,
               head_hash: attempt.entry_hash,
               genesis_hash: genesis_hash,
               directory_url: attempt.directory_url
             })
           ),
         :ok <-
           Arca.DirectoryHeads.certifiable!(user_id, attempt.identifier, attempt.entry_hash),
         {:ok, _minted} <-
           Arca.IdentityAttempts.advance(system(), attempt.id, "keys_active", "minted", %{
             user_id: user_id
           }) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # The staged keys opened in the restore's frame and sealed again in the
  # person's, each only when its public half is the one staged.
  defp resealed(attempt, user_id) do
    frame = "restore:" <> attempt.request_id

    guarded("re-sealing a restore's keys", fn ->
      with {:ok, live} <-
             reseal(
               attempt.staged_live_key_sealed,
               attempt.staged_live_public_key,
               frame,
               user_id,
               :live
             ),
           {:ok, operational} <-
             reseal(
               attempt.staged_operational_key_sealed,
               attempt.staged_operational_public_key,
               frame,
               user_id,
               :operational
             ) do
        {:ok,
         %{
           live_public_key: attempt.staged_live_public_key,
           live_key_sealed: live,
           operational_public_key: attempt.staged_operational_public_key,
           operational_key_sealed: operational
         }}
      end
    end)
  end

  defp reseal(sealed, public, frame, user_id, role) when is_binary(sealed) do
    with {:ok, private} <- Sanctum.Cipher.decrypt(sealed, CipherAAD.person_key(frame, role)),
         true <- public_half?(private, public) do
      Sanctum.Cipher.encrypt(private, CipherAAD.person_key(user_id, role))
    else
      _unopened ->
        Logger.error("[Sanctum.Recovery] a restore's staged #{role} key does not open")
        {:error, :unavailable}
    end
  end

  defp reseal(_sealed, _public, _frame, _user_id, _role), do: {:error, :unavailable}

  defp public_half?(private, public) when byte_size(private) == 32 do
    {derived, _private} = :crypto.generate_key(:eddsa, :ed25519, private)
    derived == public
  end

  defp public_half?(_private, _public), do: false

  # The athanor was minted with the person; its fill is asked for here.
  defp provisioned(user_id), do: Sanctum.Provisioning.after_sign_in(user_id)

  # The restore's session: the reserved provider, issued for the person the
  # attempt minted and named by the attempt (`Sanctum.Session.create/2`).
  defp restored_session(%{user_id: user_id} = attempt) when is_binary(user_id) do
    ctx =
      Context.build(
        user_id: user_id,
        provider: "restore",
        athanor_id: nil,
        permissions: Context.person_permissions()
      )

    with {:ok, ctx} <- Sanctum.Tenancy.resolve_status(ctx, force: true),
         {:ok, session} <- Sanctum.Session.create(ctx, restore: attempt.id) do
      {:ok,
       %{
         status: "completed",
         identifier: attempt.identifier,
         user_id: user_id,
         session_token: session.token
       }}
    else
      {:error, :unavailable} ->
        {:error, {:retry, attempt.phase, 1}}

      {:error, reason} ->
        Logger.error(
          "[Sanctum.Recovery] the restore's session could not be issued: " <>
            Prima.LoggerContext.shape(reason)
        )

        {:error, {:retry, attempt.phase, 1}}
    end
  end

  defp reread(attempt), do: Arca.IdentityAttempts.get(system(), attempt.id) |> read_back()

  defp read_back({:ok, attempt}), do: {:ok, attempt}
  defp read_back({:error, _unanswered}), do: {:error, :unavailable}

  defp advance(attempt, from, to, attrs \\ %{}) do
    case Arca.IdentityAttempts.advance(system(), attempt.id, from, to, attrs) do
      {:ok, moved} -> {:ok, moved}
      {:error, :stale} -> Arca.IdentityAttempts.get(system(), attempt.id) |> read_back()
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # ===========================================================================
  # Shared
  # ===========================================================================

  # The identity as its directory serves it now: a live read
  # (`Sanctum.IdentityFreshness.fresh!/2`), outside any transaction, which
  # verifies the whole log and caches its head, and the verified state it
  # cached.
  defp live_state(identifier, genesis, opts) do
    case Sanctum.IdentityFreshness.fresh!(identifier, [genesis: genesis] ++ opts) do
      {:ok, _head} ->
        case Client.cached(identifier) do
          {:ok, %{state: %State{} = state}} -> {:ok, state}
          {:error, _unreadable} -> {:error, :unavailable}
        end

      {:refused, :identity_stale} ->
        {:error, :directory_unavailable}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp holds(%State{recovery_keys: keys}, key) do
    if key in keys, do: :ok, else: {:error, :not_a_holder}
  end

  defp stored_request(%{entry: entry}) when is_binary(entry) do
    with {:ok, %{} = map} <- Prima.Json.decode(entry),
         {:ok, request} <- RecoverRequest.decode(map) do
      {:ok, request}
    else
      _corrupt -> {:error, :unavailable}
    end
  end

  defp stored_request(_attempt), do: {:error, :unavailable}

  defp signed_by?(attempt, recovery_key) do
    case stored_request(attempt) do
      {:ok, request} -> match?({:ok, _key}, RecoverRequest.signer(request, [recovery_key]))
      {:error, _corrupt} -> false
    end
  end

  defp sign_with(request, private),
    do: guarded("signing a recovery", fn -> {:ok, Identity.sign(request, private)} end)

  defp request_refusal({:ok, request}), do: {:ok, request}
  defp request_refusal({:error, _reason}), do: {:error, :stale_head}

  defp person(%Context{plane: :guest}), do: {:error, :guest_plane}

  defp person(%Context{authenticated: true, anonymous: false, user_id: user_id})
       when is_binary(user_id) do
    if Prima.PersonId.person?(user_id), do: {:ok, user_id}, else: {:error, :unauthenticated}
  end

  defp person(%Context{}), do: {:error, :unauthenticated}

  defp request_id(%{"request_id" => request_id}) when is_binary(request_id) do
    if Encoding.id?(request_id),
      do: {:ok, request_id},
      else: {:error, {:invalid_argument, "The request_id is not a valid request id"}}
  end

  defp request_id(_args),
    do: {:error, {:invalid_argument, "The attempt's request_id is required"}}

  defp seed(value) when is_binary(value) do
    case Encoding.unb64(value, @seed_bytes) do
      {:ok, seed} -> {:ok, seed}
      :error -> {:error, seed_refusal()}
    end
  end

  defp seed(_value), do: {:error, seed_refusal()}

  defp seed_refusal,
    do:
      {:invalid_argument,
       "The recovery_secret is a recovery code's 32-byte secret, in unpadded base64url, " <>
         "drawn by the trusted form"}

  defp seal(plaintext, aad) do
    guarded("sealing a recovery secret", fn -> Sanctum.Cipher.encrypt(plaintext, aad) end)
  end

  defp open(sealed, aad) do
    guarded("opening a recovery secret", fn ->
      case Sanctum.Cipher.decrypt(sealed, aad) do
        {:ok, seed} when byte_size(seed) == @seed_bytes ->
          {:ok, seed}

        _unopened ->
          Logger.error("[Sanctum.Recovery] a sealed recovery secret does not open")
          {:error, :unavailable}
      end
    end)
  end

  defp move(ctx, attempt, to, attrs \\ %{}) do
    case Arca.IdentityAttempts.advance(Context.actor(ctx), attempt.id, attempt.phase, to, attrs) do
      {:ok, moved} -> {:ok, moved}
      {:error, :stale} -> Arca.IdentityAttempts.get(Context.actor(ctx), attempt.id) |> read_back()
      {:error, :stale_head} -> {:error, :stale_head}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp refuse(ctx, attempt, outcome, refusal) do
    with {:ok, _refused} <- move(ctx, attempt, "refused", %{outcome: outcome}),
         do: {:error, refusal}
  end

  defp retryable(_attempt, {:rate_limited, seconds}), do: {:error, {:rate_limited, seconds}}
  defp retryable(_attempt, _reason), do: {:error, :directory_unavailable}

  defp open_refusal(ctx, user_id, kind, :attempt_in_progress),
    do: {:error, {:attempt_in_progress, in_progress_request(ctx, user_id, kind)}}

  defp open_refusal(_ctx, _user_id, _kind, reason)
       when reason in [:not_enrollable, :request_id_reused, :stale_head],
       do: {:error, if(reason == :not_enrollable, do: :not_enrolled, else: reason)}

  defp open_refusal(_ctx, _user_id, _kind, {:confirmation_required, _} = signal),
    do: {:error, signal}

  defp open_refusal(_ctx, _user_id, _kind, {:conflict, _message} = conflict),
    do: {:error, conflict}

  defp open_refusal(_ctx, _user_id, _kind, reason)
       when reason in [:not_standing, :identity_stale, :not_authenticated],
       do: {:error, reason}

  # A paired device that no longer stands where the attempt is written
  # (`Sanctum.Consent.Authz.consume/2`) is refused as an issuance refuses
  # it, never as a store that could not answer.
  defp open_refusal(_ctx, _user_id, _kind, reason)
       when Sanctum.Issuance.standing_refusal?(reason),
       do: {:error, reason}

  defp open_refusal(_ctx, _user_id, _kind, _reason), do: {:error, :unavailable}

  defp in_progress_request(ctx, user_id, kind) do
    case Arca.IdentityAttempts.in_progress(Context.actor(ctx), user_id, kind) do
      {:ok, %{request_id: request_id}} -> request_id
      _none -> nil
    end
  end

  # The directory's answers that end an attempt: a refusal it recorded or
  # made, never one it may answer otherwise on a retry.
  defp refused?({:refused, _kind, _reason}), do: true
  defp refused?({:stale_policy, _recorded}), do: true

  defp refused?(reason)
       when reason in [
              :body_too_large,
              :conflict,
              :request_id_reused,
              :wrong_identifier,
              :directory_changed,
              :read_only,
              :not_served
            ],
       do: true

  defp refused?(_reason), do: false

  defp retryable?(reason) when reason in [:unreachable, :timeout, :busy, :unavailable], do: true

  defp retryable?({kind, _seconds}) when kind in [:rate_limited, :capacity, :busy, :unavailable],
    do: true

  defp retryable?(_reason), do: false

  defp retry_seconds({_kind, seconds}) when is_integer(seconds) and seconds > 0, do: seconds
  defp retry_seconds(_reason), do: 1

  defp word(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp word({:refused, kind, _reason}) when is_atom(kind), do: "refused " <> Atom.to_string(kind)
  defp word({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)

  defp client_options!(opts) when is_list(opts) do
    case Keyword.validate(opts, [:resolver, :cacerts]) do
      {:ok, opts} ->
        opts

      {:error, unknown} ->
        raise ArgumentError,
              "Sanctum.Recovery takes only :resolver and :cacerts, not " <>
                Enum.map_join(unknown, ", ", &Prima.LoggerContext.shape/1)
    end
  end

  # Every step that holds a private key or a secret runs here. A raise inside
  # one would carry the key into a crash report through its stacktrace's
  # arguments, so it is answered `:unavailable` and only the exception's
  # module is logged.
  defp guarded(step, fun) do
    fun.()
  rescue
    exception ->
      Logger.error("[Sanctum.Recovery] #{step} failed (#{inspect(exception.__struct__)})")
      {:error, :unavailable}
  end

  defp system, do: Prima.Actor.system()
end
