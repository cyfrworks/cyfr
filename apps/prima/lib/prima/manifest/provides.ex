# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Manifest.Provides do
  @moduledoc """
  The manifest `provides` block: a publisher's public configuration for a
  need of one of its dependencies, so the person approving the app is
  shown that need as satisfied by the publisher rather than asked for an
  entry.

  ## Shape

      "provides": {
        "catalyst:local.supabase": {
          "database": {
            "destination": {"hosts": ["abc.supabase.co"], "paths": ["/rest/v1"]},
            "values": {"anon_key": "eyJ..."}
          }
        }
      }

  Keyed by the dependency's reference, exactly as `dependencies.static`
  names it, then by the dependency's need name (the need-name grammar of
  `Prima.Manifest.Needs`). Each entry is exactly `destination`, in
  `Prima.Destination`'s grammar (methods and paths optional), and
  `values`, a map of non-empty string names to string values whose names
  and values together span at most `max_values_bytes/0` bytes.

  A dependency the manifest's `dependencies.static` does not name is
  refused. Whether the dependency declares the need is not knowable from
  this manifest alone: the registry checks it at publish.

  The values are public by the publisher's declaration: attached and read
  alike. A change to them or their destination changes the consent's
  shape.
  """

  alias Prima.Destination

  @need_name ~r/^[a-z][a-z0-9_-]{0,31}$/
  @max_values_bytes 4096

  @type entry :: %{destination: Destination.t(), values: %{String.t() => String.t()}}
  @type t :: %{String.t() => %{String.t() => entry()}}
  @type error :: {:invalid_provides, term()}

  @doc "The most bytes a provided entry's value names and values span together."
  @spec max_values_bytes() :: pos_integer()
  def max_values_bytes, do: @max_values_bytes

  @doc "Validate a decoded manifest's `provides` block. Absent is valid."
  @spec validate(map() | nil) :: :ok | {:error, error()}
  def validate(manifest) do
    with {:ok, _provides} <- read(manifest), do: :ok
  end

  @doc """
  The normalized `provides` block: dependency reference to need name to
  `%{destination, values}`, the destination a `Prima.Destination`. `nil`
  when the manifest declares none or the block does not read.
  """
  @spec from_manifest(map() | nil) :: t() | nil
  def from_manifest(%{"provides" => _} = manifest) do
    case read(manifest) do
      {:ok, provides} -> provides
      {:error, _reason} -> nil
    end
  end

  def from_manifest(_manifest), do: nil

  @doc """
  One provided entry from its map, `%{"destination", "values"}`, or why
  it is refused. The shape a consent edge carries the entry in reads it
  too.
  """
  @spec read_entry(term()) :: {:ok, entry()} | {:error, term()}
  def read_entry(%{"destination" => destination, "values" => values} = raw)
      when map_size(raw) == 2 do
    with {:ok, destination} <- Destination.from_map(destination),
         :ok <- check_values(values) do
      {:ok, %{destination: destination, values: values}}
    end
  end

  def read_entry(%{} = raw) when not is_struct(raw) do
    case Map.keys(raw) -- ["destination", "values"] do
      [] -> {:error, :destination_and_values_required}
      unknown -> {:error, {:unknown_keys, Enum.sort(unknown)}}
    end
  end

  def read_entry(_raw), do: {:error, :not_a_map}

  @doc "Whether `values` is a provided entry's values: string names to strings, within the bound."
  @spec valid_values?(term()) :: boolean()
  def valid_values?(values), do: check_values(values) == :ok

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  defp read(nil), do: {:ok, %{}}

  defp read(%{"provides" => provides} = manifest) when is_map(provides) do
    declared = static_refs(manifest)

    provides
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {dependency, needs}, {:ok, acc} ->
      case read_dependency(dependency, needs, declared) do
        {:ok, entries} -> {:cont, {:ok, Map.put(acc, dependency, entries)}}
        {:error, reason} -> {:halt, {:error, {:invalid_provides, reason}}}
      end
    end)
  end

  defp read(%{"provides" => other}), do: {:error, {:invalid_provides, {:not_a_map, other}}}
  defp read(manifest) when is_map(manifest), do: {:ok, %{}}

  defp read_dependency(dependency, needs, declared) do
    cond do
      not (is_binary(dependency) and dependency in declared) ->
        {:error, {:undeclared_dependency, dependency}}

      not is_map(needs) or needs == %{} ->
        {:error, {:no_needs, dependency}}

      true ->
        needs
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce_while({:ok, %{}}, fn {need, raw}, {:ok, acc} ->
          with true <- is_binary(need) and Regex.match?(@need_name, need),
               {:ok, entry} <- read_entry(raw) do
            {:cont, {:ok, Map.put(acc, need, entry)}}
          else
            false -> {:halt, {:error, {:invalid_need, dependency, need}}}
            {:error, reason} -> {:halt, {:error, {:invalid_entry, dependency, need, reason}}}
          end
        end)
    end
  end

  # The references `dependencies.static` names, as strings or `{"ref"}`
  # objects; a malformed block names none, and `Prima.Manifest.validate/2`
  # refuses it on its own.
  defp static_refs(%{"dependencies" => %{"static" => static}}) when is_list(static),
    do: Enum.flat_map(static, &static_ref/1)

  defp static_refs(_manifest), do: []

  defp static_ref(ref) when is_binary(ref), do: [ref]
  defp static_ref(%{"ref" => ref}) when is_binary(ref), do: [ref]
  defp static_ref(_entry), do: []

  defp check_values(values) when is_map(values) and not is_struct(values) do
    cond do
      not Enum.all?(values, fn {name, value} ->
        is_binary(name) and name != "" and is_binary(value) and String.valid?(name) and
            String.valid?(value)
      end) ->
        {:error, :values_not_strings}

      values_bytes(values) > @max_values_bytes ->
        {:error, :values_too_large}

      true ->
        :ok
    end
  end

  defp check_values(_values), do: {:error, :values_not_strings}

  defp values_bytes(values),
    do:
      Enum.reduce(values, 0, fn {name, value}, sum -> sum + byte_size(name) + byte_size(value) end)
end
