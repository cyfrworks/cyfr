# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.TenantArgumentOrderTest do
  @moduledoc """
  Where the tenant comes from in a storage function, and what an
  unresolved one does.

  A bare `athanor_id` and the row key beside it are both non-empty
  strings. Nothing in the type system, in dialyzer, or in
  `where_athanor/2`'s guard can tell them apart — so a call that swaps
  them is not an error, it is a query against another athanor that
  returns that athanor's rows, or none, and looks like an ordinary miss
  either way. `Arca.ApiKeyStorage` once had both spellings at once:
  `get_key(name, athanor_id)` beside `get_key_by_id(athanor_id, id)`,
  identical `(String.t(), String.t())` specs pointing opposite ways.

  Putting the tenant first was the first half of the answer. This is the
  second: the tenant is not an argument at all. Every tenant-scoped
  facade matches a `%Cyfr.Actor{}` in its head and reads the athanor out
  of it, so the athanor comes from the caller the identity domain
  established and no argument a caller passes can move a read or a write
  to another tenant's rows. A `%Sanctum.Context{}` or a bare id matches
  no head and raises.

  ## The empty string is refused, not matched

  A head that binds the athanor out of the actor guards
  `is_binary(athanor_id) and athanor_id != ""`. Both halves are load
  bearing. `""` is an identity that was never resolved — the same thing
  `Arca.QueryHelpers.where_tenant/2` raises on — and a guard of
  `is_binary/1` alone would admit it, filter on `athanor_id == ""`, match
  nothing and answer an ordinary empty result. That turns a refusal into
  silence, which is exactly what the tenancy rules forbid.
  `Arca.VaultStorage` spells the same pair as its own `resolved/1` guard,
  which this reads as the guard it is.
  """

  use ExUnit.Case, async: true

  @storage_globs ["apps/cyfr/lib/arca.ex", "apps/cyfr/lib/arca/**/*.ex"]

  # The rule is about functions the tenant SCOPES. These are the shapes
  # where the athanor is something else:
  #
  #   * `where_athanor/2`, `where_tenant/2`,
  #     `where_tenant_unless_platform/2` and `stamp_tenant!/2` compose onto
  #     a query or a map — the subject is what is piped, and the tenant
  #     narrows or stamps it.
  #   * `update_athanor/2` writes the athanor as a VALUE onto a session
  #     found by its token hash. Swapping those looks up a session whose
  #     hash equals an athanor id, finds none, and says so; it cannot reach
  #     another tenant's row, and the two are different types besides.
  #   * `Arca.BudgetReservations.fetch/1` takes the reservation id the wire
  #     carries as an authority's identity; the row answers with its own
  #     athanor and the module says so where it stands.
  @exempt %{
    "query_helpers.ex" =>
      ~w(where_athanor where_tenant where_tenant_unless_platform stamp_tenant!),
    "session_storage.ex" => ~w(update_athanor),
    "budget_reservations.ex" => ~w(fetch)
  }

  # The files whose heads still take a `%Sanctum.Context{}` or a bare id.
  # The actor-first conversion lands facade by facade, so this is a
  # shrinking list and not an exemption: nothing may be added to it, and
  # it is empty by the end of the conversion, when it goes with this
  # comment.
  @pending ~w(
    agent_revisions.ex agent_storage.ex arca.ex component_storage.ex
    cron_schedule.ex execution.ex execution_payloads.ex keys.ex local.ex
    mcp_log.ex mcp_server_storage.ex overlay.ex policy_log.ex
    profile_storage.ex s3.ex storage.ex tenant_tables.ex thread_storage.ex
    thread_subscription_storage.ex tool_grant_storage.ex turn_storage.ex
    usage.ex webhook_storage.ex
  )

  defp root, do: Path.expand("../../../..", __DIR__)

  defp sources do
    Enum.flat_map(@storage_globs, fn glob ->
      root() |> Path.join(glob) |> Cyfr.Test.SourceTree.files!()
    end)
  end

  # Every public head of one source, as {name, whole head text, line}. A
  # head runs from `  def ` to the ` do` or `, do:` that ends it, so a
  # guard on a continuation line is part of it; a bodiless head that only
  # declares defaults ends at the blank line under it.
  defp heads(source) do
    lines = String.split(source, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} -> line =~ ~r/^  def [a-z_]+[!?]?\(/ end)
    |> Enum.map(fn {line, n} ->
      text =
        lines
        |> Enum.drop(n - 1)
        |> Enum.reduce_while([], fn l, acc ->
          cond do
            l =~ ~r/(\bdo\b\s*$|,\s*do:)/ -> {:halt, Enum.reverse([l | acc])}
            String.trim(l) == "" -> {:halt, Enum.reverse(acc)}
            true -> {:cont, [l | acc]}
          end
        end)
        |> Enum.join("\n")

      [_, name] = Regex.run(~r/^  def ([a-z_]+[!?]?)\(/, line)
      {name, text, n}
    end)
  end

  # The heads of one file that name a tenant and do not take the actor
  # first.
  defp offending(file, source) do
    exempt = Map.get(@exempt, file, [])

    for {name, text, n} <- heads(source),
        name not in exempt,
        text =~ ~r/athanor_id|%Sanctum\.Context\{|%Context\{/,
        not (text =~ ~r/^  def [a-z_]+[!?]?\(\s*%Cyfr\.Actor\{/),
        do: "#{file}:#{n}: #{text |> String.split("\n") |> hd() |> String.trim()}"
  end

  # The heads that bind the athanor out of the actor without refusing the
  # empty string in the same guard.
  defp unguarded(file, source) do
    for {_name, text, n} <- heads(source),
        text =~ ~r/%Cyfr\.Actor\{athanor_id: athanor_id\}/,
        not (text =~ ~r/athanor_id\s*!=\s*""/ or text =~ ~r/\bresolved\(athanor_id\)/),
        do: "#{file}:#{n}: #{text |> String.split("\n") |> hd() |> String.trim()}"
  end

  test "every tenant-scoped storage function takes the actor first" do
    found =
      for path <- sources(),
          Path.basename(path) not in @pending,
          offender <- offending(Path.basename(path), Cyfr.Test.SourceTree.read(path)),
          do: offender

    assert found == [],
           """
           These storage functions name a tenant but do not take a
           %Cyfr.Actor{} in the first position:

           #{Enum.map_join(found, "\n", &"  #{&1}")}

           A bare athanor_id and the row key beside it are both strings, so
           a swapped call compiles, passes dialyzer, satisfies
           where_athanor/2's guard and quietly reads another athanor's
           rows; a %Sanctum.Context{} names the identity domain from below
           it. Match the actor in the head and read the athanor out of it.
           """
  end

  test "a head that binds the athanor refuses the empty string in its guard" do
    found =
      Enum.flat_map(sources(), fn path ->
        unguarded(Path.basename(path), Cyfr.Test.SourceTree.read(path))
      end)

    assert found == [],
           """
           These heads bind the athanor out of the actor without refusing
           the empty string:

           #{Enum.map_join(found, "\n", &"  #{&1}")}

           "" is an identity that was never resolved. is_binary/1 alone
           admits it, filters on athanor_id == "", matches nothing and
           answers an ordinary empty result — a refusal turned into
           silence. Guard is_binary(athanor_id) and athanor_id != "".
           """
  end

  test "the detector sees a tenant that is not in the first position" do
    planted = """
    defmodule Arca.Planted do
      def by_actor(%Cyfr.Actor{athanor_id: athanor_id}, key)
          when is_binary(athanor_id) and athanor_id != "",
          do: {athanor_id, key}

      def by_context(%Context{athanor_id: athanor_id}, key), do: {athanor_id, key}
      def by_id(athanor_id, key), do: {athanor_id, key}
      def actor_second(key, %Cyfr.Actor{athanor_id: athanor_id}), do: {athanor_id, key}
      def id_second(key, athanor_id), do: {athanor_id, key}
      def actor_in_a_map(%{actor: %Cyfr.Actor{athanor_id: athanor_id}}), do: athanor_id
    end
    """

    assert offending("planted.ex", planted) == [
             "planted.ex:6: def by_context(%Context{athanor_id: athanor_id}, key), do: {athanor_id, key}",
             "planted.ex:7: def by_id(athanor_id, key), do: {athanor_id, key}",
             "planted.ex:8: def actor_second(key, %Cyfr.Actor{athanor_id: athanor_id}), do: {athanor_id, key}",
             "planted.ex:9: def id_second(key, athanor_id), do: {athanor_id, key}",
             "planted.ex:10: def actor_in_a_map(%{actor: %Cyfr.Actor{athanor_id: athanor_id}}), do: athanor_id"
           ]
  end

  test "the detector sees a head that admits the empty athanor" do
    planted = """
    defmodule Arca.Planted do
      def guarded(%Cyfr.Actor{athanor_id: athanor_id}, key)
          when is_binary(athanor_id) and athanor_id != "",
          do: {athanor_id, key}

      def loose(%Cyfr.Actor{athanor_id: athanor_id}, key) when is_binary(athanor_id),
        do: {athanor_id, key}
    end
    """

    assert unguarded("planted.ex", planted) == [
             "planted.ex:6: def loose(%Cyfr.Actor{athanor_id: athanor_id}, key) when is_binary(athanor_id),"
           ]
  end
end
