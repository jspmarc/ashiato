defmodule Ashiato.Ocr do
  @moduledoc """
  OCR service behaviour.

  `recognise/1` takes a locator — a path or presigned URL the OCR service reads
  itself — never image bytes. Returned line boxes are normalised to 0–1000
  regardless of the frame's pixel size, so they stay comparable across inputs.

  ## Wire contract

  The client sends one JSON object over a Unix socket:

      {"op": "ocr", "path": "/shared/page.png"}

  or `{"op": "ocr", "url": "https://example.test/page.png"}`. The service answers
  one JSON object:

      {"lines": [{"bbox": [x1, y1, x2, y2], "text": "...", "score": 0.98}]}

  The service reads the image from the locator and returns line boxes in the
  normalised 0–1000 range.
  """

  @type locator :: {:path, String.t()} | {:url, String.t()}
  @type line :: %{bbox: [integer()], text: String.t(), score: float()}

  @callback recognise(locator) :: {:ok, [line()]} | {:error, term()}

  @doc """
  The configured implementation, from `:impl` in the `Ashiato.Ocr` application
  env. Callers depend on this behaviour, never on a concrete module.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:ashiato, __MODULE__, [])[:impl] || __MODULE__.Socket
  end
end
