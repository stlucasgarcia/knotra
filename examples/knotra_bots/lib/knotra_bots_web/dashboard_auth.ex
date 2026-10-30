defmodule KnotraBotsWeb.DashboardAuth do
  @moduledoc """
  Host authorization for the observability dashboard.

  The dashboard renders execution inputs, model text and tool arguments, so it
  must not be reachable without a host decision. This demo accepts either a
  loopback request or a matching `KNOTRA_BOTS_DASHBOARD_TOKEN` (query parameter
  `token` or header `x-dashboard-token`).

  Router plugs only run on the initial HTTP request. `on_mount/4` re-checks the
  authorized session on every connected mount, including reconnects.
  """
  @behaviour Plug

  import Plug.Conn

  @loopback [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    if authorized?(conn) do
      put_session(conn, :knotra_dashboard_authorized, true)
    else
      conn |> send_resp(404, "Not found") |> halt()
    end
  end

  def on_mount(:default, _params, session, socket) do
    if session["knotra_dashboard_authorized"] == true do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  defp authorized?(conn) do
    case Application.get_env(:knotra_bots, :dashboard_token) do
      token when is_binary(token) and token != "" ->
        provided =
          conn.params["token"] ||
            case get_req_header(conn, "x-dashboard-token") do
              [value | _] -> value
              [] -> nil
            end

        is_binary(provided) and Plug.Crypto.secure_compare(provided, token)

      _ ->
        conn.remote_ip in @loopback
    end
  end
end
