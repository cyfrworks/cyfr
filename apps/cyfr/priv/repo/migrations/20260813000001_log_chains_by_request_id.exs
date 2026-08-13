# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.LogChainsByRequestId do
  @moduledoc """
  Give `mcp_logs` a real chain key, and retire `session_id` from both log
  tables.

  `mcp_logs.id` has always been the request id, which made it impossible to
  write more than one row per request — so an in-chain tool call (a formula
  calling `files.write`, say) was silently never logged. `id` becomes the
  per-call key and the new `request_id` column carries the ingress request that
  every call in a chain shares.

  `session_id` goes. MCP 2026-07-28 has no sessions, and after that cutover the
  only writer stamped a freshly minted per-request value — a second unique id
  for a row that already had one as its primary key. On `mcp_logs` it was
  indexed and read by exactly one query, whose default filtered a listing down
  to the row of the request doing the asking; on `policy_logs` it was written
  and never read. Within a chain it was constant, but so is `request_id`, which
  is indexed on both tables and is what grouping actually uses.

  The backfill runs before the drop: existing rows carry the request id in `id`,
  so copying it across preserves every historical grouping.
  """

  use Ecto.Migration

  def up do
    alter table(:mcp_logs) do
      add :request_id, :string
    end

    # Every existing row is a whole request, so its primary key is its chain.
    execute "UPDATE mcp_logs SET request_id = id WHERE request_id IS NULL"

    create index(:mcp_logs, [:request_id])

    drop index(:mcp_logs, [:session_id])

    alter table(:mcp_logs) do
      remove :session_id
    end

    alter table(:policy_logs) do
      remove :session_id
    end
  end

  def down do
    alter table(:policy_logs) do
      add :session_id, :string
    end

    alter table(:mcp_logs) do
      add :session_id, :string
    end

    create index(:mcp_logs, [:session_id])

    drop index(:mcp_logs, [:request_id])

    alter table(:mcp_logs) do
      remove :request_id
    end
  end
end
