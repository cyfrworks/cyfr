# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Directory.Handles do
  @moduledoc """
  The handle registry a CYFR serving a directory serves beside it
  (`ARCHITECTURE.md` §9.1), so a self-hosted directory names itself as the
  registry its accounts claim their names at: `GET /v1/handles/{handle}`
  and `POST /v1/namespaces/personal/claim`, a personal handle's answer and
  claim as `Prima.HandleAnswer` and `Prima.RegistryRequest` define them,
  and nothing else. It asks no policy acceptance, keeps no bans and serves
  no legal pages. `Emissary.Web.HandleController` is its one caller.

  ## Serving

  As the directory decides (`Sanctum.Directory.gate/2`): `directory_serve`
  `off` answers `:not_served`, `mirror` serves reads and answers a claim
  `:read_only`, and every request is admitted to the directory's
  per-source and per-installation windows first. The registry is this
  CYFR's host, the one a request names (`registry`) and an answer
  carries; the directory every account it accepts names is the one this
  node serves (`Sanctum.Directory.served/0`).

  ## A claim

  The request's bytes are checked by `Prima.RegistryRequest.verify/4`, in
  its order, against the account's head as this directory stores it
  (`Sanctum.Directory.state/1`). An account the directory does not hold,
  or holds gone, reads as a head that lists no one, so the request is
  `:unknown_identity` once its own checks pass, as the registry at
  cyfr.run treats an erased account. Only `handle.claim` is served
  (`:unknown_operation` for any other). Then the handle becomes the
  account's in the transaction that spends the request's nonce
  (`Arca.DirectoryHandles`): `:replayed`, `:expired`, `:handle_taken` or
  `:has_other_handle`. The answer names the handle, the account and
  whether the claim made it.

  ## Answers

  A handle no one holds is `:handle_not_found`. Every refusal of a request
  is `Prima.RegistryRequest.refusals/0`'s name, beside the directory's own
  `:not_served`, `:read_only` and `{:rate_limited, seconds}`; a store that
  cannot answer is `:directory_unavailable`.
  """

  alias Prima.{ComponentRef, HandleAnswer, RegistryRequest}
  alias Prima.Identity.{Encoding, State}

  @claim "handle.claim"
  # A head no request's account is: an identifier no genesis hashes to, and
  # no key. An account this directory does not hold is read as it.
  @nobody "per_" <> String.duplicate("0", 64)

  @typedoc "The caller's address, the key of the directory's per-source limits."
  @type source :: String.t()

  @typedoc "A claim's answer."
  @type claimed :: %{handle: String.t(), identifier: String.t(), created: boolean()}

  @doc "The account holding `handle` at this registry, as its answer."
  @spec resolve(%{handle: String.t(), source: source()}) ::
          {:ok, HandleAnswer.t()} | {:error, atom() | {atom(), term()}}
  def resolve(%{handle: handle, source: source}) when is_binary(handle) and is_binary(source) do
    with :ok <- Sanctum.Directory.gate(source, :read),
         {:ok, directory} <- registry(),
         :ok <- spelled(handle) do
      case Arca.DirectoryHandles.get(Prima.Actor.system(), handle) do
        {:ok, %{identifier: identifier}} ->
          {:ok,
           %HandleAnswer{
             registry: Encoding.home_host(directory),
             handle: handle,
             identifier: identifier,
             directory: directory
           }}

        {:error, :not_found} ->
          {:error, :handle_not_found}

        {:error, _unanswered} ->
          {:error, :directory_unavailable}
      end
    end
  end

  @doc "Claim a personal handle with a signed request, its JSON bytes (the module doc)."
  @spec claim(%{request: binary(), source: source()}) ::
          {:ok, claimed()} | {:error, atom() | {atom(), term()}}
  def claim(%{request: bytes, source: source}) when is_binary(bytes) and is_binary(source) do
    with :ok <- Sanctum.Directory.gate(source, :write),
         {:ok, directory} <- registry(),
         {:ok, head} <- head(bytes, directory),
         {:ok, request} <-
           RegistryRequest.verify(
             bytes,
             head,
             %{host: Encoding.home_host(directory), directory: directory},
             System.os_time(:millisecond)
           ),
         :ok <- if(request.operation == @claim, do: :ok, else: {:error, :unknown_operation}) do
      record(request)
    end
  end

  # ---- internals ---------------------------------------------------------------

  defp registry do
    case Sanctum.Directory.served() do
      {:ok, directory} -> {:ok, directory}
      :error -> {:error, :not_served}
    end
  end

  # A handle is a personal slug; any other spelling is no one's.
  defp spelled(handle) do
    if ComponentRef.valid_personal_slug?(handle), do: :ok, else: {:error, :handle_not_found}
  end

  # The head the request's account stands at here, read before the
  # request's own checks so they run in the protocol's order: an account
  # this directory does not hold, holds gone, or a request that names
  # none reads as no one's.
  defp head(bytes, directory) do
    case identifier_of(bytes) do
      {:ok, identifier} ->
        case Sanctum.Directory.state(identifier) do
          {:ok, state} -> {:ok, state}
          {:error, reason} when reason in [:not_found, :gone] -> {:ok, nobody(directory)}
          {:error, _unavailable} -> {:error, :directory_unavailable}
        end

      :error ->
        {:ok, nobody(directory)}
    end
  end

  defp identifier_of(bytes) do
    with true <- byte_size(bytes) <= RegistryRequest.max_bytes(),
         {:ok, %{"identifier" => identifier}} <- Prima.Json.decode(bytes),
         true <- Encoding.identifier?(identifier) do
      {:ok, identifier}
    else
      _ -> :error
    end
  end

  defp nobody(directory),
    do: %State{
      identifier: @nobody,
      directory: directory,
      head: Prima.Digest.sha256(@nobody),
      seq: 0,
      keys: [],
      recovery: []
    }

  defp record(%RegistryRequest{identifier: identifier, body: %{"handle" => handle}} = request) do
    case Arca.DirectoryHandles.claim(Prima.Actor.system(), %{
           identifier: identifier,
           handle: handle,
           nonce: request.nonce,
           expires_at: DateTime.from_unix!(request.expires_at, :millisecond)
         }) do
      {:ok, _row, result} ->
        {:ok, %{handle: handle, identifier: identifier, created: result == :created}}

      {:error, reason}
      when reason in [:replayed, :expired, :handle_taken, :has_other_handle] ->
        {:error, reason}

      {:error, _unanswered} ->
        {:error, :directory_unavailable}
    end
  end
end
