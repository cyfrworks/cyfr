# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.DropSessionsSessionId do
  @moduledoc """
  Drop the always-NULL `sessions.session_id` column.

  `Session.create` never minted one — the token hash is the row's key and
  the revocation machinery that once read this column left with the
  `revoked_sessions` table. Also delete any rows with a NULL scope so the
  restore path never sees a pre-scope-column row shape again.
  """
  use Ecto.Migration

  def up do
    execute "DELETE FROM sessions WHERE scope IS NULL"

    alter table(:sessions) do
      remove :session_id
    end
  end

  def down do
    alter table(:sessions) do
      add :session_id, :string
    end
  end
end
