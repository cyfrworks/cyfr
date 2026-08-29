# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.WITSource do
  @moduledoc """
  The WIT interface definitions, embedded at compile time — the single
  source both the scaffolder and the Locus build sandbox consume.

  WIT is the host ABI: a guest compiled against definitions the running
  host does not implement cannot work, so the definitions ship inside the
  release rather than being read from disk at runtime. The repo's `wit/`
  stays the editable source (each file is an `@external_resource`, so
  editing one recompiles this module); the scaffold tarball keeps shipping
  it as developer reference.
  """

  @wit_root Path.expand("../../../../wit", __DIR__)

  # arca:bypass-ok=C — compile-time embed of the WIT tree. The Path.wildcard
  # + File.read! calls below run only at module compilation; runtime never
  # touches the filesystem for WIT.
  wit_entries =
    for type <- Sanctum.ComponentRef.executable_types() do
      type_dir = Path.join(@wit_root, type)

      # arca:bypass-ok=C — compile-time embed of the tracked wit/ tree.
      files =
        [type_dir, "**", "*.wit"]
        |> Path.join()
        |> Path.wildcard()

      # Fail the COMPILE, not the first build at runtime: an empty embed
      # means the wit/ tree was absent from the build context, and a release
      # without its ABI must never ship.
      if files == [] do
        raise "Compendium.WITSource: no WIT files found under #{type_dir} — " <>
                "is wit/ present in the build context?"
      end

      {type, type_dir, files}
    end

  for {_type, _dir, files} <- wit_entries, file <- files do
    @external_resource file
  end

  @wit_files Map.new(wit_entries, fn {type, type_dir, files} ->
               {type,
                Enum.map(files, fn file ->
                  # arca:bypass-ok=C — compile-time embed.
                  {Path.split(Path.relative_to(file, type_dir)), File.read!(file)}
                end)}
             end)

  @doc """
  The embedded WIT files for an executable component type, as
  `{relative_segments, content}` pairs. An unknown type has none.
  """
  @spec files(atom() | String.t()) :: [{[String.t()], binary()}]
  def files(type) when is_atom(type), do: files(Atom.to_string(type))
  def files(type) when is_binary(type), do: Map.get(@wit_files, type, [])

  # The fully-qualified export names each type's world demands, derived at
  # compile time from the embedded world.wit — `package cyfr:<type>@<ver>`
  # plus each `export <iface>;` line becomes `cyfr:<type>/<iface>@<ver>`.
  # Deriving (not hand-listing) means a WIT edit moves this with it; the
  # runtime's addressing of the same names is pinned by
  # `Cyfr.WasmConventionDriftTest`.
  @expected_exports Map.new(@wit_files, fn {type, files} ->
                      world =
                        case List.keyfind(files, ["world.wit"], 0) do
                          {_, content} ->
                            content

                          nil ->
                            raise "Compendium.WITSource: wit/#{type}/world.wit is missing — " <>
                                    "every executable type declares its world there"
                        end

                      [_, ns, pkg, ver] =
                        Regex.run(~r/^package\s+([a-z0-9-]+):([a-z0-9-]+)@([0-9.]+);/m, world) ||
                          raise("Compendium.WITSource: wit/#{type}/world.wit has no package line")

                      exports =
                        ~r/^\s*export\s+([a-z0-9-]+);/m
                        |> Regex.scan(world, capture: :all_but_first)
                        |> Enum.map(fn [iface] -> "#{ns}:#{pkg}/#{iface}@#{ver}" end)

                      if exports == [] do
                        raise "Compendium.WITSource: wit/#{type}/world.wit exports nothing — " <>
                                "a world with no export is not executable"
                      end

                      {type, exports}
                    end)

  @doc """
  The export names a conforming component of `type` must carry — what the
  type's world declares. `[]` for an unknown or non-executable type.
  """
  @spec expected_exports(atom() | String.t()) :: [String.t()]
  def expected_exports(type) when is_atom(type), do: expected_exports(Atom.to_string(type))
  def expected_exports(type) when is_binary(type), do: Map.get(@expected_exports, type, [])

  @doc """
  The executable type whose world demands this export name, or `nil` —
  the reverse lookup an artifact's parsed exports answer type questions
  with.
  """
  @spec type_for_export(String.t()) :: String.t() | nil
  def type_for_export(export_name) when is_binary(export_name) do
    Enum.find_value(@expected_exports, fn {type, exports} ->
      if export_name in exports, do: type
    end)
  end
end
