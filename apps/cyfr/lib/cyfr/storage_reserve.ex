# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# arca:bypass-ok=D — entire module: the reserve's directory and its file
# are the host's own, outside every athanor's tree and every adapter.
defmodule Cyfr.StorageReserve do
  @moduledoc """
  The home's storage reserve (`ARCHITECTURE.md` §6.9): headroom kept so a
  home that runs out of space can still take authority away.

  At boot, before the gate opens, it checks the reserve's directory
  (`storage_reserve_path`), keeps the reserve file there,
  `storage_reserve_bytes` long, and derives the latch
  (`Arca.StorageReserve`); then every 5 s it reads the free space of that
  directory's filesystem and of each local storage root. While the latch
  reads `depleted`, Arca refuses new bytes in an athanor's tree, the
  decision log writes nothing, and the gate admits only reads, the
  operations declared `reduces_authority` and their confirmations.

  ## The latch

    * **`ok`** while every filesystem it reads has at least
      `storage_reserve_bytes` free. When one falls below that mark, or a
      reading fails, the latch turns `depleted` first and the file is
      deleted after, so the space it held is there for a revocation and
      the log or WAL growth its commit causes.
    * **`depleted`** until the file is allocated again and synced, which
      is tried only once every filesystem has more than the mark plus the
      reserve free: the space the freed file gave back never reads as
      headroom, so the polls after the free stay `depleted`. A failed
      allocation stays `depleted`.

  Nothing stores the latch; each boot derives it. A file of the reserve's
  size present at boot means the home held its reserve: it is allocated
  again in place, a no-op for one already allocated, and the latch is
  `ok` when every reading is at the mark. Without the file — the latch
  freed it, or it was never made — the boot takes the `depleted` rule:
  the file is made, and the latch is `ok`, only above the mark plus the
  reserve. So a restart while `depleted` stays `depleted` until space is
  freed, and a crash that lost the file's directory entry (no directory
  is synced) reads as no file, never as a reserve held. A boot below the
  mark, or one whose reading fails, is `depleted`.

  Without a directory — PostgreSQL with none set — no file is kept and
  the local storage roots alone are read, with the same mark and the same
  way back; with no local root either, nothing is read and the latch is
  `ok`. A database volume the reserve does not share and an S3 store are
  outside it, the stated limits. So is a burst of authority-reducing
  writes larger than the reserve: a revocation whose commit then fails
  does not take effect and is answered as the store's failure
  (`:database_error`, refused as unavailable). Retained object
  generations, stored execution payloads and the decision audit have no
  byte ceiling, since their retention is by age (`Arca.Retention`).

  ## The boot's refusals

  The directory, set or the SQLite default, must exist, be writable and
  report its free space, or `init/1` stops with
  `{:storage_reserve_path, reason}` and the boot is refused. A reading
  that fails later is `depleted`, never a crash: a restart of this child
  restarts everything the infrastructure tier starts after it.
  """

  use GenServer

  require Logger

  @poll_ms 5_000
  @file_name "cyfr-storage-reserve"

  @typedoc "Why the boot refused the reserve's directory."
  @type refusal :: :not_found | :not_writable | :no_free_space_reading

  @doc """
  Start the monitor. Every option defaults to this member's configuration:
  `:bytes` (`storage_reserve_bytes`), `:directory`
  (`storage_reserve_path`, nil for none), `:roots`
  (`Arca.StorageReserve.local_roots/0`), `:disk` (the filesystem's
  module, `Cyfr.StorageReserve.Disk`), `:interval` (5 s; `:infinity`
  polls only on `poll/1`) and `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The reserve file's path in `directory`."
  @spec file(Path.t()) :: Path.t()
  def file(directory), do: Path.join(directory, @file_name)

  @doc "Read the free space now and settle the latch, answering it."
  @spec poll(GenServer.server()) :: Arca.StorageReserve.state()
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll)

  @impl true
  def init(opts) do
    state = %{
      bytes: Keyword.get_lazy(opts, :bytes, &configured_bytes/0),
      directory: Keyword.get_lazy(opts, :directory, &configured_directory/0),
      roots: Keyword.get_lazy(opts, :roots, &Arca.StorageReserve.local_roots/0),
      disk: Keyword.get(opts, :disk, Cyfr.StorageReserve.Disk),
      interval: Keyword.get(opts, :interval, @poll_ms),
      latch: nil
    }

    case check_directory(state) do
      :ok ->
        state = boot(state)
        schedule(state)
        {:ok, state}

      {:error, reason} ->
        Logger.error(
          "[Cyfr.StorageReserve] the storage reserve's directory #{state.directory} " <>
            "(CYFR_STORAGE_RESERVE_PATH) #{refused(reason)}; the boot is refused"
        )

        {:stop, {:storage_reserve_path, reason}}
    end
  end

  @impl true
  def handle_call(:poll, _from, state) do
    state = polled(state)
    {:reply, state.latch, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = polled(state)
    schedule(state)
    {:noreply, state}
  end

  # A stray message is logged by its shape and dropped: a crash here would
  # restart everything the infrastructure tier starts after this child.
  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  defp configured_bytes,
    do:
      Application.get_env(
        :cyfr,
        :storage_reserve_bytes,
        Cyfr.RuntimeConfig.default_storage_reserve_bytes()
      )

  defp configured_directory, do: Application.get_env(:cyfr, :storage_reserve_path)

  defp schedule(%{interval: :infinity}), do: :ok
  defp schedule(%{interval: interval}), do: Process.send_after(self(), :poll, interval)

  # ---------------------------------------------------------------------------
  # The directory, checked once at boot
  # ---------------------------------------------------------------------------

  defp check_directory(%{directory: nil}), do: :ok

  defp check_directory(%{directory: directory, disk: disk}) do
    cond do
      not File.dir?(directory) -> {:error, :not_found}
      not writable?(directory) -> {:error, :not_writable}
      not match?({:ok, _}, disk.free_bytes(directory)) -> {:error, :no_free_space_reading}
      true -> :ok
    end
  end

  # A file can be made there. A filesystem too full to take even an empty
  # file is writable: being full is the reserve's case to handle, not a
  # reason to refuse the boot.
  defp writable?(directory) do
    probe = Path.join(directory, ".#{@file_name}.probe")

    case File.write(probe, "") do
      :ok ->
        _ = File.rm(probe)
        true

      {:error, reason} ->
        reason in [:enospc, :edquot]
    end
  end

  defp refused(:not_found), do: "does not exist"
  defp refused(:not_writable), do: "is not writable"
  defp refused(:no_free_space_reading), do: "does not report its free space"

  # ---------------------------------------------------------------------------
  # The latch
  # ---------------------------------------------------------------------------

  defp boot(state) do
    latch = if held?(state), do: steady(state), else: recover(state)
    settle(state, latch)
  end

  defp polled(%{latch: :ok} = state), do: settle(state, steady(state))
  defp polled(%{latch: :depleted} = state), do: settle(state, recover(state))

  # A reserve file of the reserve's size, allocated again in place. One of
  # another size, or one that cannot be, is removed, and the boot takes the
  # `depleted` rule.
  defp held?(%{directory: nil}), do: false

  defp held?(%{directory: directory, bytes: bytes, disk: disk}) do
    file = file(directory)

    case File.stat(file) do
      {:ok, %File.Stat{type: :regular, size: ^bytes}} ->
        disk.allocate(file, bytes) == :ok or remove(file)

      {:ok, _other} ->
        remove(file)

      {:error, _absent} ->
        false
    end
  end

  # `ok`: every reading at the mark.
  defp steady(state) do
    case lowest(state) do
      :unguarded -> :ok
      {:ok, free} when free >= state.bytes -> :ok
      _below_or_unread -> :depleted
    end
  end

  # `depleted`: every reading above the mark plus the reserve, and the
  # file allocated and synced where there is a directory.
  defp recover(state) do
    case lowest(state) do
      :unguarded -> :ok
      {:ok, free} when free > 2 * state.bytes -> allocate(state)
      _below_or_unread -> :depleted
    end
  end

  defp allocate(%{directory: nil}), do: :ok

  defp allocate(%{directory: directory, bytes: bytes, disk: disk}) do
    file = file(directory)

    case disk.allocate(file, bytes) do
      :ok ->
        :ok

      {:error, _reason} ->
        remove(file)
        :depleted
    end
  end

  # The least free space among the filesystems read, or `:error` when a
  # reading fails; `:unguarded` with nothing to read.
  defp lowest(state) do
    case Enum.uniq(Enum.reject([state.directory | state.roots], &is_nil/1)) do
      [] -> :unguarded
      paths -> Enum.reduce_while(paths, {:ok, nil}, &(read(state.disk, &1) |> lower(&2)))
    end
  end

  defp read(disk, path) do
    disk.free_bytes(path)
  rescue
    _ -> {:error, :unread}
  catch
    _kind, _reason -> {:error, :unread}
  end

  defp lower({:ok, free}, {:ok, nil}) when is_integer(free), do: {:cont, {:ok, free}}

  defp lower({:ok, free}, {:ok, least}) when is_integer(free),
    do: {:cont, {:ok, min(free, least)}}

  defp lower(_unread, _acc), do: {:halt, :error}

  # The latch published first, the file freed after: nothing reads the
  # freed space as headroom while the latch still says `ok`.
  defp settle(state, latch) do
    :ok = Arca.StorageReserve.put(latch)
    if latch == :depleted and state.directory, do: remove(file(state.directory))
    announce(state.latch, latch, state)
    %{state | latch: latch}
  end

  defp remove(file) do
    _ = File.rm(file)
    false
  end

  defp announce(same, same, _state), do: :ok

  defp announce(_was, :depleted, state) do
    Logger.error(
      "[Cyfr.StorageReserve] free space is below the storage reserve's mark of " <>
        "#{state.bytes} bytes, or could not be read: the home admits only reads and " <>
        "changes that take authority away until more than twice that is free"
    )
  end

  defp announce(nil, :ok, _state), do: :ok

  defp announce(:depleted, :ok, _state) do
    Logger.warning(
      "[Cyfr.StorageReserve] the storage reserve is held again: the home admits all work"
    )
  end
end
