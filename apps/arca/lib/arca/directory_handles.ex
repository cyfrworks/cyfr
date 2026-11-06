# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DirectoryHandles do
  @moduledoc """
  The handle registry a CYFR serving a directory serves beside it
  (`Sanctum.Directory.Handles`): personal handles
  (`Arca.Schemas.DirectoryHandle`), one per account and one account per
  handle, for good, and the nonces of the signed requests it accepted
  (`Arca.Schemas.DirectoryNonce`).

  ## A claim

  One transaction, under the member's slot (`Arca.Repo.owned/2`): the
  request's nonce is recorded first, and one the account spent before is
  `:replayed`; a request whose expiry is not after the database's clock
  is `:expired`; then the handle becomes the account's, or is answered
  `:exists` when it already is, `:handle_taken` when another account holds
  it, and `:has_other_handle` when the account holds another. Every
  refusal rolls the nonce back with the claim, so a refused request
  leaves its nonce unspent. Arca verifies no signature: the caller
  verified the request against the account's log before it claims.

  Rows are plain maps (`Arca.Data`). Only the platform's own actor reads
  or writes.
  """

  import Ecto.Query

  alias Arca.Schemas.{DirectoryHandle, DirectoryNonce}

  @typedoc "A handle row, as a plain map."
  @type row :: map()

  @doc "The account holding `handle`, or `{:error, :not_found}`."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def get(%Prima.Actor{scope: :platform}, handle) when is_binary(handle) do
    Arca.Repo.Errors.with_db_rescue("Arca.DirectoryHandles.get", fn ->
      case Arca.Repo.get(DirectoryHandle, handle) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _handle), do: {:error, :cross_tenant}

  @doc """
  Claim `attrs.handle` for the account `attrs.identifier` under the
  request's `:nonce` (16 bytes) and `:expires_at` (a `DateTime`), as the
  module doc reads. Answers `{:ok, row, :created}`, `{:ok, row, :exists}`,
  or `{:error, reason}`: `:replayed`, `:expired`, `:handle_taken`,
  `:has_other_handle`, `{:invalid, errors}`, `:not_owner`,
  `:database_error`.
  """
  @spec claim(Prima.Actor.t(), map()) ::
          {:ok, row(), :created | :exists} | {:error, term()}
  def claim(%Prima.Actor{scope: :platform, system: true}, attrs) when is_map(attrs) do
    with {:ok, attrs} <- valid(Map.new(attrs)) do
      case Arca.Repo.owned("Arca.DirectoryHandles.claim", fn -> claim_in(attrs) end) do
        {:ok, {row, result}} -> {:ok, row, result}
        {:error, _reason} = refused -> refused
      end
    end
  end

  def claim(%Prima.Actor{}, _attrs), do: {:error, :cross_tenant}

  # ---- internals -------------------------------------------------------------

  defp claim_in(%{identifier: identifier, handle: handle} = attrs) do
    now = Arca.ServerMetaStorage.now!()

    nonce = %{
      identifier: identifier,
      nonce: attrs.nonce,
      expires_at: attrs.expires_at,
      inserted_at: now
    }

    with :ok <- spent(Arca.Repo.insert_all(DirectoryNonce, [nonce], on_conflict: :nothing)),
         :ok <-
           if(DateTime.compare(attrs.expires_at, now) == :gt, do: :ok, else: {:error, :expired}) do
      row = %{handle: handle, identifier: identifier, inserted_at: now}

      case Arca.Repo.insert_all(DirectoryHandle, [row], on_conflict: :nothing) do
        {1, _} -> {:ok, {Arca.Repo.get!(DirectoryHandle, handle), :created}}
        {0, _} -> held(handle, identifier)
      end
    end
  end

  defp spent({1, _}), do: :ok
  defp spent({0, _}), do: {:error, :replayed}

  # The handle was not written: it is the account's already, another's, or
  # free while the account holds another.
  defp held(handle, identifier) do
    case Arca.Repo.get(DirectoryHandle, handle) do
      %DirectoryHandle{identifier: ^identifier} = row ->
        {:ok, {row, :exists}}

      %DirectoryHandle{} ->
        {:error, :handle_taken}

      nil ->
        if Arca.Repo.exists?(from(h in DirectoryHandle, where: h.identifier == ^identifier)),
          do: {:error, :has_other_handle},
          else: {:error, :handle_taken}
    end
  end

  defp valid(attrs) do
    errors =
      [
        {:identifier, Prima.Identity.Encoding.identifier?(attrs[:identifier])},
        {:handle, Prima.ComponentRef.valid_personal_slug?(attrs[:handle])},
        {:nonce,
         is_binary(attrs[:nonce]) and
           byte_size(attrs[:nonce]) == Prima.RegistryRequest.nonce_bytes()},
        {:expires_at, match?(%DateTime{}, attrs[:expires_at])}
      ]
      |> Enum.reject(&elem(&1, 1))
      |> Map.new(fn {field, _ok} -> {field, ["is required"]} end)

    if errors == %{},
      do: {:ok, %{attrs | expires_at: usec(attrs.expires_at)}},
      else: {:error, {:invalid, errors}}
  end

  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}
end
