# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.LocalWriteLockTest do
  @moduledoc """
  Every writer of a file goes through the Local adapter's lock on that
  file: a plain put, a tree swap and a tree delete each wait for a
  conditional replace that has read its precondition, so the replace's
  read and its rename are one step against every writer, and a reset
  that lands after an edit is what readers keep.

  The replace that owns the lock lands, then the writer that waited for
  it. The replace is parked under the file's lock, at its first call to
  the VM's file server, the precondition's read, by suspending the file
  server before the replace starts: it takes the lock, which asks the
  file server nothing, and stops at its next file operation, wherever the
  schedule puts it, until the file server is resumed. While it is
  suspended the test reads files through `:prim_file`, which does not ask
  the file server.
  """

  use ExUnit.Case, async: false

  alias Arca.Adapters.Local

  @base Path.join(System.tmp_dir!(), "arca_write_lock_#{System.unique_integer([:positive])}")

  setup do
    prev_base = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, @base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      File.rm_rf!(@base)
    end)

    {:ok, actor: Arca.Test.Actor.local()}
  end

  # A conditional replace of `path` with `bytes`, in a process of its own,
  # parked under the file's lock at its first file operation: the file
  # server is suspended before it starts. Answers what `resume/1` takes.
  defp park_replace(actor, path, bytes, precondition) do
    test = self()
    server = Process.whereis(:file_server_2)

    # Registered before the suspend: the file server is the whole VM's.
    on_exit(fn -> resume_file_server(server) end)
    true = :erlang.suspend_process(server)

    writer =
      spawn(fn ->
        send(test, {:replaced, self(), Local.put_if_match(actor, path, bytes, precondition)})
      end)

    on_exit(fn -> if Process.alive?(writer), do: Process.exit(writer, :kill) end)

    # The replace holds the file's lock, and every other writer of the file
    # waits for it; it cannot have read the file or written anything, since
    # each needs the file server.
    Prima.Test.Wait.wait_until(
      fn -> owns_file_lock?(actor, path) end,
      5_000,
      "the replace's lock"
    )

    %{writer: writer, server: server, physical: Local.build_path(actor, path)}
  end

  # The bytes at the parked replace's path, read past the suspended file
  # server.
  defp parked_bytes(%{physical: physical}), do: :prim_file.read_file(physical)

  # Resumes the file server, which lets the replace read, rename and answer,
  # and answers what it answered.
  defp resume(%{writer: writer, server: server}) do
    resume_file_server(server)
    assert_receive {:replaced, ^writer, answer}, 5_000
    answer
  end

  defp resume_file_server(server) do
    :erlang.resume_process(server)
  catch
    # Not suspended by this test any more.
    :error, :badarg -> :ok
  end

  # Whether another process holds `path`'s file lock (`Local`'s own lock
  # name): this process cannot take it.
  defp owns_file_lock?(actor, path) do
    id = {{Local, Local.build_path(actor, path)}, self()}

    if :global.set_lock(id, [node()], 0) do
      :global.del_lock(id, [node()])
      false
    else
      true
    end
  end

  # `fun` in a process of its own, reporting its answer as `{tag, answer}`.
  defp concurrently(tag, fun) do
    test = self()
    spawn_link(fn -> send(test, {tag, fun.()}) end)
  end

  test "a plain put waits for a conditional replace that has read its precondition, and " <>
         "lands after it",
       %{actor: actor} do
    path = ["aqua", "roles", "a.md"]
    :ok = Local.put(actor, path, "original")
    {:ok, "original", precondition} = Local.get_for_update(actor, path)

    parked = park_replace(actor, path, "original+edit", precondition)

    # The reset cannot land while the replace holds the file's lock, before
    # it has read its precondition or renamed its bytes into place.
    concurrently(:reset, fn -> Local.put(actor, path, "reset") end)
    refute_receive {:reset, _}, 300
    assert {:ok, "original"} = parked_bytes(parked)

    assert {:ok, _precondition} = resume(parked)
    assert_receive {:reset, :ok}, 5_000
    assert {:ok, "reset"} = Local.get(actor, path)
  end

  test "a tree swap waits for a conditional replace of a file inside the tree, and installs " <>
         "its own tree after it",
       %{actor: actor} do
    dir = ["aqua", "skills", "s"]
    file = dir ++ ["SKILL.md"]
    :ok = Local.put(actor, file, "original")
    :ok = Local.put(actor, dir ++ ["notes.md"], "notes")
    {:ok, "original", precondition} = Local.get_for_update(actor, file)

    parked = park_replace(actor, file, "original+edit", precondition)

    concurrently(:reset, fn ->
      Local.replace_tree(actor, dir, [{["SKILL.md"], "reset"}, {["other.md"], "other"}])
    end)

    refute_receive {:reset, _}, 300
    assert {:ok, "original"} = parked_bytes(parked)

    assert {:ok, _precondition} = resume(parked)
    assert_receive {:reset, :ok}, 5_000
    assert {:ok, "reset"} = Local.get(actor, file)
    assert {:ok, "other"} = Local.get(actor, dir ++ ["other.md"])
    assert {:error, :not_found} = Local.get(actor, dir ++ ["notes.md"])
  end

  test "a tree delete waits for a conditional replace of a file inside the tree, and leaves " <>
         "nothing of it",
       %{actor: actor} do
    dir = ["aqua", "skills", "t"]
    file = dir ++ ["SKILL.md"]
    :ok = Local.put(actor, file, "original")
    {:ok, "original", precondition} = Local.get_for_update(actor, file)

    parked = park_replace(actor, file, "original+edit", precondition)

    concurrently(:delete, fn -> Local.delete_tree(actor, dir) end)
    refute_receive {:delete, _}, 300
    assert {:ok, "original"} = parked_bytes(parked)

    assert {:ok, _precondition} = resume(parked)
    assert_receive {:delete, :ok}, 5_000
    assert {:error, :not_found} = Local.get(actor, file)
    assert {:ok, []} = Local.list_recursive(actor, dir)
  end

  test "a conditional replace that waited for a plain put reads what the put wrote", %{
    actor: actor
  } do
    path = ["aqua", "roles", "b.md"]
    :ok = Local.put(actor, path, "original")
    {:ok, "original", stale} = Local.get_for_update(actor, path)
    :ok = Local.put(actor, path, "reset")

    assert {:error, :precondition_failed} = Local.put_if_match(actor, path, "edit", stale)
    assert {:ok, "reset", fresh} = Local.get_for_update(actor, path)
    assert {:ok, _} = Local.put_if_match(actor, path, "reset+edit", fresh)
    assert {:ok, "reset+edit"} = Local.get(actor, path)
  end
end
