# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Canvas do
  @moduledoc """
  A person's canvases as components: writing a canvas version, activating
  a validated one, restoring the kept one, and the two reads, a canvas's
  versions document and the catalog of what a canvas may read. The
  `canvas` tool (`Compendium.Providers.Canvas`) is their one door.

  A canvas is the tincture `tincture:local.<name>` whose placement is
  `canvas`. Which of its versions a glass opens is its versions document
  (`Arca.CanvasVersions`), one fenced document per canvas in its athanor:
  every change here publishes it at the revision it read, and a document
  published since answers `conflict` with nothing merged.

    * `write/2` checks the canvas's declaration before anything is
      written, then allocates first: it publishes the next version as
      `allocated`, one patch above every version the document allocated,
      the athanor installed or the seed ships, and only then creates that
      version's directory, refusing one that exists, and registers it. Two
      writers that read one document get distinct versions or one
      `conflict`, and no version's files are ever replaced; a failure after
      the allocation leaves a version number unused.
    * `activate/2` spends the validation credential of the frame a
      candidate version was trialled in, whatever the trial's outcome. A
      tree activates the version once its tincture's grant is current
      (`Compendium.tincture_grant_revision/2`), keeping the version it
      replaces. A tree changes nothing for the version already working,
      and for a version older than the working one it publishes nothing
      and answers `conflict`. Any other outcome records the failure and
      nothing else.
    * `restore/2` makes the kept version the working one again, while it
      is still installed and under today's grant, and keeps the one it
      replaces.

  A canvas never writes its own source, so nothing it reads reaches a
  version: it declares no system action and its credential reaches no
  route but its own open's streams, so it cannot call `write/2`, and the
  catalog a writer reads answers shapes, never values.

  The refusals are `Prima.Refusal`'s classes: a `forbidden` one carries
  its code at the end of its sentence (`not_validated`, `not_primary`);
  `consent_required` and `not_owner` are the table's fixed answers. A
  frame is named by its frame id alone, and no answer, refusal or log
  line here repeats it.
  """

  require Logger

  alias Arca.CanvasVersions
  alias Compendium.ComponentPath
  alias Sanctum.Context

  @type_name "tincture"
  @module_file "canvas.js"
  @module_max_bytes 262_144
  @first_version "0.1.0"
  @outcomes ~w(tree no_tree died)
  @placement "canvas"

  @typedoc "A canvas-readable stream as the catalog lists it."
  @type catalog_stream :: %{
          name: String.t(),
          subject: String.t() | nil,
          shape: Prima.Canvas.Shape.t(),
          filter: String.t() | nil,
          refresh: boolean()
        }

  @typedoc "The catalog: the toolkit majors and every canvas-readable stream, by name."
  @type catalog :: %{toolkit: [pos_integer()], streams: [catalog_stream()]}

  @typedoc "A canvas's versions document and the revision it was read at."
  @type versions :: %{
          canvas: String.t(),
          document: CanvasVersions.document(),
          revision: non_neg_integer()
        }

  @doc "The most bytes of UTF-8 a canvas's module may take."
  @spec module_max_bytes() :: pos_integer()
  def module_max_bytes, do: @module_max_bytes

  @doc "The outcomes a validation reports to `activate/2`: a tree, no tree, or a dead candidate."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc """
  Write a new version of the canvas `name` from `args`: `"name"`,
  `"module"` (the module's source, at most #{@module_max_bytes} bytes)
  and `"streams"` (a list of `{name, subject}` objects, the streams it
  reads).

  The manifest (`frame.placement` `canvas`, `canvas`
  `{"module": "#{@module_file}", "toolkit": 1}` and the streams) is held
  to the manifest's grammar, the tincture rules and the streams a canvas
  may read before anything is allocated, so a refused write allocates
  nothing. A name some installed version of which is not a canvas is a
  `conflict`. Then the next version is allocated, its directory created
  whole with exactly the manifest and the module, counted against the
  athanor's storage like any tenant content, and registered.

  Answers `%{canvas, version, reference}`, the reference pinned to the
  version. It writes no layout and activates nothing: a glass validates
  the version before it is used.
  """
  @spec write(Context.t(), map()) ::
          {:ok, %{canvas: String.t(), version: String.t(), reference: String.t()}}
          | {:error, term()}
  def write(%Context{} = ctx, args) when is_map(args) do
    with {:ok, name} <- name(Map.get(args, "name")),
         {:ok, module} <- module(Map.get(args, "module")),
         {:ok, streams} <- streams(Map.get(args, "streams")),
         :ok <- declaration(manifest(name, @first_version, streams)),
         {:ok, installed} <- installed(ctx, name),
         :ok <- canvas_only(name, installed),
         {:ok, shipped} <- shipped(name),
         {:ok, stored, revision} <- document(ctx, name),
         version = next_version([stored.allocated | Enum.map(installed, & &1.version) ++ shipped]),
         {:ok, _published} <- publish(ctx, name, %{stored | allocated: version}, revision),
         :ok <- commit(ctx, name, version, manifest(name, version, streams), module),
         :ok <- register(ctx, name, version) do
      {:ok, %{canvas: name, version: version, reference: reference(name, version)}}
    end
  end

  def write(%Context{}, _args),
    do: {:error, {:invalid_argument, "write takes name, module and streams"}}

  @doc """
  Activate, or record the failure of, the canvas version a glass trialled:
  `args` names the `"canvas"`, its `"version"`, the `"frame"` id it was
  trialled in and the trial's `"outcome"` (#{Enum.join(@outcomes, ", ")}).

  The version must be an installed canvas version of that canvas
  (`not_found` otherwise). The frame's validation credential for that
  version is spent first, for every outcome, and nothing is activated
  without it: `forbidden` (`not_validated`) for a frame holding none,
  `not_owner` on a member that lost its slot, `forbidden`
  (`not_primary`) from a frame's own context. For a tree the version's
  tincture grant is then checked as a frame's opening checks it, though
  validation already ran under it: `consent_required` while it waits
  for the person. Then the document is published at the revision read,
  `working` the version and `kept` the one it replaces, the failure
  cleared; or, for any other outcome, `failed` the version, the outcome
  and now, and nothing else. A tree for the version already working
  publishes nothing and answers the document as it stands, so the kept
  version stays the way back. A tree for a version older than the
  working one, in version order, publishes nothing and answers
  `conflict`: a newer version of the canvas is working, and `working` and
  `kept` stay as they were.

  Answers `%{canvas, version, activated, revision, document}`.
  """
  @spec activate(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def activate(%Context{} = ctx, args) when is_map(args) do
    with {:ok, name} <- name(Map.get(args, "canvas")),
         {:ok, version} <- version(Map.get(args, "version")),
         {:ok, frame} <- frame(Map.get(args, "frame")),
         {:ok, outcome} <- outcome(Map.get(args, "outcome")),
         {:ok, digest} <- release_digest(ctx, name, version),
         :ok <- consume(ctx, frame, digest),
         :ok <- granted(ctx, name, version, outcome),
         {:ok, stored, revision} <- document(ctx, name),
         {:ok, document, published} <- trial(ctx, name, stored, revision, version, outcome) do
      {:ok,
       %{
         canvas: name,
         version: version,
         activated: outcome == "tree",
         revision: published,
         document: document
       }}
    end
  end

  def activate(%Context{}, _args),
    do: {:error, {:invalid_argument, "activate takes canvas, version, frame and outcome"}}

  @doc """
  Make the canvas `name`'s kept version its working one again, and keep
  the version it replaces. A canvas with no kept version, or whose kept
  version is no longer an installed canvas version, is `not_found`.
  The kept version opens under today's grant, never the grant it was
  kept under: the check is activation's, `consent_required` while the
  grant waits for the person. The document is published at the revision
  read, so a restore racing an activation is one `conflict`.

  Answers `%{canvas, revision, document}`.
  """
  @spec restore(Context.t(), term()) :: {:ok, map()} | {:error, term()}
  def restore(%Context{} = ctx, name) do
    with {:ok, name} <- name(name),
         {:ok, stored, revision} <- document(ctx, name),
         {:ok, kept} <- kept(stored, name),
         {:ok, installed} <- installed(ctx, name),
         :ok <- still_installed(installed, name, kept),
         :ok <- granted(ctx, name, kept, "tree"),
         restored = %{stored | working: kept, kept: stored.working},
         {:ok, published} <- publish(ctx, name, restored, revision) do
      {:ok, %{canvas: name, revision: published, document: restored}}
    end
  end

  @doc """
  The canvas `name`'s versions document and the revision it was read at.
  A canvas installed with no document yet answers the empty document at
  revision 0; a name with no installed canvas version is `not_found`.
  """
  @spec versions(Context.t(), term()) :: {:ok, versions()} | {:error, term()}
  def versions(%Context{} = ctx, name) do
    with {:ok, name} <- name(name),
         {:ok, installed} <- installed(ctx, name),
         :ok <- some_canvas(name, installed),
         {:ok, stored, revision} <- document(ctx, name) do
      {:ok, %{canvas: name, document: stored, revision: revision}}
    end
  end

  @doc """
  What a canvas may read, derived from the operation table and never
  written by hand: the toolkit majors (`Compendium.tincture_toolkit_majors/0`)
  and every stream whose declaration carries a shape (`Sanctum.Catalog.streams/0`),
  sorted by name, each with its subject grammar (the source of its anchored
  expression, or nil for none), its shape, its filter and whether it
  refreshes. Shapes and names, never a value.
  """
  @spec catalog(Context.t()) :: {:ok, catalog()}
  def catalog(%Context{}) do
    streams =
      for %Prima.Provider.Stream{shape: shape} = stream <- Sanctum.Catalog.streams(),
          not is_nil(shape) do
        %{
          name: stream.name,
          subject: stream.subject,
          shape: shape,
          filter: stream.filter,
          refresh: not is_nil(stream.refresh)
        }
      end

    {:ok,
     %{toolkit: Compendium.tincture_toolkit_majors(), streams: Enum.sort_by(streams, & &1.name)}}
  end

  # ---------------------------------------------------------------------------
  # Arguments
  # ---------------------------------------------------------------------------

  defp name(name) when is_binary(name) do
    case Prima.ComponentRef.validate_name(name) do
      :ok -> {:ok, name}
      {:error, reason} -> {:error, {:invalid_argument, "a canvas's name: #{reason}"}}
    end
  end

  defp name(_name), do: {:error, {:invalid_argument, "a canvas's name is a component name"}}

  defp module(module) when is_binary(module) do
    cond do
      not String.valid?(module) ->
        {:error, {:invalid_argument, "the module is UTF-8 text"}}

      byte_size(module) > @module_max_bytes ->
        {:error,
         {:invalid_argument,
          "the module is #{byte_size(module)} bytes, over the #{@module_max_bytes} a canvas's module may take"}}

      true ->
        {:ok, module}
    end
  end

  defp module(_module),
    do: {:error, {:invalid_argument, "the module is the canvas's source, as text"}}

  defp streams(streams) when is_list(streams), do: {:ok, streams}

  defp streams(_streams),
    do:
      {:error,
       {:invalid_argument,
        "streams is a list of the streams the canvas reads, each {name} or {name, subject}"}}

  defp version(version) do
    if CanvasVersions.version?(version),
      do: {:ok, version},
      else: {:error, {:invalid_argument, "a canvas version is MAJOR.MINOR.PATCH"}}
  end

  # The frame id is named, never echoed: a caller that put a bearer here
  # must not find it in the refusal.
  defp frame(frame) do
    if Prima.CanvasWire.frame_id?(frame),
      do: {:ok, frame},
      else:
        {:error, {:invalid_argument, "frame is the id of the frame the version was trialled in"}}
  end

  defp outcome(outcome) when outcome in @outcomes, do: {:ok, outcome}

  defp outcome(_outcome),
    do: {:error, {:invalid_argument, "the outcome is one of #{Enum.join(@outcomes, ", ")}"}}

  # ---------------------------------------------------------------------------
  # The declaration
  # ---------------------------------------------------------------------------

  defp manifest(name, version, streams) do
    %{
      "type" => @type_name,
      "name" => name,
      "version" => version,
      "tincture" => %{
        "frame" => %{"placement" => @placement},
        "canvas" => %{
          "module" => @module_file,
          "toolkit" => hd(Compendium.tincture_toolkit_majors())
        },
        "streams" => streams
      }
    }
  end

  # What publish holds a canvas version to, before anything is allocated:
  # the manifest's grammar, the rules, and the streams a canvas reads. The
  # version is the one thing it does not read.
  defp declaration(manifest) do
    table = Sanctum.Catalog.streams()

    with :ok <- grammar(manifest),
         {:ok, declaration} <- Compendium.tincture_declaration(manifest),
         :ok <- Compendium.tincture_check_streams(declaration, table),
         :ok <- Compendium.tincture_check_canvas_streams(declaration, table) do
      :ok
    else
      {:error, {:invalid_tincture, sentence}} -> {:error, {:invalid_argument, sentence}}
      {:error, _} = refusal -> refusal
    end
  end

  defp grammar(manifest) do
    case Prima.Manifest.validate(manifest, &Arca.Storage.valid_guest_path?/1) do
      :ok ->
        :ok

      {:error, {:invalid_manifest, [{_tag, sentence} | _]}} when is_binary(sentence) ->
        {:error, {:invalid_argument, sentence}}

      {:error, _refused} ->
        {:error, {:invalid_argument, "the canvas's manifest is refused"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Installed and shipped versions
  # ---------------------------------------------------------------------------

  # Every installed version of `tincture:local.<name>`, once the
  # component projection reflects the tree, with its placement.
  defp installed(ctx, name) do
    with :ok <- Compendium.ProjectionReconciler.await(ctx, "components"),
         {:ok, rows} <-
           Arca.ComponentStorage.list_components(Context.actor(ctx),
             name: name,
             publisher: ComponentPath.default_publisher(),
             component_type: @type_name,
             limit: :none
           ) do
      {:ok, Enum.map(rows, &%{version: &1.version, placement: placement(&1.manifest)})}
    else
      {:error, reason} -> unavailable("Components", reason)
    end
  end

  # A stored manifest that does not decode is damage: it places nothing,
  # so the version is refused as a canvas.
  defp placement(manifest) do
    case Prima.Manifest.decode_strict(manifest) do
      {:ok, %{"tincture" => %{"frame" => %{"placement" => placement}}}} -> placement
      {:ok, _places_nothing} -> nil
      {:error, :malformed_manifest} -> nil
    end
  end

  defp canvas_only(name, installed) do
    if Enum.all?(installed, &(&1.placement == @placement)),
      do: :ok,
      else:
        {:error,
         {:conflict,
          "#{reference(name)} is installed as a tincture that is not a canvas; " <>
            "a canvas takes a name of its own"}}
  end

  defp some_canvas(name, installed) do
    if Enum.any?(installed, &(&1.placement == @placement)),
      do: :ok,
      else: {:error, {:not_found, "Canvas", name}}
  end

  # A kept version is restored only while it is an installed canvas
  # version.
  defp still_installed(installed, name, kept) do
    if Enum.any?(installed, &(&1.version == kept and &1.placement == @placement)),
      do: :ok,
      else: not_a_canvas_version(name, kept)
  end

  defp shipped(name) do
    case Compendium.Provenance.shipped_versions(@type_name, name) do
      {:ok, versions} -> {:ok, versions}
      {:error, reason} -> unavailable("The shipped components", reason)
    end
  end

  # One patch above the highest version any source names, so the version
  # a write allocates was never allocated, installed or shipped.
  defp next_version(versions) do
    versions
    |> Enum.flat_map(fn version ->
      case is_binary(version) && Compendium.Semver.parse(version) do
        {:ok, parsed} -> [parsed]
        _ -> []
      end
    end)
    |> Enum.max(Version, fn -> nil end)
    |> case do
      nil -> @first_version
      %Version{major: major, minor: minor, patch: patch} -> "#{major}.#{minor}.#{patch + 1}"
    end
  end

  # The installed canvas version's release digest: what its validation
  # credential was minted for.
  defp release_digest(ctx, name, version) do
    case Compendium.Component.inspect_component(ctx, reference(name, version)) do
      {:ok, %{"release_digest" => "sha256:" <> _ = digest} = component} ->
        if placement(component["manifest"]) == @placement,
          do: {:ok, digest},
          else: not_a_canvas_version(name, version)

      {:ok, _unreleased} ->
        not_a_canvas_version(name, version)

      {:error, {:not_found, _}} ->
        not_a_canvas_version(name, version)

      {:error, reason} ->
        unavailable("Components", reason)
    end
  end

  defp not_a_canvas_version(name, version),
    do: {:error, {:not_found, "Canvas version", "#{name} #{version}"}}

  # ---------------------------------------------------------------------------
  # Activation
  # ---------------------------------------------------------------------------

  defp consume(ctx, frame, digest) do
    case Sanctum.TinctureAuth.consume_validation(ctx, frame, digest) do
      :ok ->
        :ok

      {:error, :not_validated} ->
        forbidden(
          :not_validated,
          "That frame holds no validation credential for this canvas version, " <>
            "so nothing is activated (not_validated)"
        )

      {:error, :not_owner} ->
        {:error, :not_owner}

      {:error, :not_primary} ->
        forbidden(
          :not_primary,
          "Only a person's session or key reports a validation, never a frame (not_primary)"
        )

      {:error, :no_athanor} ->
        {:error, :no_athanor}

      {:error, :unavailable} ->
        {:error, {:unavailable, "Validation credential"}}
    end
  end

  # Only a tree activates, and a version activates only under the grant
  # its tincture holds now, held to that version: one that reads more than
  # the grant names waits for the person as one with no grant does.
  defp granted(ctx, name, version, "tree") do
    case Compendium.tincture_grant_revision(ctx, reference(name, version)) do
      {:ok, _revision} -> :ok
      {:error, :ungranted} -> {:error, :consent_required}
      {:error, :unavailable} -> {:error, {:unavailable, "Consent"}}
      {:error, {:refused, reason}} -> {:error, reason}
    end
  end

  defp granted(_ctx, _name, _version, _outcome), do: :ok

  # A tree for the version already working changes nothing: publishing it
  # would make the working version its own kept one and lose the way back.
  # A tree for a version older than the working one, in version order, is
  # a late report, and never moves the canvas back past what is working.
  defp trial(ctx, name, %{working: working} = stored, revision, version, "tree")
       when is_binary(working) do
    case Compendium.Semver.compare(version, working) do
      :eq ->
        {:ok, stored, revision}

      :lt ->
        {:error,
         {:conflict,
          "a newer version of canvas #{name} is working (#{working}), " <>
            "so #{version} is not activated"}}

      :gt ->
        published_trial(ctx, name, stored, revision, version, "tree")
    end
  end

  defp trial(ctx, name, stored, revision, version, outcome),
    do: published_trial(ctx, name, stored, revision, version, outcome)

  defp published_trial(ctx, name, stored, revision, version, outcome) do
    document = after_trial(stored, version, outcome)

    with {:ok, published} <- publish(ctx, name, document, revision) do
      {:ok, document, published}
    end
  end

  defp after_trial(stored, version, "tree"),
    do: %{stored | working: version, kept: stored.working, failed: nil}

  defp after_trial(stored, version, outcome) do
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    %{stored | failed: %{version: version, outcome: outcome, at: at}}
  end

  defp kept(%{kept: nil}, name), do: {:error, {:not_found, "Kept version of canvas", name}}
  defp kept(%{kept: kept}, _name), do: {:ok, kept}

  # ---------------------------------------------------------------------------
  # The versions document
  # ---------------------------------------------------------------------------

  defp document(ctx, name) do
    case CanvasVersions.get(Context.actor(ctx), name) do
      {:ok, %{document: document, revision: revision}} -> {:ok, document, revision}
      {:error, :not_found} -> {:ok, CanvasVersions.empty(), 0}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp publish(ctx, name, document, revision) do
    case CanvasVersions.publish(Context.actor(ctx), name, document, revision) do
      {:ok, published} -> {:ok, published}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  # A document published since the revision was read is the one refusal
  # the caller can act on, by reading again; a member that lost its slot
  # is the table's own; the storage cap keeps a sentence of its own; every
  # other failure wrote nothing and is answered as a retry.
  defp refusal(:stale),
    do: {:conflict, "the canvas's versions changed since they were read — read them again"}

  defp refusal(:not_owner), do: :not_owner
  defp refusal(:corrupt), do: {:corrupt, {:digest, "The canvas's versions"}}

  defp refusal({:storage, {:limit_reached, :athanor_storage_bytes, cap}}),
    do: {:invalid_argument, "the athanor's storage cap of #{cap} bytes is reached"}

  defp refusal(reason) do
    Logger.warning(
      "[Compendium.Canvas] a canvas's versions were not read or published: #{inspect(reason)}"
    )

    {:unavailable, "Canvas versions"}
  end

  # ---------------------------------------------------------------------------
  # The version's files
  # ---------------------------------------------------------------------------

  # The version's directory, created whole and never over one that
  # exists: its manifest and its module, and nothing else.
  defp commit(ctx, name, version, manifest, module) do
    manifest_bytes = Jason.encode!(manifest)
    unit = ComponentPath.version_dir(@type_name, ComponentPath.default_publisher(), name, version)

    files = [
      {[@module_file], module},
      {[ComponentPath.manifest_name()], manifest_bytes}
    ]

    case Arca.Overlay.commit_unit(Context.actor(ctx), unit, {:files, files},
           cap: {:checked, byte_size(module) + byte_size(manifest_bytes)},
           if_absent: true
         ) do
      {:ok, _written} ->
        :ok

      {:error, :exists} ->
        {:error,
         {:conflict,
          "#{reference(name, version)} already exists, and a canvas version is never replaced"}}

      {:error, reason} ->
        if Prima.Refusal.reason?(reason),
          do: {:error, reason},
          else: unavailable("Storage", reason)
    end
  end

  defp register(ctx, name, version) do
    unit = ComponentPath.version_dir(@type_name, ComponentPath.default_publisher(), name, version)

    case Compendium.Registry.register_from_arca(ctx, unit) do
      {:ok, _component} ->
        :ok

      {:error, sentence} when is_binary(sentence) ->
        {:error,
         {:invalid_argument, "#{reference(name, version)} was not registered: #{sentence}"}}

      {:error, reason} ->
        if Prima.Refusal.reason?(reason),
          do: {:error, reason},
          else: unavailable("Component registry", reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp reference(name),
    do: Prima.ComponentRef.build(@type_name, ComponentPath.default_publisher(), name)

  defp reference(name, version),
    do: Prima.ComponentRef.build(@type_name, ComponentPath.default_publisher(), name, version)

  defp forbidden(code, sentence),
    do: {:error, %Prima.Refusal{class: :forbidden, reason: code, message: sentence}}

  defp unavailable(what, reason) do
    Logger.warning("[Compendium.Canvas] #{what} could not answer: #{inspect(reason)}")
    {:error, {:unavailable, what}}
  end
end
