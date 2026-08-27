# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.UnscopedQuerySeamTest do
  @moduledoc """
  Mechanical guard for the greppable marker of intentionally unscoped
  row-plane queries: `# arca:unscoped-ok <why>`. Style follows
  `Arca.DbRescueSeamTest`: read the sources, compare literals — a failure
  means either a new unscoped query was tagged without being added to the
  roster below (review it: is crossing tenants really this site's job?),
  or a tagged site moved/disappeared and the roster is stale.

  The full "every Repo call flows through where_tenant/where_athanor or
  carries a tag" assertion is deliberately not attempted: whole tables are
  legitimately not tenant-keyed (sessions and users are user-plane, consent
  proofs are token-keyed, the door store is server-wide), so a blanket scan
  would drown the five real cross-tenant sites in false positives. Pinning
  the tags keeps them greppable and reviewed instead.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  @tag_pattern ~r/# arca:unscoped-ok\s+\S/

  # The enumerated intentionally-unscoped sites: every file allowed to carry
  # the tag, with how many tagged sites it holds. Each tag sits beside the
  # query it justifies, with the reason on the same comment.
  @allowed %{
    # with_running_turn/0: boot recovery walks every athanor's mid-turn
    # conversations, then reconciles each inside its own context.
    "apps/cyfr/lib/arca/conversation_storage.ex" => 1,
    # list_stale_running/2 (the cross-tenant sweeper scan) and
    # mark_failed_if_running/2 (ids from trusted runtime state only).
    "apps/cyfr/lib/arca/execution.ex" => 2,
    # purge_expired/1: proofs are token-keyed, the sweep is server-wide.
    "apps/cyfr/lib/arca/consent_proof_storage.ex" => 1,
    # hashes_by_user/1: sessions are user-owned rows; user_id is the scope.
    "apps/cyfr/lib/arca/session_storage.ex" => 1
  }

  test "arca:unscoped-ok tags exist only at the enumerated sites" do
    found =
      for file <- Path.wildcard(Path.join([@root, "apps/cyfr/lib", "**/*.ex"])),
          count = length(Regex.scan(@tag_pattern, File.read!(file))),
          count > 0,
          into: %{} do
        {Path.relative_to(file, @root), count}
      end

    new_sites =
      for {file, count} <- found,
          count > Map.get(@allowed, file, 0),
          do: {file, count - Map.get(@allowed, file, 0)}

    assert new_sites == [],
           """
           `# arca:unscoped-ok` tags outside this test's roster:

           #{Enum.map_join(Enum.sort(new_sites), "\n", fn {f, n} -> "  #{f} (+#{n})" end)}

           A row-plane query that deliberately crosses tenants carries the
           tag beside it with its reason — and a row here, so every such
           site stays enumerated and reviewed. If the query can be scoped,
           scope it through `Arca.QueryHelpers.where_tenant/2` or
           `where_athanor/2` instead.
           """

    stale = for {file, count} <- @allowed, Map.get(found, file, 0) != count, do: file

    assert stale == [],
           "stale roster entries (tagged site count changed — update the " <>
             "roster and its comments): #{inspect(Enum.sort(stale))}"
  end
end
