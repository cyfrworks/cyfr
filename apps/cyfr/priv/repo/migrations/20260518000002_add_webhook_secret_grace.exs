# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddWebhookSecretGrace do
  @moduledoc """
  R3: dual-secret grace window for webhook secret rotation.

  `rotate/2` was a hard cutover — in-flight requests signed with the old
  secret failed immediately. These columns let the previous secret keep
  verifying until `previous_secret_expires_at`, after which it is ignored.
  """
  use Ecto.Migration

  def change do
    alter table(:webhooks) do
      add :previous_secret_encrypted, :binary
      add :previous_secret_expires_at, :utc_datetime_usec
    end
  end
end
