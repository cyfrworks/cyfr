# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.ShapeDigest do
  @moduledoc """
  What the operator was shown, hashed before any choice was made.

  The shape is the *question*: this component, at this scope, declaring
  these needs, asking for these capabilities. The answer — which credential
  satisfies which need, what gets projected — is the commit digest's job
  (`Sanctum.Consent.CommitDigest`).

  Separating them is what makes a new release detectable. Under a
  versionless consent, a release whose shape digest is unchanged asks for
  nothing new and runs; a release whose shape changed must be re-consented
  even though the version string moved on its own.

  ## Tool groups are expanded, never named

  Capabilities name `tool.action` pairs, and only pairs. A group name is
  not a stable capability: whoever defines the group could add an action to
  it later and silently widen every consent that named it. There is no
  input here that could carry a group name, so that widening is
  unrepresentable rather than merely disallowed.

  ## Normalization

  Inputs are validated and normalized before hashing — unknown keys
  rejected, lists sorted and deduplicated, durations required to be exact
  (`30s`, `5m`, never `5mm`, which `Sanctum.Policy.parse_duration/1`
  tolerates but a digest must not). Two inputs that mean the same thing
  produce the same digest; two that differ cannot collide.
  """

  alias Sanctum.Consent.Normalize
  alias Sanctum.JCS

  @type shape :: %{
          required(:scope) => :versionless | :pinned,
          required(:source_ref) => String.t(),
          optional(:release_identity) => String.t(),
          optional(:needs) => [map()],
          optional(:caps) => map(),
          optional(:tool_actions) => [String.t()],
          optional(:slots) => [String.t()]
        }

  @type error :: {:invalid_shape, atom(), String.t()} | {:invalid_digest_input, JCS.error()}

  @doc """
  Compute the shape digest.

  `:release_identity` is required when the scope is `:pinned` and forbidden
  when it is `:versionless` — a pinned consent that does not name what it
  pins would be pinned to nothing, and a versionless one that names a
  release would change digest on every release and so never be versionless.

  ## Examples

      iex> {:ok, digest} = Sanctum.Consent.ShapeDigest.compute(%{
      ...>   scope: :versionless,
      ...>   source_ref: "formula:local.daily-report",
      ...>   tool_actions: ["storage.read"]
      ...> })
      iex> String.starts_with?(digest, "sha256:")
      true

  """
  @spec compute(shape()) :: {:ok, String.t()} | {:error, error()}
  def compute(shape) when is_map(shape) do
    with {:ok, canonical} <- normalize(shape) do
      case JCS.hash(canonical) do
        {:ok, digest} -> {:ok, digest}
        {:error, reason} -> {:error, {:invalid_digest_input, reason}}
      end
    end
  end

  def compute(other),
    do: {:error, {:invalid_shape, :input, "expected a map, got: #{inspect(other)}"}}

  @doc """
  The canonical map a shape digest is taken over. Exposed so a preview can
  show exactly what was hashed, and so the commit digest can embed it.
  """
  @spec normalize(shape()) :: {:ok, map()} | {:error, error()}
  def normalize(shape) do
    with :ok <-
           Normalize.only_keys(
             shape,
             ~w(scope source_ref release_identity needs caps tool_actions slots)a,
             :invalid_shape
           ),
         {:ok, scope} <- Normalize.enum(shape, :scope, [:versionless, :pinned], :invalid_shape),
         {:ok, source_ref} <- Normalize.component_ref(shape, :source_ref, :invalid_shape),
         {:ok, release_identity} <- release_identity(shape, scope),
         {:ok, needs} <- Normalize.needs(shape, :needs, :invalid_shape),
         {:ok, caps} <- Normalize.caps(shape, :caps, :invalid_shape),
         {:ok, tool_actions} <- Normalize.tool_actions(shape, :tool_actions, :invalid_shape),
         {:ok, slots} <- Normalize.string_set(shape, :slots, :invalid_shape) do
      canonical =
        %{
          "scope" => Atom.to_string(scope),
          "source_ref" => source_ref,
          "needs" => needs,
          "caps" => caps,
          "tool_actions" => tool_actions,
          "slots" => slots
        }
        |> Normalize.put_optional("release_identity", release_identity)

      {:ok, canonical}
    end
  end

  defp release_identity(shape, :pinned) do
    case Normalize.optional_string(shape, :release_identity, :invalid_shape) do
      {:ok, nil} ->
        {:error, {:invalid_shape, :release_identity, "is required when scope is pinned"}}

      other ->
        other
    end
  end

  defp release_identity(shape, :versionless) do
    case Normalize.optional_string(shape, :release_identity, :invalid_shape) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, _present} ->
        {:error, {:invalid_shape, :release_identity, "must be absent when scope is versionless"}}

      other ->
        other
    end
  end
end
