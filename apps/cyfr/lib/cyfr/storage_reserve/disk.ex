# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# arca:bypass-ok=D — entire module: a filesystem's free space and the
# reserve file's allocation are OS facilities no storage adapter offers,
# on the host's own directory, outside every athanor's tree.
defmodule Cyfr.StorageReserve.Disk do
  @moduledoc """
  The filesystem as the storage reserve (`Cyfr.StorageReserve`) reads and
  holds it: a filesystem's free space, and the reserve file's allocation.
  A test stands another module with the same two functions in its place.

  The free space is what an unprivileged writer may still use (statvfs's
  `f_bavail` blocks of `f_frsize` bytes). The runtime has no statvfs of
  its own, so it is read through GNU `stat -f`, which asks statvfs of the
  path itself, and, where that `stat` is not GNU's, POSIX `df -P -k`,
  which finds the path's filesystem in the mount table. A reading that
  does not answer within 2 s is an error, as a hung filesystem is one the
  home cannot count on.
  """

  @callback free_bytes(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback allocate(Path.t(), pos_integer()) :: :ok | {:error, term()}

  @behaviour __MODULE__

  @read_ms 2_000
  @chunk 1024 * 1024

  @doc "The bytes an unprivileged writer may still use on `path`'s filesystem."
  @impl true
  def free_bytes(path) when is_binary(path) do
    with {:error, _not_gnu} <- run("stat", ["-f", "-c", "%a %S", path], &blocks/1),
         do: run("df", ["-P", "-k", path], &available/1)
  end

  defp run(command, args, parse) do
    case System.find_executable(command) do
      nil -> {:error, :unread}
      executable -> read(executable, args, parse)
    end
  end

  defp read(executable, args, parse) do
    task =
      Task.async(fn ->
        System.cmd(executable, args,
          env: [{"LC_ALL", "C"}, {"POSIXLY_CORRECT", "1"}],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, @read_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> parse.(output)
      {:ok, {_output, _status}} -> {:error, :unread}
      _late_or_dead -> {:error, :unread}
    end
  end

  # `stat -f -c "%a %S"`: the available blocks and the block size.
  defp blocks(output) do
    case Regex.run(~r/\A(\d+) (\d+)\n?\z/, output) do
      [_, available, size] -> {:ok, String.to_integer(available) * String.to_integer(size)}
      _ -> {:error, :unread}
    end
  end

  # The one filesystem line under `df -P`'s header: its total, used and
  # available 1024-byte blocks, then its capacity. A filesystem or mount
  # point name may hold spaces, so the numbers are found by their shape.
  defp available(output) do
    with [_header, line | _] <- String.split(output, "\n", trim: true),
         [_, available] <- Regex.run(~r/\s\d+\s+\d+\s+(\d+)\s+(?:\d+|-)%\s/, line) do
      {:ok, String.to_integer(available) * 1024}
    else
      _ -> {:error, :unread}
    end
  end

  @doc """
  Make `file` exactly `bytes` long with every block allocated, and sync
  it: `:file.allocate/3`, or, on a filesystem that offers no allocation,
  the bytes written as zeros. An existing file is kept and allocated in
  place.
  """
  @impl true
  def allocate(file, bytes) when is_binary(file) and is_integer(bytes) and bytes > 0 do
    case :file.open(file, [:read, :write, :raw, :binary]) do
      {:ok, fd} ->
        try do
          with :ok <- reserve(fd, bytes),
               {:ok, ^bytes} <- :file.position(fd, bytes),
               :ok <- :file.truncate(fd),
               do: :file.sync(fd)
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reserve(fd, bytes) do
    case :file.allocate(fd, 0, bytes) do
      {:error, :enotsup} -> zeros(fd, 0, bytes)
      other -> other
    end
  end

  defp zeros(_fd, at, bytes) when at >= bytes, do: :ok

  defp zeros(fd, at, bytes) do
    size = min(@chunk, bytes - at)

    case :file.pwrite(fd, at, :binary.copy(<<0>>, size)) do
      :ok -> zeros(fd, at + size, bytes)
      {:error, reason} -> {:error, reason}
    end
  end
end
