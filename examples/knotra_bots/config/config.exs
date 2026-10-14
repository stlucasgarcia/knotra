import Config

config :knotra_bots,
  ecto_repos: [KnotraBots.Repo]

config :knotra_bots, KnotraBotsWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [html: KnotraBotsWeb.ErrorHTML]],
  pubsub_server: KnotraBots.PubSub,
  live_view: [signing_salt: "knotra_bots_live"]

config :logger, level: :info
