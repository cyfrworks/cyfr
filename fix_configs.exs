files = Path.wildcard("apps/cyfr/lib/**/*.ex") ++ Path.wildcard("apps/cyfr/test/**/*.exs")
apps = [":sanctum", ":arca", ":emissary", ":compendium", ":sanctum_arx"]

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
