defmodule Arca.Repo.Migrations.AddFormulaParallelismFields do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      add :batch_timeout, :string, default: "5m"
      add :max_concurrent_tasks, :integer, default: 10
    end
  end
end
