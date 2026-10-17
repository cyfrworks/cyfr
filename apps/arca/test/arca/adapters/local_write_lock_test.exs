# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.LocalWriteLockTest do
  @moduledoc """
  Every writer of a file goes through the Local adapter's lock on that
  file: a plain put, a tree swap and a tree delete each wait for a
  conditional replace that has read its precondition, so the replace's
  read and its rename are one step against every writer, and a reset
  that lands after an edit is what readers keep.

  Adopts Astra's Local CAS probe of 2026-10-17, in the legal order: the
  replace that owns the lock lands, then the writer that waited for it.
  The replace is parked between its precondition read and its rename by
  tracing the adapter's private rename helper in the replace's process
  and suspending it there.
  """

  use ExUnit.Case, async: false

  alias Arca.Adapters.Local

  @base Path.join(System.tmp_dir!(), "arca_write_lock_#{System.unique_integer([:positive])}")
  @rename {Local, :write_via_rename, 2}

  setup do
    prev_base = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, @base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      File.rm_rf!(@base)
    end)

    # Call tracing of the rename helper, on the replace's process alone;
    # the pattern is the VM's and is restored first. The pattern matches
    # only a loaded module.
    on_exit(fn -> :erlang.trace_pattern(@rename, false, [:local]) end)
    Code.ensure_loaded!(Local)
    1 = :erlang.trace_pattern(@rename, true, [:local])

    {:ok, actor: Arca.Test.Actor.local()}
  end

  # A conditional replace of `path` with `bytes`, in a process of its own,
  # suspended after it has read the precondition and before it renames
  # its bytes into place. Answers the process; `resume/1` lets it finish
  # and answers what the replace answered.
  defp park_replace(actor, path, bytes, precondition) do
    test = self()

    writer =
      spawn(fn ->
        receive do
          :go ->
            send(test, {:replaced, self(), Local.put_if_match(actor, path, bytes, precondition)})
        end
      end)

    on_exit(fn -> if Process.alive?(writer), do: Process.exit(writer, :kill) end)
    1 = :erlang.trace(writer, true, [:call, {:tracer, test}])
    send(writer, :go)

    assert_receive {:trace, ^writer, :call, {Local, :write_via_rename, [_physical, ^bytes]}},
                   5_000

    true = :erlang.suspend_process(writer)
    writer
  end

  defp resume(writer) do
    true = :erlang.resume_process(writer)
    assert_receive {:replaced, ^writer, answer}, 5_000
    answer
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

    writer = park_replace(actor, path, "original+edit", precondition)

    # The reset cannot land between the replace's read and its rename.
    concurrently(:reset, fn -> Local.put(actor, path, "reset") end)
    refute_receive {:reset, _}, 300
    assert {:ok, "original"} = Local.get(actor, path)

    assert {:ok, _precondition} = resume(writer)
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

    writer = park_replace(actor, file, "original+edit", precondition)

    concurrently(:reset, fn ->
      Local.replace_tree(actor, dir, [{["SKILL.md"], "reset"}, {["other.md"], "other"}])
    end)

    refute_receive {:reset, _}, 300
    assert {:ok, "original"} = Local.get(actor, file)

    assert {:ok, _precondition} = resume(writer)
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

    writer = park_replace(actor, file, "original+edit", precondition)

    concurrently(:delete, fn -> Local.delete_tree(actor, dir) end)
    refute_receive {:delete, _}, 300
    assert {:ok, "original"} = Local.get(actor, file)

    assert {:ok, _precondition} = resume(writer)
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
