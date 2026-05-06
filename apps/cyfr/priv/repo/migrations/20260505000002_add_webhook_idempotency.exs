defmodule Arca.Repo.Migrations.AddWebhookIdempotency do
  use Ecto.Migration

  def change do
    alter table(:webhooks) do
      # Optional. When set, inbound deliveries carrying this header are
      # de-duplicated within the configured TTL window. Null = no dedup.
      add :idempotency_key_header, :string
    end

    create table(:webhook_deliveries, primary_key: false) do
      add :id, :string, primary_key: true
      add :webhook_id, references(:webhooks, type: :string, on_delete: :delete_all), null: false
      add :idempotency_key, :string, null: false
      add :first_seen_at, :utc_datetime_usec, null: false
    end

    create unique_index(:webhook_deliveries, [:webhook_id, :idempotency_key])
    create index(:webhook_deliveries, [:first_seen_at])
  end
end
