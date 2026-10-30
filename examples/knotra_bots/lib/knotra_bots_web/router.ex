defmodule KnotraBotsWeb.Router do
  @moduledoc false
  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import Knotra.Dashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {KnotraBotsWeb.Layouts, :root}
    plug :protect_from_forgery
  end

  scope "/", KnotraBotsWeb do
    pipe_through :browser
    live "/", ChatLive, :index
    live "/channels", ChannelsLive, :index
    live "/channels/:id", ChatLive, :show
    live "/agents", AgentsLive, :index
  end

  scope "/" do
    pipe_through [:browser, KnotraBotsWeb.DashboardAuth]

    knotra_dashboard("/observability",
      instance: KnotraBots.Instance,
      on_mount: [{KnotraBotsWeb.DashboardAuth, :default}]
    )
  end
end
