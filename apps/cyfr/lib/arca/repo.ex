defmodule Arca.Repo do
  use Ecto.Repo,
    otp_app: :cyfr,
    adapter: Ecto.Adapters.SQLite3
end
