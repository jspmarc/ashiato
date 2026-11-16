defmodule Ashiato.TranslatorService.PruneWorker do
  @moduledoc """
  Deletes expired translation rows. Production schedules it daily at 03:00 UTC
  through `Oban.Plugins.Cron` in `config/prod.exs`; dev and test call
  `TranslatorService.prune_expired/0` or `perform/1` directly.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ashiato.TranslatorService

  @impl Oban.Worker
  def perform(_job) do
    {:ok, _deleted} = TranslatorService.prune_expired()

    :ok
  end
end
