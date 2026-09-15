# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Archive do
  @moduledoc """
  The tar streams a build's sources enter it in and its outputs leave it
  in. Both are built and read in memory.

  ## arca:bypass-ok=D — entire module

  `:erl_tar` writes to a RAM file and reads from a binary; no path on disk
  is opened.

  An output archive is written by the build and is untrusted: only its
  regular files are read, each name must be a safe relative path
  (`Cyfr.PathSafety`), and the caller bounds the bytes it hands in.
  """

  @doc "A tar archive of `files` (`%{relative_path => content}`), in path order."
  @spec pack(%{String.t() => binary()}) :: {:ok, binary()} | {:error, term()}
  def pack(files) when is_map(files) do
    {:ok, fd} = :file.open(<<>>, [:ram, :read, :write, :binary])

    try do
      with {:ok, tar} <- :erl_tar.init(fd, :write, &ram_access/2),
           :ok <- add_all(tar, files),
           :ok <- :erl_tar.close(tar),
           {:ok, size} <- :file.position(fd, :eof),
           {:ok, bytes} <- :file.pread(fd, 0, size) do
        {:ok, bytes}
      end
    after
      :file.close(fd)
    end
  end

  defp add_all(tar, files) do
    files
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {path, content}, :ok ->
      case :erl_tar.add(tar, content, String.to_charlist(path), []) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:pack_failed, path, reason}}}
      end
    end)
  end

  defp ram_access(:write, {fd, data}), do: :file.write(fd, data)
  defp ram_access(:position, {fd, position}), do: :file.position(fd, position)
  defp ram_access(:close, _fd), do: :ok

  @doc """
  The regular files of an output archive, `%{name => content}`, and the
  names of the entries that were not regular files (directories excluded).
  An empty binary is an empty archive. More than `max_files` regular files,
  an unreadable archive or an unsafe name is refused.
  """
  @spec unpack(binary(), pos_integer()) ::
          {:ok, %{String.t() => binary()}, [String.t()]}
          | {:error,
             {:too_many_files, pos_integer()} | {:unsafe_path, String.t()} | {:unreadable, term()}}
  def unpack(<<>>, _max_files), do: {:ok, %{}, []}

  def unpack(archive, max_files) when is_binary(archive) do
    with {:ok, table} <- read(:erl_tar.table({:binary, archive}, [:verbose])),
         {regular, skipped} = Enum.split_with(table, &(elem(&1, 1) == :regular)),
         :ok <- within(length(regular), max_files),
         {:ok, entries} <- read(:erl_tar.extract({:binary, archive}, [:memory])),
         {:ok, files} <- named(entries) do
      skipped = for {name, type, _, _, _, _, _} <- skipped, type != :directory, do: to_name(name)
      {:ok, files, skipped}
    end
  end

  defp read({:ok, value}), do: {:ok, value}
  defp read({:error, reason}), do: {:error, {:unreadable, reason}}

  defp within(count, max) when count > max, do: {:error, {:too_many_files, max}}
  defp within(_count, _max), do: :ok

  defp named(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {name, content}, {:ok, acc} ->
      name = to_name(name)

      case is_binary(name) and Cyfr.PathSafety.validate_relative_path(name) do
        :ok -> {:cont, {:ok, Map.put(acc, name, content)}}
        _ -> {:halt, {:error, {:unsafe_path, inspect(name)}}}
      end
    end)
  end

  defp to_name(name) do
    case :unicode.characters_to_binary(name) do
      binary when is_binary(binary) -> binary
      _ -> nil
    end
  end
end
