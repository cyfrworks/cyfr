defmodule Arca.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    ensure_db_directory!()
    maybe_migrate_before_pool()
    Arca.Cache.init()

    children = [
      Arca.Repo,
      Arca.Cache.Sweeper
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Arca.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp ensure_db_directory! do
    config = Application.get_env(:arca, Arca.Repo, [])

    if db_path = config[:database] do
      db_path |> Path.dirname() |> File.mkdir_p!()
    end
  end

  # Run migrations before the connection pool starts to avoid
  # "database is locked" errors from pool connections racing with
  # migration DDL statements on first startup.
  defp maybe_migrate_before_pool do
    if Application.get_env(:arca, :auto_migrate, true) do
      config = Application.get_env(:arca, Arca.Repo, [])
      # Start a temporary repo with pool_size=1 just for migrations
      {:ok, repo_pid} = Arca.Repo.start_link(Keyword.put(config, :pool_size, 1))
      Ecto.Migrator.run(Arca.Repo, migrations_path(), :up, all: true)
      enable_wal_mode()
      # Stop the temporary repo so the supervisor can start the real one
      Supervisor.stop(repo_pid)
    end
  end

  defp enable_wal_mode do
    Arca.Repo.query!("PRAGMA journal_mode=WAL")
    Arca.Repo.query!("PRAGMA busy_timeout=5000")
  rescue
    _ -> :ok
  end

  defp migrations_path do
    Application.app_dir(:arca, "priv/repo/migrations")
  end
end
