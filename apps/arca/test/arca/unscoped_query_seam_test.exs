# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.UnscopedQuerySeamTest do
  @moduledoc """
  Every row-plane query over a tenant-keyed table either scopes itself or
  says why it does not.

  Discovers unscoped queries directly, including calls without exemption tags.

  What makes the check possible without drowning in false positives is that
  the tenant-keyed tables name themselves: a schema with `field :athanor_id`
  is a tenant table, and one without is not. Sessions, users, door entries
  and registry tokens are addressed by credential or by person, so they are
  simply out of scope rather than exceptions to be listed. The roster is
  derived, not written down.

  A query counts as scoped if it mentions `where_tenant`, `where_athanor`,
  or `athanor_id` — the last covers the bare-athanor storage APIs, which
  filter on the column directly. Anything else carries
  `# arca:unscoped-ok <why>` on or above the function head.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # Match reads and writes through Repo and Arca.Repo.
  # exists? and query! need alternatives without a trailing word boundary
  # between their punctuation and the opening parenthesis.
  @repo_verbs ~r/\bRepo\.(?:(?:all|one|update_all|delete_all|aggregate|get|get_by|insert|insert_all|update|delete|transaction)\b|exists\?|query!?)/
  # Scoped means the athanor column is USED — compared, bound or set —
  # not merely mentioned (a `select:` naming athanor_id once counted).
  # `stamp_tenant!` is the write-side spelling (Arca.QueryHelpers).
  @scoped ~r/where_tenant|where_athanor|stamp_tenant!|athanor_id ==|athanor_id:/
  @tag_marker ~r/#\s*arca:unscoped-ok\s+\S/

  # All apps, not just cyfr: opus and locus hold no Repo call today, so the
  # wider glob costs nothing — and the first engine-side query would
  # otherwise escape the roster by construction.
  defp sources do
    [@root, "apps/*/lib", "**/*.ex"] |> Path.join() |> Cyfr.Test.SourceTree.files!()
  end

  # Modules whose schema declares an athanor column — the tables a query can
  # be scoped to in the first place. Both spellings count: `field
  # :athanor_id` and `belongs_to :athanor` (memberships — the one
  # association in the codebase) declare the same column; detecting only
  # the first would let a future `belongs_to` schema silently leave the
  # roster.
  defp tenant_schemas do
    for path <- sources(),
        source = Cyfr.Test.SourceTree.read(path),
        source =~ ~r/^\s*(field :athanor_id|belongs_to :athanor)\b/m,
        [_, module] = Regex.run(~r/^defmodule ([\w.]+) do/m, source),
        into: MapSet.new(),
        do: module
  end

  # Top-level function bodies, paired with the line their head is on. The
  # contiguous `#` comment lines directly above the head come with it, since
  # that is where the tag goes — `@doc` blocks stay out, so prose mentioning
  # an athanor cannot pass for scoping.
  defp functions(lines) do
    starts = for {line, i} <- Enum.with_index(lines), line =~ ~r/^  defp? /, do: i

    # A function ends where the NEXT one's comment preamble begins, so a tag
    # is counted once — against the function it sits above, not also against
    # the one it happens to follow.
    bounds =
      Enum.zip(
        starts,
        Enum.map(Enum.drop(starts, 1), &(&1 - length(comments_above(lines, &1)))) ++
          [length(lines)]
      )

    for {from, to} <- bounds do
      preamble = comments_above(lines, from)
      body = Enum.slice(lines, from, max(to - from, 1))
      {from + 1, Enum.join(preamble ++ body, "\n")}
    end
  end

  defp comments_above(lines, index) do
    lines
    |> Enum.take(index)
    |> Enum.reverse()
    |> Enum.take_while(&(&1 =~ ~r/^\s*#/))
    |> Enum.reverse()
  end

  defp queried_schemas(body, enclosing, tenant_schemas, by_short) do
    named = Regex.scan(~r/\b([A-Z][\w.]*)\b/, body) |> Enum.map(&Enum.at(&1, 1))

    from_self =
      if String.contains?(body, "__MODULE__") and enclosing in tenant_schemas,
        do: [enclosing],
        else: []

    named
    |> Enum.map(fn name ->
      if MapSet.member?(tenant_schemas, name),
        do: name,
        else: Map.get(by_short, name |> String.split(".") |> List.last())
    end)
    |> Enum.concat(from_self)
    |> Enum.filter(&(&1 && MapSet.member?(tenant_schemas, &1)))
    |> Enum.uniq()
  end

  test "an unscoped query over a tenant-keyed table says why" do
    schemas = tenant_schemas()

    assert MapSet.size(schemas) > 10,
           "expected the tenant-keyed schemas to be found, got #{MapSet.size(schemas)}"

    by_short = for s <- schemas, into: %{}, do: {s |> String.split(".") |> List.last(), s}

    offenders =
      for path <- sources(),
          source = Cyfr.Test.SourceTree.read(path),
          [_, enclosing] = Regex.run(~r/^defmodule ([\w.]+) do/m, source) || [nil, nil],
          {line, body} <- functions(String.split(source, "\n")),
          body =~ @repo_verbs,
          not (body =~ @scoped),
          not (body =~ @tag_marker),
          tables = queried_schemas(body, enclosing, schemas, by_short),
          tables != [] do
        head = body |> String.split("\n") |> hd() |> String.trim()
        "#{Path.relative_to(path, @root)}:#{line}: #{head} (#{Enum.join(tables, ", ")})"
      end

    assert offenders == [],
           """
           These query a tenant-keyed table without scoping it and without
           saying why:

           #{Enum.map_join(Enum.sort(offenders), "\n", &"  #{&1}")}

           Scope it through `Arca.QueryHelpers.where_tenant/2` or
           `where_athanor/2`. If crossing tenants is genuinely this site's
           job, put `# arca:unscoped-ok <why>` on the function head so the
           reason is greppable and reviewed — a prose docstring is not the
           marker, because nothing can grep for the absence of one.
           """
  end

  test "the tag is only on functions that actually query" do
    stale =
      for path <- sources(),
          source = Cyfr.Test.SourceTree.read(path),
          {line, body} <- functions(String.split(source, "\n")),
          body =~ @tag_marker,
          not (body =~ @repo_verbs) do
        head = body |> String.split("\n") |> hd() |> String.trim()
        "#{Path.relative_to(path, @root)}:#{line}: #{head}"
      end

    assert stale == [],
           """
           `# arca:unscoped-ok` on a function that no longer queries:

           #{Enum.map_join(Enum.sort(stale), "\n", &"  #{&1}")}

           Remove the tag — a marker that outlives its query trains readers
           to ignore it.
           """
  end

  # List schemas without athanor_id explicitly. Identity and platform rows
  # are globally addressed; webhook_deliveries are scoped through their
  # tenant-owned webhook and cascade when it is deleted.
  @athanor_less %{
    "Arca.Schemas.Athanor" => "the tenant itself — it cannot carry a reference to itself",
    "Arca.Schemas.User" => "a person, addressed by their own id; people are not tenant-owned",
    "Arca.Schemas.ExternalIdentity" =>
      "how an IdP names a person — keyed by the identity key and the person's id, no tenant",
    "Arca.Schemas.RegistryToken" => "keyed by user_id — the identity plane, not a tenant's",
    "Arca.Schemas.ServerAllowlistEntry" => "the door: who may sign in at all, before any tenant",
    "Arca.Schemas.CellLease" =>
      "a member slot of the cell, keyed by the node holding it — the deployment's shape, " <>
        "and a cell has no estate",
    "Arca.Schemas.JobClaim" =>
      "a mutual-exclusion token for one of the cell's singleton jobs, keyed by (kind, key); " <>
        "several kinds have no athanor at all, and a key naming one grants no reach into it",
    "Arca.Schemas.ServerMeta" =>
      "the server's own facts (the schema and keyring fingerprints) — one row per key, no tenant",
    "Arca.Schemas.WebhookDelivery" =>
      "an idempotency claim keyed by a webhooks FK (on_delete: :delete_all), so it is " <>
        "reachable only through its tenant-owned parent and cascade-deleted with it; the " <>
        "unique index is (webhook_id, idempotency_key), so keys cannot collide across athanors"
  }

  test "every schema without an athanor column is classified" do
    schemas =
      for path <- sources(),
          source = Cyfr.Test.SourceTree.read(path),
          source =~ ~r/^\s*schema "/m,
          not (source =~ ~r/^\s*(field :athanor_id|belongs_to :athanor)\b/m),
          [_, module] = Regex.run(~r/^defmodule ([\w.]+) do/m, source),
          into: MapSet.new(),
          do: module

    unclassified = MapSet.difference(schemas, MapSet.new(Map.keys(@athanor_less)))

    assert MapSet.to_list(unclassified) == [],
           """
           These schemas carry no athanor column, so every query over them is
           invisible to this seam:

           #{Enum.map_join(Enum.sort(unclassified), "\n", &"  #{&1}")}

           If the table is tenant-owned, give it `athanor_id` and the seam
           will hold its queries to scoping. If it is addressed by something
           else — a person, a credential, a tenant-owned parent — add it to
           `@athanor_less` with the line saying what addresses it, so the
           choice is on the record instead of implied by an absence.
           """

    stale = MapSet.difference(MapSet.new(Map.keys(@athanor_less)), schemas)

    assert MapSet.to_list(stale) == [],
           """
           `@athanor_less` names schemas that no longer exist or now carry an
           athanor column:

           #{Enum.map_join(Enum.sort(stale), "\n", &"  #{&1}")}

           Remove them — a roster that outlives its rows misdescribes the
           tenancy fabric.
           """
  end
end
