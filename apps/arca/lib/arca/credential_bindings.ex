# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CredentialBindings do
  @moduledoc """
  The rows a derived credential is held to, read under lock.

  A tincture access or asset token is a narrowed derivative of one stored
  session or API key: it names the person, the athanor, the membership
  that authorized the focus and the credential it was minted from, with
  the standing generations read when it was minted. Whether it still
  opens anything is decided on those rows as they are now. `check/3`
  locks and rereads them in the order every standing transition takes
  (`Arca.SecurityTransitions`) — the person, the athanor, the membership,
  then the session or the key — reads the database's own time after every
  lock was won, and hands the caller's policy plain maps of what it found
  (nil where there is no row). Nothing is written.

  A paired device is held to its rows the same way while a sensitive
  change it asked for is written: its binding names its paired client and
  the expiry of the certificate it stands under, and the check locks the
  client and then that client's certificates expiring then, after the
  membership, and reads the person's identity row and cached head under
  the person's lock (`Arca.SecurityTransitions.Issuance`).

  A denial, an archive or a revocation that commits first is what the
  check reads; one that starts while the check holds the rows waits for
  it. Run inside a caller's transaction, the check takes its locks in
  that transaction, so they hold until the caller commits, and its
  refusal rolls the caller's transaction back. The identity domain is
  the one caller: it owns the policy, and a surface is handed only the
  narrowed context or a refusal.
  """

  alias Arca.SecurityTransitions.Issuance

  @typedoc """
  The rows a credential names: the person, the athanor it works in, the
  membership its focus rests on (nil for a key, whose focus is itself)
  and the source credential, `{:session, token_hash}`, `{:api_key, id}`
  or a paired device's `{:device, client_id, expires_at}`.
  """
  @type binding :: %{
          required(:user_id) => String.t(),
          required(:athanor_id) => String.t(),
          required(:membership_id) => String.t() | nil,
          required(:source) =>
            {:session, binary()} | {:api_key, String.t()} | {:device, String.t(), DateTime.t()}
        }

  @doc """
  Lock and reread `binding`'s rows and ask `verify:` over them.

  `verify` answers `:ok`, `{:ok, value}` or `{:error, reason}`; the check
  answers the same. A store that cannot answer is
  `{:error, :database_error}` — never a verdict either way.
  """
  @spec check(Prima.Actor.t(), binding(), keyword()) ::
          :ok | {:ok, term()} | {:error, term()}
  def check(%Prima.Actor{scope: :platform, system: true}, %{user_id: user_id} = binding, opts)
      when is_binary(user_id) and is_list(opts) do
    verify = Keyword.fetch!(opts, :verify)

    Arca.Repo.Errors.with_db_rescue("Arca.CredentialBindings.check", fn ->
      fn ->
        case verify.(Issuance.locked(binding)) do
          :ok -> :ok
          {:ok, value} -> {:ok, value}
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end
      |> Arca.Repo.locking_transaction()
      |> case do
        {:ok, :ok} -> :ok
        {:ok, {:ok, value}} -> {:ok, value}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Arca.Data.project()
  end

  def check(%Prima.Actor{}, _binding, _opts), do: {:error, :cross_tenant}
end
