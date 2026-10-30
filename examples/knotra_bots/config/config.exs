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

# Tribunal's live judge. The :llm_eval test is excluded from ordinary runs and
# only runs with a real provider key. Tribunal is a test-only dependency.
if config_env() == :test do
  config :tribunal, llm: "google:gemini-2.5-flash"
end

# Development-only code reloading: changed modules are recompiled before each
# request and the browser refreshes when watched files change. The endpoint reads
# :code_reloader at compile time, so this belongs here, not in runtime.exs.
if config_env() == :dev do
  config :knotra_bots, KnotraBotsWeb.Endpoint,
    code_reloader: true,
    debug_errors: true,
    check_origin: false,
    live_reload: [
      patterns: [
        ~r"priv/static/.*\.(css|js)$",
        ~r"lib/knotra_bots/.*\.ex$",
        ~r"lib/knotra_bots_web/.*\.(ex|heex)$"
      ]
    ]
end
