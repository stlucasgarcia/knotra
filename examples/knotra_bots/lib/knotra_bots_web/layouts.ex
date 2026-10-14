defmodule KnotraBotsWeb.Layouts do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>KnotraBots</title>
        <link rel="stylesheet" href="/assets/css/app.css" />
        <script src="/assets/vendor/phoenix.min.js">
        </script>
        <script src="/assets/vendor/phoenix_live_view.min.js">
        </script>
        <script src="/assets/js/app.js">
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
