defmodule Ashiato.Utils do
  @moduledoc """
  Small shared helpers.
  """

  @doc """
  The current time truncated to whole seconds, matching the `:utc_datetime`
  columns.
  """
  @spec utc_now() :: DateTime.t()
  def utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
