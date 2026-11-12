# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TestSeamsTest do
  # The host's test seams are read only by a build compiled with the test
  # permission (`:cyfr, :test_seams_permitted`): a release, compiled
  # without it, answers each seam's shipped default and never reads the
  # key (`Cyfr.seam/2`). Async: it reads source files and sets nothing.
  use ExUnit.Case, async: true

  alias Cyfr.Boundaries
  alias Prima.Test.SourceTree

  # The calls that read an application's environment, by their module:
  # under a named key (a literal atom, or `__MODULE__`), or without one.
  @named %{
    Application => [:get_env, :fetch_env, :fetch_env!, :compile_env, :compile_env!],
    :application => [:get_env]
  }
  @bulk %{Application => [:get_all_env], :application => [:get_all_env, :get_key]}

  # Configuration read under the module's own name rather than a key, and
  # a seam's all the same: the projection reconciler's (`config/test.exs`
  # turns it off). A module key is named as its source spells it.
  @module_keyed ["Compendium.ProjectionReconciler"]

  # The decision holds for a seam only where its read goes through it.
  # Every read of the host's application environment in every
  # application's code, read as code: a key `Cyfr.Boundaries` classes
  # `:seam` is read inside the function `Cyfr.seam/2` is handed, or by
  # `compile_env`, which fixes it when the release is built; and a read
  # inside a seam is a seam's key. tests/release-boot/host_seams.exs and
  # the restores case of tests/release-boot/boot.sh hold the shipped
  # release to the same seams.
  test "every read of a seam's key of the host is inside Cyfr.seam/2, or compiled" do
    root = Path.expand("../../../..", __DIR__)

    seams =
      for {key, :seam} <-
            Map.merge(Boundaries.config_key_classes(), Boundaries.test_only_config_key_classes()),
          into: MapSet.new(@module_keyed),
          do: key

    found =
      for lib <- SourceTree.app_libs(root),
          path <- SourceTree.files!(Path.join([root, lib, "**/*.ex"])),
          read <- reads(SourceTree.quoted(path), %{module: nil, gate: :plain}),
          do: Map.put(read, :file, Path.relative_to(path, root))

    outside =
      for %{key: key, gate: :plain, fun: fun} = read <- found,
          key in seams,
          fun not in [:compile_env, :compile_env!],
          do: read

    assert outside == [], "a seam's key read outside Cyfr.seam/2: #{inspect(outside)}"

    # A read that names no key (`Application.get_all_env(:cyfr)`,
    # `:application.get_all_env(:cyfr)`, `:application.get_key(:cyfr, :env)`)
    # or names it by a value holds every seam's key at once, and a release
    # would answer what its configuration says: none is read, inside a seam
    # or out.
    unnamed = for %{key: key} = read <- found, key in [:bulk, :dynamic], do: read
    assert unnamed == [], "a read of the host's environment names no key: #{inspect(unnamed)}"

    # Every read here spells `Application` as itself: an alias or an import
    # of it would hide a read from the walk below.
    hidden =
      for lib <- SourceTree.app_libs(root),
          path <- SourceTree.files!(Path.join([root, lib, "**/*.ex"])),
          SourceTree.read(path) =~ ~r/^\s*(alias|import) Application\b/m,
          do: Path.relative_to(path, root)

    assert hidden == []

    inside = for %{gate: :seam} = read <- found, do: read
    assert Enum.reject(inside, &(&1.key in seams)) == [], inspect(inside)

    # The seams the host's code reads through it, each once: the boot
    # switches and the stand-ins' hooks. A seam no read goes through any
    # more is a key to drop from `Cyfr.Boundaries` and `config/test.exs`.
    assert inside |> Enum.map(& &1.key) |> Enum.sort() ==
             Enum.sort([
               "Compendium.ProjectionReconciler",
               :crew_delivery_enabled,
               :cron_scheduler_enabled,
               :database_checks_enabled,
               :egress_resolver,
               :execution_archive_watch_enabled,
               :execution_sweeper_enabled,
               :external_server_reconciler_enabled,
               :provisioning_boot_enabled,
               :registry_health_probe,
               :retention_scheduler_enabled,
               :schedule_notes_enabled,
               :status_watch_enabled,
               :thread_recovery,
               :tincture_rate_limit_max,
               :worker_watch_enabled
             ])
  end

  # The reads of `:cyfr`'s environment in `ast`, each with its key (the
  # module's name as its source spells it, for `__MODULE__`; `:bulk` for a
  # read that names none; `:dynamic` for one named by a value) and its
  # gate: `:seam` inside the function `Cyfr.seam/2` or `/3` is handed,
  # `:plain` otherwise. A piped read (`:cyfr |> Application.get_all_env()`)
  # is read as the call it is.
  defp reads({:defmodule, _, [{:__aliases__, _, parts}, body]}, scope),
    do: reads(body, %{scope | module: Enum.map_join(parts, ".", &Atom.to_string/1)})

  defp reads({{:., _, [{:__aliases__, _, [:Cyfr]}, :seam]}, _, args}, scope) when is_list(args),
    do:
      Enum.flat_map(args, fn
        {:fn, _, _} = read -> reads(read, %{scope | gate: :seam})
        arg -> reads(arg, scope)
      end)

  defp reads({:|>, _, [subject, {{:., _, [module, fun]}, meta, args}]}, scope)
       when is_list(args),
       do: reads({{:., [], [module, fun]}, meta, [subject | args]}, scope)

  defp reads({{:., _, [module, fun]}, _, [:cyfr | rest] = args} = ast, scope) do
    case read(module(module), fun, rest, scope) do
      nil -> walk(ast, scope)
      read -> [read | reads(args, scope)]
    end
  end

  defp reads(ast, scope), do: walk(ast, scope)

  defp walk({form, _meta, args}, scope), do: reads(form, scope) ++ reads(List.wrap(args), scope)
  defp walk({left, right}, scope), do: reads(left, scope) ++ reads(right, scope)
  defp walk(list, scope) when is_list(list), do: Enum.flat_map(list, &reads(&1, scope))
  defp walk(_leaf, _scope), do: []

  defp module({:__aliases__, _, [:Application]}), do: Application
  defp module(:application), do: :application
  defp module(_module), do: nil

  defp read(module, fun, rest, scope) do
    cond do
      fun in Map.get(@bulk, module, []) -> %{fun: fun, key: :bulk, gate: scope.gate}
      fun in Map.get(@named, module, []) -> %{fun: fun, key: key(rest, scope), gate: scope.gate}
      true -> nil
    end
  end

  defp key([{:__MODULE__, _, _} | _], %{module: module}), do: module
  defp key([key | _], _scope) when is_atom(key), do: key
  defp key(_args, _scope), do: :dynamic
end
