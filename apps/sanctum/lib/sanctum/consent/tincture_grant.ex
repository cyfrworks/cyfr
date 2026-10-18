# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.TinctureGrant do
  @moduledoc """
  The grant one version of a tincture opens under: the head of the
  tincture's one active owner profile, held to that version as a run is
  held to the release it runs (`Sanctum.Consent.Loader.evaluate_head/4`,
  the decision table over the head's activation and shape against the
  version's). A version whose declaration reads more than the consent's
  shape — another stream, action, `background` or capability — asks
  again instead of opening, and so does a pinned consent for any other
  release.

  A tincture whose owner profile waits for the person, or that holds no
  active owner profile or no head at all, is ungranted: its declaration
  is never its grant, so it opens nothing until the person consents. A
  canvas is held to this too, though it has no way out: reading is itself
  a trust decision, so its grant names every stream it reads.

  A version opens in a frame, and a frame is admitted on the interactive
  path whoever asks (the shell, a canvas's activation or restore, a data
  route), so the head is held to the origins it admits for `:interactive`:
  a grant that admits only another origin, a schedule's say, is ungranted
  here as it is for an interactive run.
  """

  alias Prima.Authority.RootSelect
  alias Sanctum.Consent
  alias Sanctum.Consent.Components
  alias Sanctum.Consent.Loader
  alias Sanctum.Consent.ShapeDerivation
  alias Sanctum.Context

  require Components

  @typedoc """
  A grant that stands for the version: the owner profile, its head and
  the head's revision, which a frame credential binds.
  """
  @type t :: %{
          revision: pos_integer(),
          profile: RootSelect.profile_summary(),
          consent: Arca.ConsentStorage.consent()
        }

  @typedoc """
  Why the version opens nothing: `:ungranted` while the person has to
  consent (again), `:unavailable` when the grant or the version could not
  be read, and `{:refused, reason}` for a damaged profile, head or
  component graph, or an activation the installed world cannot resolve,
  which no consent repairs here.
  """
  @type refusal :: :ungranted | :unavailable | {:refused, term()}

  @doc """
  The grant the installed version `reference` (a tincture reference
  pinned to its version) opens under, or why it opens none.
  """
  @spec fetch(Context.t(), String.t()) :: {:ok, t()} | {:error, refusal()}
  def fetch(%Context{} = ctx, reference) when is_binary(reference) do
    with {:ok, ref} <- pinned(reference),
         name_ref = Prima.ComponentRef.to_name_ref(ref),
         {:ok, profile} <- owner(ctx, name_ref),
         {:ok, consent} <- head(ctx, profile),
         {:ok, row} <- version_row(ctx, ref),
         {:ok, live} <- live(ctx, row, reference),
         :ok <- standing(ctx, profile, consent, live, shape(ctx, name_ref, ref.version)) do
      {:ok, %{revision: consent.revision, profile: profile, consent: consent}}
    end
  end

  defp pinned(reference) do
    case Prima.ComponentRef.parse(reference) do
      {:ok, %{type: "tincture", version: version} = ref} when is_binary(version) -> {:ok, ref}
      _other -> {:error, {:refused, {:invalid_reference, reference}}}
    end
  end

  # The one active owner profile, as a run's default selection picks it.
  # A damaged candidate is refused as a run refuses it, never read as no
  # grant, which would send the person to grant again over a row that
  # exists.
  defp owner(ctx, name_ref) do
    case Consent.profiles(ctx, name_ref) do
      {:ok, entries} ->
        case Enum.find(entries, &(&1.status == :corrupt)) do
          %{id: id} -> {:error, {:refused, {:corrupt, {:profile, id}}}}
          nil -> select(entries)
        end

      {:error, _unreadable} ->
        {:error, :unavailable}
    end
  end

  defp select(entries) do
    case RootSelect.select(entries, :default) do
      {:ok, profile} -> {:ok, profile}
      {:error, {:ambiguous, _ids} = reason} -> {:error, {:refused, reason}}
      {:error, _none_active} -> {:error, :ungranted}
    end
  end

  defp head(ctx, %{id: profile_id}) do
    case Consent.head_consent(ctx, profile_id) do
      {:ok, consent} -> {:ok, consent}
      {:error, :not_found} -> {:error, :ungranted}
      {:error, :corrupt} -> {:error, {:refused, {:head_corrupt, profile_id}}}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

  defp version_row(ctx, ref) do
    case Components.get_component(ctx, ref.name, ref.version, ref.namespace, ref.type) do
      {:ok, row} -> {:ok, row}
      {:error, reason} when Components.is_outage(reason) -> {:error, :unavailable}
      {:error, reason} -> {:error, {:refused, reason}}
    end
  end

  # The version's verified activation, read as a run's admission reads
  # the release it runs: an outage refuses, a damaged graph is damage,
  # and any other answer is an activation the decision table answers
  # `setup_required` for.
  defp live(ctx, row, reference) do
    case Components.resolve_verified(ctx, row) do
      {:ok, _verified} = verified ->
        {:ok, verified}

      {:error, {:incomplete, _}} = incomplete ->
        {:ok, incomplete}

      {:error, reason} when Components.is_outage(reason) ->
        {:error, :unavailable}

      {:error, {:invalid_graph, _}} ->
        {:error, {:refused, {:corrupt, {:component_graph, reference}}}}

      {:error, _other} ->
        {:ok, {:error, {:incomplete, :invalid_graph}}}
    end
  end

  # A shape that cannot be derived is unknown, which the decision table
  # reads as changed: the version asks again.
  defp shape(ctx, name_ref, version) do
    case ShapeDerivation.version_digest(ctx, name_ref, version) do
      {:ok, digest} -> digest
      {:error, _underivable} -> nil
    end
  end

  defp standing(ctx, profile, consent, live, shape) do
    case Loader.evaluate_head(%{ctx | origin: :interactive}, profile, consent,
           live: live,
           live_shape_digest: shape
         ) do
      :ok -> :ok
      {:error, {:consent_required, _ask}} -> {:error, :ungranted}
      {:error, {:profile_unavailable, _status}} -> {:error, :ungranted}
      {:error, reason} -> {:error, {:refused, damage(reason, profile)}}
    end
  end

  # The app's own damage reads as every reader of its head reads it
  # (`Sanctum.Consent.Loader.damage_refusal/3`); any other reason stands.
  defp damage(reason, %{id: profile_id, source_ref: source_ref}) do
    if Loader.damage?(reason),
      do: Loader.damage_refusal(reason, profile_id, source_ref),
      else: reason
  end
end
