# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.OneFenceTest do
  @moduledoc """
  A holder-only write has one fence, `Arca.Repo.owned/2` and `owned/3`, and
  a transaction's `{:ok, value}` or rollback one reading,
  `Arca.Repo.committed/1`: no Arca module writes its own copy of either.

  The scan reads each module's syntax tree, so a comment, a renamed
  variable or a helper in between changes nothing:

    * a **fence** is a function that opens a locking transaction — through
      `Arca.Repo.locking_transaction/2` itself, or a function of its own or
      of another module that opens one — around code that reaches
      `Arca.ControlPlane.verify_held/1`: directly, or through a function of
      its own or a public function of another module that does. A call of
      `Arca.Repo.owned/2` or `owned/3` is not one: the write it runs is the
      caller's code;
    * a **reading** is a set of clauses (a `case`, a `fn`, or a function's
      own clauses) holding both `{:ok, value} -> value` and
      `{:error, reason} -> rollback(reason)`.

  `Arca.Repo` and `Arca.ControlPlane` own these. Every other function the
  scan finds is rostered below by why it is not the fence or the reading:
  a new one fails, and a rostered one that no longer is one fails too.
  """

  use ExUnit.Case, async: true

  @lib Path.expand("../../lib", __DIR__)
  @owners [[:Arca, :Repo], [:Arca, :ControlPlane]]

  # Functions that check the member's slot inside a transaction they open,
  # each with refusals, locks or answers of its own that `owned/2` and
  # `owned/3` do not carry.
  @fences %{
    {"arca/agent_storage.ex", "replace_projection/4"} =>
      "a projection replace under an attempt's provisioning claim, checked inside the projection's own transaction (`Arca.ProvisioningClaims.hold?/4`)",
    {"arca/component_storage.ex", "under_claim/3"} =>
      "a row write under an attempt's provisioning claim, which holds the claim row and verifies its slot (`Arca.ProvisioningClaims.hold?/4`)",
    {"arca/consumer_receipts.ex", "record/4"} =>
      "a receipt under a job claim: the claim judged before and after the slot check, each loss refused as itself",
    {"arca/cron_schedule.ex", "guarded/3"} =>
      "a generic schedule writer: the row locked tenant-scoped first, then the slot checked (`slot_fence/0`)",
    {"arca/execution.ex", "admit/4"} =>
      "an admission: the athanor's standing and the execution-then-attempt locks first, the slot checked within (`slot_held!/0`)",
    {"arca/fenced_publication.ex", "publish/4"} =>
      "a publication under the writer's slot inside the publication step, with its declared refusals (`:stale`, `:budget`)",
    {"arca/fenced_publication.ex", "remove/3"} =>
      "a removal under the writer's slot inside the publication step, with its declared refusals (`:stale`, `:budget`)",
    {"arca/file_offers.ex", "commit_acceptance/5"} =>
      "an acceptance's second step, under the slot its first step read, beside the offer's own turn",
    {"arca/members.ex", "reconcile_platform/3"} =>
      "a platform reconcile under a job claim: the slot checked before and after the claim is renewed, refused as `:slot_lost`",
    {"arca/pairing_invitations.ex", "consume/5"} =>
      "a consumption inside `Arca.SecurityTransitions.Issuance.run/3`, after the standing order's locks",
    {"arca/pairing_invitations.ex", "open/3"} =>
      "an invitation issued inside `Arca.SecurityTransitions.Issuance.run/3`, after the standing order's locks",
    {"arca/provisioning_claims.ex", "claim/5"} =>
      "a claim's take, which answers `{:busy, row}` as well as `{:ok, row}` and commits either, under the caller's slot",
    {"arca/provisioning_claims.ex", "under_slot/2"} =>
      "a write whose answer commits whatever it is, under the caller's slot",
    {"arca/schedule_occurrences.ex", "claim/3"} =>
      "an occurrence claim: the schedule row locked first, then the slot checked (`Arca.CronSchedule.slot_fence/0`)",
    {"arca/security_transitions.ex", "restore/1"} =>
      "the restore transition under the slot the boot names, refused as `:slot_lost`, within its deadline",
    {"arca/security_transitions/issuance.ex", "owned/1"} =>
      "the issuance's fence: `Arca.Repo.owned/2`'s shape without its rescue and projection, which `Issuance.run/3`'s callers apply",
    {"arca/storage_units.ex", "move_pointer/7"} =>
      "a pointer move: the slot under the lease row's shared lock beside an attempt's claim row, the compare in the update's WHERE",
    {"arca/storage_units.ex", "stamped_retire/4"} =>
      "a retire under the slot and an attempt's claim row, as a pointer move is"
  }

  # Functions that read a step's answer inline, inside a transaction of
  # their own whose other refusals `committed/1` does not carry.
  @readings %{
    {"arca/component_storage.ex", "under_claim/3"} =>
      "the write's answer inside the claim's transaction, beside its `:not_owner` rollback",
    {"arca/execution.ex", "admit/4"} =>
      "the execution row's insert inside the admission, whose changeset is the rollback",
    {"arca/fenced_publication.ex", "fenced/2"} =>
      "a publication step's revision, whose refusals the step's closure tags (`{Arca.FencedPublication, :closure, reason}`)"
  }

  test "no Arca module writes its own fence or its own reading" do
    modules = tree()
    assert length(modules) > 50, "the scan read no code — it is not reading"

    %{fences: fences, readings: readings} = scan(modules)

    # The owners' own definitions are what the scan looks for.
    owners = scan(modules, [])
    assert {"arca/repo.ex", "owned/3"} in owners.fences
    assert {"arca/repo.ex", "committed/1"} in owners.readings

    assert fences -- Map.keys(@fences) == [],
           "these functions open their own slot fence: use Arca.Repo.owned/2 or owned/3, or roster them with why they differ: #{inspect(fences -- Map.keys(@fences))}"

    assert readings -- Map.keys(@readings) == [],
           "these functions read {:ok, value} or roll back themselves: use Arca.Repo.committed/1, or roster them with why they differ: #{inspect(readings -- Map.keys(@readings))}"

    assert Map.keys(@fences) -- fences == [],
           "these rostered fences are gone: remove them from the roster: #{inspect(Map.keys(@fences) -- fences)}"

    assert Map.keys(@readings) -- readings == [],
           "these rostered readings are gone: remove them from the roster: #{inspect(Map.keys(@readings) -- readings)}"
  end

  test "a fence written another way is still a fence, and a write through owned/2 is not" do
    planted =
      module("arca/planted.ex", ~S'''
      defmodule Arca.Planted do
        alias Arca.Repo.Errors

        # The cron form: a caller-supplied slot, checked through a helper,
        # the answer read by Arca.Repo.committed/1.
        defp fenced(tag, slot, write) do
          Errors.with_db_rescue(tag, fn ->
            Arca.Repo.locking_transaction(fn ->
              case held(slot) do
                :ok -> write.() |> Arca.Repo.committed()
                {:error, :not_owner} -> Arca.Repo.rollback(:not_owner)
              end
            end)
          end)
        end

        defp held(slot) do
          case Arca.ControlPlane.verify_held(slot) do
            :ok -> :ok
            :lost -> {:error, :not_owner}
          end
        end

        # The nine's form, with a comment between the slot read and the
        # transaction, and its own reading.
        defp guarded(write) do
          with {:ok, slot} <- Arca.ControlPlane.member_slot() do
            # proves the slot first
            Arca.Repo.locking_transaction(fn ->
              case Arca.ControlPlane.verify_held(slot) do
                :ok -> settle(write.())
                :lost -> Arca.Repo.rollback(:not_owner)
              end
            end)
          end
        end

        def settle({:ok, row}), do: row
        def settle({:error, why}), do: Arca.Repo.rollback(why)

        # The check handed, as a closure, to a function that opens the
        # transaction; and a public wrapper of the check in another module.
        def handed(write), do: run_locked(fn -> with :ok <- held(:none), do: write.() end)
        defp run_locked(step), do: Arca.Repo.locking_transaction(step)

        def remote(write) do
          Arca.Repo.locking_transaction(fn ->
            with :ok <- Arca.CronSchedule.slot_fence(), do: write.()
          end)
        end

        # A reading as a case, and a write through owned/2: only the first
        # is a reading, and neither is a fence.
        def read(step) do
          case step.() do
            {:ok, x} -> x
            {:error, e} -> Arca.Repo.rollback(e)
          end
        end

        def through_owned(write), do: Arca.Repo.owned("Arca.Planted", write)
      end
      ''')

    %{fences: fences, readings: readings} = scan([planted | tree()])

    assert for({"arca/planted.ex", fun} <- fences, do: fun) ==
             ["fenced/3", "guarded/1", "handed/1", "remote/1"]

    assert for({"arca/planted.ex", fun} <- readings, do: fun) == ["read/1", "settle/1"]
  end

  defp tree do
    for path <- Path.wildcard(Path.join(@lib, "**/*.ex")),
        do: module(Path.relative_to(path, @lib), File.read!(path))
  end

  # A source file's module: its name, and each function's clauses as
  # `{args, body}` by `{name, arity}`.
  defp module(relative, source) do
    {:ok, ast} = Code.string_to_quoted(source)

    # A pipe is the call it pipes into, its left side the first argument,
    # so every call is seen with the arity it has.
    ast =
      Macro.postwalk(ast, fn
        {:|>, _, [lhs, {callee, meta, args}]} when is_list(args) -> {callee, meta, [lhs | args]}
        node -> node
      end)

    name =
      case ast do
        {:defmodule, _, [{:__aliases__, _, name} | _]} -> name
        _ -> []
      end

    {_, clauses} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] and is_list(body) ->
          {fun, args} =
            case head do
              {:when, _, [{fun, _, args} | _]} -> {fun, args}
              {fun, _, args} -> {fun, args}
            end

          args = List.wrap(args)
          {node, [{{fun, length(args)}, {args, body}} | acc]}

        node, acc ->
          {node, acc}
      end)

    %{
      relative: relative,
      name: name,
      funs: clauses |> Enum.reverse() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    }
  end

  # Every fence and reading outside the `owners`' modules, as
  # `{relative path, "fun/arity"}`, sorted.
  defp scan(modules, owners \\ @owners) do
    checks = grown(modules, &checks?/3, [{[:Arca, :ControlPlane], {:verify_held, 1}}])

    openers =
      grown(modules, &opens?/3, [
        {[:Arca, :Repo], {:locking_transaction, 1}},
        {[:Arca, :Repo], {:locking_transaction, 2}}
      ])

    in_scope = Enum.reject(modules, &(&1.name in owners))

    %{
      fences:
        Enum.sort(
          for m <- in_scope,
              {fun, clauses} <- m.funs,
              fence?(clauses, m, checks, openers),
              do: {m.relative, label(fun)}
        ),
      readings:
        Enum.sort(
          for m <- in_scope,
              {fun, clauses} <- m.funs,
              reading_in?(clauses),
              do: {m.relative, label(fun)}
        )
    }
  end

  defp label({fun, arity}), do: "#{fun}/#{arity}"

  # The functions, as `{module name, {fun, arity}}`, that `property` holds
  # for given those already found, from `seeds`: grown to its fixed point.
  defp grown(modules, property, seeds) do
    grow = fn known ->
      for m <- modules,
          {fun, clauses} <- m.funs,
          property.(clauses, m, known),
          into: known,
          do: {m.name, fun}
    end

    Stream.iterate(MapSet.new(seeds), grow)
    |> Stream.chunk_every(2, 1)
    |> Enum.find(fn [a, b] -> a == b end)
    |> hd()
  end

  # Whether `ast` calls a function `known` holds: one of its own module's,
  # or one of another module named by the last part of its alias.
  defp calls?(ast, m, known) do
    remote = MapSet.new(for {name, fun} <- known, name != [], do: {List.last(name), fun})

    {_, hit} =
      Macro.prewalk(ast, false, fn
        node, true ->
          {node, true}

        {{:., _, [{:__aliases__, _, alias}, fun]}, _, args} = node, false when is_list(args) ->
          {node, MapSet.member?(remote, {List.last(alias), {fun, length(args)}})}

        {fun, _, args} = node, false when is_atom(fun) and is_list(args) ->
          {node, MapSet.member?(known, {m.name, {fun, length(args)}})}

        node, false ->
          {node, false}
      end)

    hit
  end

  # Code that reaches the slot check. A call of `Arca.Repo.owned/2` or
  # `owned/3` does not: the write it runs is the caller's code.
  defp checks?(ast, m, known),
    do: calls?(ast, m, MapSet.reject(known, &match?({[:Arca, :Repo], {:owned, _}}, &1)))

  # Code that opens a locking transaction.
  defp opens?(ast, m, known), do: calls?(ast, m, known)

  # A call that opens a transaction, other than `Arca.Repo.owned/2` and
  # `owned/3`, around code that reaches the check: one of its arguments.
  defp fence?(clauses, m, checks, openers) do
    opener? = fn call -> not owned?(call) and opens?(bare(call), m, openers) end
    reaches? = &checks?(&1, m, checks)

    {_, hit} =
      Macro.prewalk(clauses, false, fn
        node, true ->
          {node, true}

        node, false ->
          {node, around?(node, opener?, reaches?)}
      end)

    hit
  end

  defp around?({_, _, args} = call, opener?, reaches?) when is_list(args),
    do: opener?.(call) and Enum.any?(args, reaches?)

  defp around?(_node, _opener?, _reaches?), do: false

  # The call alone, its arguments blanked, so that only the call itself,
  # not a call among its arguments, is asked whether it opens.
  defp bare({callee, meta, args}) when is_list(args),
    do: {callee, meta, Enum.map(args, fn _ -> nil end)}

  defp bare(node), do: node

  defp owned?({{:., _, [{:__aliases__, _, [:Arca, :Repo]}, :owned]}, _, _}), do: true
  defp owned?(_call), do: false

  # A reading among a function's own clauses, or among the clauses of any
  # `case` or `fn` inside it.
  defp reading_in?(clauses) do
    own = for {[arg], [do: body]} <- clauses, do: {arg, body}

    {_, hit} =
      Macro.prewalk(clauses, reading?(own), fn
        node, true ->
          {node, true}

        [{:->, _, _} | _] = arrows, false ->
          {arrows, reading?(for {:->, _, [[arg], body]} <- arrows, do: {arg, body})}

        node, false ->
          {node, false}
      end)

    hit
  end

  defp reading?(pairs), do: Enum.any?(pairs, &value?/1) and Enum.any?(pairs, &rollback?/1)

  defp value?({{:ok, {var, _, ctx}}, {var, _, ctx2}}) when is_atom(ctx) and is_atom(ctx2),
    do: true

  defp value?(_pair), do: false

  defp rollback?({{:error, {var, _, ctx}}, body}) when is_atom(ctx), do: rolls_back?(body, var)
  defp rollback?(_pair), do: false

  defp rolls_back?({{:., _, [{:__aliases__, _, alias}, :rollback]}, _, [{var, _, _}]}, var),
    do: List.last(alias) == :Repo

  defp rolls_back?({:rollback, _, [{var, _, _}]}, var), do: true
  defp rolls_back?(_body, _var), do: false
end
