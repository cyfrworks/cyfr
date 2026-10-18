# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.TreeDeleteCasTest do
  use ExUnit.Case, async: false

  alias Arca.Adapters.Local

  @holding {Local, :holding, 2}
  @rename {Local, :write_via_rename, 2}

  setup do
    previous = Application.fetch_env!(:arca, :base_path)
    base = Path.join(System.tmp_dir!(), "tree_delete_cas_#{System.unique_integer([:positive])}")

    # Registered before mutation; worker cleanup callbacks are registered
    # later and therefore run before the fixture and trace patterns go.
    on_exit(fn ->
      Application.put_env(:arca, :base_path, previous)
      File.rm_rf!(base)
    end)

    on_exit(fn ->
      :erlang.trace_pattern(@holding, false, [:local])
      :erlang.trace_pattern(@rename, false, [:local])
    end)

    Application.put_env(:arca, :base_path, base)
    Code.ensure_loaded!(Local)
    1 = :erlang.trace_pattern(@holding, true, [:local])
    1 = :erlang.trace_pattern(@rename, true, [:local])

    {:ok, actor: Arca.Test.Actor.local()}
  end

  test "a tree delete cannot invalidate a CAS on a file created after its leaf snapshot", %{
    actor: actor
  } do
    dir = ["aqua", "skills", "new-leaf"]
    first = dir ++ ["a.md"]
    added = dir ++ ["b.md"]
    :ok = Local.put(actor, first, "existing")
    physical_first = Local.build_path(actor, first)
    held = {{Local, physical_first}, self()}
    assert :global.set_lock(held, [node()], 0)

    try do
      deletion = worker(:deleted, fn -> Local.delete_tree(actor, dir) end, trace: true)

      # This call happens after enumeration, while A's lock prevents the
      # deletion from advancing. No timing guess determines the snapshot.
      assert_receive {:trace, ^deletion, :call, {Local, :holding, [[^physical_first], _fun]}},
                     5_000

      worker(:created, fn -> Local.put(actor, added, "original") end)

      receive do
        {:created, :ok} ->
          check_cas_after_snapshot(actor, dir, added, held)
      after
        500 ->
          # A fix may serialize creation itself behind the tree operation.
          # That order is valid and must not deadlock this regression.
          :global.del_lock(held, [node()])
          assert_receive {:deleted, :ok}, 5_000
          assert_receive {:created, :ok}, 5_000
          assert {:ok, "original"} = Local.get(actor, added)
      end
    after
      :global.del_lock(held, [node()])
    end
  end

  defp check_cas_after_snapshot(actor, dir, added, held) do
    writer = park_cas(actor, added, 20)
    :global.del_lock(held, [node()])

    receive do
      {:deleted, :ok} ->
        observed_after_delete = Local.get(actor, added)
        assert {:error, :not_found} = observed_after_delete

        # Recreate only the parent, using another supported adapter write.
        # This makes a CAS that already completed mkdir_p able to perform
        # its rename; it does not recreate B or satisfy B's precondition.
        :ok = Local.put(actor, dir ++ ["c.md"], "later independent file")
        assert {:error, :not_found} = Local.get(actor, added)
        true = :erlang.resume_process(writer)
        assert_receive {:cas, answer}, 5_000
        final = Local.get(actor, added)

        assert match?({:error, _reason}, answer),
               "CAS accepted a precondition whose object the completed deletion had removed: " <>
                 inspect(%{after_delete: observed_after_delete, cas: answer, final: final})

        assert {:error, :not_found} = final
    after
      500 ->
        # A fix may discover and wait for B's CAS before deleting it.
        true = :erlang.resume_process(writer)
        assert_receive {:cas, {:ok, _precondition}}, 5_000
        assert_receive {:deleted, :ok}, 5_000
        assert {:error, :not_found} = Local.get(actor, added)
    end
  end

  # A trace notification alone does not prove where the worker stopped.
  # Accept it only while its stack is still before File.write, it holds
  # the file lock, and the target still contains the precondition bytes.
  # Retry a missed setup window, always finishing that worker first.
  defp park_cas(_actor, _path, 0), do: flunk("could not establish the bounded CAS pause")

  defp park_cas(actor, path, tries) do
    :ok = Local.put(actor, path, "original")
    {:ok, "original", precondition} = Local.get_for_update(actor, path)

    writer =
      worker(:cas, fn -> Local.put_if_match(actor, path, "edited", precondition) end, trace: true)

    assert_receive {:trace, ^writer, :call, {Local, :write_via_rename, [_physical, "edited"]}},
                   5_000

    suspended =
      try do
        :erlang.suspend_process(writer)
      catch
        :error, :badarg -> false
      end

    if suspended and before_content_write?(writer) and owns_file_lock?(actor, path) and
         Local.get(actor, path) == {:ok, "original"} do
      writer
    else
      if suspended, do: :erlang.resume_process(writer)
      assert_receive {:cas, _answer}, 5_000
      park_cas(actor, path, tries - 1)
    end
  end

  defp before_content_write?(writer) do
    # Read the owning source's call site rather than pinning a line number
    # that changes when the writer adopts this regression.
    source = Path.expand("../../../lib/arca/adapters/local.ex", __DIR__)

    write_line =
      source
      |> File.read!()
      |> String.split("\n")
      |> Enum.find_index(&String.contains?(&1, "case File.write(tmp_path, content) do"))
      |> Kernel.+(1)

    case Process.info(writer, :current_stacktrace) do
      {:current_stacktrace, stack} ->
        Enum.any?(stack, fn
          {Local, :write_via_rename, 2, location} ->
            line = Keyword.get(location, :line, write_line)
            line < write_line

          _ ->
            false
        end)

      _ ->
        false
    end
  end

  defp owns_file_lock?(actor, path) do
    id = {{Local, Local.build_path(actor, path)}, self()}

    if :global.set_lock(id, [node()], 0) do
      :global.del_lock(id, [node()])
      false
    else
      true
    end
  end

  defp worker(tag, fun, opts \\ []) do
    test = self()

    pid =
      spawn(fn ->
        receive do
          :go -> send(test, {tag, fun.()})
        end
      end)

    on_exit(fn ->
      ref = Process.monitor(pid)
      if Process.alive?(pid), do: Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> flunk("a worker failed to stop")
      end
    end)

    if opts[:trace], do: :erlang.trace(pid, true, [:call, {:tracer, test}])
    send(pid, :go)
    pid
  end
end
