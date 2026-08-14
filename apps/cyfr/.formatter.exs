# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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
    "{lib,test}/**/*.{ex,exs}",
    "priv/repo/**/*.exs"
  ]
]
