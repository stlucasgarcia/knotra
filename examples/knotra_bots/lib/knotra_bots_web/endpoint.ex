defmodule KnotraBotsWeb.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :knotra_bots

  @session_options [
    store: :cookie,
    key: "_knotra_bots_key",
    signing_salt: "knotra_bots_session",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  # Hand-written assets only. Phoenix and LiveView ship prebuilt UMD browsers bundles
  # inside their hex packages, so no npm/esbuild/tailwind toolchain is needed.
  plug Plug.Static, at: "/assets", from: :knotra_bots, only: ~w(css js)

  plug Plug.Static,
    at: "/assets/vendor",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/assets/vendor",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  # Development only: recompile changed modules per request and let the browser
  # reload when watched files change. `phoenix_live_reload` is a dev dependency,
  # so this branch is compiled away outside development.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers, parsers: [:urlencoded, :multipart], pass: ["*/*"]
  plug Plug.MethodOverride
  plug Plug.Head

  plug Plug.Session, @session_options
  plug KnotraBotsWeb.Router
end
