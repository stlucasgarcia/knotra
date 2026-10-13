defmodule KnotraBots.Models.Logged do
  @moduledoc """
  Logs and contains model-plugin exceptions.

  Knotra deliberately redacts raw exception text from public records, so an
  unexpected raise would otherwise surface only as `plugin_exception`. This
  wrapper logs the exception with its stacktrace server-side and returns
  `{:error, :model_error}` to the runtime. Run `mix knotra_bots.check` for a
  one-shot diagnosis of the configured model.
  """
  require Logger

  @behaviour Knotra.Model

  # Version of the wrapped continuation shape. The ReqLLM adapter uses 1.
  @impl true
  def checkpoint_version, do: 1

  @impl true
  def call(request, opts) do
    {module, inner_opts} = Keyword.fetch!(opts, :plugin)
    module.call(request, inner_opts)
  rescue
    error ->
      Logger.error("model plugin raised: " <> Exception.format(:error, error, __STACKTRACE__))
      {:error, :model_error}
  catch
    kind, reason ->
      Logger.error("model plugin exited: " <> Exception.format(kind, reason, __STACKTRACE__))
      {:error, :model_error}
  end
end
