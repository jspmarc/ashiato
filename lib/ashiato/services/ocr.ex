defmodule Ashiato.Ocr do
  @moduledoc """
  OCR service behaviour.

  `recognise/1` takes a locator — a path or presigned URL the OCR service reads
  itself — never image bytes. Returned line boxes are normalised to 0–1000
  regardless of the frame's pixel size, so they stay comparable across inputs.
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
