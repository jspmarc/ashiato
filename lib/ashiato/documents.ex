defmodule Ashiato.Documents do
  @moduledoc """
  A PDF upload. Its pages are ordinary rows in `pages`, linked back through
  `pages.document_id` and ordered by `pages.page_index` (zero-based).
  """

  use Ecto.Schema

  schema "documents" do
    belongs_to :user, Ashiato.Users

    field :filename, :string
    field :page_count, :integer
    # when true the text is extracted, not OCRed
    field :has_text_layer, :boolean

    timestamps(type: :utc_datetime)

    has_many :pages, Ashiato.Pages, foreign_key: :document_id
  end
end
