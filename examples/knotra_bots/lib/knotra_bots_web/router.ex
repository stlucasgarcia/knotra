defmodule KnotraBotsWeb.Router do
  @moduledoc false
  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {KnotraBotsWeb.Layouts, :root}
    plug :protect_from_forgery
  end

  scope "/", KnotraBotsWeb do
    pipe_through :browser
    live "/", DashboardLive, :index
    live "/bots", BotsLive, :index
    live "/conversations", ConversationsLive, :index
    live "/conversations/:id", ConversationLive, :show
  end
end
