# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.HandleAnswer do
  @moduledoc """
  The registry's answer for one handle, `cyfr-handle/v1`: the registry's
  host, the handle asked for, its owner's identifier and the directory the
  owner's genesis names, five keys in all, each required. It carries no
  keys and no address: the directory is the one owner of a person's keys,
  and a reader reads them there. `tests/fixtures/registry_wire.json` holds its vectors, which the
  registry's encoder reads too.

  A refusal (`HANDLE_NOT_FOUND` for a handle no one holds, a reserved one
  among them) comes in the registry's error envelope, which
  `Prima.RegistryRequest.refusal/1` reads.

  The grammars are the ones each value has everywhere: the handle
  `Prima.ComponentRef.valid_personal_slug?/1`, the identifier and
  directory `Prima.Identity.Encoding`'s.
  """

  alias Prima.{ComponentRef, RegistryRequest}
  alias Prima.Identity.Encoding

  @protocol "cyfr-handle/v1"
  @required ~w(protocol registry handle identifier directory)

  @type t :: %__MODULE__{
          registry: String.t(),
          handle: String.t(),
          identifier: String.t(),
          directory: String.t()
        }

  @enforce_keys [:registry, :handle, :identifier, :directory]
  defstruct [:registry, :handle, :identifier, :directory]

  @doc "The protocol string an answer carries."
  @spec protocol() :: String.t()
  def protocol, do: @protocol

  @doc """
  Read an answer, its JSON bytes or their decoded map, for the `handle`
  asked of the registry `registry` (its host). A registry error envelope
  answers its refusal (`Prima.RegistryRequest.refusal/1`). An answer for
  another handle or registry, of another protocol, with any other key
  (`address` among them), or with a value outside its grammar is
  `:malformed_answer`.
  """
  @spec parse(binary() | map(), String.t(), String.t()) ::
          {:ok, t()} | {:error, RegistryRequest.refusal() | :malformed_answer}
  def parse(answer, handle, registry) when is_binary(answer) do
    case Prima.Json.decode(answer) do
      {:ok, map} when is_map(map) -> parse(map, handle, registry)
      _ -> {:error, :malformed_answer}
    end
  end

  def parse(%{"errors" => _} = envelope, _handle, _registry) do
    with {:ok, refusal} <- RegistryRequest.refusal(envelope), do: {:error, refusal}
  end

  def parse(answer, handle, registry) when is_map(answer) and not is_struct(answer) do
    with :ok <- Encoding.fields(answer, @required, []),
         {:ok, @protocol} <- Encoding.check(answer, "protocol", &(&1 == @protocol)),
         {:ok, ^registry} <- Encoding.check(answer, "registry", &(&1 == registry)),
         {:ok, ^handle} <- Encoding.check(answer, "handle", &(&1 == handle)),
         true <- Encoding.host?(registry) and ComponentRef.valid_personal_slug?(handle),
         {:ok, identifier} <- Encoding.check(answer, "identifier", &Encoding.identifier?/1),
         {:ok, directory} <- Encoding.check(answer, "directory", &Encoding.directory_url?/1) do
      {:ok,
       %__MODULE__{
         registry: registry,
         handle: handle,
         identifier: identifier,
         directory: directory
       }}
    else
      _ -> {:error, :malformed_answer}
    end
  end

  def parse(_answer, _handle, _registry), do: {:error, :malformed_answer}

  @doc "The bytes the registry answers: the JCS form of the answer."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = answer) do
    %{
      "protocol" => @protocol,
      "registry" => answer.registry,
      "handle" => answer.handle,
      "identifier" => answer.identifier,
      "directory" => answer.directory
    }
    |> Encoding.jcs!()
  end
end
