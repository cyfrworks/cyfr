# Check if Arca database is available for policy storage tests
# This runs at test compile time, before apps are fully started,
# so it may not correctly detect Arca availability.
#
# Tests tagged with @tag :requires_arca will be excluded if:
# 1. EXCLUDE_ARCA_TESTS=1 environment variable is set, OR
# 2. We can determine at compile time that Arca is unavailable
#
# Tests also have internal guards to skip gracefully at runtime.

exclude =
  cond do
    System.get_env("EXCLUDE_ARCA_TESTS") == "1" ->
      [:requires_arca]

    true ->
      []
  end

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :manual)
