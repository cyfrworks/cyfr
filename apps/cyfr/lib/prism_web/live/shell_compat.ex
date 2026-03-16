defmodule PrismWeb.ShellCompat do
  @moduledoc """
  on_mount hook that detects shell-embedded mode and sends :shell_init
  so LiveViews can load data via handle_info instead of handle_params
  (which is not called for child LiveViews rendered via live_render/3).

  Also propagates the authentication context from the parent shell session
  so child LiveViews can make MCP tool calls.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias Sanctum.Session
  alias Sanctum.Context

  def on_mount(:maybe_shell, _params, session, socket) do
    if session["shell"] do
      socket =
        socket
        |> assign(:shell_mode, true)
        |> maybe_assign_context(session)

      if connected?(socket) do
        send(self(), :shell_init)
      end

      {:cont, socket, layout: {PrismWeb.Layouts, :embedded}}
    else
      {:cont, assign(socket, :shell_mode, false)}
    end
  end

  defp maybe_assign_context(socket, session) do
    # Skip if context is already assigned (e.g. by LiveAuth)
    if socket.assigns[:context] do
      socket
    else
      case session["session_token"] && Session.get_user(session["session_token"]) do
        {:ok, user} ->
          context =
            Context.build(
              user_id: user.id,
              org_id: Map.get(user, :org_id),
              project_id: Map.get(user, :project_id),
              permissions: user.permissions,
              scope: :project,
              auth_method: :oidc,
              authenticated: true
            )

          assign(socket, :context, context)

        _ ->
          socket
      end
    end
  end
end
