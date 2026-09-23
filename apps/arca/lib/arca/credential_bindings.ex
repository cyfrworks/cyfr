# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CredentialBindings do
  @moduledoc """
  The rows a derived credential is held to, read under lock.

  A tincture access or asset token is a narrowed derivative of one stored
  session or API key: it names the person, the estate, the membership
  that authorized the focus and the credential it was minted from, with
  the standing generations read when it was minted. Whether it still
  opens anything is decided on those rows as they are now. `check/3`
  locks and rereads them in the order every standing transition takes
  (`Arca.SecurityTransitions`) — the person, the estate, the membership,
  then the session or the key — reads the database's own time after every
  lock was won, and hands the caller's policy plain maps of what it found
  (nil where there is no row). Nothing is written.

  A denial, an archive or a revocation that commits first is what the
  check reads; one that starts while the check holds the rows waits for
  it. The identity domain is the one caller: it owns the policy, and a
  surface is handed only the narrowed context or a refusal.
  """

  alias Arca.SecurityTransitions.Issuance

  @typedoc """
  The rows a derived credential names: the person, the estate it works
  in, the membership its focus rests on (nil for a key, whose focus is
  itself) and the source credential, `{:session, token_hash}` or
  `{:api_key, id}`.
  """
  @type binding :: %{
          required(:user_id) => String.t(),
          required(:athanor_id) => String.t(),
          required(:membership_id) => String.t() | nil,
          required(:source) => {:session, binary()} | {:api_key, String.t()}
        }

  @doc """
  Lock and reread `binding`'s rows and ask `verify:` over them.

  `verify` answers `:ok`, `{:ok, value}` or `{:error, reason}`; the check
  answers the same. A store that cannot answer is
  `{:error, :database_error}` — never a verdict either way.
  """
  @spec check(Cyfr.Actor.t(), binding(), keyword()) ::
          :ok | {:ok, term()} | {:error, term()}
  def check(%Cyfr.Actor{scope: :platform, system: true}, %{user_id: user_id} = binding, opts)
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
  end

  def check(%Cyfr.Actor{}, _binding, _opts), do: {:error, :cross_tenant}
end
