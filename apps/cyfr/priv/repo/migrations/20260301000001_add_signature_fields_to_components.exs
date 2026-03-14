defmodule Arca.Repo.Migrations.AddSignatureFieldsToComponents do
  use Ecto.Migration

  def change do
    alter table(:components) do
      add :signature_verified, :boolean, default: false
      add :signer_identity, :string
      add :signer_issuer, :string
    end
  end
end
