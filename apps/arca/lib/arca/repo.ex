defmodule Arca.Repo do
  use Ecto.Repo,
    otp_app: :arca,
    adapter: Ecto.Adapters.SQLite3
end
