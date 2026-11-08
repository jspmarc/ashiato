defmodule Ashiato.Ocr.Fake do
  @moduledoc """
  In-memory OCR double: canned lines, configurable error, recorded requests.

  State lives in an Agent that each test starts with `start_supervised!/1`.
  """

  use Agent

  @behaviour Ashiato.Ocr

  @default_lines [
    %{bbox: [10, 20, 500, 90], text: "こんにちは", score: 0.98},
    %{bbox: [10, 110, 500, 180], text: "またあした", score: 0.95}
  ]

  @doc """
  Starts the fake.

  ## Options

    * `:lines` — canned lines `recognise/1` returns (default: two sample lines)
    * `:error` — when set, `recognise/1` returns `{:error, error}` instead
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          lines: Keyword.get(opts, :lines, @default_lines),
          error: Keyword.get(opts, :error),
          requests: []
        }
      end,
      name: __MODULE__
    )
  end

  @doc "Returns the canned lines, or the configured error."
  @spec recognise(Ashiato.Ocr.locator()) :: {:ok, [Ashiato.Ocr.line()]} | {:error, term()}
  def recognise(locator) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = %{state | requests: [locator | state.requests]}
      reply = if state.error, do: {:error, state.error}, else: {:ok, state.lines}
      {reply, state}
    end)
  end

  @doc "Locators passed to `recognise/1`, oldest first."
  @spec requests() :: [Ashiato.Ocr.locator()]
  def requests do
    Agent.get(__MODULE__, &Enum.reverse(&1.requests))
  end
end
