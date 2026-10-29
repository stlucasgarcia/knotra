defmodule Knotra.Dashboard do
  @moduledoc """
  Opt-in Phoenix LiveView observability dashboard for a Knotra instance.

  The dashboard is compiled only when `:phoenix_live_view` is available. Add it
  to the host application's dependencies:

      {:phoenix_live_view, "~> 1.1"}

  Then mount it inside a browser pipeline. The route must be protected by the
  host's own authentication and authorization: the dashboard renders execution
  inputs, model text, tool arguments, and tool output.

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
        import Phoenix.LiveView.Router
        import Knotra.Dashboard.Router

        scope "/" do
          pipe_through [:browser, :require_admin]

          knotra_dashboard "/knotra", instance: MyApp.Agents
        end
      end

  The dashboard reads the in-memory store owned by the Knotra instance. It shows
  executions recorded since the instance started, not durable history.
  """

  @doc "True when the LiveView modules were compiled into this build."
  def available?, do: Code.ensure_loaded?(Knotra.Dashboard.Live)

  @doc false
  def session(instance), do: %{"knotra_instance" => instance}
end

if Code.ensure_loaded?(Phoenix.LiveView.Router) do
  defmodule Knotra.Dashboard.Router do
    @moduledoc """
    Router helpers for `Knotra.Dashboard`.

    Import this module (and `Phoenix.LiveView.Router`) into a Phoenix router and
    call `knotra_dashboard/2` inside a scope with the host's auth pipeline.
    """

    @doc """
    Declares `live path, Knotra.Dashboard.Live, :index` with the instance in the
    LiveView session.

    Options:

      * `:instance` (required) - the Knotra instance name.
      * `:session_name` - the `live_session/3` name. Defaults to
        `:knotra_dashboard`; pass a distinct name for a second dashboard.
      * `:live_opts` - extra options forwarded to `live/4`.

    The macro opens a `live_session/3` because that is where Phoenix LiveView 1.x
    accepts a custom session map.
    """
    defmacro knotra_dashboard(path, opts) do
      instance = Keyword.fetch!(opts, :instance)
      session_name = Keyword.get(opts, :session_name, :knotra_dashboard)
      live_opts = Keyword.get(opts, :live_opts, [])
      live_view = {:__aliases__, [alias: false], [:Knotra, :Dashboard, :Live]}

      quote do
        live_session unquote(session_name),
          session: %{"knotra_instance" => unquote(instance)} do
          scope unquote(path), alias: false do
            live("/", unquote(live_view), :index, unquote(live_opts))
          end
        end
      end
    end
  end
end
