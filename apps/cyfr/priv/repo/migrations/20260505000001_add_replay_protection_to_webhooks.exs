defmodule Arca.Repo.Migrations.AddReplayProtectionToWebhooks do
  use Ecto.Migration

  def change do
    alter table(:webhooks) do
      # Optional. When set, inbound deliveries must include this header
      # carrying a unix timestamp; HMAC payload becomes "<ts>.<raw_body>"
      # (Stripe-style) and requests outside the configured skew window are
      # rejected. Null = no timestamp check (existing webhooks unchanged).
      add :timestamp_header, :string
    end
  end
end
