# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ComponentPath do
  @moduledoc """
  The component tree's layout, as every side that names a version
  directory agrees on it:

      components/{type}s/{publisher}/{name}/{version}/

  The segments are tenant-relative — which athanor's tree they land in is
  decided by the actor handed to `Arca`, never by the path — so the shape
  is data two sides share and nothing more. The component domain spells it
  `Compendium.ComponentPath`, which adds the parsing, the artifact names
  and the unit locator and delegates the shape here; the identity domain
  reads it here to say which directory a consent or a tincture grant
  covers.

  Vocabulary note: paths and the components table say `publisher`;
  references and identity (`Prima.ComponentRef`) say `namespace` — the
  SAME value under two names, one per vocabulary. `normalize_publisher/1`
  and `default_publisher/0` are the bridge.
  """

  @default_publisher "local"
  @components_root "components"

  @doc ~s|Root prefix segments: `["components"]` — the context's athanor's tree.|
  @spec base_prefix() :: [String.t()]
  def base_prefix, do: [@components_root]

  @doc """
  The default publisher segment — the `local` namespace every
  locally-built and bundled component ships under. The one spelling;
  callers that need the literal read it here.

  ## Examples

      iex> Prima.ComponentPath.default_publisher()
      "local"

  """
  @spec default_publisher() :: String.t()
  def default_publisher, do: @default_publisher

  @doc """
  Canonical publisher segment default. `nil`/`""` collapse to the seeded
  `local` namespace, so a component's path and its id never disagree
  about an absent publisher.

  ## Examples

      iex> Prima.ComponentPath.normalize_publisher(nil)
      "local"

      iex> Prima.ComponentPath.normalize_publisher("moonmoon69")
      "moonmoon69"

  """
  @spec normalize_publisher(String.t() | nil) :: String.t()
  def normalize_publisher(publisher) when is_binary(publisher) and publisher != "", do: publisher
  def normalize_publisher(_), do: @default_publisher

  @doc """
  Whether a publisher segment names the local namespace — the
  highest-trust namespace, which only locally-built and bundled
  components may enter.

  ## Examples

      iex> Prima.ComponentPath.local_publisher?("local")
      true

      iex> Prima.ComponentPath.local_publisher?("moonmoon69")
      false

      iex> Prima.ComponentPath.local_publisher?(nil)
      true

  """
  @spec local_publisher?(String.t() | nil) :: boolean()
  def local_publisher?(publisher), do: normalize_publisher(publisher) == @default_publisher

  @doc """
  The plural directory name for a component type — the one
  pluralization rule.

  ## Examples

      iex> Prima.ComponentPath.type_plural("catalyst")
      "catalysts"

  """
  @spec type_plural(String.t()) :: String.t()
  def type_plural(type) when is_binary(type), do: type <> "s"

  @doc """
  The inverse of `type_plural/1` — the one de-pluralization, so the OCI
  repository convention and the on-disk layout cannot each spell it.

  ## Examples

      iex> Prima.ComponentPath.singular("catalysts")
      "catalyst"

  """
  @spec singular(String.t()) :: String.t()
  def singular(type_plural) when is_binary(type_plural),
    do: String.trim_trailing(type_plural, "s")

  @doc """
  Path segments to a component version directory — the shadow unit an
  overlay classifies and a consent covers.

  ## Examples

      iex> Prima.ComponentPath.version_dir("tincture", nil, "widget", "1.0.0")
      ["components", "tinctures", "local", "widget", "1.0.0"]

  """
  @spec version_dir(String.t(), String.t() | nil, String.t(), String.t()) :: [String.t()]
  def version_dir(type, publisher, name, version) do
    base_prefix() ++ [type_plural(type), normalize_publisher(publisher), name, version]
  end
end
