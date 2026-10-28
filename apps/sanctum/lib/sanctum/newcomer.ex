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
  | `:open` | the door's `*` admits; the mint rate and the athanor cap, in the mint's transaction before the person's row | a local person, their keys, their athanor |
  | `{:remote, remote}` | the door admits the identifier (`Sanctum.Door.sign_in_identifier/1`); the head the CYFR sign-in verified is still fresh | a remote person row with no keys and no athanor; pending identifier invitations activate |
  | `{:restore, restore}` | the restore's installation claim, in the mint's transaction (`Arca.InstallationClaims`) | the restored person, their athanor, the platform grant |

  The installation's first person is its platform administrator: the mint
  that writes them writes the grant, under the order row and the member
  slot (`Arca.Users.mint/4`), and no other path grants it; the grant is
  audited once it commits (`[:cyfr, :sanctum, :tenancy,
  :platform_admin_bootstrap]`). Only setup and a restore make the first
  person; any other admission onto an empty installation is refused
  `:not_set_up`.

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

  A local admission brings its credential:

    * `{:passkey, registration}` — the browser's answer to
      `Sanctum.Passkeys.newcomer_options/0`, verified with no transaction
      open (`Sanctum.Passkeys.verify_newcomer/1`) and written, active,
      inside the admission's transaction (`Sanctum.Passkeys.write_newcomer/2`),
      so a failed admission leaves neither a person nor a passkey. The
      person's id is the one the registration was drawn for. A session
      with provider `passkey` follows the commit.
    * `{:command_line, machine}`, for setup alone — a command-line session
      for `machine` (`Sanctum.CliSignIn.machine/1`), provider `setup`,
      minted after the commit.

  A remote person and a restored person bring none: the CYFR sign-in and
  the restore mint their own sessions. A session that cannot be minted
  after the commit leaves the person, whom setup answers again while they
  hold no credential.

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
  `{:door, reason}`, `:identity_stale`, `:registration_refused`, a cap's
  `{:limit_reached, key, cap}` or `{:cap_unverifiable, key}`, `:not_owner`
  (this member no longer holds its slot), `:unavailable`,
  `{:invalid_argument, sentence}` for a credential the admission does not
  take, and the restore's own refusals.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Members, Users}

  @typedoc "What the CYFR sign-in verified of a remote person."
  @type remote :: %{
          required(:identifier) => String.t(),
          required(:directory_url) => String.t(),
          required(:genesis_hash) => String.t(),
          required(:head_hash) => String.t()
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

  @type admission :: {:setup, String.t()} | :open | {:remote, remote()} | {:restore, restore()}
  @type credential :: {:passkey, map()} | {:command_line, String.t()} | :none

  @typedoc """
  The admitted person, whether setup answered them again, and the session
  token a local admission's credential minted, when it minted one.
  """
  @type admitted :: %{
          required(:person) => Users.user(),
          required(:readmitted) => boolean(),
          optional(:session_token) => String.t()
        }

  @doc "Make a person by `admission`, with `credential` (the module doc)."
  @spec admit(admission(), credential()) :: {:ok, admitted()} | {:error, term()}
  def admit(admission, credential) do
    with {:ok, credential} <- taken(admission, credential),
         :ok <- admissible(admission),
         {:ok, person_id, verified} <- verified(credential),
         {:ok, person} <- mint(admission, person_id, credential, verified) do
      readmitted = person.id != person_id
      committed(admission, person, readmitted, credential)
    end
  end

  # ---- before the transaction ----------------------------------------------

  # A missing token is refused as a wrong one is.
  defp taken({:setup, token}, _credential) when not is_binary(token),
    do: {:error, :setup_closed}

  defp taken({:setup, token}, {:passkey, registration} = credential)
       when is_binary(token) and is_map(registration),
       do: {:ok, credential}

  defp taken({:setup, token}, {:command_line, machine}) when is_binary(token) do
    with {:ok, machine} <- Sanctum.CliSignIn.machine(machine), do: {:ok, {:command_line, machine}}
  end

  defp taken(:open, {:passkey, registration} = credential) when is_map(registration),
    do: {:ok, credential}

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
          "line, an open admission a passkey"}}

  defp admissible({:setup, token}) do
    case Application.get_env(:sanctum, :setup_token) do
      configured when is_binary(configured) and byte_size(configured) == byte_size(token) ->
        if Plug.Crypto.secure_compare(configured, token), do: :ok, else: {:error, :setup_closed}

      _none_or_other ->
        {:error, :setup_closed}
    end
  end

  # An open admission needs the door's `*`. It names no identifier, so a
  # refusal leaves no request.
  defp admissible(:open) do
    case Sanctum.Door.Store.wildcard() do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, {:door, :not_allowed}}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  # The head the CYFR sign-in verified, still fresh: an identity whose
  # directory cannot be read writes no row.
  defp admissible({:remote, %{identifier: identifier}}) do
    with {:ok, :allowed} <- Sanctum.Door.sign_in_identifier(identifier) do
      case Sanctum.IdentityFreshness.fresh?(identifier) do
        {:ok, _head} -> :ok
        {:refused, :identity_stale} -> {:error, :identity_stale}
        {:error, :unavailable} -> {:error, :unavailable}
      end
    end
  end

  defp admissible({:restore, _restore}), do: :ok

  # The person's id: the one a passkey registration was drawn for, or a
  # new one.
  defp verified({:passkey, registration}) do
    with {:ok, %{user_id: user_id, verified: verified}} <-
           Sanctum.Passkeys.verify_newcomer(registration),
         do: {:ok, user_id, verified}
  end

  defp verified(_credential),
    do: {:ok, Prima.UUID7.generate_id(Prima.PersonId.prefix()), nil}

  # ---- the transaction ------------------------------------------------------

  defp mint(admission, person_id, credential, verified) do
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

    Arca.Users.mint(
      Prima.Actor.system(),
      user_attrs,
      identity(admission, now),
      [admission: kind(admission), also: &also(admission, write, &1)] ++
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
  # method: only the credential this admission brings is written.
  defp readmit(user_id, write) do
    case Arca.Users.readmit(Prima.Actor.system(), user_id, also: write) do
      {:ok, person} -> {:ok, person}
      {:error, :database_error} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  # A passkey registration names the person it was drawn for: a person of
  # that id already made means the registration was presented before.
  defp refused({:passkey, _registration}, :conflict), do: {:error, :registration_refused}
  defp refused(_credential, reason), do: {:error, reason}

  defp kind({:setup, _token}), do: "setup"
  defp kind(:open), do: "open"
  defp kind({:remote, _remote}), do: "remote"
  defp kind({:restore, _restore}), do: "restore"

  # Inside the mint's transaction, before the person's row: an open
  # admission's caps. The installation's first person is minted past them.
  defp verify(:open), do: [verify: &Sanctum.Provisioning.personal_admissible/0]
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
  defp also({:setup, _token}, write, person), do: local(person, write)
  defp also(:open, write, person), do: local(person, write)

  defp also({:remote, remote}, _write, %{id: user_id}) do
    case Arca.PersonIdentities.create(Prima.Actor.system(), %{
           user_id: user_id,
           provenance: "remote",
           identifier: remote.identifier,
           directory_url: remote.directory_url,
           genesis_hash: remote[:genesis_hash],
           head_hash: remote[:head_hash]
         }) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp also({:restore, %{also: restored}}, _write, person) do
    with :ok <- restored.(person), do: athanor(person)
  end

  defp local(person, write) do
    with :ok <- Sanctum.Person.mint_keys(person),
         :ok <- athanor(person),
         do: write.(person)
  end

  defp athanor(person) do
    case Sanctum.Provisioning.mint_personal(person) do
      {:ok, _athanor} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The credential written in the transaction: a passkey. A session needs
  # the committed person, so it follows the commit.
  defp written(%{id: user_id}, {:passkey, _registration}, verified),
    do: Sanctum.Passkeys.write_newcomer(user_id, verified)

  defp written(_person, _credential, _verified), do: :ok

  # ---- after the commit -----------------------------------------------------

  defp committed({:remote, _remote}, person, readmitted, :none) do
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
    filled(admission, person)

    with {:ok, admitted} <- answered(person, readmitted) do
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

  defp session(person, {:passkey, _registration}), do: minted(person, "passkey", [])

  defp session(person, {:command_line, machine}),
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
