[
  import_deps: [
    :ecto,
    :ecto_sql,
    :phoenix,
    :phoenix_html,
    :phoenix_live_view,
    :plug
  ],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "priv/repo/**/*.exs"
  ]
]
