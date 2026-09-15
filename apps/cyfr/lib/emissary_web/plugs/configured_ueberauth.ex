# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.ConfiguredUeberauth do
  @moduledoc """
  Ueberauth, with its route table built from the providers this boot
  configured — the generic OIDC strategy when `CYFR_AUTH_PROVIDER=oidc`, and
  nothing otherwise (GitHub and Google sign in by device flow).

  ## Why the routes are built per call

  `Ueberauth.init/1` reads `:ueberauth, Ueberauth` and returns the whole
  `{{path, method} => mfa}` table. Phoenix compiles a controller's plug
  pipeline with `Phoenix.plug_init_mode/0`, which is `:compile` everywhere
  except dev — and at compile time the only value present is
  `config/config.exs`'s `providers: []`, because the real list is assembled
  in `config/runtime.exs` at boot. So calling `Ueberauth.init/1` from
  `init/1` baked an empty table into the release: every `/auth/:provider`
  fell through to `AuthController.request/2`'s 404 and every callback to its
  400, which is byte-identical to the not-configured answer and therefore
  invisible to a test that only asserts the unconfigured case. Building here
  costs one `get_env` on the sign-in path.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts), do: Ueberauth.call(conn, Ueberauth.init(opts))
end
