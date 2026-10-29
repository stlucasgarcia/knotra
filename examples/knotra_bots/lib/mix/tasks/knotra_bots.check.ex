defmodule Mix.Tasks.KnotraBots.Check do
  @shortdoc "Calls the configured model once to diagnose API/key failures"
  @moduledoc """
  Prints the configured model, its key status, the raw provider result and the
  result through the Knotra adapter.

  Knotra redacts raw exception text from public records and collapses provider
  errors to `:model_error`, so a chat reply that fails at `model_started` shows no
  cause. This task calls ReqLLM directly and prints the provider's reason (for
  example `API key not valid`, quota or an unavailable model):

      mix knotra_bots.check

  It starts only the model dependencies, so it works while the server is running.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req_llm)

    case KnotraBots.model_status() do
      :ok -> IO.puts("model status: ok")
      {:error, reason} -> IO.puts("model status: error — #{reason}")
    end

    {module, opts} = KnotraBots.model()
    request = %{input: "Reply with the single word: ok", exchanges: [], tools: []}

    try do
      IO.inspect(module.call(request, opts), label: "adapter call")
    rescue
      error -> IO.puts(Exception.format(:error, error, __STACKTRACE__))
    catch
      kind, reason -> IO.puts(Exception.format(kind, reason, __STACKTRACE__))
    end

    raw_provider_result(opts)
  end

  # The adapter intentionally maps every provider error to :model_error; call
  # ReqLLM directly to see the real reason. Only reason/status/message are printed,
  # never request bodies that could contain credentials.
  defp raw_provider_result(plugin: {Knotra.Models.ReqLLM, inner}) do
    case ReqLLM.generate_text(
           inner[:model],
           "Reply with the single word: ok",
           inner[:options] || []
         ) do
      {:ok, response} ->
        IO.puts("raw ReqLLM: ok — " <> inspect(ReqLLM.Response.text(response)))

      {:error, error} ->
        IO.puts("raw ReqLLM error: " <> describe(error))
    end
  end

  defp raw_provider_result(_plugin), do: :ok

  defp describe(%{reason: reason, status: status}),
    do: "#{inspect(reason)} (status #{inspect(status)})"

  defp describe(%{message: message}) when is_binary(message) and message != "", do: message
  defp describe(other), do: inspect(other, limit: 4)
end
