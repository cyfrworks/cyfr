files = Path.wildcard("apps/cyfr/lib/**/*.ex") ++ Path.wildcard("apps/cyfr/test/**/*.exs")
apps = [":opus", ":locus"]

Enum.each(files, fn file ->
  content = File.read!(file)
  new_content = Enum.reduce(apps, content, fn app, acc ->
    acc
    |> String.replace("Application.get_env(#{app},", "Application.get_env(:cyfr,")
    |> String.replace("Application.fetch_env!(#{app},", "Application.fetch_env!(:cyfr,")
    |> String.replace("Application.fetch_env(#{app},", "Application.fetch_env(:cyfr,")
    |> String.replace("Application.compile_env(#{app},", "Application.compile_env(:cyfr,")
    |> String.replace("Application.get_env(#{app})", "Application.get_env(:cyfr)")
  end)

  if content != new_content do
    IO.puts("Modified #{file}")
    File.write!(file, new_content)
  end
end)

config_files = ["config/config.exs", "config/dev.exs", "config/runtime.exs", "config/test.exs"]
Enum.each(config_files, fn file ->
  if File.exists?(file) do
    content = File.read!(file)
    new_content = Enum.reduce(apps, content, fn app, acc ->
      acc |> String.replace("config #{app},", "config :cyfr,")
    end)
    if content != new_content, do: File.write!(file, new_content)
  end
end)
