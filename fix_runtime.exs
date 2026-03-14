file = "config/runtime.exs"
content = File.read!(file)

apps = [":sanctum", ":arca", ":emissary", ":compendium", ":sanctum_arx"]
new_content = Enum.reduce(apps, content, fn app, acc ->
  acc
  |> String.replace("config #{app},", "config :cyfr,")
end)

File.write!(file, new_content)
