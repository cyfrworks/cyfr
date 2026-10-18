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

  A query counts as scoped if it filters or stamps the athanor column
  itself: `where_tenant`, `where_athanor`, `stamp_tenant!`, or `athanor_id`
  compared or bound outside a join condition and a select — the last
  covers the bare-athanor storage APIs, which filter on the column
  directly. A join on the athanor column relates two rows of whatever
  athanors they are in, and a select key reads the column back; neither
  narrows the query to one athanor. Anything else carries
  `# arca:unscoped-ok <why>` on or above the function head.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # The functions of Arca.Repo that read or write rows: Ecto.Repo's
  # queries and Ecto.Adapters.SQL's, explain among them, which under
  # `analyze: true` runs the query it plans. Every other function Arca.Repo
  # has is in @not_queries, and a test holds the two to Arca.Repo's
  # functions exactly, so an Ecto release that adds a query fails here
  # rather than slipping past the scan.
  @queries ~w(aggregate all all_by delete delete! delete_all exists? explain get get! get_by
              get_by! insert insert! insert_all insert_or_update insert_or_update! one one!
              preload query query! query_many query_many! reload reload! stream transact
              transaction update update! update_all)
  @not_queries %{
    "__adapter__" => "the adapter module",
    "adapter" => "the configured adapter module",
    "busy_timeout_ms" => "a configuration read",
    "checked_out?" => "whether this process holds a connection",
    "checkout" => "holds one connection for a function, whose own queries the scan reads",
    "child_spec" => "the supervisor's start specification",
    "committed" => "unwraps a result inside a transaction, or rolls it back",
    "config" => "the repository's configuration",
    "default_options" => "the options every operation starts from",
    "disconnect_all" => "closes the pool's connections",
    "get_dynamic_repo" => "the process's repository",
    "in_transaction?" => "whether this process is inside a transaction",
    "load" => "builds a struct from data already read",
    "locking_transaction" => "a transaction, whose own queries the scan reads",
    "migrations_path" => "where the migrations live",
    "owned" => "runs a write under an ownership fence, whose own queries the scan reads",
    "prepare_query" => "the query hook",
    "prepare_transaction" => "the transaction hook",
    "put_dynamic_repo" => "sets the process's repository",
    "read_transaction" => "a transaction, whose own queries the scan reads",
    "rollback" => "ends a transaction",
    "start_link" => "starts the repository",
    "stop" => "stops the repository",
    "to_sql" => "renders a query without running it",
    "transaction_lock" => "takes an advisory lock inside a transaction"
  }
  # Longest first, and no name character after, so `get` is never read as
  # `get_by` and `exists?` and `query!` match with their punctuation.
  @repo_verbs_source "\\bRepo\\.(?:" <>
                       (@queries
                        |> Enum.sort_by(&(-String.length(&1)))
                        |> Enum.map_join("|", &Regex.escape/1)) <> ")(?![\\w?!])"
  defp repo_verbs, do: Regex.compile!(@repo_verbs_source)

  # Scoped means the athanor column is USED — compared, bound or set —
  # not merely mentioned. `stamp_tenant!` is the write-side spelling
  # (Arca.QueryHelpers). It is read with every join condition and select
  # blanked out first (`own_clauses/1`), so `on: c.athanor_id ==
  # p.athanor_id` and `select: %{athanor_id: p.athanor_id}` scope nothing.
  @scoped ~r/where_tenant|where_athanor|stamp_tenant!|athanor_id ==|athanor_id:/
  @tag_marker ~r/#\s*arca:unscoped-ok\s+\S/

  # All apps, not just cyfr: locus holds no Repo call today, so the
  # wider glob costs nothing — and the first engine-side query would
  # otherwise escape the roster by construction.
  defp sources do
    [@root, "apps/*/lib", "**/*.ex"] |> Path.join() |> Prima.Test.SourceTree.files!()
  end

  # Modules whose schema declares an athanor column — the tables a query can
  # be scoped to in the first place. Both spellings count: `field
  # :athanor_id` and `belongs_to :athanor` (memberships — the one
  # association in the codebase) declare the same column; detecting only
  # the first would let a future `belongs_to` schema silently leave the
  # roster.
  defp tenant_schemas do
    for path <- sources(),
        source = Prima.Test.SourceTree.read(path),
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

  # The body with each join condition (`on:`) and each select (`select:`,
  # `select_merge:`, `select(…)`, `select_merge(…)`) blanked out to the end
  # of its expression: a keyword clause ends at a comma at its own depth or
  # at the bracket closing the list it sits in, and a call at its closing
  # parenthesis.
  @own_clause_starts [~r/\Aon:\s/, ~r/\Aselect(?:_merge)?:\s/, ~r/\Aselect(?:_merge)?\(/]

  defp own_clauses(body), do: own_clauses(body, [])

  defp own_clauses("", acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp own_clauses(<<c::utf8, rest::binary>> = text, acc) do
    starts? = acc == [] or not (hd(acc) =~ ~r/[\w.:]/)
    start = starts? && Enum.find(@own_clause_starts, &Regex.match?(&1, text))

    if start do
      [keyword] = Regex.run(start, text)
      call? = String.ends_with?(keyword, "(")
      rest = binary_part(text, byte_size(keyword), byte_size(text) - byte_size(keyword))
      own_clauses(skip_clause(rest, if(call?, do: 1, else: 0), call?), [" " | acc])
    else
      own_clauses(rest, [<<c::utf8>> | acc])
    end
  end

  defp skip_clause("", _depth, _call?), do: ""

  defp skip_clause(<<c, rest::binary>>, depth, call?) when c in [?(, ?[, ?{],
    do: skip_clause(rest, depth + 1, call?)

  defp skip_clause(<<c, rest::binary>> = text, depth, call?) when c in [?), ?], ?}] do
    cond do
      call? and depth == 1 -> rest
      not call? and depth == 0 -> text
      true -> skip_clause(rest, depth - 1, call?)
    end
  end

  defp skip_clause(<<?,, _::binary>> = text, 0, false), do: text
  defp skip_clause(<<_, rest::binary>>, depth, call?), do: skip_clause(rest, depth, call?)

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

  # The unscoped queries over a tenant-keyed table among `files`, each a
  # path and its source, as `path:line: head (tables)`.
  defp offenders(files, schemas) do
    by_short = for s <- schemas, into: %{}, do: {s |> String.split(".") |> List.last(), s}
    verbs = repo_verbs()

    for {path, source} <- files,
        [_, enclosing] = Regex.run(~r/^defmodule ([\w.]+) do/m, source) || [nil, nil],
        {line, body} <- functions(String.split(source, "\n")),
        body =~ verbs,
        not (own_clauses(body) =~ @scoped),
        not (body =~ @tag_marker),
        tables = queried_schemas(body, enclosing, schemas, by_short),
        tables != [] do
      head = body |> String.split("\n") |> hd() |> String.trim()
      "#{Path.relative_to(path, @root)}:#{line}: #{head} (#{Enum.join(tables, ", ")})"
    end
  end

  test "the scan's verbs are every query Arca.Repo has" do
    functions =
      Arca.Repo.__info__(:functions) |> Enum.map(&to_string(elem(&1, 0))) |> MapSet.new()

    named = MapSet.union(MapSet.new(@queries), MapSet.new(Map.keys(@not_queries)))

    assert MapSet.disjoint?(MapSet.new(@queries), MapSet.new(Map.keys(@not_queries)))
    assert MapSet.difference(functions, named) |> Enum.sort() == []
    assert MapSet.difference(named, functions) |> Enum.sort() == []

    verbs = repo_verbs()

    for verb <- @queries do
      assert "Repo.#{verb}(x)" =~ verbs, "the scan does not read Repo.#{verb}"
    end

    for name <- Map.keys(@not_queries) do
      refute "Repo.#{name}(x)" =~ verbs, "the scan reads Repo.#{name} as a query"
    end
  end

  # Planted: each unscoped query over a tenant-keyed table, in a module the
  # scan reads as it reads lib, is found; the same function tagged or
  # scoped is not.
  test "the scan finds a planted unscoped query of every verb" do
    schemas = tenant_schemas()
    table = schemas |> Enum.sort() |> hd()
    short = table |> String.split(".") |> List.last()

    planted = fn verb, extra ->
      {"apps/arca/lib/arca/planted_#{String.replace(verb, ~r/[?!]/, "")}.ex",
       """
       defmodule Arca.Planted do
         alias #{table}

       #{extra}  def planted(x) do
           Repo.#{verb}(from(r in #{short}, where: r.id == ^x))
         end
       end
       """}
    end

    for verb <- @queries do
      found = offenders([planted.(verb, "")], schemas)
      assert length(found) == 1, "a planted unscoped Repo.#{verb} over #{table} was not found"
      assert hd(found) =~ "planted_" and hd(found) =~ table
      assert offenders([planted.(verb, "  # arca:unscoped-ok planted\n")], schemas) == []

      {path, source} = planted.(verb, "")
      scoped = String.replace(source, "where: r.id", "where: r.athanor_id == ^x and r.id")
      assert offenders([{path, scoped}], schemas) == []
    end
  end

  # Planted: explain under `analyze: true` executes the query it plans, a
  # delete as much as a read, so an unscoped one is found as the same query
  # through Repo.all is.
  test "an unscoped explain, which runs its query under analyze, is a row query" do
    schemas = tenant_schemas()
    table = schemas |> Enum.sort() |> hd()
    short = table |> String.split(".") |> List.last()

    planted = fn call ->
      {"apps/arca/lib/arca/explain_probe.ex",
       """
       defmodule Arca.ExplainProbe do
         alias #{table}
         def planted(x) do
           #{call}
         end
       end
       """}
    end

    ordinary = "Repo.all(from(r in #{short}, where: r.id == ^x))"
    assert length(offenders([planted.(ordinary)], schemas)) == 1

    explained =
      "Repo.explain(:delete_all, from(r in #{short}, where: r.id == ^x), " <>
        "analyze: true, wrap_in_transaction: false)"

    found = offenders([planted.(explained)], schemas)
    assert length(found) == 1, "an unscoped Repo.explain(analyze: true) was not found"
  end

  test "an unscoped query over a tenant-keyed table says why" do
    schemas = tenant_schemas()

    assert MapSet.size(schemas) > 10,
           "expected the tenant-keyed schemas to be found, got #{MapSet.size(schemas)}"

    offenders = offenders(Enum.map(sources(), &{&1, Prima.Test.SourceTree.read(&1)}), schemas)

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

  test "a join condition or a select key scopes nothing; the query's own where does" do
    joined = """
      def heads(after_id) do
        from(p in Profile,
          join: c in Consent,
          on: c.id == p.head_consent_id and c.athanor_id == p.athanor_id,
          where: p.id > ^after_id,
          select: %{athanor_id: p.athanor_id, id: p.id}
        )
        |> Repo.all()
      end
    """

    # The loose reading counted both; the query's own clauses hold neither.
    assert joined =~ @scoped
    refute own_clauses(joined) =~ @scoped
    assert own_clauses(joined) =~ "where: p.id > ^after_id"

    scoped = String.replace(joined, "where: p.id", "where: p.athanor_id == ^athanor_id and p.id")
    assert own_clauses(scoped) =~ @scoped

    piped = """
        Profile
        |> join(:inner, [p], c in Consent, on: c.athanor_id == p.athanor_id)
        |> select([p], %{athanor_id: p.athanor_id})
        |> select_merge([p], %{other: p.athanor_id})
        |> Repo.all()
    """

    refute own_clauses(piped) =~ @scoped
    assert own_clauses(piped) =~ "|> Repo.all()"

    keyword = "Repo.get_by(Profile, id: id, athanor_id: athanor_id)"
    assert own_clauses(keyword) =~ @scoped
  end

  test "the tag is only on functions that actually query" do
    verbs = repo_verbs()

    stale =
      for path <- sources(),
          source = Prima.Test.SourceTree.read(path),
          {line, body} <- functions(String.split(source, "\n")),
          body =~ @tag_marker,
          not (body =~ verbs) do
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
        "and a cell has no athanor",
    "Arca.Schemas.JobClaim" =>
      "a mutual-exclusion token for one of the cell's singleton jobs, keyed by (kind, key); " <>
        "several kinds have no athanor at all, and a key naming one grants no reach into it",
    "Arca.Schemas.ServerMeta" =>
      "the server's own facts (the schema and keyring fingerprints) — one row per key, no tenant",
    "Arca.PlatformSettings" =>
      "the cell's platform settings and each member's pins of them, keyed by setting and " <>
        "member — node facts every member reads alike, no tenant",
    "Arca.Schemas.WebhookDelivery" =>
      "an idempotency claim keyed by a webhooks FK (on_delete: :delete_all), so it is " <>
        "reachable only through its tenant-owned parent and cascade-deleted with it; the " <>
        "unique index is (webhook_id, idempotency_key), so keys cannot collide across athanors",
    "Arca.Schemas.PersonIdentity" =>
      "a person's identity and keys, keyed by their user_id and identifier; a person's " <>
        "identity is not an athanor's to delete",
    "Arca.Schemas.PersonSeal" =>
      "a person's seal at this home, keyed by their user_id and gone with their users " <>
        "row; a person's seal is never an athanor's",
    "Arca.Schemas.RestorePerson" =>
      "a person's recovery from a declared restore, keyed by the restore and their " <>
        "user_id and gone with their users row; a recovery is the person's, never an athanor's",
    "Arca.Schemas.IdentityAttempt" =>
      "a person's enrollment, restore or rotation attempt, keyed by its request id; a " <>
        "restore runs before any person or athanor exists",
    "Arca.Schemas.IdentityLogEntry" =>
      "the directory's log, keyed by the person identifier it orders; a directory holds " <>
        "no athanor",
    "Arca.Schemas.DirectoryHead" =>
      "this home's cache of another person's head, keyed by their identifier",
    "Arca.Schemas.CarryAction" =>
      "a person's sign-in carry and a relying home's login receipt, keyed by the person " <>
        "and the action; a carry moves a person between homes, never inside an athanor",
    "Arca.Schemas.Passkey" =>
      "a person's credential at this home, keyed by the person and its RP ID; revoked " <>
        "with the person, never with an athanor",
    "Arca.Schemas.DeviceCertification" =>
      "a person's certification of a device at another home, keyed by the person, that " <>
        "home and its client; the athanor it names is the other home's, not one of this " <>
        "home's",
    "Arca.Schemas.InstallationClaim" =>
      "the node's one claim by a restore, before any person or athanor exists",
    "Arca.Schemas.RequestRateWindow" =>
      "a pre-authentication limit, keyed by bucket and hashed key; no session, and so no " <>
        "athanor, stands behind the requests it bounds",
    "Arca.Schemas.InstanceEntry" =>
      "the instance's own credentials, offered to athanors and deleted with none of them: " <>
        "keyed by its id and held by the platform's actor alone (`Arca.InstanceEntries`)",
    "Arca.Schemas.InstanceEntryMember" =>
      "a person listed in an instance entry's audience, keyed by the entry and the person; " <>
        "the instance's own credentials, offered to athanors and deleted with none of them",
    "Arca.Schemas.InstanceEntryUsage" =>
      "an instance entry's use by person and day, keyed by the entry, the person and the " <>
        "day; the instance's own credentials, offered to athanors and deleted with none of them"
  }

  test "every schema without an athanor column is classified" do
    schemas =
      for path <- sources(),
          source = Prima.Test.SourceTree.read(path),
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
