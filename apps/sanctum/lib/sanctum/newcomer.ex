# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Newcomer do
  @moduledoc """
  The one path that makes a person (`admit/2`): an admission at the CYFR
  that holds them. A sign-in method never makes one; it unlocks a person
  who exists (`Sanctum.SignIn.unlock/1`). No provider subject, email or
  handle decides who a person is.

  | Admission | Checked | Makes |
  |---|---|---|
  | `{:setup, token}` | the token equals the configured setup token (constant-time); in the mint's transaction, under the installation claims' order row, no person exists and no restore holds the installation | a local person, their keys, their athanor, the platform grant |
  | `{:invitation, code}` | in the mint's transaction before the person's row, the code's invitation is unexpired, unredeemed and unrevoked, its issuer still an active person here at the standing they issued it under and, when it names a group athanor, still seated there with the group active and open, or else still the platform administrator (`Sanctum.Invitations.redeemable/1`), then the mint rate and the athanor cap; redeemed by one conditional write after the person's row | a local person, their keys, their athanor, and the seat the invitation names, counted against the group's member cap |
  | `:open` | the door's `*` admits; the mint rate and the athanor cap, in the mint's transaction before the person's row | a local person, their keys, their athanor |
  | `{:remote, remote}` | the door admits the identifier (`Sanctum.Door.sign_in_identifier/1`), or, with an invitation, no deny names it and the invitation is redeemable (`Sanctum.Invitations.redeemable_hash/1`); the head the CYFR sign-in verified is still fresh | a remote person row with no keys and no athanor; pending identifier invitations activate; with an invitation, its redemption, its seat and the identifier's allow |
  | `{:restore, restore}` | the restore's installation claim, in the mint's transaction (`Arca.InstallationClaims`) | the restored person, their athanor, the platform grant |

  The installation's first person is its platform administrator: the mint
  that writes them writes the grant, under the order row and the member
  slot (`Arca.Users.mint/4`), and no other path grants it; the grant is
  audited once it commits (`[:cyfr, :sanctum, :tenancy,
  :platform_admin_bootstrap]`). Only setup and a restore make the first
  person; any other admission onto an empty installation is refused
  `:not_set_up`.

  ## The invitation

  The invitation is the admitting act, as setup's token is, so the door
  is not asked. Its code is checked before the passkey is verified, so a
  code that admits no one starts nothing, and decided again in the mint's
  transaction, where its redemption commits with the person or not at
  all: a refused cap, a member cap the group has reached, a redemption
  another admission won first and a killed process each leave no person
  and the code unredeemed. Every refusal of the invitation itself is
  `:invitation_invalid`. Its athanor caps are the open admission's: the
  invitation mints its person an athanor as an open admission does, and
  an issuer cannot take the CYFR past the rate and the ceiling its
  operator set. The seat's announcement follows the commit.

  ## A remote person with an invitation

  A remote person whose CYFR sign-in carried an invitation (`remote`'s
  `invitation`, the code's hash, `Sanctum.Invitations.code_hash/1`) is
  admitted by the invitation in place of the door's allow rule: no deny
  may name their identifier, and the invitation must be redeemable, read
  before the transaction and again inside it. The mint's transaction
  then redeems it, seats them and writes their identifier's allow
  (`Sanctum.Invitations.redeem_hash/2`), so a deny committed after the
  first read rolls the whole admission back, makes no person and leaves
  the invitation unspent.

  ## The setup token's re-admission

  While the person setup made holds no passkey, no paired device and no
  linked sign-in method, `{:setup, token}` answers that person again
  (`readmitted: true`), with the credential it brings: the passkey written
  for them, or a new command-line session. The guard decides it under the
  order row and the person's lock, so two re-admissions decide in one
  order. From the commit that gives the person any of the three, the
  token opens nothing (`:setup_closed`). A token that is not the
  configured one, a missing one, or a CYFR with none configured, opens
  nothing either.

  ## The credential

  A local admission brings its credential: its first proof, and the new
  person's identity (`t:identity/0`, parsed from a surface's fields by
  `identity/1`) — the name they take, a recovery secret the trusted form
  or the command line drew, and the enrollment's request id.

    * `{:passkey, registration, identity}`, for setup, an invitation and
      an open admission — the browser's answer to
      `Sanctum.Passkeys.newcomer_options/0`, verified with no transaction
      open (`Sanctum.Passkeys.verify_newcomer/1`) and written, active,
      inside the admission's transaction (`Sanctum.Passkeys.write_newcomer/2`),
      so a failed admission leaves neither a person nor a passkey. The
      person's id is the one the registration was drawn for. A session
      with provider `passkey` follows the commit.
    * `{:command_line, machine, identity}`, for setup alone — a
      command-line session for `machine` (`Sanctum.CliSignIn.machine/1`),
      provider `setup`, minted after the commit.

  A remote person and a restored person bring none (`:none`): the CYFR
  sign-in and the restore mint their own sessions. A session that cannot
  be minted after the commit leaves the person, whom setup answers again
  while they hold no credential.

  ## Enrollment at admission

  The first proof is the one proof. A local admission enrolls its person
  in its own transaction, last, after their keys, athanor and passkey
  (`Sanctum.Recovery.open_at_admission/3`): the genesis over the keys just
  minted and the secret's recovery key, naming the directory this
  deployment pins (`Sanctum.directory_url/0`), the secret sealed, and the
  enrollment attempt opened at `staged` with the name. A deployment that
  pins no directory admits no local person, refused before the passkey is
  verified. Registering at the directory and claiming the name follow the
  commit (`registry.register`).

  The admission answers `recovery`: the attempt's id, the identifier, the
  name and the recovery code (`Prima.RecoveryCode`), composed from the
  sealed secret until the person says it is saved. A re-admission answers
  the attempt that stands, so the identity its credential brings is not
  used.

  ## One transaction

  The person's row, their keys (`Sanctum.Person.mint_keys/1`), their
  athanor (`Sanctum.Provisioning.mint_personal/1`), the grant and the
  passkey commit together or not at all: a process killed mid-admission
  and a member whose slot was lost leave no row. An open admission's caps
  are counted in the same transaction before the person's row
  (`Sanctum.Provisioning.personal_admissible/0`), so one refused at a cap
  writes none. The athanor's fill and the invitations' announcements
  follow the commit; a restore's fill is asked for by `Sanctum.Recovery`,
  once the head still names the restored keys.

  Refusals: `:setup_closed`, `:not_set_up`, `:restore_reserved`,
  `:invitation_invalid`, `:no_directory`, `{:door, reason}`, `:identity_stale`,
  `:registration_refused`, a cap's `{:limit_reached, key, cap}` or
  `{:cap_unverifiable, key}`, the invited seat's own refusals
  (`:recovering_from_restore` among them), `:not_owner`
  (this member no longer holds its slot), `:unavailable`,
  `{:invalid_argument, sentence}` for a credential the admission does not
  take, one without an identity among them, and the restore's own
  refusals.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Members, Users}

  @typedoc """
  What the CYFR sign-in verified of a remote person, and the hash of the
  invitation their sign-in carried, when it carried one.
  """
  @type remote :: %{
          required(:identifier) => String.t(),
          required(:directory_url) => String.t(),
          required(:genesis_hash) => String.t(),
          required(:head_hash) => String.t(),
          optional(:invitation) => String.t() | nil
        }

  @typedoc """
  A restore's mint (`Sanctum.Recovery`): the installation claim it names,
  and its closure, run in the mint's transaction in place of minting keys,
  writing the restored identity row and advancing the restore attempt.
  """
  @type restore :: %{
          required(:claim) => Arca.InstallationClaims.claim_ref(),
          required(:also) => (map() -> :ok | {:error, term()})
        }

  @type admission ::
          {:setup, String.t()}
          | {:invitation, String.t()}
          | :open
          | {:remote, remote()}
          | {:restore, restore()}

  @typedoc """
  A new local person's identity: the name they take, the recovery secret
  drawn for them (32 bytes) and the enrollment's request id.
  """
  @type identity :: %{name: String.t(), recovery_secret: <<_::256>>, request_id: String.t()}

  @type credential ::
          {:passkey, registration :: map(), identity()}
          | {:command_line, machine :: String.t(), identity()}
          | :none

  @typedoc """
  The person's enrollment as a local admission answers it: `code` while
  its secret is sealed, absent once the person said it is saved.
  """
  @type recovery :: %{
          required(:attempt_id) => String.t(),
          required(:identifier) => String.t(),
          required(:name) => String.t() | nil,
          optional(:code) => String.t()
        }

  @typedoc """
  The admitted person, whether setup answered them again, the session
  token a local admission's credential minted, when it minted one, and a
  local person's enrollment.
  """
  @type admitted :: %{
          required(:person) => Users.user(),
          required(:readmitted) => boolean(),
          optional(:session_token) => String.t(),
          optional(:recovery) => recovery()
        }

  @doc "Make a person by `admission`, with `credential` (the module doc)."
  @spec admit(admission(), credential()) :: {:ok, admitted()} | {:error, term()}
  def admit(admission, credential) do
    with {:ok, credential} <- taken(admission, credential),
         :ok <- admissible(admission),
         {:ok, directory} <- directory(credential),
         {:ok, person_id, verified} <- verified(credential),
         {:ok, person} <- mint(admission, person_id, {credential, directory}, verified) do
      readmitted = person.id != person_id
      committed(admission, person, readmitted, credential)
    end
  end

  @doc """
  Parse a surface's `%{"name", "recovery_secret", "request_id"}` into the
  identity a local admission's credential carries: the name by `name/1`,
  the secret 32 bytes of unpadded base64url (`Sanctum.Recovery.secret/1`),
  the request id by `Prima.Identity.Encoding.id?/1`. Refused
  `{:invalid_argument, sentence}`.
  """
  @spec identity(term()) :: {:ok, identity()} | {:error, {:invalid_argument, String.t()}}
  def identity(%{"name" => name, "recovery_secret" => secret, "request_id" => request_id}) do
    with :ok <- name(name),
         {:ok, secret} <- Sanctum.Recovery.secret(secret),
         :ok <- request_id(request_id),
         do: {:ok, %{name: name, recovery_secret: secret, request_id: request_id}}
  end

  def identity(_fields),
    do:
      {:error,
       {:invalid_argument, "A new person brings their name, a recovery_secret and a request_id"}}

  @doc """
  Whether `value` is a name a person may take: `Prima.ComponentRef`'s
  personal grammar, refused with the sentence a person reads.
  """
  @spec name(term()) :: :ok | {:error, {:invalid_argument, String.t()}}
  def name(value) do
    if Prima.ComponentRef.valid_personal_slug?(value),
      do: :ok,
      else:
        {:error,
         {:invalid_argument,
          "A name is lowercase letters and digits joined by single hyphens, at most 39 " <>
            "characters."}}
  end

  @doc """
  Whether `token` opens setup now: it is the configured setup token, and
  a setup would be admitted (`Arca.InstallationClaims.setup_open?/1`).
  The setup page asks before it starts a passkey ceremony, so a link that
  is not valid, or a CYFR set up already, creates no passkey, and a program
  on this machine asks through the setup status route; the admission
  decides again in its transaction. One refusal for both, as
  the admission answers, so a guesser learns nothing from it.
  """
  @spec setup_open(term()) :: :ok | {:error, :setup_closed | :unavailable}
  def setup_open(token) when is_binary(token) do
    with :ok <- admissible({:setup, token}) do
      case Arca.InstallationClaims.setup_open?(Prima.Actor.system()) do
        {:ok, true} -> :ok
        {:ok, false} -> {:error, :setup_closed}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  def setup_open(_token), do: {:error, :setup_closed}

  # ---- before the transaction ----------------------------------------------

  # A missing token is refused as a wrong one is.
  defp taken({:setup, token}, _credential) when not is_binary(token),
    do: {:error, :setup_closed}

  defp taken({:setup, _token}, {:command_line, machine, identity}) do
    with {:ok, machine} <- Sanctum.CliSignIn.machine(machine),
         :ok <- identified(identity),
         do: {:ok, {:command_line, machine, identity}}
  end

  defp taken({:invitation, code}, _credential) when not is_binary(code),
    do: {:error, :invitation_invalid}

  defp taken(:open, {:passkey, registration, identity} = credential)
       when is_map(registration) do
    with :ok <- identified(identity), do: {:ok, credential}
  end

  defp taken({kind, _secret}, {:passkey, registration, identity} = credential)
       when kind in [:setup, :invitation] and is_map(registration) do
    with :ok <- identified(identity), do: {:ok, credential}
  end

  defp taken({:remote, %{identifier: id, directory_url: dir}}, :none)
       when is_binary(id) and is_binary(dir),
       do: {:ok, :none}

  defp taken({:restore, %{claim: %{}, also: also}}, :none) when is_function(also, 1),
    do: {:ok, :none}

  defp taken(_admission, _credential),
    do:
      {:error,
       {:invalid_argument,
        "This admission does not take that credential: setup takes a passkey or the command " <>
          "line, an invitation and an open admission a passkey, each with the new person's " <>
          "identity"}}

  # The identity a local credential carries, as `identity/1` parses it.
  defp identified(%{name: name, recovery_secret: <<_::256>>, request_id: request_id}) do
    with :ok <- name(name), do: request_id(request_id)
  end

  defp identified(_identity),
    do:
      {:error,
       {:invalid_argument, "A new person brings their name, a recovery_secret and a request_id"}}

  defp request_id(value) do
    if Prima.Identity.Encoding.id?(value),
      do: :ok,
      else: {:error, {:invalid_argument, "The request_id is not a valid request id"}}
  end

  # The directory a local person's genesis names: the one this deployment
  # pins. With none pinned no local person is admitted, before the
  # passkey is verified.
  defp directory(:none), do: {:ok, nil}

  defp directory(_local) do
    case Sanctum.directory_url() do
      url when is_binary(url) and url != "" -> {:ok, url}
      _none -> {:error, :no_directory}
    end
  end

  defp admissible({:setup, token}) do
    case Application.get_env(:sanctum, :setup_token) do
      configured when is_binary(configured) and byte_size(configured) == byte_size(token) ->
        if Plug.Crypto.secure_compare(configured, token), do: :ok, else: {:error, :setup_closed}

      _none_or_other ->
        {:error, :setup_closed}
    end
  end

  # An invitation that admits no one starts nothing: its passkey is not
  # verified. The mint's transaction decides it again.
  defp admissible({:invitation, code}), do: Sanctum.Invitations.redeemable(code)

  # An open admission needs the door's `*`. It names no identifier, so a
  # refusal leaves no request.
  defp admissible(:open) do
    case Sanctum.Door.Store.wildcard() do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, {:door, :not_allowed}}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  # The door, or the invitation in place of its allow rule, then the head
  # the CYFR sign-in verified, still fresh: an identity whose directory
  # cannot be read writes no row.
  defp admissible({:remote, %{identifier: identifier} = remote}) do
    with :ok <- remote_admitted(identifier, remote[:invitation]) do
      case Sanctum.IdentityFreshness.fresh?(identifier) do
        {:ok, _head} -> :ok
        {:refused, :identity_stale} -> {:error, :identity_stale}
        {:error, :unavailable} -> {:error, :unavailable}
      end
    end
  end

  defp admissible({:restore, _restore}), do: :ok

  defp remote_admitted(identifier, nil) do
    with {:ok, :allowed} <- Sanctum.Door.sign_in_identifier(identifier), do: :ok
  end

  # A deny outranks the invitation, as it outranks every allow.
  defp remote_admitted(identifier, invitation) do
    case Sanctum.Door.Store.denied(nil, identifier) do
      {:ok, false} -> Sanctum.Invitations.redeemable_hash(invitation)
      {:ok, true} -> {:error, {:door, :denied}}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  # The person's id: the one a passkey registration was drawn for, or a
  # new one.
  defp verified({:passkey, registration, _identity}) do
    with {:ok, %{user_id: user_id, verified: verified}} <-
           Sanctum.Passkeys.verify_newcomer(registration),
         do: {:ok, user_id, verified}
  end

  defp verified(_credential),
    do: {:ok, Prima.UUID7.generate_id(Prima.PersonId.prefix()), nil}

  # ---- the transaction ------------------------------------------------------

  defp mint(admission, person_id, {credential, directory}, verified) do
    now = DateTime.utc_now()

    user_attrs = %{
      id: person_id,
      prefs: Jason.encode!(%{}),
      first_seen_at: now,
      last_seen_at: now,
      created_at: now,
      updated_at: now
    }

    write = fn person -> written(person, credential, verified) end
    enroll = fn person -> enrolled(person, credential, directory) end

    Arca.Users.mint(
      Prima.Actor.system(),
      user_attrs,
      identity(admission, now),
      [admission: kind(admission), also: &also(admission, {write, enroll}, &1)] ++
        verify(admission) ++ restore_claim(admission)
    )
    |> case do
      {:ok, person} -> {:ok, person}
      {:error, {:readmit, %{id: user_id}}} -> readmit(user_id, write)
      {:error, :database_error} -> {:error, :unavailable}
      {:error, reason} -> refused(credential, reason)
    end
  end

  # The person setup made, admitted again while they hold no sign-in
  # method: only the credential this admission brings is written, and
  # the enrollment their first admission opened stands.
  defp readmit(user_id, write) do
    case Arca.Users.readmit(Prima.Actor.system(), user_id, also: write) do
      {:ok, person} -> {:ok, person}
      {:error, :database_error} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  # A passkey registration names the person it was drawn for: a person of
  # that id already made means the registration was presented before.
  defp refused({:passkey, _registration, _identity}, :conflict),
    do: {:error, :registration_refused}

  defp refused(_credential, reason), do: {:error, reason}

  defp kind({:setup, _token}), do: "setup"
  defp kind({:invitation, _code}), do: "invitation"
  defp kind(:open), do: "open"
  defp kind({:remote, _remote}), do: "remote"
  defp kind({:restore, _restore}), do: "restore"

  # Inside the mint's transaction, before the person's row: an open
  # admission's caps, and an invitation's own check before them. The
  # installation's first person is minted past them.
  defp verify(:open), do: [verify: &Sanctum.Provisioning.personal_admissible/0]

  defp verify({:invitation, code}),
    do: [
      verify: fn ->
        with :ok <- Sanctum.Invitations.redeemable(code),
             do: Sanctum.Provisioning.personal_admissible()
      end
    ]

  defp verify({:remote, %{invitation: invitation}}) when is_binary(invitation),
    do: [verify: fn -> Sanctum.Invitations.redeemable_hash(invitation) end]

  defp verify(_admission), do: []

  defp restore_claim({:restore, %{claim: claim}}), do: [restore: claim]
  defp restore_claim(_admission), do: []

  # A remote person is named by the CYFR sign-in's identity, linked with
  # them: what a later sign-in of theirs unlocks.
  defp identity({:remote, %{identifier: identifier, directory_url: directory}}, now) do
    %{
      key: Sanctum.Auth.Identity.cyfr_key(directory, identifier),
      provider: "cyfr",
      issuer: directory,
      subject: identifier,
      first_seen_at: now,
      last_seen_at: now
    }
  end

  defp identity(_admission, _now), do: nil

  # Inside the mint's transaction, after the person's row and the first
  # person's grant.
  defp also({:setup, _token}, steps, person), do: local(person, steps)
  defp also(:open, steps, person), do: local(person, steps)

  defp also({:invitation, code}, steps, person) do
    with {:ok, invitation} <- Sanctum.Invitations.redeem(code, person.id),
         :ok <- local(person, steps),
         do: seated(invitation, person)
  end

  defp also({:remote, remote}, _write, %{id: user_id}) do
    case Arca.PersonIdentities.create(Prima.Actor.system(), %{
           user_id: user_id,
           provenance: "remote",
           identifier: remote.identifier,
           directory_url: remote.directory_url,
           genesis_hash: remote[:genesis_hash],
           head_hash: remote[:head_hash]
         }) do
      {:ok, _row} -> invited(remote, user_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp also({:restore, %{also: restored}}, _write, person) do
    with :ok <- restored.(person), do: athanor(person)
  end

  # The invitation a remote person's sign-in carried: redeemed, their seat
  # and their identifier's allow, in the mint's transaction.
  defp invited(%{invitation: invitation, identifier: identifier}, user_id)
       when is_binary(invitation),
       do:
         Sanctum.Invitations.redeem_hash(invitation, %{
           user_id: user_id,
           identifier: identifier,
           label: nil
         })

  defp invited(_remote, _user_id), do: :ok

  # The person's keys, athanor and passkey, then their enrollment, last.
  defp local(person, {write, enroll}) do
    with :ok <- Sanctum.Person.mint_keys(person),
         :ok <- athanor(person),
         :ok <- write.(person),
         do: enroll.(person)
  end

  defp athanor(person) do
    case Sanctum.Provisioning.mint_personal(person) do
      {:ok, _athanor} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The seat the invitation names, under the group's lock: its issuer
  # still seated there, read again under that lock, and the group's member
  # cap counted as an add counts it.
  defp seated(%{athanor_id: nil}, _person), do: :ok

  defp seated(%{athanor_id: athanor_id, issued_by: issuer} = invitation, %{id: user_id}) do
    case Members.create(
           %{user_id: user_id, scope: "athanor", athanor_id: athanor_id, added_by: issuer},
           reserve: fn ->
             with :ok <- Sanctum.Invitations.issuer_seated(invitation),
                  do: Members.member_cap(athanor_id)
           end
         ) do
      {:ok, _seat} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The credential written in the transaction: a passkey. A session needs
  # the committed person, so it follows the commit.
  defp written(%{id: user_id}, {:passkey, _registration, _identity}, verified),
    do: Sanctum.Passkeys.write_newcomer(user_id, verified)

  defp written(_person, _credential, _verified), do: :ok

  defp enrolled(%{id: user_id}, {_kind, _proof, identity}, directory),
    do: Sanctum.Recovery.open_at_admission(user_id, identity, directory)

  # ---- after the commit -----------------------------------------------------

  defp committed({:remote, remote}, person, readmitted, :none) do
    if is_binary(remote[:invitation]),
      do: Sanctum.Invitations.announce(remote.invitation, person.id)

    case Members.activate_invited(person) do
      {:ok, _n} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Sanctum.Newcomer] activate_invited failed for #{person.id}: #{inspect(reason)}"
        )
    end

    answered(person, readmitted)
  end

  defp committed(admission, person, readmitted, credential) do
    granted(admission, person, readmitted)
    joined(admission, person)
    filled(admission, person)

    with {:ok, admitted} <- answered(person, readmitted),
         {:ok, admitted} <- recovery(admission, admitted, person) do
      case session(person, credential) do
        {:ok, token} -> {:ok, Map.put(admitted, :session_token, token)}
        :none -> {:ok, admitted}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The widest grant in the system, written once: audited when it is.
  defp granted({first, _}, %{id: user_id}, false = _readmitted)
       when first in [:setup, :restore] do
    :telemetry.execute([:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap], %{count: 1}, %{
      user_id: user_id,
      admission: Atom.to_string(first)
    })
  end

  defp granted(_admission, _person, _readmitted), do: :ok

  # The group an invitation seated the person in is told of its new member.
  defp joined({:invitation, code}, %{id: user_id}) do
    case Sanctum.Invitations.seat(code) do
      {:ok, athanor_id} ->
        Members.broadcast_change(user_id, athanor_id, :joined)
        Sanctum.Notify.member_changed(athanor_id)

      :none ->
        :ok
    end
  end

  defp joined(_admission, _person), do: :ok

  # A restore may be superseded after its commit: `Sanctum.Recovery` asks
  # for its fill once the head still names the restored keys.
  defp filled({:restore, _restore}, _person), do: :ok
  defp filled(_admission, person), do: Sanctum.Provisioning.after_sign_in(person.id)

  defp answered(person, readmitted) do
    case Users.get(person.id) do
      {:ok, user} -> {:ok, %{person: user, readmitted: readmitted}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # A local person's enrollment: the one the admission opened, or the one a
  # re-admission finds standing. A restored person's identity is the
  # restore's, which opens no enrollment.
  defp recovery({:restore, _restore}, admitted, _person), do: {:ok, admitted}

  defp recovery(_local, admitted, %{id: user_id}) do
    case Sanctum.Recovery.admission_recovery(user_id) do
      {:ok, nil} -> {:ok, admitted}
      {:ok, recovery} -> {:ok, Map.put(admitted, :recovery, recovery)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp session(person, {:passkey, _registration, _identity}), do: minted(person, "passkey", [])

  defp session(person, {:command_line, machine, _identity}),
    do: minted(person, "setup", command_line: machine)

  defp session(_person, :none), do: :none

  defp minted(person, provider, opts) do
    ctx =
      Context.build(
        user_id: person.id,
        email: person[:email],
        provider: provider,
        athanor_id: nil,
        permissions: Context.person_permissions()
      )

    with {:ok, ctx} <- Sanctum.Tenancy.resolve_status(ctx, force: true),
         {:ok, session} <- Sanctum.Session.create(ctx, opts) do
      {:ok, session.token}
    else
      {:error, reason} ->
        Logger.warning(
          "[Sanctum.Newcomer] #{person.id} was admitted and no session minted: " <>
            Prima.LoggerContext.shape(reason)
        )

        {:error, :unavailable}
    end
  end
end
