# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.InstallationClaims do
  @moduledoc """
  Who may mint this installation's first person: the installed mode, and
  the claim a restore makes of an empty node
  (`Arca.Schemas.InstallationClaim`).

  ## The installed mode

  The boot installs `:ordinary` or `:restore_reserved` as plain data
  (`install_mode!/1`), the mechanism the settings roster's defaults use: a
  value this layer reads, never a call it makes. `mode/0` answers it and
  raises `Arca.InstallationClaims.NotInstalledError` when nothing is
  installed, as an uninstalled port does, so a node whose boot installed
  no mode refuses a first-person mint instead of defaulting open.

  ## The claim

  Only an actual restore claim writes a row. A claim is made only by
  opening its restore attempt (`Arca.IdentityAttempts.open/3`), in that
  attempt's transaction (`claim!/1`), so no claim exists without its
  attempt and an open that fails claims nothing. It binds the
  installation token's digest, the request id and the identifier being
  restored, atomically with the empty-node condition: a node that holds a
  person is refused. At most one claim is pending, and it refuses every
  other request (`:claimed`). Every token digest ever claimed keeps its
  row, so a token is spent for good (`:token_spent`), even after its
  attempt ended and another token claimed in between. The attempt's end
  ends its claim (`end!/2`), whatever the outcome, and a node still empty
  may then be claimed again with a new token.

  ## The guard

  `guard!/1` is the check every person mint runs inside its own
  transaction (`Arca.Users.mint/4`). An ordinary mint is refused
  `:restore_reserved` while a claim is pending, whatever the mode, and on
  a node with no person while the mode is `:restore_reserved`. A restore's
  mint names its claim, and is admitted only while that claim is pending,
  exactly as bound, on a node with no person.

  ## One order

  A claim and every person mint serialize on one row: the schema
  fingerprint's in `server_meta`, which every database this release
  accepts holds (`Arca.SchemaFingerprint`). On PostgreSQL it is locked
  (`Arca.QueryHelpers.for_update/1`), since the claim and a mint each read
  what the other writes and no row of either exists to lock before them;
  on SQLite the locking transaction's write lock is the order. A database
  without the row raises rather than deciding unordered.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{InstallationClaim, ServerMeta, User}

  defmodule NotInstalledError do
    @moduledoc """
    Raised by `Arca.InstallationClaims.mode/0` when no boot installed the
    installation mode.
    """

    defexception message:
                   "Arca.InstallationClaims has no installed mode, since nothing called " <>
                     "Arca.InstallationClaims.install_mode!/1, so no first person may be minted."
  end

  @mode_key {__MODULE__, :mode}
  @modes [:ordinary, :restore_reserved]

  @typedoc "The installation mode the boot installs."
  @type mode :: :ordinary | :restore_reserved

  @typedoc "What a restore names its claim by."
  @type claim_ref :: %{required(:request_id) => String.t(), required(:token_digest) => String.t()}

  @doc "Install the mode, replacing any earlier value."
  @spec install_mode!(mode()) :: :ok
  def install_mode!(mode) when mode in @modes do
    :persistent_term.put(@mode_key, mode)
    :ok
  end

  @doc "The installed mode; raises `NotInstalledError` when none is installed."
  @spec mode() :: mode()
  def mode do
    case :persistent_term.get(@mode_key, nil) do
      nil -> raise NotInstalledError
      mode -> mode
    end
  end

  @doc "Whether a mode is installed."
  @spec installed?() :: boolean()
  def installed?, do: :persistent_term.get(@mode_key, nil) != nil

  @doc """
  Erase the installed mode, leaving the node as a boot that installed none.
  The inverse of `install_mode!/1`, for a test that installs its own.
  """
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@mode_key)
    :ok
  end

  @doc """
  The installation claim that stands: the pending one, or else the one
  made last. `{:error, :not_found}` when none was ever made.
  """
  @spec get(Prima.Actor.t()) ::
          {:ok, map()} | {:error, :not_found | :cross_tenant | :database_error}
  def get(%Prima.Actor{scope: :platform}) do
    Arca.Repo.Errors.with_db_rescue("Arca.InstallationClaims.get", fn ->
      last =
        from(c in InstallationClaim, order_by: [desc: c.claimed_at, desc: c.id], limit: 1)

      case pending() || Arca.Repo.one(last) do
        nil -> {:error, :not_found}
        claim -> {:ok, claim}
      end
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}), do: {:error, :cross_tenant}

  @doc false
  @spec guard!(claim_ref() | nil) :: :ok | {:error, :restore_reserved | :not_claimed | :not_empty}
  # The first-person guard, inside the caller's locking transaction
  # (`Arca.Users.mint/4`): `nil` for an ordinary mint, or the claim a
  # restore's mint names. Answers `:ok` or the refusal the caller rolls
  # back with. Reads the installed mode, which raises when none is.
  # arca:db-raise-ok a transaction step: the mint that runs it rescues around its transaction.
  def guard!(claim) do
    mode = mode()
    lock_order!()

    case claim do
      nil ->
        cond do
          pending() != nil -> {:error, :restore_reserved}
          mode == :restore_reserved and empty?() -> {:error, :restore_reserved}
          true -> :ok
        end

      %{request_id: request_id, token_digest: token_digest} ->
        cond do
          not bound?(pending(), request_id, token_digest) -> {:error, :not_claimed}
          not empty?() -> {:error, :not_empty}
          true -> :ok
        end

      _malformed ->
        {:error, :not_claimed}
    end
  end

  @doc false
  @spec claim!(%{
          required(:token_digest) => String.t(),
          required(:request_id) => String.t(),
          required(:identifier) => String.t()
        }) :: {:ok, InstallationClaim.t()} | {:error, :claimed | :token_spent | :not_empty}
  # Claim this empty node for the restore attempt being opened in the
  # caller's transaction (`Arca.IdentityAttempts.open/3`), which writes the
  # attempt next, so the claim and its attempt commit or roll back
  # together. The pending claim of this exact request and token answers
  # itself; any other pending claim is `:claimed`; a token digest claimed
  # before, whatever claimed after it, is `:token_spent`; a node holding a
  # person is `:not_empty`.
  # arca:db-raise-ok a transaction step: its caller rescues around the transaction.
  def claim!(%{token_digest: token, request_id: request, identifier: identifier}) do
    lock_order!()

    case pending() do
      %InstallationClaim{} = held ->
        if bound?(held, request, token), do: {:ok, held}, else: {:error, :claimed}

      nil ->
        cond do
          Arca.Repo.exists?(from(c in InstallationClaim, where: c.token_digest == ^token)) ->
            {:error, :token_spent}

          not empty?() ->
            {:error, :not_empty}

          true ->
            write_claim(token, request, identifier)
        end
    end
  end

  @doc false
  @spec end!(String.t(), String.t()) :: non_neg_integer()
  # End the pending claim bound to `request_id`, recording `outcome`, inside
  # the caller's transaction: the attempt it bound has ended
  # (`Arca.IdentityAttempts`). Answers how many claims it ended.
  # arca:db-raise-ok a transaction step: its caller rescues around the transaction.
  def end!(request_id, outcome) when is_binary(request_id) and is_binary(outcome) do
    now = Arca.ServerMetaStorage.now!()

    {count, _} =
      from(c in InstallationClaim, where: c.request_id == ^request_id and c.state == "pending")
      |> Arca.Repo.update_all(
        set: [state: "ended", outcome: outcome, ended_at: now, updated_at: now]
      )

    count
  end

  # ---- internals -------------------------------------------------------------

  defp empty?, do: not Arca.Repo.exists?(from(u in User))

  # The claim's own row. The indexes (one pending claim, one row per token
  # digest) back what the order row already serializes.
  defp write_claim(token, request, identifier) do
    now = Arca.ServerMetaStorage.now!()

    row = %{
      id: Prima.UUID7.generate_id("icl"),
      token_digest: token,
      request_id: request,
      identifier: identifier,
      state: "pending",
      claimed_at: now,
      inserted_at: now,
      updated_at: now
    }

    case Arca.Repo.insert_all(InstallationClaim, [row], on_conflict: :nothing) do
      {1, _} -> {:ok, Arca.Repo.get!(InstallationClaim, row.id)}
      {0, _} -> {:error, :claimed}
    end
  end

  defp pending do
    Arca.Repo.one(from(c in InstallationClaim, where: c.state == "pending"))
  end

  defp bound?(%InstallationClaim{request_id: request, token_digest: token}, request, token),
    do: true

  defp bound?(_claim, _request_id, _token_digest), do: false

  # The one row every first-person decision serializes on (the module doc).
  # Every database this release accepts holds it; one without it has lost
  # the order, and deciding without the order is never safe.
  defp lock_order! do
    from(m in ServerMeta, where: m.key == ^Arca.SchemaFingerprint.key(), select: m.key)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> case do
      nil ->
        raise "Arca.InstallationClaims found no schema fingerprint row to order " <>
                "first-person decisions on; recreate the database (Arca.SchemaFingerprint)."

      _key ->
        :ok
    end
  end
end
