# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Newcomer do
  @moduledoc """
  The one path that makes a person here (`admit/2`): an account this CYFR
  admits by its identifier (`ARCHITECTURE.md` §9.1). The person is the
  CYFR's own fact, a `users` row, the account's identity row (its
  identifier, its directory and the head this CYFR read, never a key) and
  an athanor; nothing is written at the directory. The caller verified a
  signature by a key of the account against that head first: a browser's
  answer to a sign-in request (`Sanctum.SignIn`) or a device's `hello`.

  | Admission | Checked | Makes |
  |---|---|---|
  | `{:setup, token}` | the token equals the configured setup token (constant-time); in the mint's transaction, under the installation claims' order row, no person exists and no restore holds the installation | the person, their athanor, the platform administrator's mark, and their identifier's allow |
  | `{:invitation, hash}` | the invitation the code hash names (`Sanctum.Invitations.code_hash/1`) is redeemable, before the transaction and again inside it, no deny names the identifier, then the mint rate and the athanor cap | the person, their athanor, the invitation redeemed, the seat it names and their identifier's allow (`Sanctum.Invitations.redeem_hash/2`) |
  | `:open` | the door admits the identifier (`Sanctum.Door.sign_in_identifier/1`: `*` or an allow naming it, and no deny), then the mint rate and the athanor cap in the mint's transaction | the person and their athanor |
  | `{:restore, restore}` | the restore's installation claim, in the mint's transaction (`Arca.InstallationClaims`) | the restored person, their athanor, the platform administrator's mark |

  The installation's first person is its platform administrator: the mint
  that writes them writes the mark on their row (`users.platform_admin_at`),
  under the order row and the member slot (`Arca.Users.mint/4`), and no
  other path writes it; the mark is audited once it commits (`[:cyfr,
  :sanctum, :tenancy, :platform_admin_bootstrap]`). Only setup and a
  restore make the first person; any other admission onto an empty
  installation is refused `:not_set_up`.

  ## The setup token

  The setup token binds the installation to the first account and then
  opens nothing: once any person exists here it is `:setup_closed`,
  whoever presents it. Setup writes the first account's identifier as an
  allow, as an invitation's redemption does, so the door admits them at
  every later sign-in. A token that is not the configured one, a missing
  one, or a CYFR with none configured, opens nothing either.

  ## The invitation

  The invitation is the admitting act, so the door's allow rule is not
  asked, but a deny of the identifier still wins: the redemption writes
  the identifier's allow only where no deny stands, and reads the deny
  again before the commit, so a deny committed meanwhile rolls the whole
  admission back, makes no person and leaves the invitation unspent.
  Every refusal of the invitation itself is `:invitation_invalid`. Its
  athanor caps are the open admission's. The seat's announcement follows
  the commit.

  ## One transaction

  The person's row, their identity row, their athanor
  (`Sanctum.Provisioning.mint_personal/1`) and what the admission writes
  commit together or not at all: a process killed mid-admission and a
  member whose slot was lost leave no row. The caps are counted in the
  same transaction before the person's row
  (`Sanctum.Provisioning.personal_admissible/0`), so one refused at a cap
  writes none. An identifier another admission made a person of first is
  `:conflict`. The athanor's fill, the identifier's pending shared-thread
  invitations and the invitation's announcement follow the commit; a
  restore's fill is asked for by `Sanctum.Recovery`.

  Refusals: `:setup_closed`, `:not_set_up`, `:restore_reserved`,
  `:invitation_invalid`, `{:door, reason}`, `:conflict`, a cap's
  `{:limit_reached, key, cap}` or `{:cap_unverifiable, key}`, the invited
  seat's own refusals, `:not_owner` (this member no longer holds its
  slot), `:unavailable`, `{:invalid_argument, sentence}` for an admission
  or account that does not read, and the restore's own refusals.
  """

  require Logger

  alias Prima.Identity.Encoding
  alias Sanctum.Tenancy.Users

  @typedoc """
  The account a person is made for: its identifier, the directory its
  genesis names and the head this CYFR verified the caller's signature
  under.
  """
  @type account :: %{
          required(:identifier) => String.t(),
          required(:directory_url) => String.t(),
          required(:head_hash) => String.t()
        }

  @typedoc """
  A restore's mint (`Sanctum.Recovery`): the installation claim it names,
  and its closure, run in the mint's transaction, writing the restored
  identity row and advancing the restore attempt.
  """
  @type restore :: %{
          required(:claim) => Arca.InstallationClaims.claim_ref(),
          required(:also) => (map() -> :ok | {:error, term()})
        }

  @typedoc """
  What admits a new person: the setup token, an invitation's code hash,
  the door's verdict on the identifier, or a restore.
  """
  @type admission ::
          {:setup, String.t()} | {:invitation, String.t()} | :open | {:restore, restore()}

  @typedoc "The admitted person."
  @type admitted :: %{required(:person) => Users.user()}

  @doc """
  Make a person for `account` under `admission` (the module doc). A
  restore names no account (`:none`).
  """
  @spec admit(admission(), account() | :none) :: {:ok, admitted()} | {:error, term()}
  def admit(admission, account) do
    with :ok <- taken(admission, account),
         :ok <- admissible(admission, account),
         {:ok, person} <- mint(admission, account) do
      committed(admission, person)
    end
  end

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
  Whether `token` opens setup now: it is the configured setup token and
  this CYFR holds no person yet (`Arca.InstallationClaims.setup/1`). The
  setup page asks before it sends the browser to the account pages, so a
  link that is not valid, or a CYFR set up already, starts nothing; the
  admission decides again in its transaction. One refusal for both, as
  the admission answers, so a guesser learns nothing from it.
  """
  @spec setup_open(term()) :: :ok | {:error, :setup_closed | :unavailable}
  def setup_open(token) when is_binary(token) do
    with :ok <- admissible({:setup, token}, :none) do
      case Arca.InstallationClaims.setup(Prima.Actor.system()) do
        {:ok, :first} -> :ok
        {:ok, :closed} -> {:error, :setup_closed}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  def setup_open(_token), do: {:error, :setup_closed}

  @doc """
  Whether `token` is the configured setup token, compared in constant
  time, whether or not setup is still open.
  """
  @spec setup_token?(term()) :: boolean()
  def setup_token?(token) when is_binary(token), do: admissible({:setup, token}, :none) == :ok
  def setup_token?(_token), do: false

  # ---- before the transaction ----------------------------------------------

  defp taken({:setup, token}, account) when is_binary(token), do: account(account)
  defp taken({:setup, _token}, _account), do: {:error, :setup_closed}
  defp taken({:invitation, hash}, account) when is_binary(hash), do: account(account)
  defp taken({:invitation, _hash}, _account), do: {:error, :invitation_invalid}
  defp taken(:open, account), do: account(account)

  defp taken({:restore, %{claim: %{}, also: also}}, :none) when is_function(also, 1), do: :ok

  defp taken(_admission, _account),
    do:
      {:error,
       {:invalid_argument,
        "A new person comes in by setup, an invitation, the open door or a restore"}}

  defp account(%{identifier: identifier, directory_url: directory, head_hash: head}) do
    if Encoding.identifier?(identifier) and Encoding.directory_url?(directory) and
         Encoding.digest?(head),
       do: :ok,
       else: {:error, {:invalid_argument, "An account is its identifier, directory and head"}}
  end

  defp account(_account),
    do: {:error, {:invalid_argument, "An account is its identifier, directory and head"}}

  defp admissible({:setup, token}, _account) do
    case Application.get_env(:sanctum, :setup_token) do
      configured when is_binary(configured) and byte_size(configured) == byte_size(token) ->
        if Plug.Crypto.secure_compare(configured, token), do: :ok, else: {:error, :setup_closed}

      _none_or_other ->
        {:error, :setup_closed}
    end
  end

  # A deny outranks the invitation, as it outranks every allow; the
  # invitation that admits no one starts nothing.
  defp admissible({:invitation, hash}, %{identifier: identifier}) do
    case Sanctum.Door.Store.denied(nil, identifier) do
      {:ok, false} -> Sanctum.Invitations.redeemable_hash(hash)
      {:ok, true} -> {:error, {:door, :denied}}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp admissible(:open, %{identifier: identifier}) do
    with {:ok, :allowed} <- Sanctum.Door.sign_in_identifier(identifier), do: :ok
  end

  defp admissible({:restore, _restore}, _account), do: :ok

  # ---- the transaction ------------------------------------------------------

  defp mint(admission, account) do
    now = DateTime.utc_now()

    user_attrs = %{
      id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
      prefs: Jason.encode!(%{}),
      first_seen_at: now,
      last_seen_at: now,
      created_at: now,
      updated_at: now
    }

    Arca.Users.mint(
      Prima.Actor.system(),
      user_attrs,
      nil,
      [admission: kind(admission), also: &also(admission, account, &1)] ++
        verify(admission) ++ restore_claim(admission)
    )
    |> case do
      {:ok, person} -> {:ok, person}
      {:error, :database_error} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp kind({:setup, _token}), do: "setup"
  defp kind({:invitation, _hash}), do: "invitation"
  defp kind(:open), do: "open"
  defp kind({:restore, _restore}), do: "restore"

  # Inside the mint's transaction, before the person's row: the caps, and
  # an invitation's own check before them. The installation's first
  # person is minted past them.
  defp verify(:open), do: [verify: &Sanctum.Provisioning.personal_admissible/0]

  defp verify({:invitation, hash}),
    do: [
      verify: fn ->
        with :ok <- Sanctum.Invitations.redeemable_hash(hash),
             do: Sanctum.Provisioning.personal_admissible()
      end
    ]

  defp verify(_admission), do: []

  defp restore_claim({:restore, %{claim: claim}}), do: [restore: claim]
  defp restore_claim(_admission), do: []

  # Inside the mint's transaction, after the person's row and the first
  # person's grant: the account's identity row and the athanor, then what
  # the admission writes.
  defp also({:restore, %{also: restored}}, :none, person) do
    with :ok <- restored.(person), do: athanor(person)
  end

  defp also(admission, account, %{id: user_id} = person) do
    case Arca.PersonIdentities.create(Prima.Actor.system(), %{
           user_id: user_id,
           provenance: "remote",
           identifier: account.identifier,
           directory_url: account.directory_url,
           head_hash: account.head_hash
         }) do
      {:ok, _row} -> with :ok <- athanor(person), do: admitted(admission, account, user_id)
      {:error, reason} -> {:error, reason}
    end
  end

  # Setup's account and an invitation's are allowed by identifier from
  # here on, where no deny stands; the open door admits by the entry that
  # already admitted them.
  defp admitted({:setup, _token}, %{identifier: identifier}, user_id) do
    case Sanctum.Door.Store.allow_unless_denied("identifier", identifier, user_id, note: "setup") do
      {:ok, _entry} -> :ok
      {:error, :denied} -> {:error, {:door, :denied}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp admitted({:invitation, hash}, %{identifier: identifier}, user_id),
    do:
      Sanctum.Invitations.redeem_hash(hash, %{
        user_id: user_id,
        identifier: identifier,
        label: nil
      })

  defp admitted(:open, _account, _user_id), do: :ok

  defp athanor(person) do
    case Sanctum.Provisioning.mint_personal(person) do
      {:ok, _athanor} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---- after the commit -----------------------------------------------------

  defp committed(admission, person) do
    granted(admission, person)
    announced(admission, person)
    filled(admission, person)

    case Users.get(person.id) do
      {:ok, user} -> {:ok, %{person: user}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The widest grant in the system, written once: audited when it is.
  defp granted({first, _}, %{id: user_id}) when first in [:setup, :restore] do
    :telemetry.execute([:cyfr, :sanctum, :tenancy, :platform_admin_bootstrap], %{count: 1}, %{
      user_id: user_id,
      admission: Atom.to_string(first)
    })
  end

  defp granted(_admission, _person), do: :ok

  # The thread an invitation seated the person in is told of its new
  # member, and the shared-thread seats their identifier was invited to
  # activate.
  defp announced({:restore, _restore}, _person), do: :ok

  defp announced(admission, person) do
    seated(admission, person)

    case Sanctum.SharedThreads.activate_invited(person) do
      {:ok, _n} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Sanctum.Newcomer] an invitation's activation failed for #{person.id}: " <>
            Prima.LoggerContext.shape(reason)
        )
    end
  end

  defp seated({:invitation, hash}, person), do: Sanctum.Invitations.announce(hash, person.id)
  defp seated(_admission, _person), do: :ok

  # A restore may be superseded after its commit: `Sanctum.Recovery` asks
  # for its fill once the head still names the restored keys.
  defp filled({:restore, _restore}, _person), do: :ok
  defp filled(_admission, person), do: Sanctum.Provisioning.after_sign_in(person.id)
end
