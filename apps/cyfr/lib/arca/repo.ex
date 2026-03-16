defmodule Arca.Repo do
  use Ecto.Repo,
    otp_app: :cyfr,
    adapter: Application.compile_env(:cyfr, :repo_adapter, Ecto.Adapters.SQLite3)
end
